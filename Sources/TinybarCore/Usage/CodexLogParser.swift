import Foundation

/// Token counts in the shape Tinybar prices them.
public struct TokenCounts: Sendable, Hashable, Codable {
    /// Uncached input tokens.
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var cacheRead: Int64 = 0

    public init(input: Int64 = 0, output: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int64 { input + output + cacheWrite + cacheRead }
    public var isZero: Bool { total == 0 }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite += rhs.cacheWrite
        lhs.cacheRead += rhs.cacheRead
    }
}

/// One model response from a local CLI log (see CONTEXT.md: Usage Record).
public struct UsageRecord: Sendable, Hashable {
    public var timestamp: Date
    public var model: String
    public var cwd: String?
    public var tokens: TokenCounts
}

/// Incremental parser for one Codex rollout file (`~/.codex/sessions/**/rollout-*.jsonl`).
///
/// Codex logs an `event_msg`/`token_count` line after every model response, carrying the
/// cumulative session total and that response's own usage (`last_token_usage`). We count
/// `last_token_usage`, skipping two kinds of lines that are not new usage:
/// - repeats: the same cumulative total logged twice;
/// - fork replay: a forked session starts by copying the parent's history, token_count lines
///   included. Those lines are timestamped at the fork instant, so every token_count whose
///   timestamp is not after the fork's `session_meta` timestamp belongs to the parent.
///
/// The parser state is small and Codable so ingestion can resume at a byte offset.
public struct CodexLogParser: Sendable, Codable {
    public private(set) var model: String?
    public private(set) var cwd: String?
    private var forkInstant: Date?
    private var lastTotal: [Int64]?
    private var sawMeta = false
    // Activity state. Optional so cursors saved by earlier versions still decode.
    /// When the request for the next response was sent: a tool's output or the start of a turn.
    private var requestAt: Date?
    /// A subagent's session; its "prompts" come from the parent agent, not the user.
    private var subagent: Bool?

    public init() {}

    static let forkReplaySlack: TimeInterval = 1

    public mutating func consume(line: Data, stats: (StatEvent) -> Void = { _ in }) -> UsageRecord? {
        line.withUnsafeBytes { consume(line: $0, stats: stats) }
    }

    /// Feeds one JSONL line (without the trailing newline). Returns a record for new usage and
    /// reports activity (tool calls, edits, timing) to `stats`.
    /// Only the few interesting line types are copied out of the raw buffer.
    public mutating func consume(line: UnsafeRawBufferPointer, stats: (StatEvent) -> Void = { _ in }) -> UsageRecord? {
        // Cheap type sniffing on the line head; the envelope's type lives in the first ~100 bytes.
        let head = UnsafeRawBufferPointer(rebasing: line.prefix(160))
        if Self.contains(head, Self.tokenCountMarker) {
            return consumeTokenCount(Data(line))
        }
        if Self.activityMarkers.contains(where: { Self.contains(head, $0) }) {
            if let light = Self.light(line) {
                consumeLight(light, line, stats: stats)
            } else {
                consumeActivity(Data(line), stats: stats)
            }
            return nil
        }
        if Self.contains(head, Self.turnContextMarker) {
            // turn_context can embed large instructions; model/cwd sit in the first few KB.
            let prefix = Data(line.prefix(16 * 1024))
            if let m = Self.stringField("model", in: prefix) { model = m }
            if let c = Self.stringField("cwd", in: prefix) { cwd = c }
            return nil
        }
        if !sawMeta, Self.contains(head, Self.sessionMetaMarker) {
            sawMeta = true
            let prefix = Data(line.prefix(4 * 1024))
            if cwd == nil { cwd = Self.stringField("cwd", in: prefix) }
            let meta = Data(line.prefix(64 * 1024))
            subagent = Self.stringField("parent_thread_id", in: meta) != nil || Self.stringField("agent_path", in: meta) != nil
            if Self.stringField("forked_from_id", in: prefix) != nil,
               let ts = Self.stringField("timestamp", in: prefix).flatMap(parseISODate)
            {
                forkInstant = ts
            }
        }
        return nil
    }

    private mutating func consumeTokenCount(_ line: Data) -> UsageRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let ts = parseISODate(tsString)
        else { return nil }

        let total = info["total_token_usage"] as? [String: Any]
        if let total {
            let key = [int(total["input_tokens"]), int(total["cached_input_tokens"]), int(total["output_tokens"])]
            if key == lastTotal { return nil }
            lastTotal = key
        }
        if let forkInstant, ts.timeIntervalSince(forkInstant) <= Self.forkReplaySlack {
            return nil
        }

        let input = int(last["input_tokens"])
        let cached = min(int(last["cached_input_tokens"]), input)
        let cacheWrite = int(last["cache_write_input_tokens"])
        let tokens = TokenCounts(
            input: max(input - cached - cacheWrite, 0),
            output: int(last["output_tokens"]),
            cacheWrite: cacheWrite,
            cacheRead: cached)
        guard !tokens.isZero else { return nil }
        return UsageRecord(timestamp: ts, model: model ?? "unknown", cwd: cwd, tokens: tokens)
    }

    private func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

    /// Activity lines that need only their timestamp. Tool outputs and command results can be
    /// megabytes, so they are recognized by their first few hundred bytes and never parsed.
    enum Light {
        case request, prompt, ignore
        case stat(String)
        case edit(added: Int64, removed: Int64)
    }

    static func light(_ line: UnsafeRawBufferPointer) -> Light? {
        let head = UnsafeRawBufferPointer(rebasing: line.prefix(400))
        func has(_ s: String) -> Bool { contains(head, Data(s.utf8)) }
        if has(#""type":"item_completed""#) {
            for (item, light) in itemKinds where has(#""item":{"type":""# + item + "\"") { return light }
            if has(#""item":{"type":"Extension""#) {
                // Web actions carry their results; the kind is all that's needed.
                return contains(line, Data(#""kind":"web."#.utf8)) ? .stat(StatKey.tool("Web")) : .ignore
            }
            if has(#""item":{"type":"FileChange""#) {
                let (added, removed) = fileChangeLines(line)
                return .edit(added: added, removed: removed)
            }
            return .ignore
        }
        if has(#""type":"function_call_output""#) || has(#""type":"custom_tool_call_output""#)
            || has(#""type":"task_started""#)
        {
            return .request
        }
        if has(#""type":"user_message""#) { return .prompt }
        if has(#""type":"local_shell_call""#) { return .stat(StatKey.tool("Shell")) }
        if has(#""type":"web_search_call""#) { return .stat(StatKey.tool("Web")) }
        if has(#""type":"custom_tool_call""#) || has(#""type":"function_call""#) {
            // Newer versions' wrappers; the actions inside them arrive as items.
            if contains(line, Data(#""name":"exec""#.utf8)) || contains(line, Data(#""name":"js""#.utf8)) { return .ignore }
        }
        return nil
    }

    /// Added and removed lines of a FileChange item, read from the raw JSON: a new file's whole
    /// content can be a megabyte, and parsing it into Foundation objects costs far more than
    /// counting its newlines. Each change is `{"type":"add|update|delete", "content"|"unified_diff": "…"}`.
    static func fileChangeLines(_ line: UnsafeRawBufferPointer) -> (Int64, Int64) {
        let bytes = line.bindMemory(to: UInt8.self)
        let n = bytes.count
        func find(_ needle: String, from: Int) -> Int? {
            guard from < n, let base = line.baseAddress else { return nil }
            return Data(needle.utf8).withUnsafeBytes { nb -> Int? in
                guard let hit = memmem(base + from, n - from, nb.baseAddress!, nb.count) else { return nil }
                return base.distance(to: hit) + nb.count
            }
        }
        var added: Int64 = 0, removed: Int64 = 0
        guard var i = find(#""changes":{"#, from: 0) else { return (0, 0) }
        while let t = find(#""type":""#, from: i) {
            var j = t
            while j < n, bytes[j] != UInt8(ascii: "\"") { j += 1 }
            let kind = String(decoding: UnsafeBufferPointer(rebasing: bytes[t..<j]), as: UTF8.self)
            i = j
            guard ["add", "update", "delete"].contains(kind) else { continue }
            let key = kind == "update" ? #""unified_diff":""# : #""content":""#
            guard let start = find(key, from: i) else { break }
            // Walk the JSON string, splitting lines at `\n` escapes and noting each line's first bytes.
            var head: [UInt8] = []
            var lineHasBytes = false
            var inHunk = false
            var k = start
            func endLine() {
                defer { head.removeAll(keepingCapacity: true); lineHasBytes = false }
                if kind != "update" {
                    if kind == "add" { added += 1 } else { removed += 1 }
                    return
                }
                if head.starts(with: [0x40, 0x40]) { inHunk = true; return }  // "@@"
                if !inHunk, head.starts(with: [0x2B, 0x2B, 0x2B]) || head.starts(with: [0x2D, 0x2D, 0x2D]) { return }
                if head.first == 0x2B { added += 1 } else if head.first == 0x2D { removed += 1 }
            }
            while k < n {
                let b = bytes[k]
                if b == UInt8(ascii: "\"") { break }
                if b == UInt8(ascii: "\\"), k + 1 < n {
                    if bytes[k + 1] == UInt8(ascii: "n") { endLine() } else { lineHasBytes = true; if head.count < 3 { head.append(0) } }
                    k += 2
                    continue
                }
                lineHasBytes = true
                if head.count < 3 { head.append(b) }
                k += 1
            }
            if lineHasBytes { endLine() }
            i = k
        }
        return (added, removed)
    }

    private static let itemKinds: [(String, Light)] = [
        ("CommandExecution", .stat(StatKey.tool("Shell"))),
        ("WebSearch", .stat(StatKey.tool("Web"))),
        ("McpToolCall", .stat(StatKey.tool("MCP"))),
        ("ContextCompaction", .stat(StatKey.compactions)),
        ("UserMessage", .prompt),
    ]

    private mutating func consumeLight(_ light: Light, _ line: UnsafeRawBufferPointer, stats: (StatEvent) -> Void) {
        if case .ignore = light { return }
        guard let at = Self.stringField("timestamp", in: Data(line.prefix(200))).flatMap(parseISODate) else { return }
        if let forkInstant, at.timeIntervalSince(forkInstant) <= Self.forkReplaySlack { return }
        switch light {
        case .request:
            requestAt = at
        case .prompt:
            if Self.contains(UnsafeRawBufferPointer(rebasing: line.prefix(200)), Data(#""type":"user_message""#.utf8)) {
                requestAt = at
            }
            if subagent != true { stats(StatEvent(timestamp: at, values: [StatKey.prompts: 1])) }
        case let .stat(key):
            stats(StatEvent(timestamp: at, values: [key: 1]))
        case let .edit(added, removed):
            stats(StatEvent(timestamp: at, values: [StatKey.tool("Edit"): 1, StatKey.linesAdded: added, StatKey.linesRemoved: removed]))
        case .ignore:
            break
        }
    }

    /// Tool calls, edits, prompts, compactions and timing. Newer Codex versions report each action
    /// as an `item_completed` event (one `exec` call can run several commands); older ones logged
    /// each tool call as a `response_item` with the tool's own name.
    private mutating func consumeActivity(_ line: Data, stats: (StatEvent) -> Void) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let at = (obj["timestamp"] as? String).flatMap(parseISODate)
        else { return }
        if let forkInstant, at.timeIntervalSince(forkInstant) <= Self.forkReplaySlack { return }
        let envelope = obj["type"] as? String
        let type = payload["type"] as? String
        func emit(_ values: [String: Int64]) { stats(StatEvent(timestamp: at, values: values)) }
        func tool(_ name: String, _ extra: [String: Int64] = [:]) {
            emit(extra.merging([StatKey.tool(name): 1]) { a, _ in a })
        }

        switch (envelope, type) {
        case ("token_usage_record", _):
            let usage = payload["usage"] as? [String: Any] ?? [:]
            let output = int(usage["output_tokens"])
            if let requestAt {
                let ms = at.millis - requestAt.millis
                if SpeedSample.accepts(outputTokens: output, millis: ms) {
                    emit([StatKey.speedTokens: output, StatKey.speedMillis: ms, StatKey.speedSamples: 1])
                }
            }
            requestAt = nil
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"),
             ("event_msg", "task_started"):
            requestAt = at
        case ("event_msg", "user_message"):
            requestAt = at
            if subagent != true { emit([StatKey.prompts: 1]) }
        case ("event_msg", "task_complete"):
            let ms = int(payload["duration_ms"])
            if ms > 0 { emit([StatKey.agentMillis: ms]) }
        case ("event_msg", "item_completed"):
            let item = payload["item"] as? [String: Any] ?? [:]
            switch item["type"] as? String {
            case "CommandExecution": tool("Shell")
            case "WebSearch": tool("Web")
            case "Extension" where (item["kind"] as? String)?.hasPrefix("web.") == true: tool("Web")
            case "McpToolCall": tool("MCP")
            case "ContextCompaction": emit([StatKey.compactions: 1])
            case "UserMessage" where subagent != true: emit([StatKey.prompts: 1])
            case "FileChange":
                var added: Int64 = 0, removed: Int64 = 0
                for case let change as [String: Any] in (item["changes"] as? [String: Any] ?? [:]).values {
                    switch change["type"] as? String {
                    case "add": added += LineCount.lines(in: change["content"] as? String ?? "")
                    case "delete": removed += LineCount.lines(in: change["content"] as? String ?? "")
                    default:
                        let d = LineCount.diff(change["unified_diff"] as? String ?? "")
                        added += d.added
                        removed += d.removed
                    }
                }
                tool("Edit", [StatKey.linesAdded: added, StatKey.linesRemoved: removed])
            default: break
            }
        case ("response_item", "local_shell_call"):
            tool("Shell")
        case ("response_item", "web_search_call"):
            tool("Web")
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            // Older versions only; newer ones wrap every action in `exec` and report items instead.
            let name = payload["name"] as? String ?? ""
            switch name {
            case "shell", "container.exec", "exec_command", "local_shell": tool("Shell")
            case "apply_patch":
                var patch = payload["input"] as? String ?? ""
                if patch.isEmpty, let args = (payload["arguments"] as? String)?.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: args) as? [String: Any]
                {
                    patch = decoded["input"] as? String ?? ""
                }
                let d = LineCount.diff(patch)
                tool("Edit", [StatKey.linesAdded: d.added, StatKey.linesRemoved: d.removed])
            default:
                // Newer versions' wrappers (`exec`, `js`) and agent messaging aren't tool calls of
                // their own; MCP tools are, under their server-prefixed names.
                if ToolName.normalize(name) == "MCP" { tool("MCP") }
            }
        default: break
        }
    }

    // MARK: Byte-level helpers

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: Data) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress!, needle.count) != nil }
    }

    private static let tokenCountMarker = Data(#""type":"token_count""#.utf8)
    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
    private static let activityMarkers = [
        #""type":"token_usage_record""#, #""type":"item_completed""#, #""type":"task_started""#,
        #""type":"task_complete""#, #""type":"user_message""#, #""type":"function_call""#,
        #""type":"custom_tool_call""#, #""type":"function_call_output""#, #""type":"custom_tool_call_output""#,
        #""type":"local_shell_call""#, #""type":"web_search_call""#,
    ].map { Data($0.utf8) }

    /// Finds the first `"name":"value"` in compact JSON and returns the unescaped value.
    static func stringField(_ name: String, in data: Data) -> String? {
        let key = Data("\"\(name)\":\"".utf8)
        guard let r = data.range(of: key) else { return nil }
        var i = r.upperBound
        var escaped = false
        while i < data.endIndex {
            let b = data[i]
            if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { break }
            i += 1
        }
        guard i < data.endIndex else { return nil }
        let raw = Data([0x22]) + data[r.upperBound..<i] + Data([0x22])
        return (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String
    }
}
