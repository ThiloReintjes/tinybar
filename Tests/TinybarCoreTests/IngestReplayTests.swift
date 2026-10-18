import Foundation
@testable import TinybarCore
import Testing

private func rolloutCount(_ second: Int, input: Int, output: Int, totalInput: Int, totalOutput: Int) -> String {
    #"{"timestamp":"2026-09-25T10:00:0\#(second)Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"total_token_usage":{"input_tokens":\#(totalInput),"output_tokens":\#(totalOutput)}}}}"# + "\n"
}

@Test func legacyCursorUsesCumulativeReplayWatermark() throws {
    let legacy = try JSONDecoder().decode(CodexLogParser.self, from: Data(#"{"sawMeta":true,"lastTotal":[100,0,10]}"#.utf8))
    var parser = CodexLogParser(replaying: legacy)
    #expect(parser.consume(line: Data(rolloutCount(1, input: 100, output: 10, totalInput: 100, totalOutput: 10).utf8)) == nil)
    #expect(parser.consume(line: Data(rolloutCount(2, input: 50, output: 5, totalInput: 150, totalOutput: 15).utf8))?.tokens.total == 55)
}

@Test func sameSizeRewriteReadsNewUsage() async throws {
    for claude in [false, true] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let first = claude
            ? #"{"type":"assistant","timestamp":"2026-09-25T10:00:01Z","message":{"id":"a","model":"claude-test","usage":{"input_tokens":100,"output_tokens":10}}}"# + "\n"
            : rolloutCount(1, input: 100, output: 10, totalInput: 100, totalOutput: 10)
        let second = first.replacingOccurrences(of: "10:00:01", with: "10:00:02").replacingOccurrences(of: #""id":"a""#, with: #""id":"b""#)
        try first.write(to: file, atomically: true, encoding: .utf8)
        let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
        if claude { try await store.ingestClaude(roots: [dir]) } else { try await store.ingestCodex(roots: [dir]) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data(second.utf8)); try handle.close()
        // Make the mtime change observable even on filesystems with coarse timestamps.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        if claude { try await store.ingestClaude(roots: [dir]) } else { try await store.ingestCodex(roots: [dir]) }
        #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 220)
    }
}

@Test func backfillsLocatePreviouslyArchivedRollouts() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions/2026/09/25"), archive = dir.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("rollout-a.jsonl")
    try rolloutCount(1, input: 300_000, output: 10, totalInput: 300_000, totalOutput: 10).write(to: file, atomically: true, encoding: .utf8)
    let url = dir.appendingPathComponent("db.sqlite")
    let original = try UsageStore(path: url)
    try await original.ingestCodex(roots: [dir.appendingPathComponent("sessions")])
    let db = try SQLiteDB(path: url.path)
    try db.exec("DELETE FROM daily_stat; DELETE FROM daily_long_context; DELETE FROM meta WHERE key GLOB '*backfill*'; PRAGMA user_version = 5")
    try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
    let upgraded = try UsageStore(path: url)
    try await upgraded.backfillStats()
    try await upgraded.backfillLongContext()
    #expect(try await upgraded.stats(since: "0000").first { $0.key == StatKey.responses }?.value == 1)
    #expect(try await upgraded.daily(since: "0000").first?.long[272_000]?.total == 300_010)
    #expect(try await upgraded.ingestCodex(roots: [archive]).recordsAdded == 0)
}

@Test func absoluteWrapperPathsPreserveExecutableClassification() {
    let parsed = ShellCommand.parse("/usr/bin/env FOO=1 python3 -c 'print(1)'")
    #expect(parsed.programs == ["python"])
    #expect(parsed.inlinePython)
    #expect(ShellCommand.parse("/usr/bin/sudo -n git status").programs == ["git"])
    #expect(ShellCommand.parse("/bin/echo hi").programs == ["echo"])
}
