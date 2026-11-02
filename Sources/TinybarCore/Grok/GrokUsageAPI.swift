import Foundation

/// The calls the Grok CLI makes for `/usage`. They aren't documented, but the CLI is open source, and
/// T3 Code and CodexBar read the same ones (ADR 0012).
enum GrokUsageAPI {
    static let defaultBase = URL(string: "https://cli-chat-proxy.grok.com/v1")!
    static let noLimit = ProviderError.unexpected("Grok reports no usage limit for this account")
    static let noTeamUsage = ProviderError.unexpected("Grok doesn't report usage for team accounts")
    static let periodEnded = ProviderError.unexpected("Grok reported a usage period that has already ended")

    // MARK: Wire types

    struct Report: Decodable {
        var config: Config?
    }

    /// Only what the bar stands on has to be readable: proto3 leaves zeros out, and the money is
    /// beside the point if it changes shape.
    struct Config: Decodable {
        var creditUsagePercent: Double?
        var currentPeriod: Period?
        var billingPeriodStart: String?
        var billingPeriodEnd: String?
        var onDemandCap: Cent?
        var onDemandUsed: Cent?

        enum CodingKeys: String, CodingKey {
            case creditUsagePercent, currentPeriod, billingPeriodStart, billingPeriodEnd, onDemandCap, onDemandUsed
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Left out means zero. Present but unreadable must not read as zero too.
            creditUsagePercent = c.contains(.creditUsagePercent) ? try c.decode(Double.self, forKey: .creditUsagePercent) : nil
            currentPeriod = try? c.decode(Period.self, forKey: .currentPeriod)
            billingPeriodStart = try? c.decode(String.self, forKey: .billingPeriodStart)
            billingPeriodEnd = try? c.decode(String.self, forKey: .billingPeriodEnd)
            // Left out means zero too. nil is an amount nobody can read.
            onDemandCap = c.contains(.onDemandCap) ? try? c.decode(Cent.self, forKey: .onDemandCap) : Cent()
            onDemandUsed = c.contains(.onDemandUsed) ? try? c.decode(Cent.self, forKey: .onDemandUsed) : Cent()
        }
    }

    struct Period: Decodable {
        var type: String?
        var start: String?
        var end: String?

        enum CodingKeys: String, CodingKey { case type, start, end }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            start = try? c.decode(String.self, forKey: .start)
            end = try? c.decode(String.self, forKey: .end)
        }
    }

    /// US cents. `{}` is zero.
    struct Cent: Decodable {
        var val: Double = 0

        enum CodingKeys: String, CodingKey { case val }

        init() {}

        init(from decoder: any Decoder) throws {
            val = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Double.self, forKey: .val) ?? 0
        }
    }

    private struct Settings: Decodable {
        var tier: String?
        enum CodingKeys: String, CodingKey { case tier = "subscription_tier_display" }
    }

    // MARK: Fetch

    static func fetch(base: URL, login: GrokLogins.Login, session: URLSession) async throws -> ProviderSnapshot {
        async let plan = plan(base: base, login: login, session: session)
        // CodexBar found a team's usage turned away, so that isn't taken for a dead login. 401 still is.
        let data: Data
        do {
            data = try await HTTP.send(
                request(base: base, path: "billing", query: "format=credits", login: login, timeout: 15),
                session: session, providerName: "Grok", passing: login.team == nil ? [] : [400, 403, 404])
        } catch is HTTP.Status {
            throw noTeamUsage
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw ProviderError.unexpected("Unexpected Grok usage response")
        }
        return try await snapshot(from: report, plan: plan)
    }

    /// The name of the plan isn't in the billing report. Without it, the limits still count.
    private static func plan(base: URL, login: GrokLogins.Login, session: URLSession) async -> String? {
        let request = request(base: base, path: "settings", login: login, timeout: 5)
        guard let data = try? await HTTP.send(request, session: session, providerName: "Grok"),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return nil }
        return GrokLogins.text(settings.tier)
    }

    private static func request(base: URL, path: String, query: String? = nil, login: GrokLogins.Login, timeout: TimeInterval) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.percentEncodedQuery = query
        var request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(login.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        return request
    }

    // MARK: Mapping

    static func snapshot(from report: Report, plan: String?, now: Date = Date()) throws -> ProviderSnapshot {
        guard let config = report.config, let window = window(config) else { throw noLimit }
        // With one Account, nothing else catches this: it would look like a fresh reading resetting "now".
        if let reset = window.resetsAt, reset <= now { throw periodEnded }
        return ProviderSnapshot(provider: .grok, plan: plan, windows: [window], extraUsage: extraUsage(config), source: .cli, fetchedAt: now)
    }

    /// One pool for everything Grok does: Chat, Build and the rest are shares of it, not limits.
    private static func window(_ config: Config) -> LimitWindow? {
        let current = config.currentPeriod
        // A period's type and bounds go together, never one from each. Older accounts have only the
        // billing bounds, with no type to say what they are.
        let (type, start, end): (String?, Date?, Date?) =
            if let end = current?.end.flatMap(parseISODate) {
                (current?.type, current?.start.flatMap(parseISODate), end)
            } else if let end = config.billingPeriodEnd.flatMap(parseISODate) {
                (nil, config.billingPeriodStart.flatMap(parseISODate), end)
            } else {
                (current?.type, nil, nil)
            }
        var measured: Int?
        if let start, let end, start < end {
            measured = Int(end.timeIntervalSince(start).rounded())
        }

        let week = 7 * 86400
        let saysWeekly = type == "USAGE_PERIOD_TYPE_WEEKLY"
        let saysMonthly = type == "USAGE_PERIOD_TYPE_MONTHLY"
        let isWeekly = saysWeekly || (!saysMonthly && measured == week)
        let isMonthly = saysMonthly || (!saysWeekly && measured.map { (28 * 86400)...(31 * 86400) ~= $0 } == true)

        // Grok leaves out a zero, but only a whole period it calls weekly or monthly says that's what
        // happened. A report on the older bounds counts its use in other fields, so nothing there means zero.
        let isWholePeriod = measured != nil && (saysWeekly || saysMonthly)
        guard let used = config.creditUsagePercent ?? (isWholePeriod ? 0 : nil) else { return nil }
        let (id, title, seconds): (String, String, Int?) =
            if isWeekly {
                ("weekly", "Weekly", week)
            } else if isMonthly {
                ("monthly", "Monthly", measured ?? LimitWindow.monthSeconds(endingAt: end))
            } else {
                ("credits", "Credits", measured)
            }
        return LimitWindow(id: id, title: title, usedPercent: min(max(used, 0), 100), resetsAt: end, durationSeconds: seconds)
    }

    /// Pay-as-you-go spend past the pool. Most accounts report a zero pair, which is no spend to show.
    private static func extraUsage(_ config: Config) -> ExtraUsageSpend? {
        guard let usedCents = config.onDemandUsed?.val, let capCents = config.onDemandCap?.val else { return nil }
        let used = max(usedCents, 0) / 100
        let cap = max(capCents, 0) / 100
        guard used > 0 || cap > 0 else { return nil }
        return ExtraUsageSpend(used: used, limit: cap > 0 ? cap : nil, currency: "USD")
    }
}
