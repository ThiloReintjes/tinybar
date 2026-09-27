import CommonCrypto
import Foundation
@testable import SubarCore
import Testing

// MARK: Claude transcripts

private func assistant(id: String, ts: String = "2026-09-25T10:00:00.000Z", model: String = "claude-opus-5",
                       input: Int, output: Int, cw: Int = 0, cr: Int = 0, cwd: String = "/nonexistent/proj") -> String
{
    """
    {"type":"assistant","timestamp":"\(ts)","cwd":"\(cwd)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cw),"cache_read_input_tokens":\(cr)}}}
    """
}

@Test func parsesAssistantUsage() {
    let line = assistant(id: "msg_1", input: 10, output: 20, cw: 30, cr: 40)
    let entry = Data(line.utf8).withUnsafeBytes { ClaudeLogParser.parse(line: $0) }
    #expect(entry?.messageID == "msg_1")
    #expect(entry?.record.tokens == TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 40))
    #expect(entry?.record.cwd == "/nonexistent/proj")
}

@Test func skipsSyntheticAndNonAssistant() {
    let synthetic = assistant(id: "m", model: "<synthetic>", input: 0, output: 0)
    let user = #"{"type":"user","message":{"id":"u"}}"#
    for line in [synthetic, user] {
        #expect(Data(line.utf8).withUnsafeBytes { ClaudeLogParser.parse(line: $0) } == nil)
    }
}

@Test func routesOtherVendorModels() {
    #expect(ClaudeLogParser.provider(forModel: "gpt-6-sol") == .codex)
    #expect(ClaudeLogParser.provider(forModel: "claude-fable-5-1") == .claude)
}

private func tempRoot() throws -> (URL, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let projects = dir.appendingPathComponent("projects/p")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    return (dir, projects)
}

@Test func streamingCopiesCountOnceWithFinalUsage() async throws {
    let (dir, projects) = try tempRoot()
    let file = projects.appendingPathComponent("s1.jsonl")
    // Three streamed copies of one message: zero, partial, final.
    try [assistant(id: "msg_a", input: 0, output: 0),
         assistant(id: "msg_a", input: 5, output: 1, cr: 100),
         assistant(id: "msg_a", input: 5, output: 42, cr: 100)].joined(separator: "\n").appending("\n")
        .write(to: file, atomically: true, encoding: .utf8)

    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestClaude(roots: [dir.appendingPathComponent("projects")])
    let rows = try await store.daily(since: "2026-01-01")
    #expect(rows.count == 1)
    #expect(rows[0].tokens == TokenCounts(input: 5, output: 42, cacheWrite: 0, cacheRead: 100))
}

@Test func duplicateAcrossFilesAndLaterGrowthReplaces() async throws {
    let (dir, projects) = try tempRoot()
    let a = projects.appendingPathComponent("a.jsonl")
    let b = projects.appendingPathComponent("b.jsonl")
    try (assistant(id: "msg_x", input: 5, output: 10) + "\n").write(to: a, atomically: true, encoding: .utf8)
    // A resumed session copies the message into another transcript.
    try (assistant(id: "msg_x", input: 5, output: 10) + "\n").write(to: b, atomically: true, encoding: .utf8)

    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    let root = dir.appendingPathComponent("projects")
    try await store.ingestClaude(roots: [root])
    var rows = try await store.daily(since: "2026-01-01")
    #expect(rows.map(\.tokens.output) == [10])

    // The streamed message finishes in a later ingest: its count is replaced, not added.
    let h = try FileHandle(forWritingTo: a)
    try h.seekToEnd()
    try h.write(contentsOf: Data((assistant(id: "msg_x", input: 5, output: 99) + "\n").utf8))
    try h.close()
    try await store.ingestClaude(roots: [root])
    rows = try await store.daily(since: "2026-01-01")
    #expect(rows.map(\.tokens.output) == [99])
    #expect(rows.map(\.tokens.input) == [5])
}

// MARK: Claude API mapping

@Test func mapsClaudeUsage() throws {
    // Shapes from CodexBar's fixtures.
    let json = Data(#"""
    {"five_hour":{"utilization":12.5,"resets_at":"2025-12-25T12:00:00.000Z"},
     "seven_day":{"utilization":30,"resets_at":"2025-12-31T00:00:00.000Z"},
     "seven_day_sonnet":{"utilization":5},
     "extra_usage":{"is_enabled":true,"monthly_limit":2050,"used_credits":325}}
    """#.utf8)
    let usage = try JSONDecoder().decode(ClaudeUsageAPI.UsageResponse.self, from: json)
    let s = ClaudeUsageAPI.snapshot(from: usage, plan: "Max 5x")
    #expect(s.windows.map(\.id) == ["session", "weekly", "sonnet-weekly"])
    #expect(s.windows[0].remainingPercent == 87.5)
    #expect(s.windows[0].kind == .session)
    #expect(s.windows[2].isModelSpecific)
    #expect(s.extraUsage == ExtraUsageSpend(used: 3.25, limit: 20.5, currency: "USD"))
}

@Test func mapsScopedLimits() throws {
    let json = Data(#"""
    {"five_hour":{"utilization":1,"resets_at":"2025-12-25T12:00:00Z"},
     "seven_day_opus":{"utilization":50},
     "limits":[{"kind":"weekly_scoped","group":"weekly","percent":40,"resets_at":"2025-12-31T00:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}
    """#.utf8)
    let usage = try JSONDecoder().decode(ClaudeUsageAPI.UsageResponse.self, from: json)
    let s = ClaudeUsageAPI.snapshot(from: usage, plan: nil)
    #expect(s.windows.map(\.title) == ["5-hour", "Fable Weekly"])
}

@Test func parsesClaudeCredentials() throws {
    let json = Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#.utf8)
    let c = try ClaudeCredentials.parse(json)
    #expect(c.accessToken == "tok")
    #expect(!c.isExpired)
    #expect(c.planName == "Max 5x")
    #expect(throws: ProviderError.self) { try ClaudeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8)) }
}

// MARK: Cookies

@Test func decryptsChromiumV10Cookie() throws {
    // Encrypt a value the way Chromium does, then check our decryptor round-trips it.
    let key = Data(repeating: 7, count: 16)
    let plain = Data("sk-ant-secret".utf8)
    let iv = Data(repeating: 0x20, count: 16)
    var out = Data(count: plain.count + 16)
    var outLength = 0
    let capacity = out.count
    _ = out.withUnsafeMutableBytes { o in plain.withUnsafeBytes { p in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                k.baseAddress, 16, v.baseAddress, p.baseAddress, plain.count, o.baseAddress, capacity, &outLength)
    } } } }
    out.count = outLength
    #expect(BrowserCookies.aes128CBCDecrypt(out, key: key) == plain)
}

@Test func joinsChunkedCookies() {
    let cookies = ["tok.0": "abc", "tok.1": "def", "other": "x"]
    #expect(BrowserCookies.joined("tok", in: cookies) == "abcdef")
    #expect(BrowserCookies.joined("other", in: cookies) == "x")
    #expect(ChatGPTWebSession.cookieHeader(["__Secure-next-auth.session-token": "a", "_ga": "b"]) == "__Secure-next-auth.session-token=a")
}
