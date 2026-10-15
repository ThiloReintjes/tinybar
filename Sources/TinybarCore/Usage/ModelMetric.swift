import Foundation

/// A per-model figure the Models and Commands pages rank models by (SPEC §13). Each needs a
/// minimum of data before a model is ranked, so a model tried once doesn't top a chart.
public enum ModelMetric: String, CaseIterable, Sendable {
    case speed, responsesPerPrompt, agentPerPrompt, parallel, linesPerPrompt, peakContext
    case pipedHeadTail, grep, inline, commandLength, failed, gitStatusPerCommit

    public static let minimumPrompts: Int64 = 10
    public static let minimumResponses: Int64 = 50
    public static let minimumCommands: Int64 = 30
    public static let minimumSearches: Int64 = 20
    public static let minimumCommits: Int64 = 5

    /// The model's figure, or nil with too little data.
    public func value(_ m: StatsSummary.Model) -> Double? {
        let prompts = m.value(StatKey.prompts), commands = m.value(StatKey.commands)
        func per(_ n: Int64, _ d: Int64, minimum: Int64) -> Double? {
            d >= minimum && d > 0 ? Double(n) / Double(d) : nil
        }
        switch self {
        case .speed: return m.speed
        case .responsesPerPrompt: return per(m.responses, prompts, minimum: Self.minimumPrompts)
        case .agentPerPrompt: return per(m.value(StatKey.agentMillis), prompts, minimum: Self.minimumPrompts)
        case .parallel: return per(m.value(StatKey.parallel), m.responses, minimum: Self.minimumResponses)
        case .linesPerPrompt: return per(m.value(StatKey.linesAdded), prompts, minimum: Self.minimumPrompts)
        case .peakContext: return m.peakContext > 0 ? Double(m.peakContext) : nil
        case .pipedHeadTail: return per(m.value(StatKey.pipedHeadTail), commands, minimum: Self.minimumCommands)
        case .grep:
            let grep = m.value(StatKey.program("grep"))
            return per(grep, grep + m.value(StatKey.program("rg")), minimum: Self.minimumSearches)
        case .inline:
            return per(m.value(StatKey.inlinePython) + m.value(StatKey.inlineJS), commands, minimum: Self.minimumCommands)
        case .commandLength: return per(m.value(StatKey.commandChars), commands, minimum: Self.minimumCommands)
        case .failed: return per(m.value(StatKey.commandsFailed), m.value(StatKey.commandsFinished), minimum: Self.minimumCommands)
        case .gitStatusPerCommit:
            return per(m.value(StatKey.git("status")), m.value(StatKey.git("commit")), minimum: Self.minimumCommits)
        }
    }

    /// For `inline`, the Python share of the value; the rest is JavaScript.
    public func pythonPart(_ m: StatsSummary.Model) -> Double? {
        guard self == .inline, let v = value(m), v > 0 else { return nil }
        let py = Double(m.value(StatKey.inlinePython)), js = Double(m.value(StatKey.inlineJS))
        return v * py / max(py + js, 1)
    }

    /// Models with enough data, highest first.
    public func ranked(_ models: [StatsSummary.Model]) -> [(model: StatsSummary.Model, value: Double)] {
        models.compactMap { m in value(m).map { (m, $0) } }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.model.tokens > $1.model.tokens }
    }
}
