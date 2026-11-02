import Foundation

/// The call GitHub's own clients make for a user's Copilot quotas. It isn't documented, but the
/// Copilot SDK's types describe it and the rules here follow VS Code's `parseQuotas` (ADR 0011).
enum CopilotUsageAPI {
    static let noPlan = ProviderError.unexpected("This GitHub account has no Copilot plan")
    static let refusedHost = ProviderError.unexpected("This Copilot login is for a server Tinybar won't send it to")
    static let ended = ProviderError.unexpected("This GitHub account's Copilot subscription has ended")

    // MARK: Wire types

    struct Report: Decodable {
        var sku: String?
        var plan: String?
        var tokenBasedBilling: Bool?
        var quotaResetDateUTC: String?
        var quotaResetDate: String?
        var limitedUserResetDate: String?
        var snapshots: [String: Entry]?
        var monthlyQuotas: [String: LossyNumber]?
        var limitedUserQuotas: [String: LossyNumber]?

        enum CodingKeys: String, CodingKey {
            case sku = "access_type_sku"
            case plan = "copilot_plan"
            case tokenBasedBilling = "token_based_billing"
            case quotaResetDateUTC = "quota_reset_date_utc"
            case quotaResetDate = "quota_reset_date"
            case limitedUserResetDate = "limited_user_reset_date"
            case snapshots = "quota_snapshots"
            case monthlyQuotas = "monthly_quotas"
            case limitedUserQuotas = "limited_user_quotas"
        }
    }

    /// A quota that is null or unreadable is one quota lost, not the report.
    struct Entry: Decodable {
        var quota: Quota?

        init(from decoder: any Decoder) throws {
            quota = try? Quota(from: decoder)
        }
    }

    struct Quota: Decodable {
        var unlimited: Bool?
        var hasQuota: Bool?
        var entitlement: LossyNumber?
        var remaining: LossyNumber?
        var percentRemaining: LossyNumber?
        var creditsUsed: LossyNumber?
        var resetAt: LossyNumber?

        /// The SDK documents an entitlement of -1 as this too.
        var isUnlimited: Bool { unlimited == true || entitlement?.value == -1 }

        enum CodingKeys: String, CodingKey {
            case unlimited
            case hasQuota = "has_quota"
            case entitlement
            case remaining
            case percentRemaining = "percent_remaining"
            case creditsUsed = "credits_used"
            case resetAt = "quota_reset_at"
        }
    }

    /// A number, sometimes as a string. Anything else counts as absent rather than failing the report.
    struct LossyNumber: Decodable {
        var value: Double?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let number = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap(Double.init)
            value = number.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    // MARK: Fetch

    /// Where a host's API is. A token only goes to GitHub, GitHub Enterprise Cloud (`*.ghe.com`) or
    /// this Mac (`Scripts/verify-copilot.py`), never to a host named in a file (SECURITY.md).
    static func origin(host raw: String) -> URL? {
        guard let c = URLComponents(string: raw.contains("://") ? raw : "https://\(raw)"),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased()
        else { return nil }
        var origin = URLComponents()
        if HTTP.isLoopback(scheme: scheme, host: host) {
            origin.scheme = scheme
            origin.host = c.host
            origin.port = c.port
            return origin.url
        }
        guard scheme == "https", c.port == nil, host == "github.com" || host.hasSuffix(".ghe.com") else { return nil }
        origin.scheme = "https"
        origin.host = host.hasPrefix("api.") ? host : "api.\(host)"
        return origin.url
    }

    static func fetch(origin: URL, token: String, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: origin.appendingPathComponent("copilot_internal/user"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            data = try await HTTP.send(request, session: session, providerName: "GitHub", passing: [403, 404])
        } catch let status as HTTP.Status {
            if status.code == 404 { throw noPlan }
            // The rate limit is per GitHub user, and `gh` and everything else share it.
            let message = String(decoding: status.body, as: UTF8.self).lowercased()
            throw message.contains("rate limit") ? ProviderError.rateLimited(retryAfter: nil) : ProviderError.loginExpired
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw ProviderError.unexpected("Unexpected Copilot usage response")
        }
        return try snapshot(from: report)
    }

    // MARK: Mapping

    /// All of them run for a calendar month. `chat` and `completions` are unlimited on paid plans.
    static func snapshot(from report: Report, now: Date = Date()) throws -> ProviderSnapshot {
        if report.sku == "subscription_ended" { throw ended }
        let reset = [report.quotaResetDateUTC, report.quotaResetDate, report.limitedUserResetDate]
            .lazy.compactMap { $0.flatMap(parseResetDate) }.first
        let billedByTokens = report.tokenBasedBilling == true
        let windows = [
            ("premium_interactions", "premium", billedByTokens ? "AI Credits" : "Premium"),
            ("chat", "chat", "Chat"),
            ("completions", "completions", "Completions"),
        ].compactMap { key, id, title in window(report, key: key, id: id, title: title, reset: reset) }

        // A seat billed by tokens, or on a pool with no budget per user, has no share to report.
        guard !windows.isEmpty || billedByTokens || report.snapshots?.values.contains(where: { $0.quota?.isUnlimited == true }) == true
        else { throw noPlan }
        return ProviderSnapshot(
            provider: .copilot, plan: planName(report), windows: windows,
            creditsUsed: creditsUsed(report.snapshots?["premium_interactions"]?.quota), source: .cli, fetchedAt: now)
    }

    private static func window(_ report: Report, key: String, id: String, title: String, reset: Date?) -> LimitWindow? {
        let quota = report.snapshots?[key]?.quota
        if quota?.isUnlimited == true { return nil }
        var remaining: Double?
        var ends = reset
        // A snapshot decides, unless it has no entitlement to speak of, as on Free's premium
        // requests. Under token billing `has_quota` is always false, so it says nothing.
        if let quota, quota.entitlement?.value != 0 {
            remaining = quota.percentRemaining?.value ?? share(quota.remaining?.value, of: quota.entitlement?.value)
            if let at = quota.resetAt?.value, at > 0 { ends = Date(timeIntervalSince1970: at) }
        } else {
            // Older Free accounts report what's left beside the month's allotment.
            remaining = share(report.limitedUserQuotas?[key]?.value, of: report.monthlyQuotas?[key]?.value)
        }
        guard let remaining else { return nil }
        return LimitWindow(
            id: id, title: title, usedPercent: min(max(100 - remaining, 0), 100),
            resetsAt: ends, durationSeconds: LimitWindow.monthSeconds(endingAt: ends))
    }

    private static func share(_ part: Double?, of whole: Double?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return part / whole * 100
    }

    /// Credits only count on an unlimited plan: a metered one reports 0 here whatever it has used,
    /// and a depleted pool has `has_quota` false.
    private static func creditsUsed(_ premium: Quota?) -> Double? {
        guard let premium, premium.isUnlimited, premium.hasQuota != false,
              let used = premium.creditsUsed?.value, used >= 0
        else { return nil }
        return used
    }

    /// `quota_reset_date` is a day, the others an instant.
    private static func parseResetDate(_ raw: String) -> Date? {
        parseISODate(raw) ?? parseISODate("\(raw)T00:00:00Z")
    }

    /// As VS Code names them. `individual` is what GitHub sells as Pro.
    private static func planName(_ report: Report) -> String? {
        switch report.sku {
        case "free_limited_copilot": return "Free"
        case "free_educational_quota": return "Education"
        default: break
        }
        switch report.plan {
        case "individual_edu": return "Education"
        case "individual": return "Pro"
        case "individual_pro": return "Pro+"
        case "individual_max": return "Max"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return nil
        }
    }
}
