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
    /// Reset (which shows how much headroom is left). nil when it's untouched, already used up, or
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
