import Foundation

/// The highest share one weekly Limit Window reached (SPEC §14).
public struct LimitReading: Sendable, Hashable {
    public var windowID: String
    public var resetsAt: Date
    public var duration: TimeInterval
    public var plan: String?
    public var usedPercent: Double
    /// When `usedPercent` was first seen, the end of the usage it covers.
    public var readAt: Date
    public var planChanged: Bool
    /// The Account it belongs to. Empty for readings from before Accounts.
    public var account: String

    public init(windowID: String, resetsAt: Date, duration: TimeInterval, plan: String?, usedPercent: Double, readAt: Date, planChanged: Bool = false, account: String = "") {
        self.windowID = windowID
        self.resetsAt = resetsAt
        self.duration = duration
        self.plan = plan
        self.usedPercent = usedPercent
        self.readAt = readAt
        self.planChanged = planChanged
        self.account = account
    }

    public var start: Date { resetsAt.addingTimeInterval(-duration) }
}

extension LimitReading {
    /// What one Account has to go on: its own readings, and those from before Accounts for windows
    /// it has none of. A window can have both after it was part of a Pool, which doesn't claim them.
    public static func forOnly(account: String, in readings: [LimitReading]) -> [LimitReading] {
        let own = readings.filter { $0.account == account }
        let old = readings.filter { old in
            old.account.isEmpty && !own.contains { $0.windowID == old.windowID && abs($0.resetsAt.timeIntervalSince(old.resetsAt)) < 3600 }
        }
        // Old ones aren't pruned any more, so the same limit on past windows is held here.
        return Dictionary(grouping: own + old, by: \.windowID).values.flatMap { window in
            window.sorted { $0.resetsAt > $1.resetsAt }.prefix(UsageStore.keptReadings)
        }.sorted { $0.resetsAt > $1.resetsAt }
    }
}

/// List prices of individual plans, in US dollars a month (ADR 0008). A plan that isn't here shows
/// no per-dollar figures.
public enum PlanPrice {
    public static func monthly(provider: ProviderID, plan: String?) -> Double? {
        switch (provider, plan?.lowercased()) {
        case (.claude, "pro"): 20
        case (.claude, "max 5x"): 100
        case (.claude, "max 20x"): 200
        case (.codex, "go"): 8
        case (.codex, "plus"): 20
        case (.codex, "prolite"): 100
        case (.codex, "pro"): 200
        default: nil
        }
    }
}

/// One model's results on the Artificial Analysis Intelligence Index, at maximum effort. Copied
/// by hand: the site's terms rule out scraping it and its API doesn't list these fields (ADR 0008).
public struct ModelBenchmark: Sendable, Hashable {
    public var model: String
    public var score: Double
    /// US dollars per Benchmark Task.
    public var cost: Double
    public var minutes: Double

    public static let asOf = "Oct 30, 2026"
    public static let sourceURL = URL(string: "https://artificialanalysis.ai/#intelligence-efficiency-tabs")!

    public static func all(for provider: ProviderID) -> [ModelBenchmark] {
        switch provider {
        case .claude:
            [
                ModelBenchmark(model: "claude-opus-5-5", score: 58.4, cost: 10.04, minutes: 19.1),
                ModelBenchmark(model: "claude-sonnet-5-5", score: 54.2, cost: 10.02, minutes: 21.5),
                ModelBenchmark(model: "claude-fable-5-1", score: 49.0, cost: 12.99, minutes: 18.7),
                ModelBenchmark(model: "claude-haiku-5-5", score: 36.2, cost: 0.41, minutes: 9.9),
            ]
        case .codex:
            [
                ModelBenchmark(model: "gpt-6-astra", score: 56.9, cost: 6.24, minutes: 10.3),
                ModelBenchmark(model: "gpt-6.1-sol", score: 54.5, cost: 1.27, minutes: 13.6),
                ModelBenchmark(model: "gpt-6.1-terra", score: 51.0, cost: 0.96, minutes: 10.7),
                ModelBenchmark(model: "gpt-6-luna", score: 27.8, cost: 0.15, minutes: 10.2),
            ]
        case .gemini, .cursor, .opencode: []
        }
    }
}

/// What a subscription buys, from the user's own limits and logs (CONTEXT.md: Plan Value).
public struct PlanValue: Sendable, Equatable {
    /// How much of the window must be used before its value means anything: limits move in 1%
    /// steps, so 10% is good to about a tenth.
    public static let minimumUsedPercent = 10.0
    /// Average weeks in a month.
    public static let weeksPerMonth = 365.25 / 12 / 7

    /// A model's benchmark results, and how many Benchmark Tasks a full week covers on it alone.
    public struct Model: Sendable, Equatable {
        public var benchmark: ModelBenchmark
        public var tasksPerWeek: Double
    }

    /// The share of the current window used so far.
    public var usedPercent: Double
    /// Theoretical Cost of a full window, the median of the windows measured. nil until one has
    /// enough use.
    public var fullWindow: Double?
    /// Some use in those windows has no known price, so `fullWindow` is a lower bound.
    public var fullHasUnpriced: Bool
    public var low: Double?
    public var high: Double?
    /// How many windows were measured.
    public var windows: Int
    /// The newest measured window: what its logged use would cost and the share it took.
    public var measuredCost: Double?
    public var measuredPercent: Double?
    /// Whether that window is the one still open.
    public var measuredIsCurrent: Bool
    public var monthlyPrice: Double?
    /// Theoretical Cost a dollar of plan buys.
    public var perDollar: Double?
    /// Highest score first.
    public var models: [Model]
    /// Theoretical Cost of the last 7 days, today included, as Usage's 7d shows it.
    public var recentCost: Double
    /// Some of the last 7 days has no known price, so `recentCost` is a lower bound.
    public var recentHasUnpriced: Bool
    /// Each model's share of `recentCost`, under its undated name.
    public var recentShares: [String: Double]

    /// `recentCost` against a full week. Over 1 after an early reset.
    public var usedShareOfWeek: Double? {
        fullWindow.flatMap { $0 > 0 ? recentCost / $0 : nil }
    }

    /// Theoretical Cost per dollar of plan if every week went like the last 7 days.
    public var perDollarAtPace: Double? {
        monthlyPrice.flatMap { $0 > 0 ? recentCost * Self.weeksPerMonth / $0 : nil }
    }

    public static func build(
        provider: ProviderID, plan: String?, readings: [LimitReading],
        usage: [DailyUsage], hours: [DailyStat],
        prices: PriceTable, now: Date = Date(), calendar: Calendar = .current) -> PlanValue?
    {
        guard !usage.isEmpty else { return nil }
        let current = readings.filter { $0.resetsAt > now }.max { $0.resetsAt < $1.resetsAt }
        let tokens = HourlyTokens(hours)
        // An early reset starts a new window before the old one's stated reset, which ends it.
        let newest = Dictionary(readings.map { ($0.windowID, $0.resetsAt) }, uniquingKeysWith: max)
        func isOpen(_ r: LimitReading) -> Bool { r.resetsAt > now && r.resetsAt == newest[r.windowID] }
        // An open window covers everything logged so far, the current hour in full even if it resets
        // within that hour, and nothing dated later.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        func end(_ r: LimitReading) -> Date { isOpen(r) ? min(max(r.resetsAt, nextHour), tomorrow) : r.readAt }
        // Without a plan in this snapshot, the newest one seen: other tiers' weeks are worth other sums.
        let tier = plan ?? readings.filter { $0.plan != nil }.max { $0.resetsAt < $1.resetsAt }?.plan
        let measured: [(reading: LimitReading, cost: Double)] = readings
            .filter { r in
                !r.planChanged && r.usedPercent >= minimumUsedPercent && (tier == nil || r.plan == nil || r.plan == tier)
            }
            .sorted { $0.resetsAt > $1.resetsAt }
            .compactMap { r in
                let cost = windowCost(from: r.start, to: end(r), usage: usage, hours: tokens, prices: prices, calendar: calendar)
                return cost > 0 ? (r, cost) : nil
            }
        let values = measured.map { $0.cost / $0.reading.usedPercent * 100 }
        let full = median(values)
        let price = PlanPrice.monthly(provider: provider, plan: tier)
        let recent = recentUse(usage: usage, prices: prices, now: now, calendar: calendar)

        return PlanValue(
            usedPercent: current?.usedPercent ?? 0,
            fullWindow: full,
            fullHasUnpriced: measured.contains { m in
                hasUnpricedUse(from: m.reading.start, to: end(m.reading), usage: usage, hours: tokens, prices: prices, calendar: calendar)
            },
            low: values.min(), high: values.max(), windows: values.count,
            measuredCost: measured.first?.cost, measuredPercent: measured.first?.reading.usedPercent,
            measuredIsCurrent: measured.first.map { isOpen($0.reading) } ?? false,
            monthlyPrice: price, perDollar: perDollar(full: full, price: price),
            models: models(provider, full: full),
            recentCost: recent.total,
            recentHasUnpriced: recent.hasUnpriced,
            recentShares: recent.shares)
    }

    /// What a Pool buys (SPEC §14). Logs can't be split between Accounts, so this is the Theoretical
    /// Cost of the time every Account has readings ÷ the shares used in it, for one Account's full
    /// week, times the number of Accounts. `plans` holds each Account's plan, nil when unknown.
    public static func buildPool(
        provider: ProviderID, plans: [String?], readings: [LimitReading],
        usage: [DailyUsage], hours: [DailyStat],
        prices: PriceTable, now: Date = Date(), calendar: Calendar = .current) -> PlanValue?
    {
        guard !usage.isEmpty, !plans.isEmpty else { return nil }
        let recent = recentUse(usage: usage, prices: prices, now: now, calendar: calendar)
        let theirs = readings.filter { !$0.account.isEmpty }
        let owned = theirs.filter { !$0.planChanged }
        let starts = Dictionary(owned.map { ($0.account, $0.start) }, uniquingKeysWith: min)
        var full: Double?
        var hasUnpriced = false
        var used = 0.0
        var measuredCost: Double?
        // Without a reading from every Account there's no time they were all measured.
        if let from = starts.values.max(), Set(theirs.map(\.account)).count >= plans.count {
            // Tokens up to the current hour count, as they do for one Account's open window.
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
            // An early reset starts a new window before the old one's stated reset, which ends it.
            let newest = Dictionary(theirs.map { ("\($0.account)/\($0.windowID)", $0.resetsAt) }, uniquingKeysWith: max)
            let isOpen = { (r: LimitReading) in r.resetsAt > now && r.resetsAt == newest["\(r.account)/\(r.windowID)"] }
            let to = owned.contains(where: isOpen) ? min(nextHour, tomorrow) : (owned.map(\.readAt).max() ?? now)
            for r in owned {
                // The share reached by a window's last reading is spread evenly over its time so far.
                let end = isOpen(r) ? now : r.readAt
                let length = end.timeIntervalSince(r.start)
                guard length > 0 else { continue }
                let inside = min(end, to).timeIntervalSince(max(r.start, from))
                used += r.usedPercent * min(max(inside, 0) / length, 1)
            }
            if used >= minimumUsedPercent, to > from {
                let tokens = HourlyTokens(hours)
                let cost = windowCost(from: from, to: to, usage: usage, hours: tokens, prices: prices, calendar: calendar)
                if cost > 0 {
                    measuredCost = cost
                    full = cost / used * 100 * Double(plans.count)
                }
                hasUnpriced = hasUnpricedUse(from: from, to: to, usage: usage, hours: tokens, prices: prices, calendar: calendar)
            }
        }
        // Without every plan's price, a per-dollar figure would divide by too little.
        let listed = plans.map { PlanPrice.monthly(provider: provider, plan: $0) }
        let price = listed.contains { $0 == nil } ? nil : listed.compactMap { $0 }.reduce(0, +)
        return PlanValue(
            usedPercent: used, fullWindow: full, fullHasUnpriced: hasUnpriced,
            low: nil, high: nil, windows: full == nil ? 0 : 1,
            measuredCost: measuredCost, measuredPercent: measuredCost == nil ? nil : used,
            measuredIsCurrent: true,
            monthlyPrice: price, perDollar: perDollar(full: full, price: price),
            models: models(provider, full: full),
            recentCost: recent.total,
            recentHasUnpriced: recent.hasUnpriced,
            recentShares: recent.shares)
    }

    private static func perDollar(full: Double?, price: Double?) -> Double? {
        guard let full, let price else { return nil }
        return full * weeksPerMonth / price
    }

    private static func models(_ provider: ProviderID, full: Double?) -> [Model] {
        guard let full else { return [] }
        return ModelBenchmark.all(for: provider)
            .sorted { $0.score > $1.score }
            .map { Model(benchmark: $0, tasksPerWeek: full / $0.cost) }
    }

    /// The last 7 days' Theoretical Cost, today included, with each undated model's share of it.
    private static func recentUse(
        usage: [DailyUsage], prices: PriceTable, now: Date, calendar: Calendar) -> (total: Double, shares: [String: Double], hasUnpriced: Bool)
    {
        let from = DayKey.daysAgo(6, from: now, calendar: calendar)
        let today = DayKey.string(for: now, calendar: calendar)
        var recent: [String: Double] = [:]
        var hasUnpriced = false
        for row in usage where row.day >= from && row.day <= today {
            if let c = prices.cost(row) {
                recent[ModelName.undated(row.model), default: 0] += c
            } else {
                hasUnpriced = true
            }
        }
        let total = recent.values.reduce(0, +)
        return (total, total > 0 ? recent.mapValues { $0 / total } : [:], hasUnpriced)
    }

    /// Whether any use between two moments has no known price.
    private static func hasUnpricedUse(
        from start: Date, to end: Date, usage: [DailyUsage], hours: HourlyTokens,
        prices: PriceTable, calendar: Calendar) -> Bool
    {
        let first = DayKey.string(for: start, calendar: calendar)
        let last = DayKey.string(for: end, calendar: calendar)
        return usage.contains {
            $0.day >= first && $0.day <= last && prices.cost($0) == nil
                && hours.share(day: $0.day, model: $0.model, from: start, to: end, calendar: calendar) > 0
        }
    }

    /// Theoretical Cost between two moments. Days are priced whole; the share of a day inside the
    /// range comes from the tokens of each hour, per model.
    static func windowCost(
        from start: Date, to end: Date, usage: [DailyUsage], hours: HourlyTokens,
        prices: PriceTable, calendar: Calendar) -> Double
    {
        guard end > start else { return 0 }
        let first = DayKey.string(for: start, calendar: calendar)
        let last = DayKey.string(for: end, calendar: calendar)
        var total = 0.0
        var shares: [String: Double] = [:]
        for row in usage where row.day >= first && row.day <= last {
            guard let cost = prices.cost(row) else { continue }
            // Rows are per project; a day's split is per model and takes calendar work.
            let key = row.day + "|" + row.model
            let share = shares[key] ?? hours.share(day: row.day, model: row.model, from: start, to: end, calendar: calendar)
            shares[key] = share
            total += cost * share
        }
        return total
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Tokens by day, model and local hour, from the `tokens.hour.HH` counters.
struct HourlyTokens {
    private struct Key: Hashable {
        var day: String
        var model: String
    }

    private var tokens: [Key: [Int: Int64]] = [:]

    init(_ stats: [DailyStat]) {
        for s in stats where s.key.hasPrefix(StatKey.hourTokensPrefix) {
            guard let hour = Int(s.key.dropFirst(StatKey.hourTokensPrefix.count)), (0..<24).contains(hour) else { continue }
            tokens[Key(day: s.day, model: s.model), default: [:]][hour, default: 0] += s.value
        }
    }

    /// The share of a day's tokens between two moments, assuming they fall evenly within each
    /// hour. A day with no hourly counters is split by time instead.
    func share(day: String, model: String, from start: Date, to end: Date, calendar: Calendar) -> Double {
        let midnight = DayKeyDate.date(day, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86400)
        if start <= midnight, nextDay <= end { return 1 }
        func overlap(_ a: Date, _ b: Date) -> Double {
            guard b > a else { return 0 }
            return max(min(b, end).timeIntervalSince(max(a, start)), 0) / b.timeIntervalSince(a)
        }
        guard let byHour = tokens[Key(day: day, model: model)], case let total = byHour.values.reduce(0, +), total > 0 else {
            return overlap(midnight, nextDay)
        }
        // By the clock, since a clock change can repeat, skip or shorten an hour. Those changes fall
        // on a quarter of an hour.
        var spans: [Int: (start: Date, end: Date)] = [:]
        var moment = midnight
        while moment < nextDay {
            let hour = calendar.component(.hour, from: moment)
            let next = moment.addingTimeInterval(900)
            spans[hour] = (spans[hour]?.start ?? moment, next)
            moment = next
        }
        return byHour.reduce(0.0) { sum, bucket in
            guard let span = spans[bucket.key] else { return sum }
            return sum + Double(bucket.value) * overlap(span.start, span.end)
        } / Double(total)
    }
}

extension Format {
    /// An estimate's dollars, without false precision: "$1110", "$48", "$3.40", "$0.55".
    public static func roughCost(_ c: Double) -> String {
        "$" + (c >= 10 ? rough(c) : String(format: "%.2f", c))
    }

    /// An estimate's count, to two significant figures: "3400", "710", "31", "3.4", "0.34".
    public static func rough(_ n: Double) -> String {
        switch n {
        case 100...:
            let scale = pow(10, floor(log10(n)) - 1)
            return String(format: "%.0f", (n / scale).rounded() * scale)
        case 10...: return String(format: "%.0f", n)
        case 1...: return String(format: "%.1f", n)
        default: return String(format: "%.2g", n)
        }
    }
}
