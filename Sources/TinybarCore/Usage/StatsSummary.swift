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

/// How many days one bar of the Stats chart covers.
public enum StatsBucket: String, Sendable {
    case day, week, month

    /// One bar per day up to three months, per week up to about a year and a half, then per month,
    /// so the chart stays between roughly 30 and 90 bars wide.
    public static func fitting(days: Int) -> StatsBucket {
        days <= 92 ? .day : days <= 7 * 78 ? .week : .month
    }
}

/// Everything the Stats window shows for one range: token totals from `daily_usage`, activity
/// from `daily_stat`, streaks from the full day list (SPEC §13). With a model picked, everything
/// but the model list counts that model alone.
public struct StatsSummary: Sendable {
    /// One bar of the chart: a day, a week (Monday to Sunday) or a calendar month.
    public struct Bar: Sendable, Identifiable {
        public var id: String { start }
        /// First and last day the bar covers; the last bar ends today.
        public var start: String
        public var end: String
        public var tokens: [ProviderID: Int64]
        public var cost: Double?
        public var hasUnpriced: Bool = false
        public var prompts: Int64
        public var toolCalls: Int64
        public var agentMillis: Int64
        public var linesAdded: Int64

        public var totalTokens: Int64 { tokens.values.reduce(0, +) }
    }

    public struct Tool: Sendable, Identifiable {
        public var id: ToolCategory { category }
        public var category: ToolCategory
        public var calls: Int64
        public var byProvider: [ProviderID: Int64]
        /// The tool names counted in this category, most used first.
        public var names: [Count]
    }

    public struct Count: Sendable, Hashable {
        public var name: String
        public var value: Int64
    }

    public struct Model: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var provider: ProviderID
        public var tokens: Int64
        public var cost: Double?
        public var responses: Int64
        /// Output tokens per second, when there are enough samples to say.
        public var speed: Double?
        public var speedSamples: Int64
        public var peakContext: Int64
        /// Every counter summed for this model over the range (hourly ones aside), for the pages
        /// that compare models.
        public var values: [String: Int64] = [:]

        public func value(_ key: String) -> Int64 { values[key] ?? 0 }
    }

    /// Something counted by name and split by subscription: a program, a language.
    public struct Split: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var byProvider: [ProviderID: Int64]
        public var total: Int64 { byProvider.values.reduce(0, +) }
    }

    /// The shell commands the agents ran (SPEC §13).
    public struct Commands: Sendable {
        public var count: Int64 = 0
        public var byProvider: [ProviderID: Int64] = [:]
        public var chars: Int64 = 0
        public var pipedHeadTail: Int64 = 0
        public var inlinePython: Int64 = 0
        public var inlineJS: Int64 = 0
        public var finished: Int64 = 0
        public var failed: Int64 = 0
        /// Programs by how many commands ran them, most first.
        public var programs: [Split] = []
        /// Git subcommands by how many commands ran them, most first.
        public var git: [Count] = []
    }

    /// One language's lines written, from the edited files' kinds.
    public struct Language: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var added: [ProviderID: Int64]
        public var removed: Int64
        public var edits: Int64
        public var totalAdded: Int64 { added.values.reduce(0, +) }
    }

    /// One weekday-and-hour cell of the heat map, summed over every such hour in the range.
    public struct Hour: Sendable {
        public var responses: Int64 = 0
        public var tokens: Int64 = 0
    }

    public var range: StatsRange
    /// The model everything is filtered to, if one is picked.
    public var model: String?
    public var firstDay: String
    public var lastDay: String

    public var tokens: Int64
    /// Every model's tokens in the range, filtered or not: the card sizes its type to this, so
    /// picking a model doesn't resize it.
    public var allTokens: Int64
    /// The same tokens by kind: fresh input, output, cache writes and cache reads.
    public var tokenCounts: TokenCounts
    public var tokensByProvider: [ProviderID: Int64]
    public var cost: Double?
    /// True when some contributing rows have no price; cost is the known part only.
    public var hasUnpriced: Bool = false
    public var bucket: StatsBucket
    public var bars: [Bar]

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
    /// Every model used in the range, unfiltered, most tokens first.
    public var models: [Model]
    public var commands: Commands
    /// Languages by lines added, most first.
    public var languages: [Language]
    public var projects: Int
    /// Projects by tokens, for the window only: the copied image shows just the count.
    public var topProjects: [Count]

    /// By weekday (0 = Monday) and local hour.
    public var heat: [[Hour]]
    /// How many of each weekday the range spans, Monday first.
    public var weekdays: [Int]
    public var activeDays: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var busiestDay: (day: String, tokens: Int64)?

    /// For Providers whose activity was counted from only part of their tokens' logs (the rest
    /// were deleted or compressed before Tinybar counted activity): the share that was read.
    public var activityCoverage: [ProviderID: Double]

    public var isEmpty: Bool { tokens == 0 && responses == 0 }

    /// Speed needs this many samples before it is shown.
    public static let minimumSpeedSamples: Int64 = 10

    /// `allDays` are the days with any usage over all history: all time starts at the first.
    /// Streaks count `streakDays` instead when given (the days one model was used).
    public static func build(
        usage: [DailyUsage], stats: [DailyStat], allDays: [String], streakDays: [String]? = nil,
        range: StatsRange, model: String? = nil,
        prices: PriceTable, now: Date = Date(), calendar: Calendar = .current) -> StatsSummary
    {
        let today = DayKey.string(for: now, calendar: calendar)
        let first: String
        if let n = range.days {
            first = DayKey.daysAgo(n - 1, from: now, calendar: calendar)
        } else {
            first = min(allDays.first ?? today, today)
        }
        let allUsage = usage.filter { $0.day >= first && $0.day <= today }
        let allStats = stats.filter { $0.day >= first && $0.day <= today }
        let usage = model.map { m in allUsage.filter { $0.model == m } } ?? allUsage
        let stats = model.map { m in allStats.filter { $0.model == m } } ?? allStats

        // Every day in the range, then the bars they fall into.
        var dayList: [String] = []
        var cursor = DayKeyDate.date(first, calendar: calendar)
        let end = DayKeyDate.date(today, calendar: calendar)
        while cursor <= end {
            dayList.append(DayKey.string(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let bucket = range == .all ? StatsBucket.fitting(days: dayList.count) : .day
        var barIndex: [String: Int] = [:]
        var bars: [Bar] = []
        var weekdays = Array(repeating: 0, count: 7)
        for day in dayList {
            weekdays[weekday(day, calendar)] += 1
            let start = barStart(day, bucket, calendar)
            if let last = bars.indices.last, bars[last].start == start {
                bars[last].end = day
                barIndex[day] = last
            } else {
                barIndex[day] = bars.count
                bars.append(Bar(start: start, end: day, tokens: [:], cost: nil, prompts: 0, toolCalls: 0, agentMillis: 0, linesAdded: 0))
            }
        }

        var tokens: Int64 = 0
        var counts = TokenCounts()
        var byProvider: [ProviderID: Int64] = [:]
        var cost = 0.0
        var priced = false
        var unpriced = false
        var dayTotals: [String: Int64] = [:]
        var input: Int64 = 0, cacheRead: Int64 = 0
        var projects: [String: Int64] = [:]
        let aliases = UsageSummary.projectAliases(usage.map(\.project))
        for r in usage {
            let t = r.tokens.total
            tokens += t
            counts += r.tokens
            byProvider[r.provider, default: 0] += t
            dayTotals[r.day, default: 0] += t
            let c = prices.cost(r)
            if let c { cost += c; priced = true } else { unpriced = true }
            if let i = barIndex[r.day] {
                bars[i].tokens[r.provider, default: 0] += t
                if let c { bars[i].cost = (bars[i].cost ?? 0) + c } else { bars[i].hasUnpriced = true }
            }
            input += r.tokens.input + r.tokens.cacheWrite + r.tokens.cacheRead
            cacheRead += r.tokens.cacheRead
            if !r.project.isEmpty { projects[aliases[r.project] ?? r.project, default: 0] += t }
        }

        var sums: [String: Int64] = [:]
        var tools: [ToolCategory: [ProviderID: Int64]] = [:]
        var toolNames: [ToolCategory: [String: Int64]] = [:]
        var peak: Int64 = 0
        var heat = Array(repeating: Array(repeating: Hour(), count: 24), count: 7)
        var counted: [ProviderID: Int64] = [:]
        for s in stats {
            let bar = barIndex[s.day]
            if s.key.hasPrefix(StatKey.hourTokensPrefix) {
                if let h = Int(s.key.dropFirst(StatKey.hourTokensPrefix.count)), (0..<24).contains(h) {
                    heat[weekday(s.day, calendar)][h].tokens += s.value
                }
                counted[s.provider, default: 0] += s.value
            } else if s.key.hasPrefix(StatKey.hourPrefix) {
                if let h = Int(s.key.dropFirst(StatKey.hourPrefix.count)), (0..<24).contains(h) {
                    heat[weekday(s.day, calendar)][h].responses += s.value
                }
            } else if s.key.hasPrefix(StatKey.toolPrefix) {
                let name = String(s.key.dropFirst(StatKey.toolPrefix.count))
                let category = ToolCategory(tool: name)
                tools[category, default: [:]][s.provider, default: 0] += s.value
                toolNames[category, default: [:]][name, default: 0] += s.value
                if let bar { bars[bar].toolCalls += s.value }
            } else if s.key == StatKey.contextMax {
                peak = max(peak, s.value)
            } else if !s.key.hasPrefix("speed.") {
                sums[s.key, default: 0] += s.value
                if let bar {
                    switch s.key {
                    case StatKey.prompts: bars[bar].prompts += s.value
                    case StatKey.agentMillis: bars[bar].agentMillis += s.value
                    case StatKey.linesAdded: bars[bar].linesAdded += s.value
                    default: break
                    }
                }
            }
        }

        var commands = Commands()
        var programs: [String: [ProviderID: Int64]] = [:]
        var git: [String: Int64] = [:]
        var languages: [String: Language] = [:]
        for s in stats where s.key.hasPrefix("cmd.") || s.key.hasPrefix("ext.") {
            switch s.key {
            case StatKey.commands:
                commands.count += s.value
                commands.byProvider[s.provider, default: 0] += s.value
            case StatKey.commandChars: commands.chars += s.value
            case StatKey.pipedHeadTail: commands.pipedHeadTail += s.value
            case StatKey.inlinePython: commands.inlinePython += s.value
            case StatKey.inlineJS: commands.inlineJS += s.value
            case StatKey.commandsFinished: commands.finished += s.value
            case StatKey.commandsFailed: commands.failed += s.value
            case let k where k.hasPrefix(StatKey.programPrefix):
                programs[String(k.dropFirst(StatKey.programPrefix.count)), default: [:]][s.provider, default: 0] += s.value
            case let k where k.hasPrefix(StatKey.gitPrefix):
                git[String(k.dropFirst(StatKey.gitPrefix.count)), default: 0] += s.value
            default:
                for (prefix, part) in [(StatKey.extAddedPrefix, 0), (StatKey.extRemovedPrefix, 1), (StatKey.extEditsPrefix, 2)]
                where s.key.hasPrefix(prefix) {
                    let name = FileKind.language(String(s.key.dropFirst(prefix.count)))
                    var l = languages[name] ?? Language(name: name, added: [:], removed: 0, edits: 0)
                    switch part {
                    case 0: l.added[s.provider, default: 0] += s.value
                    case 1: l.removed += s.value
                    default: l.edits += s.value
                    }
                    languages[name] = l
                }
            }
        }
        commands.programs = programs.map { Split(name: $0.key, byProvider: $0.value) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        commands.git = git.map { Count(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }

        let toolLines = tools.map { category, byProvider in
            Tool(category: category, calls: byProvider.values.reduce(0, +), byProvider: byProvider,
                 names: (toolNames[category] ?? [:]).map { Count(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value })
        }.sorted { $0.calls > $1.calls }

        // Days with activity, as a set over all history, for streaks.
        let (current, longest) = streaks(Set((streakDays ?? allDays).filter { $0 <= today }), today: today, calendar: calendar)
        let busiest = dayTotals.max { $0.value < $1.value }

        // Token totals outlive the logs; activity is counted from the logs on disk. Where they
        // differ, say how much was read rather than imply the agents were idle.
        var coverage: [ProviderID: Double] = [:]
        for (provider, t) in byProvider where t > 0 {
            let share = Double(counted[provider] ?? 0) / Double(t)
            if share < 0.97 { coverage[provider] = share }
        }

        return StatsSummary(
            range: range, model: model, firstDay: first, lastDay: today,
            tokens: tokens, allTokens: allUsage.reduce(0) { $0 + $1.tokens.total }, tokenCounts: counts, tokensByProvider: byProvider, cost: priced ? cost : nil, hasUnpriced: unpriced, bucket: bucket, bars: bars,
            prompts: sums[StatKey.prompts] ?? 0,
            responses: sums[StatKey.responses] ?? 0,
            toolCalls: toolLines.reduce(0) { $0 + $1.calls }, tools: toolLines,
            linesAdded: sums[StatKey.linesAdded] ?? 0, linesRemoved: sums[StatKey.linesRemoved] ?? 0,
            agentMillis: sums[StatKey.agentMillis] ?? 0,
            compactions: sums[StatKey.compactions] ?? 0, compactedTokens: sums[StatKey.compactedTokens] ?? 0,
            peakContext: peak,
            cacheShare: input > 0 ? Double(cacheRead) / Double(input) : nil,
            models: models(allUsage, allStats, prices),
            commands: commands,
            languages: languages.values.filter { $0.totalAdded + $0.removed > 0 || $0.edits > 0 }
                .sorted { $0.totalAdded != $1.totalAdded ? $0.totalAdded > $1.totalAdded : $0.name < $1.name },
            projects: projects.count,
            topProjects: projects.map { Count(name: ProjectResolver.displayName($0.key), value: $0.value) }.sorted { $0.value > $1.value },
            heat: heat, weekdays: weekdays, activeDays: dayTotals.count, currentStreak: current, longestStreak: longest,
            busiestDay: busiest.map { (day: $0.key, tokens: $0.value) },
            activityCoverage: coverage)
    }

    private static func models(_ usage: [DailyUsage], _ stats: [DailyStat], _ prices: PriceTable) -> [Model] {
        var models: [String: Model] = [:]
        for r in usage {
            var m = models[r.model] ?? Model(name: r.model, provider: r.provider, tokens: 0, cost: 0, responses: 0,
                                              speed: nil, speedSamples: 0, peakContext: 0)
            m.tokens += r.tokens.total
            let c = prices.cost(r)
            m.cost = c.flatMap { c in m.cost.map { $0 + c } }
            models[r.model] = m
        }
        var speed: [String: (tokens: Int64, ms: Int64)] = [:]
        for s in stats where models[s.model] != nil {
            switch s.key {
            case StatKey.responses: models[s.model]?.responses += s.value
            case StatKey.contextMax:
                let peak = models[s.model]?.peakContext ?? 0
                models[s.model]?.peakContext = max(peak, s.value)
            case StatKey.speedTokens: speed[s.model, default: (0, 0)].tokens += s.value
            case StatKey.speedMillis: speed[s.model, default: (0, 0)].ms += s.value
            case StatKey.speedSamples: models[s.model]?.speedSamples += s.value
            default:
                if !s.key.hasPrefix(StatKey.hourPrefix), !s.key.hasPrefix(StatKey.hourTokensPrefix) {
                    models[s.model]?.values[s.key, default: 0] += s.value
                }
            }
            if s.key == StatKey.responses { models[s.model]?.values[s.key, default: 0] += s.value }
        }
        for (name, s) in speed {
            guard let m = models[name], m.speedSamples >= minimumSpeedSamples, s.ms > 0 else { continue }
            models[name]?.speed = Double(s.tokens) / (Double(s.ms) / 1000)
        }
        return models.values.sorted { $0.tokens > $1.tokens }
    }

    /// The first day of the bar a day falls into.
    static func barStart(_ day: String, _ bucket: StatsBucket, _ calendar: Calendar) -> String {
        switch bucket {
        case .day:
            return day
        case .week:
            let date = DayKeyDate.date(day, calendar: calendar)
            let monday = calendar.date(byAdding: .day, value: -weekday(day, calendar), to: date) ?? date
            return DayKey.string(for: monday, calendar: calendar)
        case .month:
            return String(day.prefix(7)) + "-01"
        }
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

    static func weekday(_ day: String, _ calendar: Calendar) -> Int {
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
