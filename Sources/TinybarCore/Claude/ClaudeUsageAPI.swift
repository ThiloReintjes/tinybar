import Foundation

/// Read-only calls to the endpoints Claude Code itself uses for `/usage`.
enum ClaudeUsageAPI {
    static let baseURL = URL(string: "https://api.anthropic.com")!
    static let betaHeader = "oauth-2025-04-20"

    // MARK: Wire types

    struct UsageResponse: Decodable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?
        var extraUsage: ExtraUsage?
        var limits: [LimitEntry]?
        /// Saved "Reset for free" grants, present when asked for with `cedar_ember=1`.
        var resetGrants: ResetGrants?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
            case limits
            case resetGrants = "cedar_ember"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDayOpus = try? c.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? c.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
            extraUsage = try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
            limits = (try? c.decodeIfPresent([CodexUsageAPI.Lossy<LimitEntry>].self, forKey: .limits))?.compactMap(\.value)
            resetGrants = try? c.decodeIfPresent(ResetGrants.self, forKey: .resetGrants)
        }
    }

    /// Claude's Banked Resets. Grant ids are redemption handles, so they are never decoded.
    struct ResetGrants: Decodable {
        var eligible: Bool
        var grants: [CodexUsageAPI.Lossy<Grant>]

        struct Grant: Decodable {
            var resetsLeft: Int
            var startsAt: String?
            var endsAt: String?
            /// Required: a grant whose pause state is unknown isn't counted.
            var paused: Bool

            enum CodingKeys: String, CodingKey {
                case resetsLeft = "resets_left"
                case startsAt = "starts_at"
                case endsAt = "ends_at"
                case paused
            }
        }

        /// One entry per reset still usable at `now`: a grant with two left counts twice.
        func available(at now: Date) -> [BankedReset] {
            guard eligible else { return [] }
            var out: [BankedReset] = []
            for case let grant? in grants.map(\.value) where !grant.paused && grant.resetsLeft > 0 {
                let starts = grant.startsAt.flatMap(parseISODate)
                let ends = grant.endsAt.flatMap(parseISODate)
                if grant.startsAt != nil && starts == nil || grant.endsAt != nil && ends == nil { continue }
                if let starts, starts > now { continue }
                if let ends, ends <= now { continue }
                // An implausible count is malformed rather than a reason to draw 10,000 rows.
                guard grant.resetsLeft <= 50 - out.count else { return [] }
                for _ in 0..<grant.resetsLeft {
                    out.append(BankedReset(id: "claude-\(out.count)", title: nil, status: "available", expiresAt: ends))
                }
            }
            return out
        }
    }

    struct Window: Decodable {
        /// Already a percentage, 0–100.
        var utilization: Double?
        var resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    /// Newer shape for model-scoped weekly limits.
    struct LimitEntry: Decodable {
        var kind: String?
        var group: String?
        var percent: Double?
        var resetsAt: String?
        var scope: Scope?
        var isActive: Bool?

        struct Scope: Decodable {
            var model: Model?
        }

        struct Model: Decodable {
            var id: String?
            var displayName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    struct ExtraUsage: Decodable {
        var isEnabled: Bool?
        var monthlyLimit: Double?
        var usedCredits: Double?
        var currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case currency
        }
    }

    // MARK: Requests

    static func fetchUsage(accessToken: String, session: URLSession) async throws -> UsageResponse {
        let data = try await withResetGrants(baseURL.appendingPathComponent("api/oauth/usage")) { url, passing in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            return try await HTTP.send(request, session: session, providerName: "Claude", passing: passing)
        }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected Claude usage response")
        }
    }

    /// Asks a usage endpoint to include Banked Resets (`cedar_ember=1`, as claude.ai does). An
    /// account the query isn't open to gets 400 or 403; then the plain request is sent once, so
    /// the limits still show. `send` throws `HTTP.Status` for the codes it's given.
    static func withResetGrants(
        _ url: URL, send: (URL, Set<Int>) async throws -> Data) async throws -> Data
    {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1")]
        do {
            return try await send(components.url!, [400, 403])
        } catch is HTTP.Status {
            return try await send(url, [])
        }
    }

    /// Matches the official CLI's User-Agent, using the installed Claude Code version when known.
    static var userAgent: String {
        "claude-code/\(ClaudeCodeVersion.installed ?? "2.1.0")"
    }

    // MARK: Mapping

    static func snapshot(from usage: UsageResponse, plan: String?, now: Date = Date()) -> ProviderSnapshot {
        var windows: [LimitWindow] = []

        func add(_ w: Window?, id: String, title: String, seconds: Int, modelSpecific: Bool) {
            guard let w, let util = w.utilization else { return }
            windows.append(LimitWindow(
                id: id, title: title,
                usedPercent: min(max(util, 0), 100),
                resetsAt: w.resetsAt.flatMap(parseISODate),
                durationSeconds: seconds,
                isModelSpecific: modelSpecific))
        }

        add(usage.fiveHour, id: "session", title: "5-hour", seconds: 5 * 3600, modelSpecific: false)
        add(usage.sevenDay, id: "weekly", title: "Weekly", seconds: 7 * 86400, modelSpecific: false)

        // Prefer the newer scoped `limits` list; fall back to the flat per-model fields.
        let scoped = (usage.limits ?? []).filter {
            $0.isActive != false && $0.scope?.model != nil && $0.percent != nil
        }
        if !scoped.isEmpty {
            for entry in scoped {
                let name = entry.scope?.model?.displayName ?? entry.scope?.model?.id ?? "Model"
                let weekly = entry.group == "weekly" || (entry.kind ?? "").contains("weekly")
                windows.append(LimitWindow(
                    id: "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(weekly ? "weekly" : "limit")",
                    title: weekly ? "\(name) Weekly" : name,
                    usedPercent: min(max(entry.percent ?? 0, 0), 100),
                    resetsAt: entry.resetsAt.flatMap(parseISODate),
                    durationSeconds: weekly ? 7 * 86400 : nil,
                    isModelSpecific: true))
            }
        } else {
            add(usage.sevenDayOpus, id: "opus-weekly", title: "Opus Weekly", seconds: 7 * 86400, modelSpecific: true)
            add(usage.sevenDaySonnet, id: "sonnet-weekly", title: "Sonnet Weekly", seconds: 7 * 86400, modelSpecific: true)
        }

        var extra: ExtraUsageSpend?
        if let e = usage.extraUsage, e.isEnabled == true, let used = e.usedCredits {
            // The API reports credits in cents.
            extra = ExtraUsageSpend(used: used / 100, limit: e.monthlyLimit.map { $0 / 100 }, currency: e.currency ?? "USD")
        }
        let banked = usage.resetGrants?.available(at: now) ?? []
        return ProviderSnapshot(
            provider: .claude, plan: plan, windows: windows,
            bankedResets: banked.isEmpty ? nil : banked, extraUsage: extra, fetchedAt: now)
    }
}

/// Claude Code's version from its install, for the User-Agent. Read once, no process spawn.
enum ClaudeCodeVersion {
    static let installed: String? = {
        let fm = FileManager.default
        // Native installer keeps versions under ~/.local/share/claude/versions/<semver>.
        let versionsDir = Paths.home.appendingPathComponent(".local/share/claude/versions")
        if let names = try? fm.contentsOfDirectory(atPath: versionsDir.path) {
            let versions = names.filter { $0.first?.isNumber == true }
            if let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                return newest
            }
        }
        // npm global install.
        for prefix in ["/opt/homebrew/lib", "/usr/local/lib"] {
            let pkg = URL(fileURLWithPath: "\(prefix)/node_modules/@anthropic-ai/claude-code/package.json")
            if let data = try? Data(contentsOf: pkg),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = json["version"] as? String
            {
                return v
            }
        }
        return nil
    }()
}
