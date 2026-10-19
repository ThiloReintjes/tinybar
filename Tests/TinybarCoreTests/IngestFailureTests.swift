import Foundation
@testable import TinybarCore
import Testing

@Test func readerFailuresAreNotSuccessfulEmptyReads() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(throws: (any Error).self) { try JSONLReader.forEachLine(url: missing, from: 0) { _ in } }
    // Opening a directory succeeds, but reading its bytes must fail.
    #expect(throws: (any Error).self) { try JSONLReader.forEachLine(url: FileManager.default.temporaryDirectory, from: 0) { _ in } }
}

@Test func projectAncestorCacheDoesNotSupplyFallbackNames() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let resolver = ProjectResolver()
    #expect(resolver.project(for: dir.path) == "")
    #expect(resolver.project(for: dir.appendingPathComponent("deleted").path) == "deleted")
    #expect(resolver.project(for: dir.appendingPathComponent("deleted/child").path) == "child")
}

@Test func leadingHereRedirectionsKeepTheExecutable() {
    #expect(ShellCommand.parse("<<<'{}' jq .").programs == ["jq"])
    #expect(ShellCommand.parse("<<EOF cat\nhello\nEOF").programs == ["cat"])
}

@Test func replacementRetainsPersistedHourBucket() throws {
    let old = try JSONDecoder().decode(MessageStats.self, from: Data(#"{"t":{},"s":0,"e":0,"h":10}"#.utf8))
    let later = try JSONDecoder().decode(MessageStats.self, from: Data(#"{"t":{},"s":0,"e":0,"h":12}"#.utf8))
    let merged = later.merged(with: old)
    #expect(merged.h == 10)
    var batch = StatBatch()
    batch.replace(day: "2026-09-25", provider: .claude, model: "test", old: old.contributions(tokens: TokenCounts(input: 100)), new: merged.contributions(tokens: TokenCounts(input: 150)))
    #expect(batch.sums.first { $0.key.key == StatKey.hourTokens(10) }?.value == 50)
    #expect(!batch.sums.keys.contains { $0.key == StatKey.hourTokens(12) })
    let legacy = try JSONDecoder().decode(MessageStats.self, from: Data(#"{"t":{},"s":0,"e":0}"#.utf8))
    #expect(legacy.h == nil)
}
