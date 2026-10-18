import Foundation
@testable import TinybarCore
import Testing

@Test func numericModelSuffixIsNotADatedSnapshot() throws {
    let table = try PriceTable.parse(Data(#"{"anthropic":{"models":{"claude-sonnet-4":{"cost":{"input":3,"output":15}}}}}"#.utf8), fetchedAt: nil)
    #expect(table.price(provider: .claude, model: "claude-sonnet-4-20250514")?.input == 3)
    #expect(table.price(provider: .claude, model: "claude-sonnet-4-5") == nil)
    #expect(table.price(provider: .claude, model: "claude-sonnet-4-") == nil)
}

@Test func releaseVersionsRespectPrereleasesAndPrefixes() {
    #expect(ReleaseCheck.isNewer("0.6.0", than: "0.6.0-beta"))
    #expect(!ReleaseCheck.isNewer("0.6.1-beta", than: "0.6.1"))
    #expect(ReleaseCheck.isNewer("v1.0.0", than: "0.9.0"))
    #expect(ReleaseCheck.isNewer("0.6.0-beta.10", than: "0.6.0-beta.2"))
    #expect(!ReleaseCheck.isNewer("0.6.0+build.2", than: "0.6.0+build.1"))
    #expect(ReleaseCheck.isNewer("0.6.0-beta", than: "0.5.9"))
    #expect(ReleaseCheck.isNewer("0.6.0-beta", than: "0.6.0-alpha"))
    #expect(!ReleaseCheck.isNewer("", than: "0.6.0"))
}

@Test func summariesExcludeFutureDaysAcrossDST() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    let days = ["2026-10-25", "2026-10-26", "2026-11-01", "2026-11-02"]
    let usage = days.map { DailyUsage(day: $0, provider: .codex, model: "m", project: "", tokens: TokenCounts(input: 10)) }
    let stats = days.map { DailyStat(day: $0, provider: .codex, model: "m", key: StatKey.prompts, value: 1) }
    let today = UsageSummary.build(rows: usage, range: .today, prices: .empty, now: now, calendar: calendar)
    #expect(today.totalTokens == 10)
    let week = UsageSummary.build(rows: usage, range: .week, prices: .empty, now: now, calendar: calendar)
    #expect(week.totalTokens == 20)
    let summary = StatsSummary.build(usage: usage, stats: stats, allDays: days, range: .week, prices: .empty, now: now, calendar: calendar)
    #expect(summary.tokens == 20)
    #expect(summary.prompts == 2)
    #expect(summary.activeDays == 2)
    #expect(summary.bars.count == 7)
    #expect(summary.bars.reduce(0) { $0 + $1.totalTokens } == summary.tokens)
    #expect(summary.longestStreak == 2)
    let future = StatsSummary.build(usage: Array(usage.suffix(1)), stats: [], allDays: ["2026-11-02"], range: .all, prices: .empty, now: now, calendar: calendar)
    #expect(future.firstDay == future.lastDay)
    #expect(future.tokens == 0)
    #expect(future.longestStreak == 0)
}

@Test func statsMarkPartialCostsWithoutDiscardingKnownPrices() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    let prices = PriceTable(prices: [.codex: ["known": ModelPrice(input: 2, output: 10)]], fetchedAt: nil)
    let usage = [
        DailyUsage(day: "2026-10-15", provider: .codex, model: "known", project: "", tokens: TokenCounts(input: 1_000_000)),
        DailyUsage(day: "2026-10-15", provider: .codex, model: "unknown", project: "", tokens: TokenCounts(input: 1_000_000)),
        DailyUsage(day: "2026-10-14", provider: .codex, model: "known", project: "", tokens: TokenCounts(input: 1_000_000)),
    ]
    let summary = StatsSummary.build(usage: usage, stats: [], allDays: ["2026-10-14", "2026-10-15"], range: .week, prices: prices, now: now, calendar: calendar)
    #expect(summary.cost == 4)
    #expect(summary.hasUnpriced)
    #expect(summary.bars.last?.cost == 2)
    #expect(summary.bars.last?.hasUnpriced == true)
    #expect(summary.bars.dropLast().allSatisfy { !$0.hasUnpriced })
    let known = StatsSummary.build(usage: usage, stats: [], allDays: ["2026-10-14", "2026-10-15"], range: .week, model: "known", prices: prices, now: now, calendar: calendar)
    #expect(known.cost == 4)
    #expect(!known.hasUnpriced)
    let unknown = StatsSummary.build(usage: usage, stats: [], allDays: ["2026-10-14", "2026-10-15"], range: .week, model: "unknown", prices: prices, now: now, calendar: calendar)
    #expect(unknown.cost == nil)
    #expect(unknown.hasUnpriced)
}

@Test func longContextBandsCannotExceedTotalTokens() {
    let tier = ModelPrice(input: 4, output: 20, cacheRead: 2, cacheWrite: 6)
    let price = ModelPrice(input: 2, output: 10, cacheRead: 1, cacheWrite: 3, tiers: [.init(size: 200_000, price: tier)])
    let total = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
    let excessive = TokenCounts(input: 2_000_000, output: 2_000_000, cacheWrite: 2_000_000, cacheRead: 2_000_000)
    #expect(price.cost(total, long: [200_000: excessive]) == tier.cost(total))
    #expect(price.cost(total, long: [200_000: total, 400_000: total]) == tier.cost(total))
    #expect(price.cost(TokenCounts(), long: [200_000: excessive]) == 0)
}

@Test func malformedFeedsDoNotClearCachedData() throws {
    #expect(throws: (any Error).self) { try PriceTable.parse(Data("{}".utf8), fetchedAt: nil) }
    let base = URL(string: "https://status.example.com")!
    #expect(throws: (any Error).self) {
        try StatusFeed.statuspage(Data("{}".utf8), provider: .claude, base: base, components: nil)
    }
    #expect(throws: (any Error).self) {
        try StatusFeed.incidentIOAffected(Data(#"{"summary":{}}"#.utf8), group: "Codex")
    }
    #expect(try StatusFeed.statuspage(Data(#"{"incidents":[]}"#.utf8), provider: .claude, base: base, components: nil).isEmpty)
}

@Test func missingResetBeforeExpiryKeepsAlertCycle() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let reset = now.addingTimeInterval(3600)
    func snapshot(_ used: Double, _ resetsAt: Date?) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, plan: nil, windows: [
            LimitWindow(id: "weekly", title: "Weekly", usedPercent: used, resetsAt: resetsAt, durationSeconds: 7 * 86400),
        ])
    }
    var planner = LimitAlertPlanner()
    #expect(planner.evaluate(snapshot(96, reset), now: now).count == 1)
    #expect(planner.evaluate(snapshot(96, nil), now: now).isEmpty)
    planner = try JSONDecoder().decode(LimitAlertPlanner.self, from: JSONEncoder().encode(planner))
    let next = reset.addingTimeInterval(7 * 86400)
    #expect(planner.evaluate(snapshot(0, next), now: reset) == [.reset(provider: .claude, window: "Weekly")])
    #expect(planner.evaluate(snapshot(96, next), now: reset).count == 1)
    #expect(planner.evaluate(snapshot(96, next), now: reset).isEmpty)
}

@Test func projectsKeepRootIdentityAndLanguagesKeepEmptyEdits() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    let usage = ["/a/app", "/b/app"].map {
        DailyUsage(day: "2026-10-15", provider: .codex, model: "m", project: $0, tokens: TokenCounts(input: 10))
    }
    let popover = UsageSummary.build(rows: usage, range: .today, prices: .empty, now: now, calendar: calendar)
    #expect(popover.projects.count == 2)
    #expect(Set(popover.projects.map(\.id)) == ["/a/app", "/b/app"])
    #expect(popover.projects.allSatisfy { $0.name == "app" && $0.tokens == 10 })
    let stats = [DailyStat(day: "2026-10-15", provider: .codex, model: "m", key: StatKey.extEditsPrefix + "py", value: 1)]
    let summary = StatsSummary.build(usage: usage, stats: stats, allDays: ["2026-10-15"], range: .week, prices: .empty, now: now, calendar: calendar)
    #expect(summary.projects == 2)
    #expect(summary.topProjects.count == 2)
    #expect(summary.languages.first?.name == "Python")
    #expect(summary.languages.first?.edits == 1)
}

@Test func unifiedDiffsCountContentNotLaterFileHeaders() {
    let patch = "--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-old\n+new\n--- a/b.ts\n+++ b/b.ts\n@@ -1 +1 @@\n-old\n+new"
    let files = LineCount.files(inPatch: patch)
    #expect(files.map(\.path) == ["a.py", "b.ts"])
    #expect(files.map(\.added) == [1, 1])
    #expect(files.map(\.removed) == [1, 1])
    #expect(LineCount.diff(patch).added == 2)
    #expect(LineCount.diff(patch).removed == 2)
    let deleted = "--- a/deleted.py\n+++ /dev/null\n@@ -1,2 +0,0 @@\n--- comment\n-line"
    #expect(LineCount.files(inPatch: deleted).first?.path == "deleted.py")
    #expect(LineCount.diff(deleted).removed == 2)
    let content = "--- a/content.py\n+++ b/content.py\n@@ -1 +1 @@\n--- old\n+++ new"
    #expect(LineCount.diff(content).added == 1)
    #expect(LineCount.diff(content).removed == 1)
}
