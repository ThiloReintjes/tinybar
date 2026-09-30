import AppKit
import Observation
import SubarCore

/// Per-Provider UI state: the latest snapshot plus staleness (CONTEXT.md: Stale).
struct ProviderState {
    var snapshot: ProviderSnapshot?
    var error: ProviderError?
    var lastAttempt: Date?
    var backoffUntil: Date?

    var isStale: Bool { error != nil }
}

@MainActor
@Observable
final class AppModel {
    private(set) var providers: [ProviderID: ProviderState] = [:]
    private(set) var usage: [UsageRange: UsageSummary] = [:]
    private(set) var importProgress: Double?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    let settings: Settings
    private let sources: [ProviderID: any UsageProvider]
    private let store: UsageStore?
    private let pricing = PricingService()
    private let notifier = Notifier()
    private let logWatcher = LogWatcher(roots: UsageStore.codexRoots + UsageStore.claudeRoots)
    private var alertPlanner: LimitAlertPlanner

    private var pollTimer: Timer?
    private var isAsleep = false

    static let pollInterval: TimeInterval = 5 * 60
    static let openThrottle: TimeInterval = 60

    init(settings: Settings) {
        self.settings = settings
        let browserFlags = settings.browserFallbackFlags
        sources = [
            .claude: ClaudeProvider(allowBrowser: { browserFlags.isEnabled(.claude) }),
            .codex: CodexProvider(allowBrowser: { browserFlags.isEnabled(.codex) }),
        ]
        store = try? UsageStore()
        alertPlanner = settings.loadAlertState()
        for (id, source) in sources where settings.isEnabled(id, detected: source.isConfigured()) {
            providers[id] = ProviderState()
        }
    }

    var enabledProviders: [ProviderID] { providers.keys.sorted() }

    // MARK: Lifecycle

    func start() {
        notifier.requestAuthorizationOnce()
        observeSleepAndLock()
        schedulePoll()
        Task { await refresh(force: true) }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: false) }
        }
        timer.tolerance = 30  // let macOS coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func observeSleepAndLock() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.pollTimer?.invalidate()
            }
        }
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isAsleep else { return }
                self.isAsleep = false
                self.schedulePoll()
                Task { await self.refresh(force: false) }
            }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pause)
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resume)
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause)
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resume)
    }

    // MARK: Refresh

    /// Popover opened or refresh clicked: refresh, throttled to once per minute per Provider.
    func refreshOnOpen() {
        Task { await refresh(force: false, throttle: Self.openThrottle) }
    }

    func refresh(force: Bool, throttle: TimeInterval = 0) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, ProviderError>)?.self) { group in
            for id in enabledProviders {
                guard let source = sources[id] else { continue }
                let state = providers[id] ?? ProviderState()
                if !force {
                    if let until = state.backoffUntil, until > now { continue }
                    if throttle > 0, let last = state.lastAttempt, now.timeIntervalSince(last) < throttle { continue }
                }
                providers[id, default: ProviderState()].lastAttempt = now
                group.addTask {
                    do {
                        return (id, .success(try await source.fetch()))
                    } catch let e as ProviderError {
                        return (id, .failure(e))
                    } catch {
                        return (id, .failure(.unexpected(error.localizedDescription)))
                    }
                }
            }
            for await result in group {
                guard let (id, outcome) = result else { continue }
                apply(outcome, to: id)
            }
        }
        lastUpdated = Date()
        await refreshUsage()
    }

    private func apply(_ outcome: Result<ProviderSnapshot, ProviderError>, to id: ProviderID) {
        var state = providers[id] ?? ProviderState()
        switch outcome {
        case let .success(snapshot):
            state.snapshot = snapshot
            state.error = nil
            state.backoffUntil = nil
            if settings.notificationsEnabled {
                for alert in alertPlanner.evaluate(snapshot) { notifier.send(alert) }
                settings.saveAlertState(alertPlanner)
            }
        case let .failure(error):
            state.error = error
            if case let .rateLimited(retryAfter) = error {
                state.backoffUntil = Date().addingTimeInterval(retryAfter ?? Self.pollInterval)
            }
        }
        providers[id] = state
    }

    private func refreshUsage() async {
        guard let store else { return }
        let firstImport = !((try? await store.hasCompletedInitialImport()) ?? false)
        if firstImport {
            // The first import can read gigabytes of logs. Run it in a child process so the
            // memory it churns through goes back to the OS when it exits.
            importProgress = 0
            await HistoryImport.run { [weak self] fraction in self?.importProgress = fraction }
            try? await store.markInitialImportDone()
            importProgress = nil
        }
        // Incremental ingestion runs on the store's actor, off the main thread. Only files
        // FSEvents saw change are checked; a full walk happens on launch or if events were dropped.
        switch logWatcher.drain() {
        case .all: _ = try? await store.ingestAll()
        case let .paths(paths) where !paths.isEmpty: _ = try? await store.ingestAll(only: paths)
        case .paths: break
        }

        let prices = await pricing.refreshIfNeeded()
        let rows = (try? await store.daily(since: DayKey.daysAgo(UsageRange.month.days - 1))) ?? []
        var next: [UsageRange: UsageSummary] = [:]
        for range in UsageRange.allCases {
            next[range] = UsageSummary.build(rows: rows, range: range, prices: prices)
        }
        usage = next
    }

    // MARK: Pinned Limit

    /// The window shown in the menu bar: the user's pick, else the first Provider's 5-hour
    /// window, else its weekly window (SPEC §6).
    var pinned: (ProviderID, LimitWindow)? {
        if let key = settings.pinnedLimit {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = ProviderID(rawValue: parts[0]),
               let window = providers[id]?.snapshot?.windows.first(where: { $0.id == parts[1] })
            {
                return (id, window)
            }
        }
        for id in enabledProviders {
            guard let windows = providers[id]?.snapshot?.windows else { continue }
            if let w = windows.first(where: { $0.kind == .session && !$0.isModelSpecific })
                ?? windows.first(where: { $0.kind == .weekly && !$0.isModelSpecific })
            {
                return (id, w)
            }
        }
        return nil
    }

    func pin(_ provider: ProviderID, _ window: LimitWindow) {
        settings.pinnedLimit = "\(provider.rawValue)/\(window.id)"
    }

    func isPinned(_ provider: ProviderID, _ window: LimitWindow) -> Bool {
        guard let p = pinned else { return false }
        return p.0 == provider && p.1.id == window.id
    }

    // MARK: Settings changes

    func setEnabled(_ id: ProviderID, _ enabled: Bool) {
        settings.setEnabled(id, enabled)
        if enabled {
            providers[id] = providers[id] ?? ProviderState()
            Task { await refresh(force: true) }
        } else {
            providers[id] = nil
        }
    }
}
