import Foundation

/// Browser fallback for Claude: the claude.ai endpoints the web app itself calls, authenticated
/// with the browser's `sessionKey` cookie. Read-only GETs.
enum ClaudeWebAPI {
    static let baseURL = URL(string: "https://claude.ai/api")!

    struct Organization: Decodable {
        var uuid: String
        var capabilities: [String]?
    }

    struct OverageLimit: Decodable {
        var isEnabled: Bool?
        var monthlyCreditLimit: Double?
        var usedCredits: Double?
        var currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyCreditLimit = "monthly_credit_limit"
            case usedCredits = "used_credits"
            case currency
        }
    }

    static func fetch(sessionKey: String, session: URLSession) async throws -> ProviderSnapshot {
        let orgs = try JSONDecoder().decode([Organization].self, from: try await get("organizations", sessionKey, session))
        // The subscription lives on the chat organization, not API-only ones.
        guard let org = orgs.first(where: { ($0.capabilities ?? []).contains("chat") })
            ?? orgs.first(where: { Set($0.capabilities ?? []) != ["api"] })
            ?? orgs.first
        else { throw ProviderError.unexpected("No claude.ai organization") }

        let usageData = try await get("organizations/\(org.uuid)/usage", sessionKey, session)
        let usage = try JSONDecoder().decode(ClaudeUsageAPI.UsageResponse.self, from: usageData)
        var snapshot = ClaudeUsageAPI.snapshot(from: usage, plan: nil)
        snapshot.source = .browser

        if snapshot.extraUsage == nil,
           let data = try? await get("organizations/\(org.uuid)/overage_spend_limit", sessionKey, session),
           let overage = try? JSONDecoder().decode(OverageLimit.self, from: data),
           overage.isEnabled == true, let used = overage.usedCredits
        {
            snapshot.extraUsage = ExtraUsageSpend(
                used: used / 100, limit: overage.monthlyCreditLimit.map { $0 / 100 }, currency: overage.currency ?? "USD")
        }
        return snapshot
    }

    private static func get(_ path: String, _ sessionKey: String, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await HTTP.send(request, session: session, providerName: "claude.ai")
    }
}
