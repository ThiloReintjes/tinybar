import Foundation
@testable import TinybarCore
import Testing

private func codexRecord(_ seconds: Int, input: Int = 100) -> String {
    #"{"timestamp":"2026-09-25T10:00:\#(String(format: "%02d", seconds))Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"output_tokens":1}}}}"# + "\n"
}

@Test func archivedCodexSessionIsCountedOnlyOnce() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions"), archive = dir.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("rollout-session.jsonl")
    try codexRecord(1).write(to: file, atomically: true, encoding: .utf8)
    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestCodex(roots: [sessions, archive])
    let moved = archive.appendingPathComponent(file.lastPathComponent)
    try FileManager.default.moveItem(at: file, to: moved)
    try await store.ingestCodex(roots: [sessions, archive])
    #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 101)
    #expect(try await store.stats(since: "0000").filter { $0.key == StatKey.responses }.reduce(0) { $0 + $1.value } == 1)
    let handle = try FileHandle(forWritingTo: moved)
    try handle.seekToEnd(); try handle.write(contentsOf: Data(codexRecord(2).utf8)); try handle.close()
    try await store.ingestCodex(roots: [sessions, archive])
    #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 202)
}

@Test func codexRewriteSkipsPreviouslyCountedPrefix() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("rollout-session.jsonl")
    try (codexRecord(1) + codexRecord(2) + String(repeating: " ", count: 1000)).write(to: file, atomically: true, encoding: .utf8)
    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestCodex(roots: [dir])
    // Same inode, shorter than the saved size but longer than the consumed offset.
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data((codexRecord(1) + codexRecord(2) + codexRecord(3)).utf8))
    try handle.close()
    try await store.ingestCodex(roots: [dir])
    #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 303)
}

@Test func oversizedLineRemainsSkippedAfterAnIncrementalRead() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(repeating: 0x20, count: 2 * JSONLReader.maxLineBytes).write(to: file)
    let offset = try JSONLReader.forEachLine(url: file, from: 0) { _ in Issue.record("oversized prefix") }
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: Data((codexRecord(1) + codexRecord(2)).utf8)); try handle.close()
    var lines: [String] = []
    _ = try JSONLReader.forEachLine(url: file, from: offset) { lines.append(String(decoding: $0, as: UTF8.self)) }
    #expect(lines == [String(codexRecord(2).dropLast())])
}

@Test func forkCanFinishNewUsageWithinOneSecond() {
    var parser = CodexLogParser()
    _ = parser.consume(line: Data(#"{"timestamp":"2026-09-25T10:00:00.100Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent"}}"#.utf8))
    let line = codexRecord(1).replacingOccurrences(of: "10:00:01Z", with: "10:00:00.800Z")
    #expect(parser.consume(line: Data(line.utf8))?.tokens.total == 101)
}

@Test func notificationDoesNotRestartAgentStep() {
    var parser = ClaudeLogParser.Session()
    func assistant(_ id: String, _ seconds: String) -> String {
        #"{"type":"assistant","timestamp":"2026-09-25T10:00:\#(seconds)Z","message":{"id":"\#(id)","model":"claude-test","usage":{"input_tokens":1}}}"#
    }
    _ = Data(assistant("a", "00").utf8).withUnsafeBytes { parser.consume(line: $0) }
    let notification = #"{"type":"user","uuid":"n","timestamp":"2026-09-25T10:00:10Z","origin":{"kind":"task-notification"},"message":{"content":"done"}}"#
    _ = Data(notification.utf8).withUnsafeBytes { parser.consume(line: $0) }
    let events = Data(assistant("b", "20").utf8).withUnsafeBytes { parser.consume(line: $0) }
    guard case let .message(message) = events.last else { Issue.record("expected response"); return }
    #expect(message.stepStart == parseISODate("2026-09-25T10:00:00Z"))
}

@Test func shellClassificationRespectsArgvWrappersAndBuiltins() {
    #expect(ShellCommand.parse(ShellCommand.text(argv: ["rg", "a|b", "src"])).programs == ["rg"])
    #expect(ShellCommand.parse("sudo -n git status").programs == ["git"])
    #expect(ShellCommand.parse("nice -n 5 git status").programs == ["git"])
    #expect(!ShellCommand.parse("rg python -c src").inlinePython)
    #expect(!ShellCommand.parse("cat node -e foo").inlineJS)
    #expect(ShellCommand.parse("echo hi; printf x; pwd").programs.isEmpty)
    #expect(ShellCommand.parse("/bin/echo hi").programs == ["echo"])
}

@Test func relativeWorktreePathsResolveCanonically() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo"), wt = root.appendingPathComponent("wt")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
    try "gitdir: ../repo/.git/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(ProjectResolver().project(for: wt.path) == repo.path)
    #expect(LogWatcher.watchPaths(roots: [root.appendingPathComponent("not-installed/sessions")]) == [root.path])
}
