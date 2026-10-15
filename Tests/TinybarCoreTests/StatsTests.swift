import Foundation
@testable import TinybarCore
import Testing

// MARK: Claude activity

private func ts(_ seconds: Int) -> String {
    let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(seconds))
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func prompt(_ uuid: String, at s: Int, text: String = "Fix the bug") -> String {
    #"{"type":"user","uuid":"\#(uuid)","timestamp":"\#(ts(s))","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
}

private func assistantLine(_ id: String, at s: Int, output: Int, block: String) -> String {
    #"{"type":"assistant","uuid":"a-\#(id)-\#(s)","timestamp":"\#(ts(s))","cwd":"/nonexistent/p","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[\#(block)],"usage":{"input_tokens":10,"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":5000}}}"#
}

private func toolUse(_ id: String, _ name: String) -> String {
    #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}"#
}

private func toolResult(_ toolID: String, at s: Int, patch: String? = nil) -> String {
    let result = patch.map { #","toolUseResult":{"type":"update","structuredPatch":[{"lines":\#($0)}]}"# } ?? ""
    return #"{"type":"user","uuid":"r-\#(toolID)","timestamp":"\#(ts(s))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(toolID)","content":"ok"}]}\#(result)}"#
}

/// Prompt at 0 s; a response streams a thinking block and a Bash call (ends at 10 s); the tool
/// returns at 15 s; a second response edits a file (ends at 20 s); the edit's result lands at 22 s.
private let turn = [
    prompt("p1", at: 0),
    assistantLine("m1", at: 4, output: 400, block: #"{"type":"thinking","thinking":""}"#),
    assistantLine("m1", at: 10, output: 400, block: toolUse("t1", "Bash")),
    toolResult("t1", at: 15),
    assistantLine("m2", at: 20, output: 50, block: toolUse("t2", "Edit")),
    toolResult("t2", at: 22, patch: #"["+a","+b","-c"," d"]"#),
    #"{"type":"user","isMeta":true,"uuid":"meta","timestamp":"\#(ts(23))","message":{"role":"user","content":"injected"}}"#,
]

private func store(with files: [String: [String]]) throws -> (UsageStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for (name, lines) in files {
        let url = dir.appendingPathComponent("projects/p/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    return (try UsageStore(path: dir.appendingPathComponent("db.sqlite")), dir)
}

private func totals(_ store: UsageStore) async throws -> [String: Int64] {
    var t: [String: Int64] = [:]
    for row in try await store.stats(since: "0000") {
        let key = row.key.hasPrefix(StatKey.hourPrefix) ? "hours" : row.key.hasPrefix(StatKey.hourTokensPrefix) ? "hourTokens" : row.key
        if StatKey.isMaximum(key) { t[key] = max(t[key] ?? 0, row.value) } else { t[key, default: 0] += row.value }
    }
    return t
}

@Test func claudeTurnCountsToolsEditsPromptsAndTime() async throws {
    let (store, dir) = try store(with: ["s.jsonl": turn])
    try await store.ingestClaude(roots: [dir.appendingPathComponent("projects")])
    let t = try await totals(store)
    #expect(t[StatKey.prompts] == 1)
    #expect(t[StatKey.responses] == 2)
    #expect(t["hours"] == 2)
    #expect(t["hourTokens"] == Int64(2 * 5010 + 400 + 50))
    #expect(t[StatKey.tool("Bash")] == 1)
    #expect(t[StatKey.tool("Edit")] == 1)
    #expect(t[StatKey.linesAdded] == 2)
    #expect(t[StatKey.linesRemoved] == 1)
    #expect(t[StatKey.contextMax] == 5010)
    // Agent Time: prompt to the first response's end (10 s), then that end to the second's (10 s).
    #expect(t[StatKey.agentMillis] == 20_000)
    // Only the 400-token response is a speed sample: request at 0 s, done at 10 s.
    #expect(t[StatKey.speedSamples] == 1)
    #expect(t[StatKey.speedTokens] == 400)
    #expect(t[StatKey.speedMillis] == 10_000)
}

@Test func claudeStatsDoNotDependOnWhereAReadStops() async throws {
    let (whole, wholeDir) = try store(with: ["s.jsonl": turn])
    try await whole.ingestClaude(roots: [wholeDir.appendingPathComponent("projects")])

    // The same transcript, read once after each line was written.
    let (split, splitDir) = try store(with: ["s.jsonl": []])
    let file = splitDir.appendingPathComponent("projects/p/s.jsonl")
    try Data().write(to: file)
    for line in turn {
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try handle.close()
        try await split.ingestClaude(roots: [splitDir.appendingPathComponent("projects")])
    }
    #expect(try await totals(split) == totals(whole))
}

@Test func claudeResumedCopyCountsNothingTwice() async throws {
    // A resumed session copies the history into a new transcript, then continues.
    let resumed = turn + [prompt("p2", at: 100), assistantLine("m3", at: 105, output: 20, block: toolUse("t3", "Read"))]
    let (store, dir) = try store(with: ["a.jsonl": turn, "b.jsonl": resumed])
    try await store.ingestClaude(roots: [dir.appendingPathComponent("projects")])
    let t = try await totals(store)
    #expect(t[StatKey.prompts] == 2)
    #expect(t[StatKey.responses] == 3)
    #expect(t[StatKey.tool("Bash")] == 1)
    #expect(t[StatKey.tool("Read")] == 1)
    #expect(t[StatKey.linesAdded] == 2)
    #expect(t[StatKey.agentMillis] == 25_000)
}

@Test func claudeSkipsNotificationsAndNormalizesMCP() {
    var session = ClaudeLogParser.Session()
    func feed(_ line: String) -> ClaudeLogParser.Event? {
        Data(line.utf8).withUnsafeBytes { session.consume(line: $0) }.first
    }
    let notification = #"{"type":"user","uuid":"n","timestamp":"\#(ts(0))","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>done"}}"#
    #expect(feed(notification) == nil)
    let legacy = #"{"type":"user","uuid":"l","timestamp":"\#(ts(1))","message":{"role":"user","content":"[Request interrupted by user]"}}"#
    #expect(feed(legacy) == nil)
    guard case let .message(m) = feed(assistantLine("m", at: 2, output: 1, block: toolUse("x", "mcp__srv-123__fetch"))) else {
        Issue.record("expected a message")
        return
    }
    #expect(m.tools.map(\.name) == ["MCP"])
}

@Test func claudeEventsCountUnderTheModelThatAnswered() async throws {
    // A prompt is answered by Opus; the next one, after a model switch, by Sonnet, which edits.
    let sonnet = { (line: String) in line.replacingOccurrences(of: "claude-opus-5-5", with: "claude-sonnet-5-5") }
    let lines = Array(turn.prefix(2)) + [
        prompt("p2", at: 30),
        sonnet(assistantLine("m4", at: 35, output: 10, block: toolUse("t4", "Write"))),
        toolResult("t4", at: 36, patch: #"["+x"]"#),
    ]
    let (store, dir) = try store(with: ["s.jsonl": lines])
    try await store.ingestClaude(roots: [dir.appendingPathComponent("projects")])
    var byModel: [String: [String: Int64]] = [:]
    for row in try await store.stats(since: "0000") { byModel[row.model, default: [:]][row.key, default: 0] += row.value }
    #expect(byModel["claude-opus-5-5"]?[StatKey.prompts] == 1)
    #expect(byModel["claude-sonnet-5-5"]?[StatKey.prompts] == 1)
    #expect(byModel["claude-sonnet-5-5"]?[StatKey.linesAdded] == 1)
    #expect(byModel["claude-opus-5-5"]?[StatKey.linesAdded] == nil)
    #expect(byModel[""] == nil)
}

@Test func claudePromptsWithoutAnAnswerDontCount() async throws {
    // A local command (/model) gets no response; the prompt after it does.
    let command = prompt("cmd", at: 0, text: "<command-name>/model</command-name>")
    let lines = [command, prompt("p1", at: 1)] + Array(turn.dropFirst(1).prefix(2))
    let (store, dir) = try store(with: ["s.jsonl": lines])
    try await store.ingestClaude(roots: [dir.appendingPathComponent("projects")])
    #expect(try await totals(store)[StatKey.prompts] == 1)
}

@Test func claudePromptWaitsForItsAnswerAcrossReads() {
    var session = ClaudeLogParser.Session()
    func feed(_ line: String) -> [ClaudeLogParser.Event] {
        Data(line.utf8).withUnsafeBytes { session.consume(line: $0) }
    }
    #expect(feed(turn[0]).isEmpty)
    // The state is saved between reads.
    session = try! JSONDecoder().decode(ClaudeLogParser.Session.self, from: JSONEncoder().encode(session))
    let events = feed(turn[1])
    #expect(events.first == .prompt(id: "p1", at: parseISODate(ts(0))!, model: "claude-opus-5-5"))
    #expect(events.count == 2)
}

// MARK: Codex activity

private func codex(_ s: Int, _ type: String, _ payload: String) -> String {
    #"{"timestamp":"\#(ts(s))","type":"\#(type)","payload":\#(payload)}"#
}

@Test func codexActivityFromItemsAndTiming() {
    var parser = CodexLogParser()
    var events: [StatEvent] = []
    let lines = [
        codex(0, "session_meta", #"{"id":"s","cwd":"/tmp/x"}"#),
        codex(1, "event_msg", #"{"type":"task_started","turn_id":"t"}"#),
        codex(2, "event_msg", #"{"type":"item_completed","item":{"type":"UserMessage","id":"u"}}"#),
        codex(4, "event_msg", #"{"type":"item_completed","item":{"type":"CommandExecution","id":"c","aggregated_output":"lots"}}"#),
        codex(5, "event_msg", #"{"type":"item_completed","item":{"type":"Extension","id":"e","kind":"web.search","results":[]}}"#),
        codex(6, "event_msg", #"{"type":"item_completed","item":{"type":"Reasoning","id":"r"}}"#),
        codex(11, "token_usage_record", #"{"usage":{"input_tokens":100,"output_tokens":300}}"#),
        codex(12, "response_item", #"{"type":"custom_tool_call","name":"exec","input":"tools.exec_command()"}"#),
        codex(13, "event_msg", #"{"type":"item_completed","item":{"type":"ContextCompaction","id":"cc"}}"#),
        codex(20, "event_msg", #"{"type":"task_complete","duration_ms":19000}"#),
    ]
    for line in lines { _ = parser.consume(line: Data(line.utf8)) { events.append($0) } }
    var t: [String: Int64] = [:]
    for e in events { t.merge(e.values, uniquingKeysWith: +) }
    #expect(t[StatKey.prompts] == 1)
    #expect(t[StatKey.tool("Shell")] == 1)
    #expect(t[StatKey.tool("Web")] == 1)
    #expect(t[StatKey.compactions] == 1)
    #expect(t[StatKey.agentMillis] == 19_000)
    // Requested when the turn started (1 s), answered at 11 s.
    #expect(t[StatKey.speedTokens] == 300)
    #expect(t[StatKey.speedMillis] == 10_000)
    #expect(t.count == 8)
}

@Test func codexSubagentsAndForkReplayAreNotCounted() {
    var sub = CodexLogParser()
    var events: [StatEvent] = []
    _ = sub.consume(line: Data(codex(0, "session_meta", #"{"id":"s","parent_thread_id":"p","cwd":"/tmp"}"#).utf8))
    _ = sub.consume(line: Data(codex(1, "event_msg", #"{"type":"item_completed","item":{"type":"UserMessage","id":"u"}}"#).utf8)) { events.append($0) }
    #expect(events.isEmpty)

    var fork = CodexLogParser()
    _ = fork.consume(line: Data(codex(10, "session_meta", #"{"id":"f","forked_from_id":"s","timestamp":"\#(ts(10))","cwd":"/tmp"}"#).utf8))
    _ = fork.consume(line: Data(codex(10, "event_msg", #"{"type":"item_completed","item":{"type":"CommandExecution","id":"old"}}"#).utf8)) { events.append($0) }
    _ = fork.consume(line: Data(codex(30, "event_msg", #"{"type":"item_completed","item":{"type":"CommandExecution","id":"new"}}"#).utf8)) { events.append($0) }
    #expect(events.count == 1)
}

@Test func codexLegacyToolCalls() {
    var parser = CodexLogParser()
    var events: [StatEvent] = []
    let patch = #"*** Begin Patch\n*** Add File: a.txt\n+one\n+two\n*** Update File: b.txt\n@@\n-x\n+y\n*** End Patch"#
    for line in [
        codex(1, "response_item", #"{"type":"function_call","name":"shell","arguments":"{}"}"#),
        codex(2, "response_item", #"{"type":"custom_tool_call","name":"apply_patch","input":"\#(patch)"}"#),
        codex(3, "response_item", #"{"type":"function_call","name":"update_plan","arguments":"{}"}"#),
    ] {
        _ = parser.consume(line: Data(line.utf8)) { events.append($0) }
    }
    var t: [String: Int64] = [:]
    for e in events { t.merge(e.values, uniquingKeysWith: +) }
    #expect(t[StatKey.tool("Shell")] == 1)
    #expect(t[StatKey.tool("Edit")] == 1)
    #expect(t[StatKey.linesAdded] == 3)
    #expect(t[StatKey.linesRemoved] == 1)
    #expect(t[StatKey.tool("Other")] == nil)
}

@Test func codexCursorFromAnEarlierVersionStillDecodes() throws {
    let old = #"{"model":"gpt-6-sol","cwd":"/tmp","lastTotal":[1,2,3],"sawMeta":true}"#
    let parser = try JSONDecoder().decode(CodexLogParser.self, from: Data(old.utf8))
    #expect(parser.model == "gpt-6-sol")
}

// MARK: Summary

@Test func displaysModelNames() {
    #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
    #expect(ModelName.display("claude-sonnet-5-5-20260101") == "Sonnet 5.5")
    #expect(ModelName.display("claude-fable-5-1") == "Fable 5.1")
    #expect(ModelName.display("gpt-6.1-sol") == "GPT-6.1 Sol")
    #expect(ModelName.display("gpt-6-astra") == "GPT-6 Astra")
}

@Test func streaksCountConsecutiveDays() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let days: Set = ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-07", "2026-10-08"]
    let s = StatsSummary.streaks(days, today: "2026-10-09", calendar: cal)
    #expect(s.current == 2)  // today has nothing yet; the run ends yesterday
    #expect(s.longest == 3)
}

@Test func barsFitTheSpan() {
    #expect(StatsBucket.fitting(days: 30) == .day)
    #expect(StatsBucket.fitting(days: 92) == .day)
    #expect(StatsBucket.fitting(days: 400) == .week)
    #expect(StatsBucket.fitting(days: 900) == .month)

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!  // a Thursday
    let usage = [
        DailyUsage(day: "2025-09-03", provider: .codex, model: "g", project: "", tokens: TokenCounts(input: 5)),  // a Wednesday
        DailyUsage(day: "2026-10-13", provider: .claude, model: "m", project: "", tokens: TokenCounts(input: 7)),
        DailyUsage(day: "2026-10-15", provider: .claude, model: "m", project: "", tokens: TokenCounts(input: 1)),
    ]
    let s = StatsSummary.build(usage: usage, stats: [], allDays: ["2025-09-03", "2026-10-13", "2026-10-15"],
                               range: .all, prices: .empty, now: now, calendar: cal)
    #expect(s.bucket == .week)
    #expect(s.bars.first?.start == "2025-09-01")
    #expect(s.bars.first?.end == "2025-09-07")
    #expect(s.bars.last?.start == "2026-10-12")
    #expect(s.bars.last?.end == "2026-10-15")
    #expect(s.bars.last?.totalTokens == 8)
    #expect(s.bars.reduce(0) { $0 + $1.totalTokens } == 13)
}

@Test func summaryFiltersToOneModel() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    let usage = [
        DailyUsage(day: "2026-10-15", provider: .claude, model: "m", project: "/x/a", tokens: TokenCounts(input: 10)),
        DailyUsage(day: "2026-10-15", provider: .codex, model: "g", project: "/x/b", tokens: TokenCounts(input: 30)),
    ]
    let stats = [
        DailyStat(day: "2026-10-15", provider: .claude, model: "m", key: StatKey.prompts, value: 2),
        DailyStat(day: "2026-10-15", provider: .codex, model: "g", key: StatKey.prompts, value: 5),
        DailyStat(day: "2026-10-15", provider: .codex, model: "g", key: StatKey.tool("Shell"), value: 4),
        DailyStat(day: "2026-10-15", provider: .codex, model: "g", key: StatKey.hourTokens(9), value: 30),
    ]
    let all = StatsSummary.build(usage: usage, stats: stats, allDays: ["2026-10-15"], range: .week, prices: .empty, now: now, calendar: cal)
    #expect(all.prompts == 7)
    #expect(all.toolCalls == 4)
    #expect(all.heat[3][9].tokens == 30)
    let m = StatsSummary.build(usage: usage, stats: stats, allDays: ["2026-10-15"], range: .week, model: "m",
                               prices: .empty, now: now, calendar: cal)
    #expect(m.tokens == 10)
    #expect(m.tokensByProvider == [.claude: 10])
    #expect(m.prompts == 2)
    #expect(m.toolCalls == 0)
    #expect(m.projects == 1)
    #expect(m.heat[3][9].tokens == 0)
    // The model list stays whole, so another model can be picked.
    #expect(m.models.map(\.name) == ["g", "m"])
}

@Test func summaryBucketsHoursByWeekdayAndPicksSpeed() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!  // a Thursday
    let stats = [
        DailyStat(day: "2026-10-12", provider: .claude, model: "", key: StatKey.hour(14), value: 5),  // Monday
        DailyStat(day: "2026-10-15", provider: .codex, model: "", key: StatKey.hour(2), value: 3),    // Thursday
        DailyStat(day: "2026-10-15", provider: .claude, model: "m", key: StatKey.speedTokens, value: 9000),
        DailyStat(day: "2026-10-15", provider: .claude, model: "m", key: StatKey.speedMillis, value: 100_000),
        DailyStat(day: "2026-10-15", provider: .claude, model: "m", key: StatKey.speedSamples, value: 12),
        DailyStat(day: "2026-10-15", provider: .claude, model: "", key: StatKey.tool("Bash"), value: 7),
        DailyStat(day: "2026-10-15", provider: .codex, model: "", key: StatKey.tool("Shell"), value: 3),
        DailyStat(day: "2026-10-01", provider: .claude, model: "", key: StatKey.tool("Read"), value: 99),  // outside 7 days
    ]
    let usage = [DailyUsage(day: "2026-10-15", provider: .claude, model: "m", project: "/x/repo",
                            tokens: TokenCounts(input: 10, output: 10, cacheWrite: 0, cacheRead: 80))]
    let s = StatsSummary.build(usage: usage, stats: stats, allDays: ["2026-10-15"], range: .week, prices: .empty, now: now, calendar: cal)
    #expect(s.heat[0][14].responses == 5)
    #expect(s.heat[3][2].responses == 3)
    #expect(s.weekdays == [1, 1, 1, 1, 1, 1, 1])
    #expect(s.models.first?.speed == 90)
    #expect(s.tools.first?.category == .shell)
    #expect(s.tools.first?.calls == 10)
    #expect(s.toolCalls == 10)
    #expect(s.cacheShare == 80.0 / 90.0)
    #expect(s.bars.count == 7)
    #expect(s.projects == 1)
}
