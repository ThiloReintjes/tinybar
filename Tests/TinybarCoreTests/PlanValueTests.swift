import Foundation
@testable import TinybarCore
import Testing

private let prices = PriceTable(prices: [.claude: ["m": ModelPrice(input: 1, output: 1), "n": ModelPrice(input: 2, output: 2)]], fetchedAt: nil)
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// A moment in the day after 2026-10-01, in UTC.
private func at(_ day: Int, _ hour: Double = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!.addingTimeInterval(hour * 3600)
}

private func key(_ day: Int) -> String { String(format: "2026-10-%02d", day) }

/// A day's usage costing `dollars` on model `model`.
private func usage(_ day: Int, _ dollars: Double, model: String = "m") -> DailyUsage {
    DailyUsage(day: key(day), provider: .claude, model: model, project: "", tokens: TokenCounts(input: Int64(dollars * 1_000_000 / (model == "n" ? 2 : 1))))
}

private func stat(_ day: Int, _ k: String, _ value: Int64, model: String = "m") -> DailyStat {
    DailyStat(day: key(day), provider: .claude, model: model, key: k, value: value)
}

private func reading(reset: Date, used: Double, read: Date, plan: String = "Max 5x", changed: Bool = false) -> LimitReading {
    LimitReading(windowID: "weekly", resetsAt: reset, duration: 7 * 86400, plan: plan, usedPercent: used, readAt: read, planChanged: changed)
}

private func build(_ readings: [LimitReading], usage rows: [DailyUsage], stats: [DailyStat] = [], plan: String? = "Max 5x", now: Date) -> PlanValue? {
    PlanValue.build(provider: .claude, plan: plan, readings: readings, usage: rows, hours: stats, prices: prices, now: now, calendar: calendar)
}

@Test func aWindowIsWorthItsCostOverTheShareUsed() throws {
    // Started at the start of day 3. $100 for 25% makes $400 for all of it.
    let v = try #require(build([reading(reset: at(10), used: 25, read: at(5))], usage: [usage(3, 60), usage(4, 40)], now: at(5)))
    #expect(v.fullWindow == 400)
    #expect(v.windows == 1)
    #expect(v.monthlyPrice == 100)
    #expect(abs(v.perDollar! - 400 * PlanValue.weeksPerMonth / 100) < 1e-9)
}

@Test func onlyThePartOfADayInsideTheWindowCounts() throws {
    // The window opens at 12:00 on day 3: half of that day's tokens came before.
    let hours = [stat(3, StatKey.hourTokens(6), 500), stat(3, StatKey.hourTokens(18), 500)]
    let v = try #require(build([reading(reset: at(10, 12), used: 50, read: at(5))], usage: [usage(3, 40), usage(4, 30)], stats: hours, now: at(5)))
    #expect(abs(v.fullWindow! - 100) < 1e-9)
    // Without hourly counters a day splits by time.
    let w = try #require(build([reading(reset: at(10, 12), used: 50, read: at(5))], usage: [usage(3, 40), usage(4, 30)], now: at(5)))
    #expect(abs(w.fullWindow! - 100) < 1e-9)
}

@Test func aFinishedWindowEndsWhenItsShareWasLastSeen() throws {
    // Tokens after the last reading of a finished window belong to no share of it.
    let hours = [stat(4, StatKey.hourTokens(1), 500), stat(4, StatKey.hourTokens(20), 500)]
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(4, 12))], usage: [usage(4, 100)], stats: hours, now: at(20)))
    #expect(v.fullWindow == 100)
}

@Test func anOpenWindowCountsTheCurrentHourInFull() throws {
    // 06:15 with all of the day's tokens logged in the hour so far.
    let hours = [stat(5, StatKey.hourTokens(6), 1000)]
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(5, 6.25))], usage: [usage(5, 100)], stats: hours, now: at(5, 6.25)))
    #expect(v.fullWindow == 200)
}

@Test func anEarlyResetEndsTheOldWindowAtItsLastReading() throws {
    // The old window says it resets on the 12th, but a new one started on the 7th.
    let old = reading(reset: at(12), used: 100, read: at(6, 12))
    let new = reading(reset: at(14), used: 50, read: at(8))
    let hours = [stat(6, StatKey.hourTokens(1), 1000), stat(7, StatKey.hourTokens(1), 1000)]
    let rows = [usage(6, 100), usage(7, 100)]
    let v = try #require(build([new, old], usage: rows, stats: hours, now: at(8)))
    #expect(v.low == 100)
    #expect(v.high == 200)
    #expect(v.measuredIsCurrent)
}

@Test func hourBucketsFollowTheClockAcrossAClockChange() {
    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
    func moment(_ day: Int, _ hour: Int) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    let day = "2026-10-25", hourTokens = { (hour: Int) in
        HourlyTokens([DailyStat(day: day, provider: .claude, model: "m", key: StatKey.hourTokens(hour), value: 100)])
    }
    // This day has 25 hours, so hour 23 starts 24 hours after midnight.
    #expect(hourTokens(23).share(day: day, model: "m", from: moment(25, 23), to: moment(26, 0), calendar: berlin) == 1)
    #expect(hourTokens(22).share(day: day, model: "m", from: moment(25, 23), to: moment(26, 0), calendar: berlin) == 0)
    // The repeated hour is one bucket of two hours. A day without counters is split by time.
    #expect(hourTokens(2).share(day: day, model: "m", from: moment(25, 0), to: moment(26, 0), calendar: berlin) == 1)
    #expect(HourlyTokens([]).share(day: day, model: "m", from: moment(25, 0), to: moment(26, 0), calendar: berlin) == 1)
}

@Test func hourBucketsHandleSkippedAndShortenedHours() {
    func shares(_ zone: String, _ day: Int, month: Int, from hour: Int, buckets: [Int]) -> Double {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        let start = c.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        let next = c.date(byAdding: .day, value: 1, to: c.startOfDay(for: start))!
        let name = String(format: "2026-%02d-%02d", month, day)
        let hours = HourlyTokens(buckets.map { DailyStat(day: name, provider: .claude, model: "m", key: StatKey.hourTokens($0), value: 100) })
        return hours.share(day: name, model: "m", from: start, to: next, calendar: c)
    }
    // Berlin skips 02:00 on March 29; hour 1 is still one hour, before a window starting at 03:00.
    #expect(shares("Europe/Berlin", 29, month: 3, from: 3, buckets: [1]) == 0)
    // Lord Howe skips half an hour at 02:00 on October 4.
    #expect(shares("Australia/Lord_Howe", 4, month: 10, from: 3, buckets: [1, 2]) == 0)
    #expect(shares("Australia/Lord_Howe", 4, month: 10, from: 3, buckets: [3]) == 1)
}

@Test func withoutACurrentPlanOnlyTheNewestPlansWindowsCount() throws {
    let old = reading(reset: at(10), used: 50, read: at(9), plan: "Pro")
    let new = reading(reset: at(17), used: 50, read: at(16), plan: "Max 5x")
    let v = try #require(build([old, new], usage: [usage(5, 50), usage(12, 500)], plan: nil, now: at(20)))
    #expect(v.windows == 1)
    #expect(v.fullWindow == 1000)
    #expect(v.monthlyPrice == 100)
}

@Test func aWindowResettingWithinTheHourCountsThatHourInFull() throws {
    // 12:05, resetting at 12:15, with the day's tokens all in the hour so far.
    let hours = [stat(5, StatKey.hourTokens(12), 1000)]
    let v = try #require(build([reading(reset: at(5, 12.25), used: 50, read: at(5, 12.08))], usage: [usage(5, 100)], stats: hours, now: at(5, 12.08)))
    #expect(v.fullWindow == 200)
}

@Test func tooLittleUseOrAPlanChangeMeasuresNothing() throws {
    let few = try #require(build([reading(reset: at(10), used: 9, read: at(5))], usage: [usage(4, 10)], now: at(5)))
    #expect(few.fullWindow == nil)
    #expect(few.usedPercent == 9)
    let changed = try #require(build([reading(reset: at(10), used: 80, read: at(5), changed: true)], usage: [usage(4, 10)], now: at(5)))
    #expect(changed.fullWindow == nil)
    let otherPlan = try #require(build([reading(reset: at(10), used: 80, read: at(5), plan: "Pro")], usage: [usage(4, 10)], now: at(5)))
    #expect(otherPlan.fullWindow == nil)
    #expect(build([reading(reset: at(10), used: 80, read: at(5))], usage: [], now: at(5)) == nil)
}

@Test func severalWindowsGiveTheirMedianAndRange() throws {
    let readings = [
        reading(reset: at(8), used: 100, read: at(7)),    // $100
        reading(reset: at(15), used: 100, read: at(14)),  // $300
        reading(reset: at(22), used: 50, read: at(16)),   // $200 for half: $400
    ]
    let v = try #require(build(readings, usage: [usage(5, 100), usage(10, 300), usage(16, 200)], now: at(17)))
    #expect(v.fullWindow == 300)
    #expect(v.low == 100)
    #expect(v.high == 400)
    #expect(v.windows == 3)
}

@Test func aPlanWithoutAKnownPriceHasNoPerDollarFigures() throws {
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(5), plan: "Team")], usage: [usage(4, 100)], plan: "Team", now: at(5)))
    #expect(v.fullWindow == 200)
    #expect(v.perDollar == nil)
    #expect(!v.models.isEmpty)
    #expect(PlanPrice.monthly(provider: .claude, plan: "Max 20x") == 200)
    #expect(PlanPrice.monthly(provider: .codex, plan: "Prolite") == 100)
    #expect(PlanPrice.monthly(provider: .codex, plan: "Team") == nil)
}

@Test func theHeadlineShowsWhatItWasWorkedOutFrom() throws {
    let readings = [reading(reset: at(10), used: 25, read: at(5)), reading(reset: at(3), used: 90, read: at(2))]
    let v = try #require(build(readings, usage: [usage(4, 100)], now: at(5)))
    #expect(v.measuredCost == 100)
    #expect(v.measuredPercent == 25)
    #expect(v.measuredIsCurrent)
    let later = try #require(build([reading(reset: at(10), used: 25, read: at(5))], usage: [usage(4, 100)], now: at(20)))
    #expect(!later.measuredIsCurrent)
}

@Test func aFullWeekIsDividedByEachModelsBenchmarkCost() throws {
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(5))], usage: [usage(4, 502)], now: at(5)))
    #expect(v.models.map(\.benchmark.model) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-5-5"])
    #expect(abs(v.models[0].tasksPerWeek - 100) < 1e-9)
    let measuring = try #require(build([reading(reset: at(10), used: 2, read: at(5))], usage: [usage(4, 100)], now: at(5)))
    #expect(measuring.models.isEmpty)
}

@Test func theLastSevenDaysShowUseAgainstAFullWeek() throws {
    // Seven days including today: days 10 to 16 count, and day 9 doesn't.
    let rows = [usage(9, 900), usage(10, 100), usage(16, 200), usage(16, 100, model: "n")]
    let v = try #require(build([reading(reset: at(20), used: 50, read: at(16))], usage: rows, now: at(16, 12)))
    #expect(abs(v.recentCost - 400) < 1e-9)
    #expect(abs(v.recentShares["m"]! - 0.75) < 1e-9)
    let week = try #require(v.fullWindow)
    #expect(abs(v.usedShareOfWeek! - 400 / week) < 1e-9)
    #expect(abs(v.perDollarAtPace! - 400 * PlanValue.weeksPerMonth / 100) < 1e-9)
}

@Test func nothingRecentMeansNoShares() throws {
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(5))], usage: [usage(4, 100)], now: at(25)))
    #expect(v.recentCost == 0)
    #expect(v.recentShares.isEmpty)
    #expect(v.perDollarAtPace == 0)
}

@Test func aDatedModelCountsTowardsItsBenchmarkName() throws {
    let priced = PriceTable(prices: [.claude: ["claude-sonnet-5-5-20261015": ModelPrice(input: 1, output: 1)]], fetchedAt: nil)
    let row = DailyUsage(day: key(5), provider: .claude, model: "claude-sonnet-5-5-20261015", project: "", tokens: TokenCounts(input: 1_000_000))
    let v = try #require(PlanValue.build(provider: .claude, plan: "Max 5x", readings: [], usage: [row], hours: [], prices: priced, now: at(6), calendar: calendar))
    #expect(v.recentShares["claude-sonnet-5-5"] == 1)
}

@Test func aDashedDateCountsTowardsItsBenchmarkNameToo() {
    #expect(ModelName.undated("gpt-6.1-sol-2026-10-15") == "gpt-6.1-sol")
    #expect(ModelName.undated("gpt-6.1-sol") == "gpt-6.1-sol")
    #expect(ModelName.display("gpt-6.1-sol-2026-10-15") == "GPT-6.1 Sol")
}

@Test func unpricedUseMakesItsFigureALowerBound() throws {
    let unpriced = DailyUsage(day: key(5), provider: .claude, model: "unknown", project: "", tokens: TokenCounts(input: 1000))
    let recent = try #require(build([reading(reset: at(10), used: 50, read: at(5))], usage: [usage(4, 100), unpriced], now: at(5)))
    #expect(recent.recentHasUnpriced)
    #expect(recent.fullHasUnpriced)
    let clean = try #require(build([reading(reset: at(10), used: 50, read: at(5))], usage: [usage(4, 100)], now: at(5)))
    #expect(!clean.recentHasUnpriced)
    #expect(!clean.fullHasUnpriced)
}

@Test func anOpenWindowLeavesOutUseDatedAfterToday() throws {
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(5))], usage: [usage(4, 100), usage(6, 900)], now: at(5)))
    #expect(v.fullWindow == 200)
}

@Test func unpricedUseOutsideAWindowLeavesItsFigureExact() throws {
    // The window was last read on the 4th; the unpriced use came after.
    let unpriced = DailyUsage(day: key(8), provider: .claude, model: "unknown", project: "", tokens: TokenCounts(input: 1000))
    let v = try #require(build([reading(reset: at(10), used: 50, read: at(4))], usage: [usage(3, 100), unpriced], now: at(20)))
    #expect(!v.fullHasUnpriced)
}

@Test func theLastSevenDaysEndToday() throws {
    let v = try #require(build([], usage: [usage(5, 10), usage(6, 90)], now: at(5, 12)))
    #expect(v.recentCost == 10)
}

@Test func onlyBenchmarkedProvidersHaveModels() {
    #expect(ModelBenchmark.all(for: .gemini).isEmpty)
    #expect(ModelBenchmark.all(for: .cursor).isEmpty)
}

@Test func roughFiguresDropFalsePrecision() {
    #expect(Format.rough(1106) == "1100")
    #expect(Format.rough(712) == "710")
    #expect(Format.rough(48.3) == "48")
    #expect(Format.rough(4.9) == "4.9")
    #expect(Format.rough(0.344) == "0.34")
    #expect(Format.roughCost(1106) == "$1100")
    #expect(Format.roughCost(14.31) == "$14")
    #expect(Format.roughCost(1.55) == "$1.55")
}

// MARK: Readings

private func tempStore() throws -> (UsageStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (try UsageStore(path: dir.appendingPathComponent("usage.sqlite")), dir)
}

private func snapshot(used: Double, reset: Date, at: Date, plan: String? = "Max 5x", extra: [LimitWindow] = []) -> ProviderSnapshot {
    ProviderSnapshot(provider: .claude, plan: plan, windows: [
        LimitWindow(id: "weekly", title: "Weekly", usedPercent: used, resetsAt: reset, durationSeconds: 7 * 86400),
    ] + extra, fetchedAt: at)
}

@Test func readingsKeepTheHighestShareAndWhenItWasSeen() async throws {
    let (store, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let reset = at(10)
    try await store.recordLimitReadings(snapshot(used: 20, reset: reset, at: at(4)))
    try await store.recordLimitReadings(snapshot(used: 26, reset: reset, at: at(5)))
    // A later lower reading and a reset restated by seconds change nothing.
    try await store.recordLimitReadings(snapshot(used: 25, reset: reset.addingTimeInterval(30), at: at(6)))
    let readings = try await store.limitReadings(provider: .claude)
    #expect(readings.count == 1)
    #expect(readings[0].usedPercent == 26)
    #expect(readings[0].readAt == at(5))
    #expect(readings[0].resetsAt == reset)
    #expect(readings[0].planChanged == false)
}

@Test func onlyWeeklyAccountWideWindowsAreRead() async throws {
    let (store, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let extra = [
        LimitWindow(id: "session", title: "5-hour", usedPercent: 50, resetsAt: at(5), durationSeconds: 5 * 3600),
        LimitWindow(id: "opus-weekly", title: "Opus Weekly", usedPercent: 50, resetsAt: at(9), durationSeconds: 7 * 86400, isModelSpecific: true),
    ]
    try await store.recordLimitReadings(snapshot(used: 20, reset: at(10), at: at(4), extra: extra))
    #expect(try await store.limitReadings(provider: .claude).map(\.windowID) == ["weekly"])
}

@Test func aPlanChangeMarksTheWindowAndANewWindowStartsClean() async throws {
    let (store, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await store.recordLimitReadings(snapshot(used: 20, reset: at(10), at: at(4), plan: "Pro"))
    // A snapshot without a plan (the browser fallback) isn't a change.
    try await store.recordLimitReadings(snapshot(used: 21, reset: at(10), at: at(5), plan: nil))
    #expect(try await store.limitReadings(provider: .claude)[0].planChanged == false)
    #expect(try await store.limitReadings(provider: .claude)[0].plan == "Pro")
    try await store.recordLimitReadings(snapshot(used: 5, reset: at(10), at: at(6), plan: "Max 5x"))
    #expect(try await store.limitReadings(provider: .claude)[0].planChanged == true)
    // An early reset opens a new window.
    try await store.recordLimitReadings(snapshot(used: 1, reset: at(14), at: at(7), plan: "Max 5x"))
    let readings = try await store.limitReadings(provider: .claude)
    #expect(readings.count == 2)
    #expect(readings[0].planChanged == false)
}

@Test func onlyTheNewestReadingsAreKept() async throws {
    let (store, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0..<12 {
        try await store.recordLimitReadings(snapshot(used: 20, reset: at(1).addingTimeInterval(Double(i) * 7 * 86400), at: at(1)))
    }
    let readings = try await store.limitReadings(provider: .claude)
    #expect(readings.count == 8)
    #expect(readings[0].resetsAt == at(1).addingTimeInterval(11 * 7 * 86400))
}
