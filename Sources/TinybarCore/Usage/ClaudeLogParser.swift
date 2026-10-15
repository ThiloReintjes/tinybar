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

    /// What one transcript line adds beyond tokens. `model` is the normalized model the event
    /// belongs to: the one that answered a prompt, made an edit, or had its context compacted.
    public enum Event: Sendable, Equatable {
        /// An assistant line: its usage plus the tool calls and timing it carries.
        case message(Message)
        /// A prompt the user typed (not a tool result, injected context or notification), reported
        /// with the response that answers it.
        case prompt(id: String, at: Date, model: String)
        /// A file edit's result, keyed by the tool call's id, with the edited file's kind (`FileKind`).
        case edit(id: String, at: Date, model: String, ext: String, added: Int64, removed: Int64)
        /// A shell command the model ran, as its counters (`ShellCommand`), keyed by the call's id.
        case command(id: String, at: Date, model: String, values: [String: Int64])
        /// A shell command's result: whether it exited non-zero.
        case commandResult(id: String, at: Date, model: String, failed: Bool)
        case compaction(id: String, at: Date, model: String, droppedTokens: Int64)
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
        // Model attribution. Optional so state saved by earlier versions still decodes.
        /// The model of the latest response.
        var model: String?
        /// The prompt waiting for its answer. It counts under the model that answers it; one that
        /// gets none before the next prompt (a local command like /model, a retried message) doesn't
        /// count.
        var unanswered: Prompt?
        /// Edit tool calls whose results haven't arrived, by call id → model.
        var pendingEdits: [String: String]?
        /// The same for shell commands.
        var pendingCommands: [String: String]?

        struct Prompt: Sendable, Codable, Equatable {
            var id: String
            var at: Date
        }

        public init(subagentFile: Bool = false) {
            self.subagentFile = subagentFile
        }

        private static let userMarker = Data(#""type":"user""#.utf8)
        private static let compactMarker = Data(#""compact_boundary""#.utf8)
        private static let toolResultMarker = Data(#""type":"tool_result""#.utf8)
        private static let patchMarker = Data(#""structuredPatch""#.utf8)
        private static let sidechainMarker = Data(#""isSidechain":true"#.utf8)
        private static let errorMarker = Data(#""is_error":true"#.utf8)

        public mutating func consume(line: UnsafeRawBufferPointer) -> [Event] {
            guard let base = line.baseAddress else { return [] }
            func has(_ marker: Data) -> Bool {
                marker.withUnsafeBytes { memmem(base, line.count, $0.baseAddress!, $0.count) } != nil
            }
            if has(ClaudeLogParser.assistantMarker) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      obj["type"] as? String == "assistant"
                else { return [] }
                return assistant(obj)
            }
            if has(Self.userMarker) {
                if has(Self.toolResultMarker), !has(Self.patchMarker) {
                    // A tool result that isn't an edit: only its time matters, and its output can be
                    // large. The first `"timestamp"` is the line's own (results come after it).
                    guard let at = CodexLogParser.stringField("timestamp", in: Data(line)).flatMap(parseISODate) else { return [] }
                    if subagentFile || !has(Self.sidechainMarker) {
                        lastUser = at
                        lastUserWasPrompt = false
                    }
                    guard pendingCommands != nil,
                          let id = CodexLogParser.stringField("tool_use_id", in: Data(line)),
                          let by = pendingCommands?.removeValue(forKey: id)
                    else { return [] }
                    if pendingCommands?.isEmpty == true { pendingCommands = nil }
                    // Only error results need reading; they are short.
                    let failed = has(Self.errorMarker)
                        && (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]).map(Self.exitedNonZero) == true
                    return [.commandResult(id: id, at: at, model: by, failed: failed)]
                }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      obj["type"] as? String == "user"
                else { return [] }
                return user(obj)
            }
            if has(Self.compactMarker) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary",
                      let id = obj["uuid"] as? String,
                      let at = (obj["timestamp"] as? String).flatMap(parseISODate)
                else { return [] }
                let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
                let pre = (meta["preTokens"] as? NSNumber)?.int64Value ?? 0
                let post = (meta["postTokens"] as? NSNumber)?.int64Value ?? pre
                return [.compaction(id: id, at: at, model: model ?? "unknown", droppedTokens: max(pre - post, 0))]
            }
            return []
        }

        private func timed(_ obj: [String: Any]) -> Bool {
            subagentFile || obj["isSidechain"] as? Bool != true
        }

        private mutating func assistant(_ obj: [String: Any]) -> [Event] {
            guard let entry = ClaudeLogParser.entry(obj) else { return [] }
            let at = entry.record.timestamp
            let message = obj["message"] as? [String: Any]
            let blocks = (message?["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }
            let tools: [ToolUse] = blocks.compactMap { block in
                guard let id = block["id"] as? String else { return nil }
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
            let name = ModelName.normalize(entry.record.model)
            model = name
            var edits = pendingEdits ?? [:]
            for t in tools where ToolCategory(tool: t.name) == .edit {
                // Results arrive right after their calls; this only bounds calls that never got one.
                if edits.count >= 256 { edits.removeAll() }
                edits[t.id] = name
            }
            pendingEdits = edits.isEmpty ? nil : edits
            var events: [Event] = []
            var commands = pendingCommands ?? [:]
            for block in blocks where block["name"] as? String == "Bash" {
                guard let id = block["id"] as? String,
                      let command = (block["input"] as? [String: Any])?["command"] as? String
                else { continue }
                if commands.count >= 256 { commands.removeAll() }
                commands[id] = name
                events.append(.command(id: id, at: at, model: name, values: ShellCommand.stats(command)))
            }
            pendingCommands = commands.isEmpty ? nil : commands
            if obj["isSidechain"] as? Bool != true, let p = unanswered {
                events.insert(.prompt(id: p.id, at: p.at, model: name), at: 0)
                unanswered = nil
            }
            events.append(.message(Message(entry: entry, tools: tools, at: at, request: request, stepStart: stepStart)))
            return events
        }

        private mutating func user(_ obj: [String: Any]) -> [Event] {
            guard let at = (obj["timestamp"] as? String).flatMap(parseISODate) else { return [] }
            // Injected context (skill bodies, caveats) arrives with the prompt; it starts nothing.
            if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return [] }
            let content = (obj["message"] as? [String: Any])?["content"]
            let blocks = content as? [[String: Any]] ?? []
            let result = blocks.first { $0["type"] as? String == "tool_result" }

            if timed(obj) {
                lastUser = at
                lastUserWasPrompt = result == nil
            }
            if let result {
                guard let id = result["tool_use_id"] as? String else { return [] }
                if let by = pendingCommands?.removeValue(forKey: id) {
                    if pendingCommands?.isEmpty == true { pendingCommands = nil }
                    return [.commandResult(id: id, at: at, model: by, failed: Self.exitedNonZero(obj))]
                }
                let by = pendingEdits?.removeValue(forKey: id) ?? model ?? "unknown"
                if pendingEdits?.isEmpty == true { pendingEdits = nil }
                guard result["is_error"] as? Bool != true, let edit = obj["toolUseResult"] as? [String: Any] else { return [] }
                let ext = FileKind.of(path: edit["filePath"] as? String ?? "")
                if let hunks = edit["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
                    let (added, removed) = LineCount.hunks(hunks)
                    return [.edit(id: id, at: at, model: by, ext: ext, added: added, removed: removed)]
                }
                if edit["type"] as? String == "create", let text = edit["content"] as? String {
                    return [.edit(id: id, at: at, model: by, ext: ext, added: LineCount.lines(in: text), removed: 0)]
                }
                return []
            }

            guard obj["isSidechain"] as? Bool != true, let id = obj["uuid"] as? String else { return [] }
            if let origin = obj["origin"] as? [String: Any] {
                guard origin["kind"] as? String == "human" else { return [] }
            } else {
                let text = content as? String
                    ?? blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
                if Self.notTyped.contains(where: text.hasPrefix) { return [] }
            }
            unanswered = Prompt(id: id, at: at)
            return []
        }

        /// A shell command's error result says "Exit code N" when the command ran and failed;
        /// other errors (blocked by a hook, denied, timed out by the harness) aren't the command's.
        static func exitedNonZero(_ obj: [String: Any]) -> Bool {
            let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            guard let result = blocks.first(where: { $0["type"] as? String == "tool_result" }),
                  result["is_error"] as? Bool == true
            else { return false }
            let text = result["content"] as? String
                ?? (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return text.hasPrefix("Exit code ")
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
