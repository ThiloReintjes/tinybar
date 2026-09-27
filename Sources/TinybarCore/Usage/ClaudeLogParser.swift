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
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
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
