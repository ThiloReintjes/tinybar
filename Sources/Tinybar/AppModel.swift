import AppKit
import CoreGraphics
import Observation
import TinybarCore

/// Per-Provider UI state: its Pool's snapshot plus staleness (CONTEXT.md: Pool, Stale).
struct ProviderState {
    var snapshot: ProviderSnapshot?
    var error: ProviderError?
    var lastAttempt: Date?
    var backoffUntil: Date?
    /// Who `backoffUntil` is for, whatever the numbers were last read through.
    var backoffLogin: String?
    /// Every Account, soonest next Reset first.
    var accounts: [Account] = []
    /// Each Account's snapshot as it was read, before a Pool treats a passed Reset as full.
    var readSnapshots: [String: ProviderSnapshot] = [:]

    var isStale: Bool { error != nil }
    var hasSeveralAccounts: Bool { accounts.count > 1 }
}

@MainActor
@Observable
final class AppModel {
    private(set) var providers: [ProviderID: ProviderState] = [:]
    /// Keep Retry-After and the last attempt when a Provider is toggled off and on.
    private var disabledProviders: [ProviderID: ProviderState] = [:]
    /// Each Provider's default login, an extra login folder's Account by folder, and claude-swap's.
    /// They keep their last values when a fetch fails, and are merged into `providers`.
    private var defaultLogins: [ProviderID: Account] = [:]
    private var folderAccounts: [LoginFolder: Account] = [:]
    private var folderBackoff: [LoginFolder: Date] = [:]
    private var swapAccounts: [Account] = []
    /// Extra login folders found on this Mac, on or off.
    private(set) var loginFolders: [LoginFolder] = []
    private(set) var isClaudeSwapInstalled = false
    /// Why claude-swap's accounts couldn't be read on the last try.
    private(set) var claudeSwapError: String?
    /// All Providers together, for the overview.
    private(set) var usage: [UsageRange: UsageSummary] = [:]
    /// One Provider each, for its detail view.
    private(set) var providerUsage: [ProviderID: [UsageRange: UsageSummary]] = [:]
    /// What each subscription with token history gets you, for the Stats window's Plans page.
    private(set) var plans: [PlanRow] = []
    private var usageRows: [DailyUsage] = []
    private var prices = PriceTable.empty
    /// Open Incidents from each subscription's status page.
    private(set) var incidents: [ProviderID: [Incident]] = [:]
    private var lastStatusCheck: Date?
    private(set) var importProgress: Double?
    private(set) var lastUpdated: Date?
    var isRefreshing: Bool { isFetching || usageTask != nil }
    private var isFetching = false
    private var usageTask: Task<Void, Never>?

    let settings: Settings
    let updater = Updater()
    private let sources: [ProviderID: any UsageProvider]
    private let store: UsageStore?
    private let pricing = PricingService()
    private let notifier = Notifier()
    @ObservationIgnored private var logRoots: [URL]
    @ObservationIgnored private var logWatcher: LogWatcher
    private var alertPlanner: LimitAlertPlanner

    private var pollTimer: Timer?
    private var isAsleep = false
    private var isLocked = false
    private var pendingRefreshThrottle: TimeInterval?
    private var historyImportFailed = false
    private var initialImportFailed = false
    private var pendingIngest = LogWatcher.Changes.paths([])

    static let pollInterval: TimeInterval = 5 * 60
    static let openThrottle: TimeInterval = 60

    init(settings: Settings) {
        self.settings = settings
        logRoots = UsageStore.codexRoots + UsageStore.claudeRoots
        logWatcher = LogWatcher(roots: logRoots)
        let browserFlags = settings.browserFallbackFlags
        sources = [
            .claude: ClaudeProvider(allowBrowser: { browserFlags.isEnabled(.claude) }),
            .codex: CodexProvider(allowBrowser: { browserFlags.isEnabled(.codex) }),
            .gemini: GeminiProvider(),
            .cursor: CursorProvider(),
            .opencode: OpenCodeProvider(),
        ]
        // `TINYBAR_DB` points development runs (snapshots) at a scratch database.
        store = try? ProcessInfo.processInfo.environment["TINYBAR_DB"].map { try UsageStore(path: URL(fileURLWithPath: $0)) }
            ?? UsageStore()
        alertPlanner = settings.loadAlertState()
        loginFolders = LoginFolders.find()
        isClaudeSwapInstalled = ClaudeSwap.locate() != nil
        for (id, source) in sources
        where settings.isEnabled(id, detected: source.isConfigured() || loginFolders.contains { $0.provider == id }) {
            providers[id] = ProviderState()
        }
    }

    var enabledProviders: [ProviderID] { providers.keys.sorted() }

    // MARK: Lifecycle

    func start() {
        notifier.requestAuthorizationOnce()
        observeSleepAndLock()
        isLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if !isLocked {
            schedulePoll()
            Task { await refresh(force: true) }
        }
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
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(asleep: true) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(asleep: false) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(locked: true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(locked: false) }
        }
    }

    private func setPaused(asleep: Bool? = nil, locked: Bool? = nil) {
        let wasPaused = isAsleep || isLocked
        if let asleep { isAsleep = asleep }
        if let locked { isLocked = locked }
        if isAsleep || isLocked {
            pollTimer?.invalidate()
        } else if wasPaused {
            schedulePoll()
            if isFetching { pendingRefreshThrottle = 0 }
            else { Task { await refresh(force: false) } }
        }
    }

    // MARK: Refresh

    /// Popover opened or refresh clicked: refresh, throttled to once per minute per Provider.
    func refreshOnOpen() {
        Task { await refresh(force: false, throttle: Self.openThrottle) }
    }

    func refresh(force: Bool, throttle: TimeInterval = 0) async {
        if let task = await fetchAndStartUsage(force: force, throttle: throttle) { await task.value }
    }

    /// Network polls stay independent of a slow history import. Every caller shares one usage task.
    private func fetchAndStartUsage(force: Bool, throttle: TimeInterval) async -> Task<Void, Never>? {
        guard !isAsleep, !isLocked else { return nil }
        guard !isFetching else {
            if force { pendingRefreshThrottle = 0 }
            return nil
        }
        isFetching = true
        defer {
            isFetching = false
            if let throttle = pendingRefreshThrottle {
                pendingRefreshThrottle = nil
                Task { await refresh(force: false, throttle: throttle) }
            }
        }

        let now = Date()
        let swap = settings.readClaudeSwap ? ClaudeSwap.locate() : nil
        (loginFolders, isClaudeSwapInstalled) = await Task.detached(priority: .utility) {
            (LoginFolders.find(), ClaudeSwap.locate() != nil)
        }.value
        let folders = loginFolders.filter { settings.isLoginFolderEnabled($0) }
        folderAccounts = folderAccounts.filter { folders.contains($0.key) }
        if swap == nil {
            swapAccounts = []
            claudeSwapError = nil
        }
        for id in Set(providers.keys).union(disabledProviders.keys) { rebuild(id) }

        await withTaskGroup(of: Fetched?.self) { group in
            for id in enabledProviders {
                guard let source = sources[id] else { continue }
                let state = providers[id] ?? ProviderState()
                if !force, throttle > 0, let last = state.lastAttempt, now.timeIntervalSince(last) < throttle { continue }
                providers[id, default: ProviderState()].lastAttempt = now
                let waiting = state.backoffUntil.map { $0 > now } ?? false
                let waitingLogin = state.backoffLogin
                group.addTask {
                    let identity = source.identity()
                    // A wait is for the login that was asked to. Switched to another, it doesn't apply.
                    if waiting, Self.loginID(id, identity) == waitingLogin { return nil }
                    return .login(id, identity, await Self.result { try await source.fetch() })
                }
                for folder in folders where folder.provider == id {
                    if let until = folderBackoff[folder], until > now { continue }
                    group.addTask {
                        .folder(folder, LoginFolders.account(for: folder), await Self.result { try await folder.source.fetch() })
                    }
                }
                if id == .claude, let swap {
                    group.addTask { .swap(await Self.result { try ClaudeSwap.read(executable: swap) }) }
                }
            }
            for await result in group {
                if let result { apply(result) }
            }
        }
        sendLimitAlerts()
        guard !isAsleep, !isLocked else { return nil }
        await refreshIncidents(throttle: throttle)
        guard !isAsleep, !isLocked else { return nil }
        if let release = await updater.checkIfDue(), settings.notificationsEnabled {
            notifier.send(update: release)
        }
        guard !isAsleep, !isLocked else { return nil }
        if usageTask == nil {
            usageTask = Task {
                await refreshUsage()
                lastUpdated = Date()
                usageTask = nil
            }
        }
        return usageTask
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

    /// What one fetch brought back.
    private enum Fetched: Sendable {
        case login(ProviderID, LoginIdentity?, Result<ProviderSnapshot, ProviderError>)
        case folder(LoginFolder, Account, Result<ProviderSnapshot, ProviderError>)
        case swap(Result<[Account], ProviderError>)
    }

    private nonisolated static func result<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, ProviderError> {
        do {
            return .success(try await work())
        } catch let e as ProviderError {
            return .failure(e)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }

    private func apply(_ fetched: Fetched) {
        switch fetched {
        case let .login(id, identity, outcome):
            let asked = Self.loginID(id, identity)
            // A browser's session may be someone else's, so its numbers aren't filed under the CLI's login.
            let viaBrowser = switch outcome {
            case let .success(snapshot): snapshot.source == .browser
            case .failure: defaultLogins[id]?.snapshot?.source == .browser
            }
            let identity = viaBrowser ? nil : identity
            let found = Account(
                id: Self.loginID(id, identity),
                name: identity?.email ?? id.displayName,
                organizationName: identity?.organizationName,
                isActive: true)
            defaultLogins[id] = updated(found, last: defaultLogins[id], with: outcome)
            guard var state = providers[id] ?? disabledProviders[id] else { break }
            state.backoffUntil = retryDate(after: outcome)
            state.backoffLogin = asked
            store(state, id)
            rebuild(id)
        case let .folder(folder, found, outcome):
            // Turned off while this fetch was out.
            guard settings.isLoginFolderEnabled(folder) else { break }
            folderAccounts[folder] = updated(found, last: folderAccounts[folder], with: outcome)
            folderBackoff[folder] = retryDate(after: outcome)
            rebuild(folder.provider)
        case let .swap(outcome):
            guard settings.readClaudeSwap else { break }
            switch outcome {
            case let .success(rows):
                claudeSwapError = nil
                let last = Dictionary(swapAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                swapAccounts = rows.map { row in
                    var row = row
                    row.snapshot = row.snapshot ?? last[row.id]?.snapshot
                    return row
                }
            case let .failure(error):
                claudeSwapError = error.localizedDescription
                for i in swapAccounts.indices { swapAccounts[i].error = error }
            }
            rebuild(.claude)
        }
    }

    private nonisolated static func loginID(_ id: ProviderID, _ identity: LoginIdentity?) -> String {
        identity?.accountID ?? LoginIdentity.accountID(place: id.rawValue)
    }

    private func updated(_ found: Account, last: Account?, with outcome: Result<ProviderSnapshot, ProviderError>) -> Account {
        var account = found
        // Numbers kept after a failure must be this login's, not the one switched away from.
        if let last, last.id == account.id { account.snapshot = last.snapshot }
        switch outcome {
        case let .success(snapshot):
            account.snapshot = snapshot
            account.error = nil
        case let .failure(error):
            account.error = error
        }
        return account
    }

    /// When a rate-limited login may be asked again. A fetch only starts once any earlier wait is
    /// over, so anything else leaves nothing to wait for.
    private func retryDate(after outcome: Result<ProviderSnapshot, ProviderError>) -> Date? {
        guard case .failure(.rateLimited(let retryAfter)) = outcome else { return nil }
        return Date().addingTimeInterval(retryAfter ?? Self.pollInterval)
    }

    /// Merges a Provider's Accounts into its Pool, the default login first (SPEC §15).
    private func rebuild(_ id: ProviderID) {
        let main = defaultLogins[id]
        let rows = id == .claude ? AccountRoster.swapRows(swapAccounts, defaultLogin: main, provider: id) : []
        let folders = loginFolders.filter { $0.provider == id }.compactMap { folderAccounts[$0] }
        let accounts = AccountRoster.merge(main.map { [$0] } ?? [], folders, rows)
        let pool = Pool(provider: id, accounts: accounts)
        guard var state = providers[id] ?? disabledProviders[id] else { return }
        state.snapshot = pool.snapshot
        state.error = pool.error
        state.accounts = pool.accounts
        state.readSnapshots = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.snapshot.map { (account.id, $0) }
        })
        store(state, id)
    }

    private func store(_ state: ProviderState, _ id: ProviderID) {
        if providers[id] != nil { providers[id] = state } else { disabledProviders[id] = state }
    }

    /// Per Account, naming it when there are several. Stale Accounts have nothing new to say.
    private func sendLimitAlerts() {
        guard settings.notificationsEnabled else { return }
        for id in enabledProviders {
            guard let state = providers[id] else { continue }
            for account in state.accounts where !account.isStale {
                guard let snapshot = state.readSnapshots[account.id] else { continue }
                let name = state.hasSeveralAccounts ? account.displayName : nil
                for alert in alertPlanner.evaluate(snapshot, account: account.id, inheritsOldState: account.isActive) { notifier.send(alert, account: name) }
            }
        }
        settings.saveAlertState(alertPlanner)
    }

    private func refreshUsage() async {
        guard let store else { return }
        if !historyImportFailed {
            let firstImport = !((try? await store.hasCompletedInitialImport()) ?? false)
            var jobs: [HistoryImport.Job] = []
            if firstImport {
                jobs = [.importHistory]
            } else {
                if !((try? await store.hasCompletedStatsBackfill()) ?? true) { jobs.append(.backfillStats) }
                if !((try? await store.hasCompletedLongContextBackfill()) ?? true) { jobs.append(.backfillLongContext) }
                if !((try? await store.hasCompletedOpenCodeImport()) ?? true) { jobs.append(.importOpenCode) }
                if !((try? await store.unreadLogRoots().isEmpty) ?? true) { jobs.append(.importLogFolders) }
            }
            for job in jobs {
                guard !isAsleep, !isLocked else { return }
                importProgress = 0
                let succeeded = await HistoryImport.run(job) { [weak self] fraction in
                    guard self?.importProgress != nil else { return }
                    self?.importProgress = fraction
                }
                importProgress = nil
                if !succeeded {
                    historyImportFailed = true
                    initialImportFailed = job == .importHistory
                    break
                }
            }
        }
        guard !isAsleep, !isLocked else { return }
        // A failed initial import must not fall back to a heavy read in this process.
        // A failed backfill can wait for relaunch without stopping new usage from being counted.
        // A log folder its import didn't finish is as heavy as an initial import, so it waits too.
        if !initialImportFailed, (try? await store.unreadLogRoots().isEmpty) ?? true {
            // A login folder or `cswap run` profile that appeared gets watched and read from now on.
            let roots = UsageStore.codexRoots + UsageStore.claudeRoots
            if roots != logRoots {
                logRoots = roots
                logWatcher = LogWatcher(roots: roots)
            }
            switch (pendingIngest, logWatcher.drain()) {
            case (.all, _), (_, .all): pendingIngest = .all
            case let (.paths(old), .paths(new)): pendingIngest = .paths(old.union(new))
            }
            do {
                switch pendingIngest {
                case .all: _ = try await store.ingestAll()
                // Empty batches still perform daily ID pruning without scanning any logs.
                case let .paths(paths): _ = try await store.ingestAll(only: paths)
                }
                pendingIngest = .paths([])
            } catch {
                // Keep the drained paths for the next poll, even if no more events arrive.
            }
        }

        guard !isAsleep, !isLocked else { return }
        prices = await pricing.refreshIfNeeded()
        guard !isAsleep, !isLocked else { return }
        usageRows = (try? await store.daily(since: DayKey.daysAgo(UsageRange.month.days - 1))) ?? []
        rebuildUsage()
        await refreshPlanValues(store)
    }

    /// Notes each Account's fresh weekly reading, then works out what the plans buy (SPEC §14).
    private func refreshPlanValues(_ store: UsageStore) async {
        var readings: [ProviderID: [LimitReading]] = [:]
        for id in enabledProviders where id == .claude || id == .codex {
            guard let state = providers[id], state.snapshot != nil else { continue }
            for account in state.accounts where !account.isStale {
                if let snapshot = state.readSnapshots[account.id] { try? await store.recordLimitReadings(snapshot, account: account.id, claiming: !state.hasSeveralAccounts) }
            }
            let all = (try? await store.limitReadings(provider: id)) ?? []
            let ids = Set(state.accounts.map(\.id))
            readings[id] = state.hasSeveralAccounts || state.accounts.isEmpty
                ? all.filter { ids.contains($0.account) }
                : LimitReading.forOnly(account: state.accounts[0].id, in: all)
        }
        // Kept windows go back further than the rows held for Usage.
        let month = DayKey.daysAgo(UsageRange.month.days - 1)
        let oldest = readings.values.joined().map(\.start).min().map { DayKey.string(for: $0) }
        let since = min(oldest ?? month, month)
        let rows = since < month ? (try? await store.daily(since: since)) ?? usageRows : usageRows
        let hours = (try? await store.hourlyTokens(since: since)) ?? []
        plans = readings.keys.sorted().compactMap { id in
            guard let state = providers[id], let snapshot = state.snapshot else { return nil }
            let usage = rows.filter { $0.provider == id }, tokens = hours.filter { $0.provider == id }
            if state.hasSeveralAccounts {
                let value = PlanValue.buildPool(
                    provider: id, plans: state.accounts.map { $0.snapshot?.plan }, readings: readings[id] ?? [],
                    usage: usage, hours: tokens, prices: prices)
                return value.map { PlanRow(id: id, plan: snapshot.plan, value: $0, accounts: state.accounts.count) }
            }
            let value = PlanValue.build(
                provider: id, plan: snapshot.plan, readings: readings[id] ?? [],
                usage: usage, hours: tokens, prices: prices)
            return value.map { PlanRow(id: id, plan: snapshot.plan, value: $0) }
        }
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
            var summary = StatsSummary.build(
                usage: usage, stats: stats, allDays: days, streakDays: modelDays, range: range, model: model, prices: prices)
            if CommandLine.arguments.contains("--redact-projects") {
                for i in summary.topProjects.indices {
                    summary.topProjects[i].name = "Project \(i + 1)"
                }
            }
            return summary
        } catch {
            return nil
        }
    }

    // MARK: Pinned Limit

    /// The window shown in the menu bar: the one the user pinned, else Auto (SPEC §6).
    var pinned: (ProviderID, LimitWindow)? {
        explicitPin.map { ($0.0, $0.1) } ?? autoPinned
    }

    /// The user's pick, while its window still exists: `claude/weekly` for a Pool's window,
    /// `claude@<account>/weekly` for one Account's.
    private var explicitPin: (ProviderID, LimitWindow, Account?)? {
        guard let key = settings.pinnedLimit else { return nil }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = owner.first, let id = ProviderID(rawValue: name), let state = providers[id] else { return nil }
        if owner.count == 2 {
            guard let account = state.accounts.first(where: { $0.id == owner[1] }),
                  let window = account.snapshot?.windows.first(where: { $0.id == parts[1] })
            else { return nil }
            return (id, window, account)
        }
        return state.snapshot?.windows.first { $0.id == parts[1] }.map { (id, $0, nil) }
    }

    /// The Account whose window the menu bar shows, when it's one Account's rather than a Pool's.
    var pinnedAccount: Account? { explicitPin?.2 }

    /// Whether what the menu bar shows is out of date.
    var isPinnedStale: Bool {
        if let account = pinnedAccount { return account.isStale }
        return pinned.map { providers[$0.0]?.isStale ?? false } ?? false
    }

    /// Whether the menu bar follows Auto rather than a pinned window.
    var isAuto: Bool { explicitPin == nil }

    /// Auto: of every Pool's windows that aren't model-specific, the one that runs out first before
    /// its Reset; if none does, the one with the least left. Stale Pools only count when nothing else
    /// is known.
    private var autoPinned: (ProviderID, LimitWindow)? {
        func candidates(stale: Bool) -> [(ProviderID, LimitWindow, Date?)] {
            enabledProviders.flatMap { id -> [(ProviderID, LimitWindow, Date?)] in
                guard let state = providers[id], state.isStale == stale, let snapshot = state.snapshot else { return [] }
                return snapshot.windows.filter { !$0.isModelSpecific }.map { w in
                    let runOut = stale ? nil : w.runOutTime(asOf: snapshot.fetchedAt).flatMap { w.runsOutBeforeReset($0) ? $0 : nil }
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

    /// Pins a Pool's window, or with `account` one Account's; clicking the pinned window again goes
    /// back to Auto.
    func pin(_ provider: ProviderID, _ window: LimitWindow, account: Account? = nil) {
        let key = "\(provider.rawValue)\(account.map { "@\($0.id)" } ?? "")/\(window.id)"
        settings.pinnedLimit = !isAuto && isPinned(provider, window, account: account) ? nil : key
    }

    func isPinned(_ provider: ProviderID, _ window: LimitWindow, account: Account? = nil) -> Bool {
        guard let p = pinned else { return false }
        // A pin on an Account that is now the only one still shows on its page.
        let sameOwner = pinnedAccount?.id == account?.id || providers[provider]?.hasSeveralAccounts != true
        return p.0 == provider && p.1.id == window.id && sameOwner
    }

    // MARK: Settings changes

    func setLoginFolder(_ folder: LoginFolder, enabled: Bool) {
        settings.setLoginFolder(folder, enabled: enabled)
        if !enabled {
            folderAccounts[folder] = nil
            rebuild(folder.provider)
        }
        Task { await refresh(force: true) }
    }

    func setReadClaudeSwap(_ enabled: Bool) {
        settings.readClaudeSwap = enabled
        if !enabled {
            swapAccounts = []
            claudeSwapError = nil
            rebuild(.claude)
        }
        Task { await refresh(force: true) }
    }

    /// Whether the Claude page offers to show claude-swap's Accounts.
    var offersClaudeSwap: Bool {
        isClaudeSwapInstalled && !settings.readClaudeSwap && !settings.claudeSwapHintDismissed
    }

    /// Snapshots only: reads the logs without asking any Provider for limits.
    func refreshUsageForSnapshot() async {
        await refreshUsage()
        lastUpdated = Date()
    }

    /// Snapshots only: stands in for logins on this Mac. `readings` are the Pool's weekly shares,
    /// priced with the real logs for the Plans page.
    func showForSnapshot(defaults: [ProviderID: Account], folders: [LoginFolder: Account], swap: [Account], readings: [LimitReading]) {
        defaultLogins.merge(defaults) { _, new in new }
        folderAccounts = folders
        loginFolders = folders.keys.sorted { $0.id < $1.id }
        swapAccounts = swap
        isClaudeSwapInstalled = true
        settings.savesChanges = false
        settings.readClaudeSwap = !swap.isEmpty
        settings.claudeSwapHintDismissed = !swap.isEmpty
        for id in defaults.keys { providers[id] = providers[id] ?? ProviderState() }
        for id in Set(providers.keys) { rebuild(id) }
        guard let accounts = providers[.claude]?.accounts, accounts.count > 1 else { return }
        let value = PlanValue.buildPool(
            provider: .claude, plans: accounts.map { $0.snapshot?.plan }, readings: readings,
            usage: usageRows.filter { $0.provider == .claude }, hours: [], prices: prices)
        plans = (value.map { [PlanRow(id: .claude, plan: providers[.claude]?.snapshot?.plan, value: $0, accounts: accounts.count)] } ?? [])
            + plans.filter { $0.id != .claude }
    }

    func setEnabled(_ id: ProviderID, _ enabled: Bool) {
        settings.setEnabled(id, enabled)
        if enabled {
            providers[id] = providers[id] ?? disabledProviders.removeValue(forKey: id) ?? ProviderState()
            if isFetching { pendingRefreshThrottle = pendingRefreshThrottle ?? Self.openThrottle }
            else { Task { await refresh(force: false, throttle: Self.openThrottle) } }
        } else if let state = providers.removeValue(forKey: id) {
            disabledProviders[id] = state
        }
    }
}
