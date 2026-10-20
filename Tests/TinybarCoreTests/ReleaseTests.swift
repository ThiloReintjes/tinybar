import Foundation
@testable import TinybarCore
import Testing

// Claude Banked Resets, Long-context Prices, Incidents and the release check (0.5.0).

private let gptPrices = Data(#"""
{"openai": {"models": {
  "gpt-6.1-sol": {"cost": {"input": 2, "output": 10, "cache_read": 0.1,
    "tiers": [{"input": 4, "output": 15, "cache_read": 0.2, "tier": {"type": "context", "size": 272000}}]}},
  "gpt-old": {"cost": {"input": 1, "output": 2, "context_over_200k": {"input": 3, "output": 4}}}
}}, "anthropic": {"models": {}}}
"""#.utf8)

@Test func parsesContextTiers() throws {
    let table = try PriceTable.parse(gptPrices, fetchedAt: nil)
    let sol = try #require(table.price(provider: .codex, model: "gpt-6.1-sol"))
    #expect(sol.tiers?.map(\.size) == [272_000])
    #expect(sol.tiers?.first?.price.output == 15)
    // The older field reads as a tier at 200K.
    #expect(table.price(provider: .codex, model: "gpt-old")?.tiers?.first?.size == 200_000)
}

@Test func longRequestsTakeTheirTier() throws {
    let sol = try #require(try PriceTable.parse(gptPrices, fetchedAt: nil).price(provider: .codex, model: "gpt-6.1-sol"))
    let long = TokenCounts(input: 1_000_000, output: 1_000_000)
    let short = TokenCounts(input: 1_000_000)
    let total = TokenCounts(input: 2_000_000, output: 1_000_000)
    // Short at $2/M; long at $4 + $15.
    #expect(sol.cost(total, long: [272_000: long]) == 2 + 4 + 15)
    // A band above the tier takes it too; a band below it doesn't.
    #expect(sol.cost(total, long: [400_000: long]) == 21)
    #expect(sol.cost(total, long: [200_000: long]) == sol.cost(total))
    #expect(sol.cost(short) == 2)
}

@Test func contextBands() {
    #expect(ContextBand.of(TokenCounts(input: 99_000)) == nil)
    #expect(ContextBand.of(TokenCounts(input: 1_000, cacheRead: 150_000)) == 100_000)
    #expect(ContextBand.of(TokenCounts(input: 272_000)) == 200_000)
    #expect(ContextBand.of(TokenCounts(input: 2_000, cacheRead: 280_000)) == 272_000)
}

private func codexLines(context: Int, output: Int) -> String {
    """
    {"timestamp":"2026-09-25T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","cwd":"/nonexistent/p"}}
    {"timestamp":"2026-09-25T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(context),"cached_input_tokens":\(context - 1000),"output_tokens":\(output)}}}}
    """
}

@Test func storeFilesLongRequestsByBand() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = dir.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try (codexLines(context: 300_000, output: 10) + "\n" + codexLines(context: 50_000, output: 5) + "\n")
        .write(to: sessions.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)

    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestCodex(roots: [sessions])
    let rows = try await store.daily(since: "2026-01-01")
    #expect(rows.count == 1)
    #expect(rows[0].tokens.total == 350_015)
    #expect(rows[0].long == [272_000: TokenCounts(input: 1000, output: 10, cacheRead: 299_000)])

    // The one-time backfill (for stores from before schema 6) re-reads up to the saved offset
    // and adds only long requests: token totals and activity stay as they are.
    let stats = try await store.stats(since: "2026-01-01")
    try await store.backfillLongContext()
    #expect(try await store.daily(since: "2026-01-01")[0].tokens == rows[0].tokens)
    #expect(try await store.stats(since: "2026-01-01").sorted { $0.key < $1.key } == stats.sorted { $0.key < $1.key })
}

// MARK: Claude Banked Resets

@Test func claudeResetGrantsCountAvailableResets() throws {
    let json = Data(#"""
    {"five_hour": {"utilization": 12},
     "cedar_ember": {"eligible": true, "grants": [
       {"id": "handle", "resets_left": 2, "resets_total": 2, "starts_at": "2020-01-01T00:00:00Z",
        "ends_at": "2099-01-01T00:00:00Z", "paused": false},
       {"resets_left": 1, "paused": true},
       {"resets_left": 1, "paused": false, "ends_at": "2020-01-01T00:00:00Z"},
       {"resets_left": 1, "paused": false, "starts_at": "2099-01-01T00:00:00Z"},
       {"resets_left": 1}
     ]}}
    """#.utf8)
    let usage = try JSONDecoder().decode(ClaudeUsageAPI.UsageResponse.self, from: json)
    let snapshot = ClaudeUsageAPI.snapshot(from: usage, plan: nil)
    #expect(snapshot.bankedResets?.count == 2)
    #expect(snapshot.bankedResets?.allSatisfy(\.isAvailable) == true)
    #expect(snapshot.bankedResets?.first?.expiresAt == parseISODate("2099-01-01T00:00:00Z"))
    #expect(snapshot.windows.first?.usedPercent == 12)

    let ineligible = try JSONDecoder().decode(
        ClaudeUsageAPI.UsageResponse.self,
        from: Data(#"{"five_hour": {"utilization": 1}, "cedar_ember": {"eligible": false, "grants": []}}"#.utf8))
    #expect(ClaudeUsageAPI.snapshot(from: ineligible, plan: nil).bankedResets == nil)
}

@Test func resetGrantQueryFallsBackOnRefusal() async throws {
    let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    var asked: [String?] = []
    let data = try await ClaudeUsageAPI.withResetGrants(url) { u, passing in
        asked.append(u.query)
        if u.query != nil, passing.contains(403) { throw HTTP.Status(code: 403) }
        return Data("ok".utf8)
    }
    #expect(asked == ["cedar_ember=1", nil])
    #expect(String(decoding: data, as: UTF8.self) == "ok")
}

// MARK: Incidents

@Test func statuspageCountsOnlyRelevantComponents() throws {
    let json = Data(#"""
    {"incidents": [
      {"id": "a", "name": "Elevated errors for Claude Opus 5.5", "status": "investigating", "impact": "major",
       "shortlink": "https://stspg.io/x", "updated_at": "2026-10-06T10:00:00Z",
       "components": [{"name": "Claude Code", "status": "partial_outage"}, {"name": "Claude Cowork", "status": "major_outage"}]},
      {"id": "b", "name": "Elevated errors on platform.claude.com", "status": "identified", "impact": "major",
       "components": [{"name": "Claude Console (platform.claude.com)", "status": "major_outage"}]},
      {"id": "c", "name": "Issue with spend limits", "status": "monitoring", "impact": "minor", "components": []},
      {"id": "d", "name": "Old", "status": "resolved", "impact": "critical", "components": []}
    ],
    "scheduled_maintenances": [
      {"id": "m", "name": "Database upgrade", "status": "in_progress", "impact": "maintenance",
       "components": [{"name": "claude.ai", "status": "under_maintenance"}]},
      {"id": "n", "name": "Later", "status": "scheduled", "components": [{"name": "claude.ai", "status": "operational"}]}
    ]}
    """#.utf8)
    let base = URL(string: "https://status.claude.com")!
    let found = try StatusFeed.statuspage(json, provider: .claude, base: base, components: ["claude.ai", "Claude API", "Claude Code"])
    #expect(found.map(\.title) == ["Elevated errors for Claude Opus 5.5", "Issue with spend limits", "Database upgrade"])
    // Severity from the components that count (Cowork's major outage doesn't).
    #expect(found[0].severity == .partialOutage)
    #expect(found[0].components == ["Claude Code"])
    #expect(found[0].url.absoluteString == "https://stspg.io/x")
    #expect(found[0].page == "status.claude.com")
    #expect(found[1].severity == .degraded)
    #expect(found[2].severity == .maintenance)
}

@Test func incidentIOCountsOneGroup() throws {
    let proxy = Data(#"""
    {"summary": {
      "affected_components": [
        {"component_id": "c-cli", "status": "degraded_performance"},
        {"component_id": "c-web", "status": "full_outage"},
        {"component_id": "c-img", "status": "full_outage"}
      ],
      "structure": {"items": [
        {"group": {"id": "g1", "name": "Codex", "components": [
          {"component_id": "c-cli", "name": "CLI"}, {"component_id": "c-web", "name": "Codex Web"}]}},
        {"group": {"id": "g2", "name": "APIs", "components": [{"component_id": "c-img", "name": "Images"}]}}
      ]}
    }}
    """#.utf8)
    let affected = try StatusFeed.incidentIOAffected(proxy, group: "Codex")
    #expect(affected.map(\.name) == ["Codex CLI", "Codex Web"])
    let summary = Data(#"""
    {"incidents": [
      {"id": "i1", "name": "Image generation errors", "status": "investigating", "impact": "major"},
      {"id": "i2", "name": "Degraded performance in Codex", "status": "identified", "impact": "minor"}
    ]}
    """#.utf8)
    let base = URL(string: "https://status.openai.com")!
    let found = StatusFeed.incidentIO(affected: affected, summary: summary, provider: .codex, base: base, group: "Codex")
    #expect(found.count == 1)
    #expect(found[0].title == "Degraded performance in Codex")
    #expect(found[0].severity == .majorOutage)
    #expect(found[0].url.absoluteString == "https://status.openai.com/incidents/i2")

    let quiet = try StatusFeed.incidentIOAffected(Data(#"{"summary": {"affected_components": [], "structure": {"items": []}}}"#.utf8), group: "Codex")
    #expect(quiet.isEmpty)
}

// MARK: Releases

@Test func comparesVersionsNumerically() {
    #expect(ReleaseCheck.isNewer("0.5.0", than: "0.4.0"))
    #expect(ReleaseCheck.isNewer("0.10.0", than: "0.9.1"))
    #expect(ReleaseCheck.isNewer("1.0", than: "0.99.9"))
    #expect(!ReleaseCheck.isNewer("0.4.0", than: "0.4.0"))
    #expect(!ReleaseCheck.isNewer("0.4", than: "0.4.0"))
    #expect(!ReleaseCheck.isNewer("0.3.9", than: "0.4.0"))
}

@Test func updateChecksWaitADayAfterAnAnswer() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var schedule = UpdateSchedule()
    #expect(schedule.isDue(now: t0, version: "0.5.0"))
    schedule.attempt(at: t0, version: "0.5.0")
    schedule.lastCheck = t0
    #expect(!schedule.isDue(now: t0 + 23 * 3600, version: "0.5.0"))
    #expect(schedule.isDue(now: t0 + 24 * 3600, version: "0.5.0"))
}

@Test func failedUpdateChecksRetryWithinTheHour() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // Answered a day ago, then the next one failed.
    var schedule = UpdateSchedule(lastCheck: t0 - 24 * 3600, lastAttempt: t0 - 24 * 3600, version: "0.5.0")
    schedule.attempt(at: t0, version: "0.5.0")
    #expect(!schedule.isDue(now: t0 + 59 * 60, version: "0.5.0"))
    #expect(schedule.isDue(now: t0 + 3600, version: "0.5.0"))
    // Never answered at all: the same hour, not a day.
    var fresh = UpdateSchedule()
    fresh.attempt(at: t0, version: "0.5.0")
    #expect(fresh.isDue(now: t0 + 3600, version: "0.5.0"))
}

@Test func aNewVersionChecksRightAway() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let checked = UpdateSchedule(lastCheck: t0, lastAttempt: t0, version: "0.5.0")
    #expect(checked.isDue(now: t0 + 60, version: "0.5.1"))
    // Stores from before the version was kept check once too.
    #expect(UpdateSchedule(lastCheck: t0).isDue(now: t0 + 60, version: "0.5.0"))
    // Once the new version has asked, even without an answer, the usual waits apply.
    var updated = checked
    updated.attempt(at: t0 + 60, version: "0.5.1")
    #expect(!updated.isDue(now: t0 + 120, version: "0.5.1"))
    // That failed, and the old version's answer doesn't hold it off for a day.
    #expect(updated.isDue(now: t0 + 60 + 3600, version: "0.5.1"))
}
