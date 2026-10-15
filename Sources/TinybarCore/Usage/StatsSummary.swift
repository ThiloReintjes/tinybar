import Foundation

/// The span a Stats view covers.
public enum StatsRange: String, CaseIterable, Sendable, Identifiable {
    case week, month, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All time"
        }
    }

    /// nil for all time.
    public var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// Everything the Stats window shows for one range: token totals from `daily_usage`, activity
/// from `daily_stat`, streaks from the full day list (SPEC §13).
public struct StatsSummary: Sendable {
    public struct Day: Sendable, Identifiable {
        public var id: String { day }
        public var day: String
        public var tokens: [ProviderID: Int64]
    }

    public struct Tool: Sendable, Identifiable {
        public var id: ToolCategory { category }
        public var category: ToolCategory
        public var calls: Int64
        public var byProvider: [ProviderID: Int64]
    }

    public struct Model: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var provider: ProviderID
        public var tokens: Int64
        public var cost: Double?
        /// Output tokens per second, when there are enough samples to say.
        public var speed: Double?
        public var peakContext: Int64
    }

    public var range: StatsRange
    public var firstDay: String
    public var lastDay: String

    public var tokens: Int64
    public var tokensByProvider: [ProviderID: Int64]
    public var cost: Double?
    public var days: [Day]

    public var prompts: Int64
    public var responses: Int64
    public var toolCalls: Int64
    public var tools: [Tool]
    public var linesAdded: Int64
    public var linesRemoved: Int64
    public var agentMillis: Int64
    public var compactions: Int64
    public var compactedTokens: Int64
    public var peakContext: Int64
    /// Share of input tokens read from the prompt cache.
    public var cacheShare: Double?
    public var models: [Model]
    public var projects: Int

    /// Responses by weekday (0 = Monday) and local hour.
    public var heat: [[Int64]]
    public var activeDays: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var busiestDay: (day: String, tokens: Int64)?

    /// Providers whose activity counting starts after the range does (their older logs were
    /// gone before Tinybar counted activity), with the first day that is counted.
    public var activitySince: [ProviderID: String]

    public var isEmpty: Bool { tokens == 0 && responses == 0 }

    /// Speed needs this many samples before it is shown.
    public static let minimumSpeedSamples: Int64 = 10

    public static func build(
        usage: [DailyUsage], stats: [DailyStat], allDays: [String], range: StatsRange, prices: PriceTable,
        now: Date = Date(), calendar: Calendar = .current) -> StatsSummary
    {
        let today = DayKey.string(for: now, calendar: calendar)
        let first: String
        if let n = range.days {
            first = DayKey.daysAgo(n - 1, from: now, calendar: calendar)
        } else {
            first = allDays.first ?? today
        }
        let usage = usage.filter { $0.day >= first }
        let stats = stats.filter { $0.day >= first }

        var tokens: Int64 = 0
        var byProvider: [ProviderID: Int64] = [:]
        var cost = 0.0
        var priced = false
        var dayTotals: [String: [ProviderID: Int64]] = [:]
        var modelTokens: [String: (ProviderID, Int64, Double?)] = [:]
        var input: Int64 = 0, cacheRead: Int64 = 0
        var projects = Set<String>()
        for r in usage {
            let t = r.tokens.total
            tokens += t
            byProvider[r.provider, default: 0] += t
            dayTotals[r.day, default: [:]][r.provider, default: 0] += t
            let c = prices.cost(provider: r.provider, model: r.model, tokens: r.tokens)
            if let c { cost += c; priced = true }
            let m = modelTokens[r.model] ?? (r.provider, 0, 0)
            modelTokens[r.model] = (m.0, m.1 + t, c.flatMap { c in m.2.map { $0 + c } })
            input += r.tokens.input + r.tokens.cacheWrite + r.tokens.cacheRead
            cacheRead += r.tokens.cacheRead
            if !r.project.isEmpty { projects.insert(ProjectResolver.displayName(r.project)) }
        }

        var sums: [String: Int64] = [:]
        var tools: [ToolCategory: [ProviderID: Int64]] = [:]
        var speed: [String: (tokens: Int64, ms: Int64, n: Int64)] = [:]
        var peak: [String: Int64] = [:]
        var heat = Array(repeating: Array(repeating: Int64(0), count: 24), count: 7)
        var statStart: [ProviderID: String] = [:]
        for s in stats {
            statStart[s.provider] = min(statStart[s.provider] ?? s.day, s.day)
            if s.key.hasPrefix(StatKey.hourPrefix), let h = Int(s.key.dropFirst(StatKey.hourPrefix.count)), (0..<24).contains(h) {
                heat[weekday(s.day, calendar)][h] += s.value
            } else if s.key.hasPrefix(StatKey.toolPrefix) {
                let category = ToolCategory(tool: String(s.key.dropFirst(StatKey.toolPrefix.count)))
                tools[category, default: [:]][s.provider, default: 0] += s.value
            } else if s.key == StatKey.contextMax {
                peak[s.model] = max(peak[s.model] ?? 0, s.value)
            } else if s.key.hasPrefix("speed.") {
                var v = speed[s.model] ?? (0, 0, 0)
                switch s.key {
                case StatKey.speedTokens: v.tokens += s.value
                case StatKey.speedMillis: v.ms += s.value
                default: v.n += s.value
                }
                speed[s.model] = v
            } else {
                sums[s.key, default: 0] += s.value
            }
        }

        let toolLines = tools.map { Tool(category: $0.key, calls: $0.value.values.reduce(0, +), byProvider: $0.value) }
            .sorted { $0.calls > $1.calls }
        let models = modelTokens.map { name, v in
            let s = speed[name]
            return Model(
                name: name, provider: v.0, tokens: v.1, cost: v.2,
                speed: s.flatMap { $0.n >= minimumSpeedSamples && $0.ms > 0 ? Double($0.tokens) / (Double($0.ms) / 1000) : nil },
                peakContext: peak[name] ?? 0)
        }.sorted { $0.tokens > $1.tokens }

        // Days with activity, as a set over all history, for streaks.
        let active = Set(allDays)
        let (current, longest) = streaks(active, today: today, calendar: calendar)
        let busiest = dayTotals.map { ($0.key, $0.value.values.reduce(0, +)) }.max { $0.1 < $1.1 }

        // Every day in the range, so the chart has its gaps.
        var days: [Day] = []
        var cursor = DayKeyDate.date(first, calendar: calendar)
        let end = DayKeyDate.date(today, calendar: calendar)
        while cursor <= end {
            let key = DayKey.string(for: cursor, calendar: calendar)
            days.append(Day(day: key, tokens: dayTotals[key] ?? [:]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // Activity counting can start later than the token history (logs deleted before an
        // upgrade); say so rather than imply the agents were idle.
        var since: [ProviderID: String] = [:]
        for (provider, firstToken) in Dictionary(grouping: usage, by: \.provider).compactMapValues({ $0.map(\.day).min() }) {
            if let s = statStart[provider], s > firstToken { since[provider] = s }
        }

        return StatsSummary(
            range: range, firstDay: first, lastDay: today,
            tokens: tokens, tokensByProvider: byProvider, cost: priced ? cost : nil, days: days,
            prompts: sums[StatKey.prompts] ?? 0,
            responses: sums[StatKey.responses] ?? 0,
            toolCalls: toolLines.reduce(0) { $0 + $1.calls }, tools: toolLines,
            linesAdded: sums[StatKey.linesAdded] ?? 0, linesRemoved: sums[StatKey.linesRemoved] ?? 0,
            agentMillis: sums[StatKey.agentMillis] ?? 0,
            compactions: sums[StatKey.compactions] ?? 0, compactedTokens: sums[StatKey.compactedTokens] ?? 0,
            peakContext: peak.values.max() ?? 0,
            cacheShare: input > 0 ? Double(cacheRead) / Double(input) : nil,
            models: models, projects: projects.count,
            heat: heat, activeDays: dayTotals.count, currentStreak: current, longestStreak: longest,
            busiestDay: busiest.map { (day: $0.0, tokens: $0.1) },
            activitySince: since)
    }

    /// Consecutive active days ending today (or yesterday, while today has nothing yet), and the
    /// longest run ever.
    static func streaks(_ active: Set<String>, today: String, calendar: Calendar) -> (current: Int, longest: Int) {
        func previous(_ day: String) -> String {
            let d = DayKeyDate.date(day, calendar: calendar)
            return DayKey.string(for: calendar.date(byAdding: .day, value: -1, to: d) ?? d, calendar: calendar)
        }
        var current = 0
        var day = active.contains(today) ? today : previous(today)
        while active.contains(day) {
            current += 1
            day = previous(day)
        }
        var longest = 0
        for d in active where !active.contains(previous(d)) {
            var run = 0
            var x = DayKeyDate.date(d, calendar: calendar)
            while active.contains(DayKey.string(for: x, calendar: calendar)) {
                run += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: x) else { break }
                x = next
            }
            longest = max(longest, run)
        }
        return (current, longest)
    }

    private static func weekday(_ day: String, _ calendar: Calendar) -> Int {
        // Calendar weekday: 1 = Sunday … 7 = Saturday. Rows run Monday to Sunday.
        (calendar.component(.weekday, from: DayKeyDate.date(day, calendar: calendar)) + 5) % 7
    }
}

public enum DayKeyDate {
    public static func date(_ key: String, calendar: Calendar = .current) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}

extension ModelName {
    /// "claude-opus-5-5" → "Opus 5.5", "gpt-6.1-sol" → "GPT-6.1 Sol". For display only.
    public static func display(_ name: String) -> String {
        var parts = name.split(separator: "-").map(String.init)
        // Drop a trailing date stamp (claude-sonnet-5-5-20260101).
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        if parts.first == "claude" { parts.removeFirst() }
        var words: [String] = []
        var version: [String] = []
        func flush() {
            if !version.isEmpty { words.append(version.joined(separator: ".")); version = [] }
        }
        for p in parts {
            if p.first?.isNumber == true {
                version.append(p)
            } else {
                flush()
                words.append(p == "gpt" ? "GPT" : p.prefix(1).uppercased() + p.dropFirst())
            }
        }
        flush()
        guard !words.isEmpty else { return name }
        if words.first == "GPT", words.count > 1 { return "GPT-" + words[1] + (words.count > 2 ? " " + words.dropFirst(2).joined(separator: " ") : "") }
        return words.joined(separator: " ")
    }
}
