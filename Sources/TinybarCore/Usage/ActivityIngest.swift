import Foundation

extension TokenCounts {
    /// The context a response read: everything sent in, cached or not.
    public var context: Int64 { input + cacheWrite + cacheRead }

    /// Keep a whole usage snapshot: GPT streams can reclassify preliminary input as cached.
    /// More output means a more complete copy; on a tie, the later copy wins.
    func mergingCopy(_ later: TokenCounts) -> TokenCounts {
        later.output >= output ? later : self
    }
}

/// One Claude message as seen across its streamed lines in a single read of a file.
struct ClaudeMessage {
    var record: UsageRecord
    var tools: [String: String]
    var start: Date
    var end: Date
    var request: Date?
    var stepStart: Date?

    init(_ m: ClaudeLogParser.Message) {
        record = m.entry.record
        tools = Dictionary(m.tools.map { ($0.id, $0.name) }) { a, _ in a }
        start = m.at
        end = m.at
        request = m.request
        stepStart = m.stepStart
    }

    mutating func merge(_ m: ClaudeLogParser.Message) {
        record.tokens = record.tokens.mergingCopy(m.entry.record.tokens)
        if record.cwd == nil { record.cwd = m.entry.record.cwd }
        for t in m.tools where tools[t.id] == nil { tools[t.id] = t.name }
        start = min(start, m.at)
        end = max(end, m.at)
        request = Self.earliest(request, m.request)
        stepStart = Self.earliest(stepStart, m.stepStart)
    }

    static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): min(a, b)
        default: a ?? b
        }
    }
}

/// What has been counted for a Claude message, kept in `claude_message.stats`. Stats are derived
/// from it, so when a later read of the message adds a tool call or a later line, the old
/// contribution is replaced rather than added to (like the token counts).
struct MessageStats: Codable, Equatable {
    /// Tool call id → normalized tool name.
    var t: [String: String]
    /// First and last line, request sent, step start (epoch milliseconds).
    var s: Int64
    var e: Int64
    var r: Int64?
    var p: Int64?

    init(_ m: ClaudeMessage) {
        t = m.tools
        s = m.start.millis
        e = m.end.millis
        r = m.request?.millis
        p = m.stepStart?.millis
    }

    func merged(with old: MessageStats?) -> MessageStats {
        guard let old else { return self }
        var m = old
        m.t.merge(t) { a, _ in a }
        m.s = min(old.s, s)
        m.e = max(old.e, e)
        m.r = [old.r, r].compactMap { $0 }.min()
        m.p = [old.p, p].compactMap { $0 }.min()
        return m
    }

    var encoded: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }

    /// The counters this message adds, keyed by stat key.
    func contributions(tokens: TokenCounts) -> [String: Int64] {
        var c: [String: Int64] = [StatKey.responses: 1]
        let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(s) / 1000))
        c[StatKey.hour(hour)] = 1
        c[StatKey.hourTokens(hour)] = tokens.total
        for name in t.values { c[StatKey.tool(name), default: 0] += 1 }
        if t.count > 1 { c[StatKey.parallel] = 1 }
        if let r, SpeedSample.accepts(outputTokens: tokens.output, millis: e - r) {
            c[StatKey.speedTokens] = tokens.output
            c[StatKey.speedMillis] = e - r
            c[StatKey.speedSamples] = 1
        }
        if let p, (0...AgentTime.maximumStepMillis).contains(e - p) {
            c[StatKey.agentMillis] = e - p
        }
        return c
    }
}

/// Stat changes collected during one file read, written in one go.
struct StatBatch {
    struct Slot: Hashable {
        var day: String
        var provider: ProviderID
        var model: String
        var key: String
    }

    private(set) var sums: [Slot: Int64] = [:]
    private(set) var maxima: [Slot: Int64] = [:]

    private func slot(_ day: String, _ provider: ProviderID, _ model: String, _ key: String) -> Slot {
        Slot(day: day, provider: provider, model: model, key: key)
    }

    mutating func add(_ event: StatEvent, provider: ProviderID, model: String) {
        let day = DayKey.string(for: event.timestamp)
        for (key, value) in event.values { sums[slot(day, provider, model, key), default: 0] += value }
    }

    /// A Codex response: counted, bucketed by hour, and its context size.
    mutating func addResponse(day: String, provider: ProviderID, model: String, at: Date, tokens: TokenCounts) {
        let hour = Calendar.current.component(.hour, from: at)
        sums[slot(day, provider, model, StatKey.responses), default: 0] += 1
        sums[slot(day, provider, model, StatKey.hour(hour)), default: 0] += 1
        sums[slot(day, provider, model, StatKey.hourTokens(hour)), default: 0] += tokens.total
        addMaximum(day: day, provider: provider, model: model, StatKey.contextMax, tokens.context)
    }

    mutating func addMaximum(day: String, provider: ProviderID, model: String, _ key: String, _ value: Int64) {
        let s = slot(day, provider, model, key)
        maxima[s] = max(maxima[s] ?? 0, value)
    }

    /// Swaps an earlier contribution for a new one.
    mutating func replace(day: String, provider: ProviderID, model: String, old: [String: Int64], new: [String: Int64]) {
        for key in Set(old.keys).union(new.keys) {
            let delta = (new[key] ?? 0) - (old[key] ?? 0)
            if delta != 0 { sums[slot(day, provider, model, key), default: 0] += delta }
        }
    }
}
