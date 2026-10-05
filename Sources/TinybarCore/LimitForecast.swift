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

    /// When the window reaches 0% left at its average pace so far, if that comes before its Reset.
    /// nil when it lasts until the Reset, is already used up, or can't be forecast (no reset time
    /// or duration, or too early in the window). `asOf` is when `usedPercent` was read.
    public func runOutTime(asOf: Date) -> Date? {
        guard let resetsAt, let duration = durationSeconds, duration > 0 else { return nil }
        let length = TimeInterval(duration)
        let untilReset = resetsAt.timeIntervalSince(asOf)
        guard untilReset > 0, untilReset <= length else { return nil }
        let elapsed = length - untilReset
        guard elapsed >= length * Self.forecastMinimumElapsed else { return nil }

        let used = min(max(usedPercent, 0), 100)
        guard used > 0, used < 100 else { return nil }
        let untilEmpty = (100 - used) * elapsed / used
        return untilEmpty < untilReset ? asOf.addingTimeInterval(untilEmpty) : nil
    }
}

extension ProviderSnapshot {
    /// The window that runs out first, among those that run out before their Reset.
    public func firstRunOut(includeModelSpecific: Bool = true) -> (window: LimitWindow, at: Date)? {
        windows
            .filter { includeModelSpecific || !$0.isModelSpecific }
            .compactMap { w in w.runOutTime(asOf: fetchedAt).map { (w, $0) } }
            .min { $0.1 < $1.1 }
    }
}
