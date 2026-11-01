import Foundation

/// Usage Records from OpenCode's database, Go subscription only (ADR 0009): messages routed to
/// Claude or ChatGPT use those subscriptions, and may be logged by their own CLI too.
enum OpenCodeHistory {
    struct Row: Sendable {
        /// What identifies a response. Message ids don't: a fork copies its messages under new ids,
        /// and 2.x leaves the copies it converted from 1.x in the old table. Time and tokens stay.
        var key: String
        var record: UsageRecord
    }

    struct Reading: Sendable {
        var rows: [Row]
        /// The newest change to any message, Go or not, so the next read skips them all.
        var newest: Int64
    }

    /// How far back a read starts from the newest row seen, for rows committed late by another
    /// session. Counting is by response, so reading one twice is safe.
    static let overlapMillis: Int64 = 10 * 60 * 1000

    /// `output` excludes `reasoning`.
    private static func tokenColumns(_ data: String) -> String {
        ["input", "output", "reasoning", "cache.write", "cache.read"]
            .map { "CAST(json_extract(\(data), '$.tokens.\($0)') AS INTEGER)" }
            .joined(separator: ", ")
    }

    /// Each row is one finished step, with `tokens` set at its end.
    private static let v1Query = """
    SELECT CAST(json_extract(data, '$.time.created') AS INTEGER), CAST(json_extract(data, '$.modelID') AS TEXT),
           \(tokenColumns("data")), json_extract(data, '$.path.cwd')
    FROM message
    WHERE time_updated >= ? AND json_valid(data) AND json_extract(data, '$.role') = 'assistant'
      AND json_extract(data, '$.providerID') = 'opencode-go' AND json_extract(data, '$.time.completed') IS NOT NULL
    """

    /// 2.x keeps `model` and `providerID` under `model` and the directory on the session. A
    /// compaction is priced too and has no `completed`; a failed one has no model.
    private static let v2Query = """
    SELECT CAST(json_extract(m.data, '$.time.created') AS INTEGER), CAST(json_extract(m.data, '$.model.id') AS TEXT),
           \(tokenColumns("m.data")), s.directory
    FROM session_message m LEFT JOIN session_v2 s ON s.id = m.session_id
    WHERE m.time_updated >= ? AND m.type IN ('assistant', 'compaction') AND json_valid(m.data)
      AND json_extract(m.data, '$.model.providerID') = 'opencode-go'
      AND (m.type = 'compaction' OR json_extract(m.data, '$.time.completed') IS NOT NULL)
    """

    /// Rows updated since the newest change seen (epoch milliseconds), less the overlap. nil if the
    /// database couldn't be read as expected, so nothing moves on and the next poll tries again.
    static func read(database: URL, after seen: Int64) -> Reading? {
        let since = max(seen - overlapMillis, 0)
        return CredentialDatabase.read(database) { handle -> Reading? in
            var reading = Reading(rows: [], newest: 0)
            for (table, marker, query) in [("message", "message", v1Query), ("session_message", "session_v2", v2Query)]
            where SQLiteDB.hasTable(marker, in: handle) {
                guard let rows = SQLiteDB.rows(handle, query, [.int(since)]),
                      let newest = SQLiteDB.rows(handle, "SELECT max(time_updated) FROM \(table)")?.first?.first?.int
                else { return nil }
                reading.rows += rows.compactMap(row)
                reading.newest = max(reading.newest, newest)
            }
            return reading
        }
    }

    /// More than any response could use. Keeps a corrupt count from overflowing the sums.
    private static let maxTokens: Int64 = 1 << 40

    /// nil for a row without a time, a model or any tokens, or with an impossible count.
    private static func row(_ columns: [SQLiteDB.Value]) -> Row? {
        func int(_ column: Int) -> Int64 { max(columns[column].int, 0) }
        guard (2...6).allSatisfy({ int($0) <= maxTokens }) else { return nil }
        let created = int(0)
        let tokens = TokenCounts(input: int(2), output: int(3) + int(4), cacheWrite: int(5), cacheRead: int(6))
        guard created > 0, let model = columns[1].text, !tokens.isZero else { return nil }
        return Row(
            key: "\(created)|\(model)|\(tokens.input)|\(tokens.output)|\(tokens.cacheWrite)|\(tokens.cacheRead)",
            record: UsageRecord(
                timestamp: Date(timeIntervalSince1970: Double(created) / 1000),
                model: model, cwd: columns[7].text, tokens: tokens))
    }
}
