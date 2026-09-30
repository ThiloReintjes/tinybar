import Foundation
@testable import SubarCore
import Testing

// MARK: Codex log parsing

private func tokenCount(_ ts: String, total: (Int, Int, Int), last: (Int, Int, Int)) -> String {
    """
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total.0),"cached_input_tokens":\(total.1),"output_tokens":\(total.2)},"last_token_usage":{"input_tokens":\(last.0),"cached_input_tokens":\(last.1),"cache_write_input_tokens":0,"output_tokens":\(last.2)}}}}
    """
}

private func parse(_ lines: [String]) -> [UsageRecord] {
    var parser = CodexLogParser()
    return lines.compactMap { parser.consume(line: Data($0.utf8)) }
}

@Test func countsLastTokenUsageAndSplitsCache() {
    let records = parse([
        #"{"timestamp":"2026-09-25T10:00:00.000Z","type":"session_meta","payload":{"id":"a","timestamp":"2026-09-25T10:00:00.000Z","cwd":"/tmp/x"}}"#,
        #"{"timestamp":"2026-09-25T10:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/x","model":"gpt-6-sol"}}"#,
        tokenCount("2026-09-25T10:00:05.000Z", total: (100, 60, 10), last: (100, 60, 10)),
    ])
    #expect(records.count == 1)
    #expect(records[0].model == "gpt-6-sol")
    #expect(records[0].cwd == "/tmp/x")
    #expect(records[0].tokens == TokenCounts(input: 40, output: 10, cacheWrite: 0, cacheRead: 60))
}

@Test func skipsRepeatedTotals() {
    let records = parse([
        tokenCount("2026-09-25T10:00:05.000Z", total: (100, 0, 10), last: (100, 0, 10)),
        tokenCount("2026-09-25T10:00:06.000Z", total: (100, 0, 10), last: (100, 0, 10)),
        tokenCount("2026-09-25T10:00:07.000Z", total: (250, 0, 20), last: (150, 0, 10)),
    ])
    #expect(records.map(\.tokens.input) == [100, 150])
}

@Test func skipsForkReplayedHistory() {
    let records = parse([
        #"{"timestamp":"2026-09-25T10:00:00.100Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","timestamp":"2026-09-25T10:00:00.000Z"}}"#,
        // Replayed parent lines, stamped at the fork instant.
        tokenCount("2026-09-25T10:00:00.100Z", total: (1000, 0, 100), last: (1000, 0, 100)),
        tokenCount("2026-09-25T10:00:00.100Z", total: (3000, 0, 300), last: (2000, 0, 200)),
        // The fork's own first response.
        tokenCount("2026-09-25T10:00:09.000Z", total: (3500, 0, 330), last: (500, 0, 30)),
    ])
    #expect(records.count == 1)
    #expect(records[0].tokens.input == 500)
}

@Test func resumesFromEncodedState() throws {
    var parser = CodexLogParser()
    _ = parser.consume(line: Data(#"{"timestamp":"2026-09-25T10:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/y","model":"gpt-6-astra"}}"#.utf8))
    _ = parser.consume(line: Data(tokenCount("2026-09-25T10:00:05.000Z", total: (100, 0, 10), last: (100, 0, 10)).utf8))
    var resumed = try JSONDecoder().decode(CodexLogParser.self, from: JSONEncoder().encode(parser))
    // Same total again after resume must still be treated as a repeat.
    #expect(resumed.consume(line: Data(tokenCount("2026-09-25T10:00:06.000Z", total: (100, 0, 10), last: (100, 0, 10)).utf8)) == nil)
    let next = resumed.consume(line: Data(tokenCount("2026-09-25T10:00:07.000Z", total: (150, 0, 12), last: (50, 0, 2)).utf8))
    #expect(next?.model == "gpt-6-astra")
}

@Test func stringFieldUnescapes() {
    let data = Data(#"{"cwd":"/Users/a \"b\"/c","model":"x"}"#.utf8)
    #expect(CodexLogParser.stringField("cwd", in: data) == #"/Users/a "b"/c"#)
}

// MARK: Incremental ingestion

@Test func ingestsOnlyAppendedBytes() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = dir.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("rollout-a.jsonl")
    let ctx = #"{"timestamp":"2026-09-25T10:00:01.000Z","type":"turn_context","payload":{"cwd":"/nonexistent/proj","model":"gpt-6-sol"}}"#
    try (ctx + "\n" + tokenCount("2026-09-25T10:00:05.000Z", total: (100, 0, 10), last: (100, 0, 10)) + "\n")
        .write(to: file, atomically: true, encoding: .utf8)

    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    var r = try await store.ingestCodex(roots: [sessions])
    #expect(r.recordsAdded == 1)

    // Unchanged file: skipped entirely.
    r = try await store.ingestCodex(roots: [sessions])
    #expect(r.filesScanned == 0)

    // Append a new line plus a partial one; only the complete line counts.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((tokenCount("2026-09-25T10:00:09.000Z", total: (180, 0, 15), last: (80, 0, 5)) + "\n{\"partial").utf8))
    try handle.close()
    r = try await store.ingestCodex(roots: [sessions])
    #expect(r.recordsAdded == 1)

    let rows = try await store.daily(since: "2026-01-01")
    #expect(rows.count == 1)
    #expect(rows[0].tokens.input == 180)
    #expect(rows[0].tokens.output == 15)
    #expect(rows[0].project == "proj")  // deleted path → last component
}

// MARK: Projects

@Test func worktreeResolvesToMainRepo() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let repo = root.appendingPathComponent("repo")
    try fm.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
    try fm.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
    let wt = root.appendingPathComponent("wt")
    try fm.createDirectory(at: wt.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "gitdir: \(repo.path)/.git/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

    let resolver = ProjectResolver()
    #expect(resolver.project(for: repo.appendingPathComponent("src").path) == repo.path)
    #expect(resolver.project(for: wt.appendingPathComponent("sub").path) == repo.path)
    #expect(resolver.project(for: root.path) == ProjectResolver.noProject)
    #expect(resolver.project(for: nil) == ProjectResolver.noProject)
}

// MARK: Limit Alerts

private func snapshot(_ percent: Double, resets: Date) -> ProviderSnapshot {
    ProviderSnapshot(provider: .codex, plan: nil, windows: [
        LimitWindow(id: "weekly", title: "Weekly", usedPercent: percent, resetsAt: resets, durationSeconds: 7 * 86400),
        LimitWindow(id: "spark-weekly", title: "Spark Weekly", usedPercent: percent, resetsAt: resets, durationSeconds: 7 * 86400, isModelSpecific: true),
    ])
}

@Test func alertsOncePerThresholdPerCycle() {
    var planner = LimitAlertPlanner()
    let reset = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(planner.evaluate(snapshot(50, resets: reset)).isEmpty)
    #expect(planner.evaluate(snapshot(91, resets: reset)).count == 1)
    #expect(planner.evaluate(snapshot(92, resets: reset)).isEmpty)
    #expect(planner.evaluate(snapshot(97, resets: reset)) == [.threshold(provider: .codex, window: "Weekly", percent: 95, resetsAt: reset)])
    // New cycle: reset announced because 90% was crossed.
    let next = reset.addingTimeInterval(7 * 86400)
    #expect(planner.evaluate(snapshot(1, resets: next)) == [.reset(provider: .codex, window: "Weekly")])
}

@Test func noResetAlertBelowNinety() {
    var planner = LimitAlertPlanner()
    let reset = Date(timeIntervalSince1970: 2_000_000_000)
    _ = planner.evaluate(snapshot(60, resets: reset))
    #expect(planner.evaluate(snapshot(0, resets: reset.addingTimeInterval(7 * 86400))).isEmpty)
}

@Test func jumpStraightPastBothThresholdsSendsOne() {
    var planner = LimitAlertPlanner()
    let alerts = planner.evaluate(snapshot(99, resets: Date(timeIntervalSince1970: 2_000_000_000)))
    #expect(alerts.count == 1)
}

// MARK: Pricing

@Test func pricesCachedAndUnknownModels() throws {
    let json = Data(#"{"openai":{"models":{"gpt-6-sol":{"cost":{"input":2,"output":10,"cache_read":0.2}}}}}"#.utf8)
    let table = try PriceTable.parse(json, fetchedAt: nil)
    let cost = table.cost(provider: .codex, model: "gpt-6-sol", tokens: TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000))
    #expect(abs((cost ?? 0) - 12.2) < 1e-9)
    #expect(table.cost(provider: .codex, model: "codex-auto-review", tokens: TokenCounts(input: 1)) == nil)
}

@Test func summaryMarksUnpriced() throws {
    let table = try PriceTable.parse(Data(#"{"openai":{"models":{"gpt-6-sol":{"cost":{"input":1,"output":1}}}}}"#.utf8), fetchedAt: nil)
    let today = DayKey.string(for: Date())
    let rows = [
        DailyUsage(day: today, provider: .codex, model: "gpt-6-sol", project: "/a/repo", tokens: TokenCounts(input: 1_000_000)),
        DailyUsage(day: today, provider: .codex, model: "mystery", project: "repo", tokens: TokenCounts(input: 5)),
    ]
    let s = UsageSummary.build(rows: rows, range: .today, prices: table)
    #expect(s.hasUnpriced)
    #expect(s.cost == 1)
    #expect(s.projects.count == 1)  // "/a/repo" and deleted "repo" merge by name
}

// MARK: Codex API mapping

@Test func mapsUsageResponse() throws {
    let json = Data(#"""
    {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"reset_at":1790000000,"limit_window_seconds":18000},
     "secondary_window":{"used_percent":40,"reset_at":1790500000,"limit_window_seconds":604800}},
     "credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},
     "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1790000000,"limit_window_seconds":18000}}}, {"bogus":true}]}
    """#.utf8)
    let usage = try JSONDecoder().decode(CodexUsageAPI.UsageResponse.self, from: json)
    let s = CodexUsageAPI.snapshot(from: usage, bankedResets: nil)
    #expect(s.plan == "Pro")
    #expect(s.windows.map(\.id) == ["session", "weekly", "gpt-5-3-codex-spark-session"])
    #expect(s.windows[2].isModelSpecific)
    #expect(s.credits?.balance == 12.5)
}
