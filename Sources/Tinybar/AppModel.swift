import AppKit
import Observation
import TinybarCore

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
    /// All Providers together, for the overview.
    private(set) var usage: [UsageRange: UsageSummary] = [:]
    /// One Provider each, for its detail view.
    private(set) var providerUsage: [ProviderID: [UsageRange: UsageSummary]] = [:]
    private var usageRows: [DailyUsage] = []
    private var prices = PriceTable.empty
    /// Open Incidents from each subscription's status page.
    private(set) var incidents: [ProviderID: [Incident]] = [:]
    private var lastStatusCheck: Date?
    private(set) var importProgress: Double?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    let settings: Settings
    let updater = Updater()
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
            .gemini: GeminiProvider(),
            .cursor: CursorProvider(),
        ]
        // `TINYBAR_DB` points development runs (snapshots) at a scratch database.
        store = try? ProcessInfo.processInfo.environment["TINYBAR_DB"].map { try UsageStore(path: URL(fileURLWithPath: $0)) }
            ?? UsageStore()
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
        await refreshIncidents(throttle: throttle)
        if let release = await updater.checkIfDue(), settings.notificationsEnabled {
            notifier.send(update: release)
        }
        await refreshUsage()
    }

    /// Reads the status pages of the enabled subscriptions that have one. A page that can't be
    /// read keeps its last answer.
    private func refreshIncidents(throttle: TimeInterval) async {
        let now = Date()
        if let last = lastStatusCheck, last > now || (throttle > 0 && now.timeIntervalSince(last) < throttle) { return }
        lastStatusCheck = now
        let ids = enabledProviders.filter(StatusFeed.hasFeed)
        await withTaskGroup(of: (ProviderID, [Incident]?).self) { group in
            for id in ids {
                group.addTask { (id, try? await StatusFeed.fetch(id)) }
            }
            for await (id, found) in group {
                if let found { incidents[id] = found }
            }
        }
        for id in incidents.keys where !ids.contains(id) { incidents[id] = nil }
    }

    /// Snapshots only: shows an Incident without a real one.
    func showForSnapshot(_ incident: Incident) {
        incidents[incident.provider] = [incident]
        lastStatusCheck = .distantFuture
    }

    /// The worst Incident that disrupts a subscription (maintenance doesn't), for the menu bar.
    var disruption: Incident? {
        enabledProviders.compactMap { incidents[$0]?.first }.filter { $0.severity >= .degraded }.max { $0.severity < $1.severity }
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
            await HistoryImport.run(.importHistory) { [weak self] fraction in self?.importProgress = fraction }
            try? await store.markInitialImportDone()
            // That import counted activity and long requests too.
            try? await store.markStatsBackfillDone()
            try? await store.markLongContextBackfillDone()
            importProgress = nil
        } else if !((try? await store.hasCompletedStatsBackfill()) ?? true) {
            // Upgraded from a version without Stats: count activity in the logs read so far, once.
            importProgress = 0
            await HistoryImport.run(.backfillStats) { [weak self] fraction in self?.importProgress = fraction }
            try? await store.markStatsBackfillDone()
            importProgress = nil
        }
        if !((try? await store.hasCompletedLongContextBackfill()) ?? true) {
            // Upgraded to Long-context Prices: file the long Codex requests already read, once.
            importProgress = 0
            await HistoryImport.run(.backfillLongContext) { [weak self] fraction in self?.importProgress = fraction }
            try? await store.markLongContextBackfillDone()
            importProgress = nil
        }
        // Incremental ingestion runs on the store's actor, off the main thread. Only files
        // FSEvents saw change are checked; a full walk happens on launch or if events were dropped.
        switch logWatcher.drain() {
        case .all: _ = try? await store.ingestAll()
        case let .paths(paths) where !paths.isEmpty: _ = try? await store.ingestAll(only: paths)
        case .paths: break
        }

        prices = await pricing.refreshIfNeeded()
        usageRows = (try? await store.daily(since: DayKey.daysAgo(UsageRange.month.days - 1))) ?? []
        rebuildUsage()
    }

    /// Recomputes summaries from the in-memory 30-day rows (a few thousand at most), so opening
    /// a detail view needs no database access.
    private func rebuildUsage() {
        func summaries(_ rows: [DailyUsage]) -> [UsageRange: UsageSummary] {
            Dictionary(uniqueKeysWithValues: UsageRange.allCases.map {
                ($0, UsageSummary.build(rows: rows, range: $0, prices: prices))
            })
        }
        usage = summaries(usageRows)
        var perProvider: [ProviderID: [UsageRange: UsageSummary]] = [:]
        for id in Set(usageRows.map(\.provider)) {
            perProvider[id] = summaries(usageRows.filter { $0.provider == id })
        }
        providerUsage = perProvider
    }

    // MARK: Stats

    /// Opens the Stats window; set by the status item, which owns the window and the popover.
    @ObservationIgnored var openStats: () -> Void = {}

    /// Reads what the Stats window shows for a range. Only runs while that window is open; nothing
    /// is kept afterwards.
    func statsSummary(_ range: StatsRange, model: String? = nil) async -> StatsSummary? {
        guard let store else { return nil }
        let since = range.days.map { DayKey.daysAgo($0 - 1) } ?? "0000"
        do {
            let usage = try await store.daily(since: since)
            let stats = try await store.stats(since: since)
            // All time starts at the first day of any model, so the model list stays complete.
            let days = try await store.activeDays()
            let modelDays = model == nil ? nil : try await store.activeDays(model: model)
            return StatsSummary.build(
                usage: usage, stats: stats, allDays: days, streakDays: modelDays, range: range, model: model, prices: prices)
        } catch {
            return nil
        }
    }

    // MARK: Pinned Limit

    /// The window shown in the menu bar: the one the user pinned, else Auto (SPEC §6).
    var pinned: (ProviderID, LimitWindow)? {
        explicitPin ?? autoPinned
    }

    /// The user's pick, while its window still exists.
    private var explicitPin: (ProviderID, LimitWindow)? {
        guard let key = settings.pinnedLimit else { return nil }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = ProviderID(rawValue: parts[0]),
              let window = providers[id]?.snapshot?.windows.first(where: { $0.id == parts[1] })
        else { return nil }
        return (id, window)
    }

    /// Whether the menu bar follows Auto rather than a pinned window.
    var isAuto: Bool { explicitPin == nil }

    /// Auto: of every subscription's account-wide windows, the one that runs out first before its
    /// Reset; if none does, the one with the least left. Stale subscriptions only count when
    /// nothing else is known.
    private var autoPinned: (ProviderID, LimitWindow)? {
        func candidates(stale: Bool) -> [(ProviderID, LimitWindow, Date?)] {
            enabledProviders.flatMap { id -> [(ProviderID, LimitWindow, Date?)] in
                guard let state = providers[id], state.isStale == stale, let snapshot = state.snapshot else { return [] }
                return snapshot.windows.filter { !$0.isModelSpecific }.map { w in
                    let runOut = w.runOutTime(asOf: snapshot.fetchedAt).flatMap { w.runsOutBeforeReset($0) ? $0 : nil }
                    return (id, w, runOut)
                }
            }
        }
        let fresh = candidates(stale: false)
        let all = fresh.isEmpty ? candidates(stale: true) : fresh
        if let first = all.filter({ $0.2 != nil }).min(by: { $0.2! < $1.2! }) { return (first.0, first.1) }
        return all.min {
            ($0.1.remainingPercent, $0.1.resetsAt ?? .distantFuture) < ($1.1.remainingPercent, $1.1.resetsAt ?? .distantFuture)
        }.map { ($0.0, $0.1) }
    }

    /// Pins a window; clicking the pinned window again goes back to Auto.
    func pin(_ provider: ProviderID, _ window: LimitWindow) {
        let key = "\(provider.rawValue)/\(window.id)"
        settings.pinnedLimit = settings.pinnedLimit == key && !isAuto ? nil : key
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
