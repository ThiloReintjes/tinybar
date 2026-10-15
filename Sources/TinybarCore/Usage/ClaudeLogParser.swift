import Foundation

/// Parser for Claude Code transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Claude Code writes an `assistant` line per content block of a response while it streams,
/// all sharing one `message.id`: early copies carry partial or zero usage, the last one the
/// final counts. So a message's usage is not known from any single line. We keep the latest
/// usage per `message.id` and let the store count it once, replacing earlier counts.
///
/// The same `message.id` also recurs across files when a session is resumed or forked (the
/// history is copied into the new transcript), so de-duplication is global, not per file.
public enum ClaudeLogParser {
    public struct Entry: Sendable, Equatable {
        public var messageID: String
        public var record: UsageRecord
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    public static func parse(line: UnsafeRawBufferPointer) -> Entry? {
        // Cheap filter first: only assistant lines carry usage.
        guard let base = line.baseAddress,
              assistantMarker.withUnsafeBytes({ memmem(base, line.count, $0.baseAddress!, $0.count) }) != nil
        else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        return entry(obj)
    }

    static func entry(_ obj: [String: Any]) -> Entry? {
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let id = message["id"] as? String,
              let usage = message["usage"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(parseISODate)
        else { return nil }

        let model = message["model"] as? String ?? "unknown"
        // Placeholder responses Claude Code synthesizes locally (errors, interrupts).
        guard model != "<synthetic>" else { return nil }

        func int(_ key: String) -> Int64 { (usage[key] as? NSNumber)?.int64Value ?? 0 }
        let tokens = TokenCounts(
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheWrite: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens"))
        return Entry(
            messageID: id,
            record: UsageRecord(timestamp: ts, model: model, cwd: obj["cwd"] as? String, tokens: tokens))
    }

    // MARK: Activity

    /// A tool call issued by an assistant message, deduplicated by its block id.
    public struct ToolUse: Sendable, Equatable {
        public var id: String
        public var name: String
    }

    /// What one transcript line adds beyond tokens.
    public enum Event: Sendable, Equatable {
        /// An assistant line: its usage plus the tool calls and timing it carries.
        case message(Message)
        /// A prompt the user typed (not a tool result, injected context or notification).
        case prompt(id: String, at: Date)
        /// A file edit's result, keyed by the tool call's id.
        case edit(id: String, at: Date, added: Int64, removed: Int64)
        case compaction(id: String, at: Date, droppedTokens: Int64)
    }

    public struct Message: Sendable, Equatable {
        public var entry: Entry
        public var tools: [ToolUse]
        public var at: Date
        /// When the request for this response was sent (the last user line before it).
        public var request: Date?
        /// When the agent's step that ends with this response began: the prompt for a turn's first
        /// response, otherwise the previous response (so tool execution counts as agent time).
        public var stepStart: Date?
    }

    /// Per-file reading state, Codable so ingestion can resume at a byte offset. Timing needs the
    /// lines before a response, which may have been read in an earlier ingest.
    public struct Session: Sendable, Codable, Equatable {
        var lastUser: Date?
        var lastUserWasPrompt = false
        var lastAssistant: Date?
        var current: String?
        var currentRequest: Date?
        var currentStepStart: Date?
        /// Subagent transcripts live in their own files under `subagents/`. Older Claude Code
        /// versions interleaved subagent lines into the main transcript, where they can't be timed.
        var subagentFile = false

        public init(subagentFile: Bool = false) {
            self.subagentFile = subagentFile
        }

        private static let userMarker = Data(#""type":"user""#.utf8)
        private static let compactMarker = Data(#""compact_boundary""#.utf8)
        private static let toolResultMarker = Data(#""type":"tool_result""#.utf8)
        private static let patchMarker = Data(#""structuredPatch""#.utf8)
        private static let sidechainMarker = Data(#""isSidechain":true"#.utf8)

        public mutating func consume(line: UnsafeRawBufferPointer) -> Event? {
            guard let base = line.baseAddress else { return nil }
            func has(_ marker: Data) -> Bool {
                marker.withUnsafeBytes { memmem(base, line.count, $0.baseAddress!, $0.count) } != nil
            }
            if has(ClaudeLogParser.assistantMarker) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      obj["type"] as? String == "assistant"
                else { return nil }
                return assistant(obj)
            }
            if has(Self.userMarker) {
                if has(Self.toolResultMarker), !has(Self.patchMarker) {
                    // A tool result that isn't an edit: only its time matters, and its output can be
                    // large. The first `"timestamp"` is the line's own (results come after it).
                    guard let at = CodexLogParser.stringField("timestamp", in: Data(line)).flatMap(parseISODate) else { return nil }
                    if subagentFile || !has(Self.sidechainMarker) {
                        lastUser = at
                        lastUserWasPrompt = false
                    }
                    return nil
                }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      obj["type"] as? String == "user"
                else { return nil }
                return user(obj)
            }
            if has(Self.compactMarker) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary",
                      let id = obj["uuid"] as? String,
                      let at = (obj["timestamp"] as? String).flatMap(parseISODate)
                else { return nil }
                let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
                let pre = (meta["preTokens"] as? NSNumber)?.int64Value ?? 0
                let post = (meta["postTokens"] as? NSNumber)?.int64Value ?? pre
                return .compaction(id: id, at: at, droppedTokens: max(pre - post, 0))
            }
            return nil
        }

        private func timed(_ obj: [String: Any]) -> Bool {
            subagentFile || obj["isSidechain"] as? Bool != true
        }

        private mutating func assistant(_ obj: [String: Any]) -> Event? {
            guard let entry = ClaudeLogParser.entry(obj) else { return nil }
            let at = entry.record.timestamp
            let message = obj["message"] as? [String: Any]
            let tools: [ToolUse] = (message?["content"] as? [[String: Any]] ?? []).compactMap { block in
                guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { return nil }
                return ToolUse(id: id, name: ToolName.normalize(block["name"] as? String ?? ""))
            }
            var request: Date?
            var stepStart: Date?
            if timed(obj) {
                if entry.messageID != current {
                    let userIsLatest = lastUser.map { u in lastAssistant.map { u >= $0 } ?? true } ?? false
                    current = entry.messageID
                    currentRequest = userIsLatest ? lastUser : nil
                    currentStepStart = userIsLatest && lastUserWasPrompt ? lastUser : lastAssistant
                }
                request = currentRequest
                stepStart = currentStepStart
                lastAssistant = max(lastAssistant ?? at, at)
            }
            return .message(Message(entry: entry, tools: tools, at: at, request: request, stepStart: stepStart))
        }

        private mutating func user(_ obj: [String: Any]) -> Event? {
            guard let at = (obj["timestamp"] as? String).flatMap(parseISODate) else { return nil }
            // Injected context (skill bodies, caveats) arrives with the prompt; it starts nothing.
            if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return nil }
            let content = (obj["message"] as? [String: Any])?["content"]
            let blocks = content as? [[String: Any]] ?? []
            let result = blocks.first { $0["type"] as? String == "tool_result" }

            if timed(obj) {
                lastUser = at
                lastUserWasPrompt = result == nil
            }
            if let result {
                guard let id = result["tool_use_id"] as? String, result["is_error"] as? Bool != true,
                      let edit = obj["toolUseResult"] as? [String: Any]
                else { return nil }
                if let hunks = edit["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
                    let (added, removed) = LineCount.hunks(hunks)
                    return .edit(id: id, at: at, added: added, removed: removed)
                }
                if edit["type"] as? String == "create", let text = edit["content"] as? String {
                    return .edit(id: id, at: at, added: LineCount.lines(in: text), removed: 0)
                }
                return nil
            }

            guard obj["isSidechain"] as? Bool != true, let id = obj["uuid"] as? String else { return nil }
            if let origin = obj["origin"] as? [String: Any] {
                guard origin["kind"] as? String == "human" else { return nil }
            } else {
                let text = content as? String
                    ?? blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
                if Self.notTyped.contains(where: text.hasPrefix) { return nil }
            }
            return .prompt(id: id, at: at)
        }

        /// User lines older Claude Code versions write without an `origin` that nobody typed.
        private static let notTyped = ["<task-notification>", "<local-command", "[Request interrupted", "<system-reminder>"]
    }

    /// Claude Code can run other vendors' models (e.g. GPT via a subagent). Those tokens belong
    /// to that vendor's Provider for pricing and charts.
    public static func provider(forModel model: String) -> ProviderID {
        let m = model.lowercased()
        if m.hasPrefix("gpt-") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("codex") {
            return .codex
        }
        return .claude
    }
}
