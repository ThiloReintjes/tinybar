import Foundation

/// Counters derived from Claude Code and Codex logs beyond token counts: what the agents did
/// (tool calls, lines changed, compactions) and how long it took (Agent Time, Output Speed).
/// Stored per (day, Provider, model, key) as plain sums or maxima, so a new stat needs no schema
/// change (SPEC §9).
public enum StatKey {
    /// Model responses. Per model.
    public static let responses = "responses"
    /// Prompts the user typed. Model "".
    public static let prompts = "prompts"
    /// `tool.<name>`: tool calls by normalized tool name. Per model (Claude) or "" (Codex).
    public static let toolPrefix = "tool."
    public static let linesAdded = "lines.added"
    public static let linesRemoved = "lines.removed"
    public static let compactions = "compactions"
    /// Tokens a Claude compaction summarized away (context before minus after).
    public static let compactedTokens = "compacted.tokens"
    /// Largest context one response read (input plus cache). Stored as a maximum. Per model.
    public static let contextMax = "context.max"
    /// Output Speed samples: output tokens, milliseconds and sample count. Per model.
    public static let speedTokens = "speed.tokens"
    public static let speedMillis = "speed.ms"
    public static let speedSamples = "speed.n"
    /// Agent Time in milliseconds.
    public static let agentMillis = "agent.ms"
    /// `hour.<HH>`: responses started in that local hour. Model "".
    public static let hourPrefix = "hour."

    public static func tool(_ name: String) -> String { toolPrefix + name }
    public static func hour(_ h: Int) -> String { hourPrefix + String(format: "%02d", h) }

    /// Keys stored as maxima rather than sums.
    public static func isMaximum(_ key: String) -> Bool { key == contextMax }
}

/// Output Speed sampling rules (SPEC §13). Short responses are dominated by the wait for the first
/// token, so they would measure latency rather than speed.
public enum SpeedSample {
    public static let minimumOutputTokens: Int64 = 200
    public static let durationRange: ClosedRange<Int64> = 1_000...600_000

    public static func accepts(outputTokens: Int64, millis: Int64) -> Bool {
        outputTokens >= minimumOutputTokens && durationRange.contains(millis)
    }
}

/// Agent Time rules (SPEC §13): a pause longer than this between two steps of a turn is someone
/// waiting (on a permission prompt, a sleeping laptop), not the agent working.
public enum AgentTime {
    public static let maximumStepMillis: Int64 = 30 * 60 * 1000
}

/// One counted fact from a log line, before it is attributed to a day.
public struct StatEvent: Sendable, Equatable {
    public var timestamp: Date
    public var values: [String: Int64]

    public init(timestamp: Date, values: [String: Int64]) {
        self.timestamp = timestamp
        self.values = values
    }
}

/// What a tool call did, for display. Raw tool names stay in the database so the grouping can
/// change without re-reading logs.
public enum ToolCategory: String, CaseIterable, Sendable {
    case shell, edit, read, search, web, subagent, mcp, other

    public var label: String {
        switch self {
        case .shell: "Shell commands"
        case .edit: "File edits"
        case .read: "File reads"
        case .search: "Code searches"
        case .web: "Web lookups"
        case .subagent: "Subagents"
        case .mcp: "MCP tools"
        case .other: "Other"
        }
    }

    public init(tool name: String) {
        switch name {
        case "Bash", "BashOutput", "KillShell", "Shell": self = .shell
        case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .edit
        case "Read", "NotebookRead": self = .read
        case "Grep", "Glob", "LS", "ToolSearch": self = .search
        case "WebSearch", "WebFetch", "Web": self = .web
        case "Agent", "Task": self = .subagent
        case "MCP": self = .mcp
        default: self = .other
        }
    }
}

public enum ToolName {
    /// MCP tools carry a server id in their name (`mcp__<server>__<tool>`); they are stored as "MCP"
    /// so nothing identifying a server lands on disk.
    public static func normalize(_ raw: String) -> String {
        if raw.hasPrefix("mcp__") || raw.contains("__") { return "MCP" }
        return raw.isEmpty ? "Other" : raw
    }
}

public enum LineCount {
    /// Lines in a file's content, counting a last line without a trailing newline.
    public static func lines(in text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        var n: Int64 = 0
        for b in text.utf8 where b == 0x0A { n += 1 }
        return text.utf8.last == 0x0A ? n : n + 1
    }

    /// Added and removed lines in a unified diff or Codex patch. `---`/`+++` file headers before
    /// the first hunk are skipped; inside a hunk they are content (a removed `-- comment`).
    public static func diff(_ patch: String) -> (added: Int64, removed: Int64) {
        var added: Int64 = 0, removed: Int64 = 0
        var inHunk = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { inHunk = true; continue }
            if !inHunk, line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    /// Lines in Claude Code's `structuredPatch` hunks (`[{"lines": ["+a", "-b", " c"]}]`).
    public static func hunks(_ hunks: [[String: Any]]) -> (added: Int64, removed: Int64) {
        var added: Int64 = 0, removed: Int64 = 0
        for hunk in hunks {
            for line in hunk["lines"] as? [String] ?? [] {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }
}

extension Date {
    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
