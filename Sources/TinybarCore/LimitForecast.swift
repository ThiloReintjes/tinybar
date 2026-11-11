import Foundation

/// When a Limit Window runs out at its current pace (see CONTEXT.md: Run-out Time).
///
/// The pace is the window's own average: the share used so far, divided by the time since the
/// window opened (its reset minus its duration). The average includes the idle hours and nights
/// that will recur before the reset, so it needs no stored history, and one quiet or busy poll
/// barely moves it.
extension LimitWindow {
    /// Before this share of the window has passed, a forecast is mostly noise from 1% steps.
    public static let forecastMinimumElapsed = 0.05

    /// When the window reaches 0% left at its average pace so far, even if that comes after its
    /// Reset (then it lasts until the Reset). nil when it's untouched, already used up, or
    /// can't be forecast (no reset time or duration, or too early in the window). `asOf` is when
    /// `usedPercent` was read.
    public func runOutTime(asOf: Date) -> Date? {
        // A Pool's Accounts don't start or end their windows together, so it has no one pace.
        guard poolRefill == nil, let resetsAt, let duration = durationSeconds, duration > 0 else { return nil }
        let length = TimeInterval(duration)
        let untilReset = resetsAt.timeIntervalSince(asOf)
        guard untilReset > 0, untilReset <= length else { return nil }
        let elapsed = length - untilReset
        guard elapsed >= length * Self.forecastMinimumElapsed else { return nil }

        let used = min(max(usedPercent, 0), 100)
        guard used > 0, used < 100 else { return nil }
        return asOf.addingTimeInterval((100 - used) * elapsed / used)
    }

    /// Whether a Run-out Time comes before this window's Reset, so the limit actually binds.
    public func runsOutBeforeReset(_ runOut: Date) -> Bool {
        resetsAt.map { runOut < $0 } ?? false
    }

    /// How much less is used than an even pace would have used by now: the share of the window
    /// passed minus the share used. nil unless the window lasts until its Reset.
    public func reservePercent(asOf: Date) -> Double? {
        guard let runOut = runOutTime(asOf: asOf), !runsOutBeforeReset(runOut),
            let resetsAt, let duration = durationSeconds else { return nil }
        let length = TimeInterval(duration)
        return (length - resetsAt.timeIntervalSince(asOf)) / length * 100 - usedPercent
    }
}

extension ProviderSnapshot {
    /// The window that runs out first, among those that run out before their Reset.
    public func firstRunOut(includeModelSpecific: Bool = true) -> (window: LimitWindow, at: Date)? {
        windows
            .filter { includeModelSpecific || !$0.isModelSpecific }
            .compactMap { w in w.runOutTime(asOf: fetchedAt).map { (w, $0) } }
            .filter { $0.0.runsOutBeforeReset($0.1) }
            .min { $0.1 < $1.1 }
    }
}

/// What the menu bar shows when no window is pinned (see CONTEXT.md: Pinned Limit, SPEC §6).
public enum AutoLimit {
    /// One Provider as Auto sees it: its Pool's snapshot, and whether every Account of it is Stale.
    public struct Pool: Sendable {
        public var provider: ProviderID
        public var snapshot: ProviderSnapshot
        public var isStale: Bool

        public init(provider: ProviderID, snapshot: ProviderSnapshot, isStale: Bool) {
            self.provider = provider
            self.snapshot = snapshot
            self.isStale = isStale
        }
    }

    /// Of every Pool's windows that aren't model-specific, the one that runs out first before its
    /// Reset; if none does, the one with the least left (ties: the earlier Reset). Stale Pools only
    /// count when nothing else is known. A Pool with a window used up can't be used until that
    /// Reset, so it only counts when every other Pool is used up too: the menu bar follows what
    /// can still be used, not a 0% that stays put for days. With every Pool used up, it shows the
    /// one usable again first: the Pool whose last used-up window resets soonest, by that window.
    public static func pick(_ pools: [Pool]) -> (provider: ProviderID, window: LimitWindow)? {
        let known = pools.filter { $0.snapshot.windows.contains { !$0.isModelSpecific } }
        let fresh = known.filter { !$0.isStale }
        let current = fresh.isEmpty ? known : fresh
        let open = current.filter { !$0.snapshot.isUsedUp }
        guard !open.isEmpty else { return firstBack(current) }

        // A Stale Pool's pace is out of date, so it has no Run-out Time here.
        let runningOut = open.filter { !$0.isStale }.compactMap { pool in
            pool.snapshot.firstRunOut(includeModelSpecific: false)
                .map { (provider: pool.provider, window: $0.window, at: $0.at) }
        }
        if let first = runningOut.min(by: { $0.at < $1.at }) { return (first.provider, first.window) }

        let windows = open.flatMap { pool in
            pool.snapshot.windows.filter { !$0.isModelSpecific }.map { (provider: pool.provider, window: $0) }
        }
        return windows.min {
            ($0.window.remainingPercent, $0.window.resetsAt ?? .distantFuture)
                < ($1.window.remainingPercent, $1.window.resetsAt ?? .distantFuture)
        }
    }

    /// A used-up Pool comes back when the last of its used-up windows resets; a window with no
    /// known Reset never does.
    private static func firstBack(_ pools: [Pool]) -> (provider: ProviderID, window: LimitWindow)? {
        func reset(_ window: LimitWindow) -> Date { window.resetsAt ?? .distantFuture }
        return pools.compactMap { pool in
            pool.snapshot.usedUpWindows.max { reset($0) < reset($1) }.map { (provider: pool.provider, window: $0) }
        }.min { reset($0.window) < reset($1.window) }
    }
}

extension ProviderSnapshot {
    /// Whether a window that isn't model-specific has nothing left, which blocks the whole
    /// Provider (or, for a Pool, every Account of it) until its Reset.
    public var isUsedUp: Bool { !usedUpWindows.isEmpty }

    var usedUpWindows: [LimitWindow] {
        windows.filter { !$0.isModelSpecific && $0.remainingPercent <= 0 }
    }
}
