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

    private static let resetBackoff = HTTP.Backoff()

    /// An optional extra's 429 must not hide fresh limits or make us retry that endpoint early.
    static func fetchBankedResets(
        _ creds: CodexCredentials, session: URLSession, backoff: HTTP.Backoff = resetBackoff,
        now: @Sendable () -> Date = { Date() }) async throws -> [BankedReset]?
    {
        guard await backoff.permitsRequest(at: now()) else { return nil }
        do {
            let data = try await get("wham/rate-limit-reset-credits", creds: creds, session: session, timeout: 8)
            let decoded = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
            return decoded.credits.map {
                BankedReset(id: $0.id, title: $0.title, status: $0.status, expiresAt: $0.expiresAt.flatMap(parseISODate))
            }
        } catch ProviderError.rateLimited(let delay) {
            await backoff.deferRequests(until: now().addingTimeInterval(delay ?? 300))
            return nil
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

        return try await HTTP.send(request, session: session, providerName: "Codex")
    }

    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "Tinybar (Mac OS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion); \(arch))"
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

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}

func parseISODate(_ raw: String) -> Date? {
    if let d = parseUTCTimestamp(raw) { return d }
    // Foundation normalizes invalid dates and ignores suffix garbage; validate before falling back.
    let syntax = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])\z"#
    guard raw.range(of: syntax, options: .regularExpression) != nil,
          parseUTCTimestamp(String(raw.prefix(19)) + "Z") != nil else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: raw) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}

/// `2026-10-15T07:52:26.877Z`, the shape both CLIs log on every line, without a formatter: the
/// log parsers read hundreds of thousands of them. nil for anything else (offsets, no `Z`).
func parseUTCTimestamp(_ raw: String) -> Date? {
    var utf8 = raw.utf8.makeIterator()
    var bytes: [UInt8] = []
    bytes.reserveCapacity(24)
    while let b = utf8.next() {
        guard bytes.count < 32 else { return nil }
        bytes.append(b)
    }
    guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"), bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
          bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":")
    else { return nil }
    func num(_ from: Int, _ count: Int) -> Int? {
        var n = 0
        for i in from..<(from + count) {
            let d = Int(bytes[i]) - 48
            guard (0...9).contains(d) else { return nil }
            n = n * 10 + d
        }
        return n
    }
    guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
          let s = num(17, 2), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61
    else { return nil }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    let monthDays = mo == 2 ? (leap ? 29 : 28) : ([4, 6, 9, 11].contains(mo) ? 30 : 31)
    guard d <= monthDays else { return nil }
    var fraction = 0.0
    if bytes.count > 20 {
        guard bytes[19] == UInt8(ascii: "."), bytes.count > 21 else { return nil }
        var scale = 0.1
        for i in 20..<(bytes.count - 1) {
            let digit = Int(bytes[i]) - 48
            guard (0...9).contains(digit) else { return nil }
            fraction += Double(digit) * scale
            scale /= 10
        }
    } else if bytes[19] != UInt8(ascii: "Z") {
        return nil
    }
    // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + s) + fraction)
}
