import Foundation

/// Read-only calls to the ChatGPT backend endpoints the Codex CLI itself uses.
enum CodexUsageAPI {
    static let baseURL = URL(string: "https://chatgpt.com/backend-api")!

    // MARK: Wire types

    struct UsageResponse: Decodable {
        var planType: String?
        var rateLimit: RateLimit?
        var credits: CreditsWire?
        var additionalRateLimits: [AdditionalRateLimit]?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case credits
            case additionalRateLimits = "additional_rate_limits"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            planType = try? c.decodeIfPresent(String.self, forKey: .planType)
            rateLimit = try? c.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
            credits = try? c.decodeIfPresent(CreditsWire.self, forKey: .credits)
            // Lossy: one malformed model-specific limit must not hide the others.
            additionalRateLimits = (try? c.decodeIfPresent([Lossy<AdditionalRateLimit>].self, forKey: .additionalRateLimits))?
                .compactMap(\.value)
        }
    }

    struct RateLimit: Decodable {
        var primaryWindow: Window?
        var secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? c.decodeIfPresent(Window.self, forKey: .primaryWindow)
            secondaryWindow = try? c.decodeIfPresent(Window.self, forKey: .secondaryWindow)
        }
    }

    struct Window: Decodable {
        var usedPercent: Double
        var resetAt: Int?
        var limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    struct AdditionalRateLimit: Decodable {
        var limitName: String?
        var rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }

    struct CreditsWire: Decodable {
        var hasCredits: Bool
        var unlimited: Bool
        var balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = (try? c.decode(Bool.self, forKey: .hasCredits)) ?? false
            unlimited = (try? c.decode(Bool.self, forKey: .unlimited)) ?? false
            balance = (try? c.decode(Double.self, forKey: .balance))
                ?? (try? c.decode(String.self, forKey: .balance)).flatMap(Double.init)
        }
    }

    struct ResetCreditsResponse: Decodable {
        var credits: [ResetCredit]
    }

    struct ResetCredit: Decodable {
        var id: String
        var status: String
        var expiresAt: String?
        var title: String?

        enum CodingKeys: String, CodingKey {
            case id, status, title
            case expiresAt = "expires_at"
        }
    }

    struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    // MARK: Requests

    static func fetchUsage(_ creds: CodexCredentials, session: URLSession) async throws -> UsageResponse {
        let data = try await get("wham/usage", creds: creds, session: session, timeout: 20)
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected Codex usage response")
        }
    }

    static func fetchBankedResets(_ creds: CodexCredentials, session: URLSession) async throws -> [BankedReset] {
        let data = try await get("wham/rate-limit-reset-credits", creds: creds, session: session, timeout: 8)
        let decoded = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
        return decoded.credits.map {
            BankedReset(id: $0.id, title: $0.title, status: $0.status, expiresAt: $0.expiresAt.flatMap(parseISODate))
        }
    }

    private static func get(
        _ path: String, creds: CodexCredentials, session: URLSession, timeout: TimeInterval) async throws -> Data
    {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unexpected("No HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.loginExpired
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retry)
        default: throw ProviderError.unexpected("Codex API returned HTTP \(http.statusCode)")
        }
    }

    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "Subar (Mac OS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion); \(arch))"
    }()

    // MARK: Mapping

    static func snapshot(from usage: UsageResponse, bankedResets: [BankedReset]?, now: Date = Date()) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        for (window, fallbackID) in [(usage.rateLimit?.primaryWindow, "primary"), (usage.rateLimit?.secondaryWindow, "secondary")] {
            guard let window else { continue }
            windows.append(limitWindow(window, idPrefix: nil, fallbackID: fallbackID, titlePrefix: nil))
        }
        for extra in usage.additionalRateLimits ?? [] {
            let name = extra.limitName?.trimmingCharacters(in: .whitespaces)
            let slug = slugify(name ?? "extra")
            for (window, fallbackID) in [(extra.rateLimit?.primaryWindow, "primary"), (extra.rateLimit?.secondaryWindow, "secondary")] {
                guard let window else { continue }
                var mapped = limitWindow(window, idPrefix: slug, fallbackID: fallbackID, titlePrefix: name)
                mapped.isModelSpecific = true
                windows.append(mapped)
            }
        }
        let credits = usage.credits.map { Credits(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance) }
        return ProviderSnapshot(
            provider: .codex,
            plan: usage.planType.map(formatPlan),
            windows: windows,
            credits: credits,
            bankedResets: bankedResets,
            fetchedAt: now)
    }

    private static func limitWindow(_ w: Window, idPrefix: String?, fallbackID: String, titlePrefix: String?) -> LimitWindow {
        let kind = WindowKind(durationSeconds: w.limitWindowSeconds)
        let base = kind.idComponent ?? fallbackID
        let title = WindowKind.title(durationSeconds: w.limitWindowSeconds)
        return LimitWindow(
            id: idPrefix.map { "\($0)-\(base)" } ?? base,
            title: titlePrefix.map { "\($0) \(title)" } ?? title,
            usedPercent: min(max(w.usedPercent, 0), 100),
            resetsAt: w.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationSeconds: w.limitWindowSeconds)
    }

    static func formatPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro": "Pro"
        case "plus": "Plus"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        case "free": "Free"
        default: raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    private static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}

func parseISODate(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: raw) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}
