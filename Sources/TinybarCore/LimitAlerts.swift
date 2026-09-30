import Foundation

/// Decides which Limit Alerts to send (SPEC §8). Pure logic; the app delivers them.
///
/// Scope: 5-hour and weekly windows. Thresholds 90% and 95%, each once per window cycle.
/// A Reset is announced only if that cycle crossed 90%. A cycle is identified by its reset time,
/// so state survives restarts and never repeats within one cycle.
public struct LimitAlertPlanner: Codable, Sendable, Equatable {
    public enum Alert: Sendable, Equatable {
        case threshold(provider: ProviderID, window: String, percent: Int, resetsAt: Date?)
        case reset(provider: ProviderID, window: String)
    }

    public static let thresholds = [90, 95]

    struct CycleState: Codable, Sendable, Equatable {
        var resetsAt: Date?
        var notified: Set<Int>
    }

    /// Keyed by "provider/windowID".
    var cycles: [String: CycleState] = [:]

    public init() {}

    public mutating func evaluate(_ snapshot: ProviderSnapshot, now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        for w in snapshot.windows where !w.isModelSpecific && (w.kind == .session || w.kind == .weekly) {
            let key = "\(snapshot.provider.rawValue)/\(w.id)"
            var state = cycles[key] ?? CycleState(resetsAt: w.resetsAt, notified: [])

            if Self.isNewCycle(previous: state.resetsAt, current: w.resetsAt, now: now) {
                if state.notified.contains(90) {
                    alerts.append(.reset(provider: snapshot.provider, window: w.title))
                }
                state = CycleState(resetsAt: w.resetsAt, notified: [])
            }
            state.resetsAt = w.resetsAt

            // Only the highest newly crossed threshold, so a jump to 97% sends one alert.
            let crossed = Self.thresholds.filter { Double($0) <= w.usedPercent && !state.notified.contains($0) }
            if let top = crossed.max() {
                alerts.append(.threshold(provider: snapshot.provider, window: w.title, percent: top, resetsAt: w.resetsAt))
                state.notified.formUnion(crossed)
            }
            cycles[key] = state
        }
        return alerts
    }

    /// A reset time that moved forward by more than a few minutes, or one that has passed, is a new cycle.
    static func isNewCycle(previous: Date?, current: Date?, now: Date) -> Bool {
        guard let previous else { return false }
        if let current, current.timeIntervalSince(previous) > 5 * 60 { return true }
        return current == nil && previous <= now
    }
}
