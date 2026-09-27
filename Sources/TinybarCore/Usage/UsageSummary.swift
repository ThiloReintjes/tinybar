import Foundation

public enum UsageRange: String, CaseIterable, Sendable, Identifiable {
    case today, week, month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: "Today"
        case .week: "7d"
        case .month: "30d"
        }
    }

    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// What the popover's Usage section renders for one range.
public struct UsageSummary: Sendable {
    public struct Line: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var tokens: Int64
        /// Theoretical Cost; nil when any part of it is unpriced.
        public var cost: Double?
        /// Tokens per Provider, so a project used from several subscriptions can show the split.
        public var byProvider: [ProviderID: Int64]

        public init(name: String, tokens: Int64, cost: Double?, byProvider: [ProviderID: Int64] = [:]) {
            self.name = name
            self.tokens = tokens
            self.cost = cost
            self.byProvider = byProvider
        }
    }

    public struct DayBar: Sendable, Identifiable {
        public var id: String { "\(day)-\(provider.rawValue)" }
        public var day: String
        public var provider: ProviderID
        public var tokens: Int64
    }

    public var range: UsageRange
    public var totalTokens: Int64
    public var cost: Double?
    /// True when some tokens have no known price (cost excludes them).
    public var hasUnpriced: Bool
    public var models: [Line]
    public var projects: [Line]
    public var days: [DayBar]

    public static func build(
        rows: [DailyUsage], range: UsageRange, prices: PriceTable, now: Date = Date(),
        calendar: Calendar = .current) -> UsageSummary
    {
        let since = DayKey.daysAgo(range.days - 1, from: now, calendar: calendar)
        let rows = rows.filter { $0.day >= since }

        var total: Int64 = 0
        var cost = 0.0
        var priced = false
        var unpriced = false
        var models: [String: Acc] = [:]
        var projects: [String: Acc] = [:]
        var bars: [String: Int64] = [:]

        for r in rows {
            let t = r.tokens.total
            let c = prices.cost(provider: r.provider, model: r.model, tokens: r.tokens)
            total += t
            if let c { cost += c; priced = true } else { unpriced = true }

            models[r.model, default: Acc()].add(r.provider, t, c)

            // Keyed by display name: a deleted worktree (stored as a bare name) merges with its
            // live repository of the same folder name.
            projects[ProjectResolver.displayName(r.project), default: Acc()].add(r.provider, t, c)

            bars["\(r.day)|\(r.provider.rawValue)", default: 0] += t
        }

        func lines(_ d: [String: Acc], name: (String) -> String) -> [Line] {
            d.map { Line(name: name($0.key), tokens: $0.value.tokens, cost: $0.value.cost, byProvider: $0.value.byProvider) }
                .sorted { ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens) }
        }

        return UsageSummary(
            range: range,
            totalTokens: total,
            cost: priced ? cost : nil,
            hasUnpriced: unpriced,
            models: lines(models) { $0 },
            projects: lines(projects) { $0 },
            days: bars.map { key, tokens in
                let parts = key.split(separator: "|")
                return DayBar(day: String(parts[0]), provider: ProviderID(rawValue: String(parts[1])) ?? .codex, tokens: tokens)
            }.sorted { $0.day < $1.day })
    }

    private struct Acc {
        var tokens: Int64 = 0
        var cost: Double? = 0
        var byProvider: [ProviderID: Int64] = [:]

        mutating func add(_ provider: ProviderID, _ t: Int64, _ c: Double?) {
            tokens += t
            cost = UsageSummary.add(cost, c)
            byProvider[provider, default: 0] += t
        }
    }

    fileprivate static func add(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a + b
    }
}

public enum Format {
    public static func tokens(_ n: Int64) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return String(format: "%.1fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.0fK", d / 1e3)
        default: return "\(n)"
        }
    }

    public static func cost(_ c: Double?) -> String {
        guard let c else { return "—" }
        if c >= 1000 { return String(format: "$%.0f", c) }
        return String(format: "$%.2f", c)
    }

    public static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }
}
