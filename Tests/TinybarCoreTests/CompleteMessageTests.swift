import Foundation
@testable import TinybarCore
import Testing

private func streamedUsage(input: Int, output: Int, cached: Int) -> String {
    #"{"type":"assistant","timestamp":"2026-09-25T10:00:00Z","message":{"id":"same-message","model":"gpt-test","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cached)}}}"# + "\n"
}

@Test func activityReplayPreservesSnapshotPairedWithDailyTokens() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("a.jsonl"), url = dir.appendingPathComponent("db.sqlite")
    try streamedUsage(input: 1000, output: 10, cached: 0).write(to: file, atomically: true, encoding: .utf8)
    let initial = try UsageStore(path: url)
    try await initial.ingestClaude(roots: [dir])
    let db = try SQLiteDB(path: url.path)
    try db.exec("DELETE FROM meta WHERE key GLOB 'stats_backfill*'; DELETE FROM daily_stat; UPDATE claude_message SET stats = NULL")
    let store = try UsageStore(path: url) // Freezes the preliminary prefix.
    for backfill in [true, false] {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(streamedUsage(input: 100, output: 10, cached: 900).utf8))
        try handle.close()
        try await store.ingestClaude(roots: [dir])
        if backfill { try await store.backfillStats() }
    }
    #expect(try await store.daily(since: "0000").first?.tokens == TokenCounts(input: 100, output: 10, cacheRead: 900))
    let saved = try #require(try db.run("SELECT input, cache_read FROM claude_message").first)
    #expect(saved[0].int == 100)
    #expect(saved[1].int == 900)
}

@Test func gptInClaudeKeepsWholeFinalUsageAcrossFilesAndReads() async throws {
    let preliminary = streamedUsage(input: 61_384, output: 0, cached: 0)
    let final = streamedUsage(input: 6_167, output: 61, cached: 54_400)
    for split in [false, true] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.jsonl")
        try (split ? preliminary : preliminary + final).write(to: file, atomically: true, encoding: .utf8)
        let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
        try await store.ingestClaude(roots: [dir])
        if split {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(final.utf8)); try handle.close()
            try await store.ingestClaude(roots: [dir])
        }
        // A later-discovered transcript with the partial copy must not undo the final one.
        try preliminary.write(to: dir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        try await store.ingestClaude(roots: [dir])
        let row = try #require(try await store.daily(since: "0000").first)
        #expect(row.tokens == TokenCounts(input: 6_167, output: 61, cacheRead: 54_400))
        #expect(try await store.stats(since: "0000").first { $0.key == StatKey.contextMax }?.value == 60_567)
        // Equally complete copies may refine input/cache classification too.
        try streamedUsage(input: 6_000, output: 61, cached: 54_567)
            .write(to: dir.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
        try await store.ingestClaude(roots: [dir])
        #expect(try await store.daily(since: "0000").first?.tokens == TokenCounts(input: 6_000, output: 61, cacheRead: 54_567))
    }
}
