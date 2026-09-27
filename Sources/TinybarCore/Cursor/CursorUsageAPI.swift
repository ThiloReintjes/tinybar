import Foundation

/// Read-only calls to the endpoint Cursor's own dashboard uses (cursor.com/dashboard → Usage).
enum CursorUsageAPI {
    static let baseURL = URL(string: "https://cursor.com")!
    static let sessionCookie = "WorkosCursorSessionToken"

    // MARK: Wire types

    struct Summary: Decodable {
        var billingCycleStart: String?
        var billingCycleEnd: String?
        var membershipType: String?
        var isUnlimited: Bool?
        var individualUsage: Individual?
        var teamUsage: Team?
    }

    struct Individual: Decodable {
        var plan: Plan?
        var onDemand: Amount?
        var overall: Amount?
    }

    struct Team: Decodable {
        var onDemand: Amount?
        var pooled: Amount?
    }

    /// Money values are in cents; `*PercentUsed` are already percentages (0.36 means 0.36%).
    struct Plan: Decodable {
        var enabled: Bool?
        var used: Int?
        var limit: Int?
        var autoPercentUsed: Double?
        var apiPercentUsed: Double?
        var totalPercentUsed: Double?
    }

    struct Amount: Decodable {
        var enabled: Bool?
        var used: Int?
        var limit: Int?
    }

    // MARK: Fetch

    static func fetch(cookieHeader: String, source: DataSource, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/usage-summary"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let data = try await HTTP.send(request, session: session, providerName: "Cursor")
        let summary: Summary
        do {
            summary = try JSONDecoder().decode(Summary.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected Cursor usage response")
        }
        var snapshot = snapshot(from: summary)
        snapshot.source = source
        return snapshot
    }

    // MARK: Mapping

    /// One window per billing cycle: the plan's included usage, split into Auto and API
    /// (named models) when Cursor reports them separately. Team plans without an individual
    /// plan fall back to the member's cap, then the shared pool.
    static func snapshot(from s: Summary, now: Date = Date()) -> ProviderSnapshot {
        let start = s.billingCycleStart.flatMap(parseISODate)
        let end = s.billingCycleEnd.flatMap(parseISODate)
        let duration: Int? = if let start, let end, end > start { Int(end.timeIntervalSince(start)) } else { nil }

        func window(_ id: String, _ title: String, _ percent: Double, modelSpecific: Bool = false) -> LimitWindow {
            LimitWindow(
                id: id, title: title, usedPercent: min(max(percent, 0), 100),
                resetsAt: end, durationSeconds: duration, isModelSpecific: modelSpecific)
        }
        func percent(_ used: Int?, _ limit: Int?) -> Double? {
            guard let used, let limit, limit > 0 else { return nil }
            return Double(used) / Double(limit) * 100
        }

        var windows: [LimitWindow] = []
        let plan = s.individualUsage?.plan
        let total = plan?.totalPercentUsed
            ?? percent(plan?.used, plan?.limit)
            ?? percent(s.individualUsage?.overall?.used, s.individualUsage?.overall?.limit)
            ?? percent(s.teamUsage?.pooled?.used, s.teamUsage?.pooled?.limit)
        if s.isUnlimited != true, let total {
            windows.append(window("monthly", "Billing cycle", total))
            if let auto = plan?.autoPercentUsed { windows.append(window("monthly-auto", "Auto", auto, modelSpecific: true)) }
            if let api = plan?.apiPercentUsed { windows.append(window("monthly-api", "API models", api, modelSpecific: true)) }
        }

        // On-demand spend beyond the plan, like Claude's extra usage.
        var extra: ExtraUsageSpend?
        if let od = s.individualUsage?.onDemand, od.enabled == true || (od.used ?? 0) > 0 {
            extra = ExtraUsageSpend(
                used: Double(od.used ?? 0) / 100, limit: od.limit.map { Double($0) / 100 }, currency: "USD")
        }

        return ProviderSnapshot(
            provider: .cursor,
            plan: s.membershipType.map(formatPlan),
            windows: windows,
            extraUsage: extra,
            source: .cli,
            fetchedAt: now)
    }

    static func formatPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "free", "hobby": "Hobby"
        case "free_trial": "Trial"
        case "pro": "Pro"
        case "pro_plus", "pro+": "Pro+"
        case "ultra": "Ultra"
        case "team", "business": "Teams"
        case "enterprise": "Enterprise"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
