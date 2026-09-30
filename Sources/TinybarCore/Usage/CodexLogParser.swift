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

    public init() {}

    static let forkReplaySlack: TimeInterval = 1

    public mutating func consume(line: Data) -> UsageRecord? {
        line.withUnsafeBytes { consume(line: $0) }
    }

    /// Feeds one JSONL line (without the trailing newline). Returns a record for new usage.
    /// Only the few interesting line types are copied out of the raw buffer.
    public mutating func consume(line: UnsafeRawBufferPointer) -> UsageRecord? {
        // Cheap type sniffing on the line head; the envelope's type lives in the first ~100 bytes.
        let head = UnsafeRawBufferPointer(rebasing: line.prefix(160))
        if Self.contains(head, Self.tokenCountMarker) {
            return consumeTokenCount(Data(line))
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

    // MARK: Byte-level helpers

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: Data) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress!, needle.count) != nil }
    }

    private static let tokenCountMarker = Data(#""type":"token_count""#.utf8)
    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)

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
