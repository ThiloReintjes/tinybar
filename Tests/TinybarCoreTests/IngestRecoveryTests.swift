import Foundation
@testable import TinybarCore
import Testing

private func recoveryLog(model: String = "gpt-test", output: Int = 1) -> String {
    """
    {"timestamp":"2026-09-25T10:00:00Z","type":"turn_context","payload":{"model":"\(model)"}}
    {"timestamp":"2026-09-25T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300000,"output_tokens":\(output)}}}}

    """
}

@Test func backfillsResumeCommittedBatchesWithoutDoubleCounting() async throws {
    for longContext in [false, true] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for i in 0..<201 {
            try recoveryLog(model: i == 200 ? "z-fail" : "gpt-test")
                .write(to: sessions.appendingPathComponent(String(format: "%03d.jsonl", i)), atomically: true, encoding: .utf8)
        }
        let url = dir.appendingPathComponent("db.sqlite")
        let store = try UsageStore(path: url)
        try await store.ingestCodex(roots: [sessions])
        let db = try SQLiteDB(path: url.path)
        // Model the upgrade's empty counters, then fail in the second batch.
        let table = longContext ? "daily_long_context" : "daily_stat"
        let marker = longContext ? "long_context_backfill" : "stats_backfill"
        try db.exec("DELETE FROM \(table); DELETE FROM meta WHERE key = '\(marker)' OR key GLOB '\(marker)_*';")
        try db.exec("""
        CREATE TRIGGER fail_backfill BEFORE INSERT ON \(table) WHEN NEW.model = 'z-fail'
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
        """)
        do {
            if longContext { try await store.backfillLongContext() } else { try await store.backfillStats() }
            Issue.record("backfill should fail in the second batch")
        } catch {}
        #expect(try db.run("SELECT value FROM meta WHERE key = ?", [.text(marker)]).isEmpty)
        try db.exec("DROP TRIGGER fail_backfill")
        // Incremental ingestion remains available after a failed upgrade. Its new bytes must
        // not become part of the frozen prefix when backfill resumes.
        let file = sessions.appendingPathComponent("200.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(recoveryLog(model: "z-fail").replacingOccurrences(of: "10:00:01", with: "10:00:02").utf8))
        try handle.close()
        try await store.ingestCodex(roots: [sessions])
        let reopened = try UsageStore(path: url)
        if longContext { try await reopened.backfillLongContext() } else { try await reopened.backfillStats() }
        let countSQL = longContext ? "SELECT sum(output) FROM daily_long_context" : "SELECT sum(value) FROM daily_stat WHERE key = 'responses'"
        #expect(try db.run(countSQL).first?.first?.int == 202)
        // A completed one-time backfill is a no-op, even through the developer CLI.
        if longContext { try await reopened.backfillLongContext() } else { try await reopened.backfillStats() }
        #expect(try db.run(countSQL).first?.first?.int == 202)
    }
}

@Test func failedMigrationRollsBackAllSchemaAndCounterChanges() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("db.sqlite")
    _ = try UsageStore(path: url)
    let db = try SQLiteDB(path: url.path)
    try db.exec("""
    PRAGMA user_version = 4;
    INSERT INTO daily_stat VALUES ('2026-09-25', 'claude', 'test', 'responses', 1);
    INSERT INTO claude_message VALUES ('m', '2026-09-25', 'claude', 'test', '', 300000, 1, 0, 0, '{}');
    CREATE TRIGGER fail_migration BEFORE UPDATE ON claude_message
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
    """)
    #expect(throws: (any Error).self) { _ = try UsageStore(path: url) }
    #expect(try db.run("PRAGMA user_version").first?.first?.int == 4)
    #expect(try db.run("SELECT count(*) FROM daily_stat").first?.first?.int == 1)
    #expect(try db.run("SELECT count(*) FROM daily_long_context").first?.first?.int == 0)
    try db.exec("DROP TRIGGER fail_migration")
    _ = try UsageStore(path: url)
    #expect(try db.run("PRAGMA user_version").first?.first?.int == 9)
}

@Test func completedSchemaSixBackfillsRemainUntouched() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try recoveryLog().write(to: sessions.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    let url = dir.appendingPathComponent("db.sqlite")
    let original = try UsageStore(path: url)
    try await original.ingestCodex(roots: [sessions])
    try await original.markStatsBackfillDone()
    try await original.markInitialImportDone()
    let rows = try await original.daily(since: "0000")
    let stats = try await original.stats(since: "0000")
    let db = try SQLiteDB(path: url.path)
    let metaBefore = try db.run("SELECT key FROM meta ORDER BY key").compactMap { $0[0].text }
    let reopened = try UsageStore(path: url)
    #expect(try db.run("SELECT key FROM meta ORDER BY key").compactMap { $0[0].text } == metaBefore)
    #expect(try await reopened.hasCompletedInitialImport())
    #expect(try await reopened.hasCompletedStatsBackfill())
    #expect(try await reopened.hasCompletedLongContextBackfill())
    #expect(try await reopened.backfillStats().filesScanned == 0)
    #expect(try await reopened.backfillLongContext().filesScanned == 0)
    #expect(try await reopened.daily(since: "0000") == rows)
    #expect(try await reopened.stats(since: "0000") == stats)
}

@Test func longBackfillDoesNotCreateOrphansOrExceedStoredTotals() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try recoveryLog().write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    let url = dir.appendingPathComponent("db.sqlite")
    let store = try UsageStore(path: url)
    try await store.ingestCodex(roots: [dir])
    let db = try SQLiteDB(path: url.path)
    try db.exec("DELETE FROM daily_long_context; DELETE FROM meta WHERE key GLOB 'long_context_backfill*'; UPDATE daily_usage SET project = 'historical-project'")
    try await store.backfillLongContext()
    #expect(try db.run("SELECT count(*) FROM daily_long_context").first?.first?.int == 0)
    try db.exec("DELETE FROM meta WHERE key GLOB 'long_context_backfill*'; UPDATE daily_usage SET project = '', input = 100")
    try await store.backfillLongContext()
    let row = try #require(try await store.daily(since: "0000").first)
    #expect(row.long.values.reduce(0) { $0 + $1.input } == 100)
}

@Test func claudeWriteCreationCountsWithoutStructuredPatch() {
    var parser = ClaudeLogParser.Session()
    let call = #"{"type":"assistant","timestamp":"2026-09-25T10:00:00Z","message":{"id":"m","model":"claude-test","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"write","name":"Write","input":{"file_path":"/p/new.py","content":"one\ntwo\n"}}]}}"#
    let result = #"{"type":"user","timestamp":"2026-09-25T10:00:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"write","content":"created"}]},"toolUseResult":{"type":"create","filePath":"/p/new.py","content":"one\ntwo\n"}}"#
    _ = Data(call.utf8).withUnsafeBytes { parser.consume(line: $0) }
    let events = Data(result.utf8).withUnsafeBytes { parser.consume(line: $0) }
    guard case let .edit(id, _, model, ext, added, removed) = events.first else {
        Issue.record("Write creation must produce an edit")
        return
    }
    #expect(id == "write")
    #expect(model == "claude-test")
    #expect(ext == "py")
    #expect(added == 2)
    #expect(removed == 0)
}
