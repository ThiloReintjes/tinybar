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

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
            case limits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDayOpus = try? c.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? c.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
            extraUsage = try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
            limits = (try? c.decodeIfPresent([CodexUsageAPI.Lossy<LimitEntry>].self, forKey: .limits))?.compactMap(\.value)
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
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/oauth/usage"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await HTTP.send(request, session: session, providerName: "Claude")
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected Claude usage response")
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
        return ProviderSnapshot(provider: .claude, plan: plan, windows: windows, extraUsage: extra, fetchedAt: now)
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
