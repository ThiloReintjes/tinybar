import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable, Comparable {
    case claude
    case codex
    case gemini
    case cursor

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        }
    }

    /// The CLI Subar reads through, where there is one.
    public var cliCommand: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "agy"
        case .cursor: nil
        }
    }

    /// What the user does to renew an expired login. Subar never does it for them (ADR 0001).
    public var loginHint: String {
        switch self {
        case .claude, .codex, .gemini: "run `\(cliCommand!)` once to refresh"
        case .cursor: "open Cursor or sign in at cursor.com"
        }
    }

    /// Whether the opt-in browser fallback applies. Cursor reads its browser session as a
    /// regular source, so it has no separate toggle.
    public var hasBrowserFallback: Bool { self == .claude || self == .codex }

    public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum WindowKind: String, Codable, Sendable {
    case session  // 5-hour
    case weekly
    case other
}

/// A period in which a Provider caps usage (see CONTEXT.md: Limit Window).
public struct LimitWindow: Codable, Sendable, Hashable, Identifiable {
    /// Stable within a Provider, e.g. "session", "weekly", "spark-weekly".
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationSeconds: Int?
    public var isModelSpecific: Bool

    public init(
        id: String, title: String, usedPercent: Double, resetsAt: Date?,
        durationSeconds: Int?, isModelSpecific: Bool = false)
    {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
        self.isModelSpecific = isModelSpecific
    }

    public var kind: WindowKind { WindowKind(durationSeconds: durationSeconds) }

    /// What the UI shows: the share of the window still available, 100 → 0.
    public var remainingPercent: Double { min(max(100 - usedPercent, 0), 100) }
}

extension WindowKind {
    public init(durationSeconds: Int?) {
        switch durationSeconds {
        case 5 * 3600: self = .session
        case 7 * 86400: self = .weekly
        default: self = .other
        }
    }

    public static func title(durationSeconds: Int?) -> String {
        guard let s = durationSeconds, s > 0 else { return "Limit" }
        switch WindowKind(durationSeconds: s) {
        case .session: return "5-hour"
        case .weekly: return "Weekly"
        case .other:
            if s % 86400 == 0 { return "\(s / 86400)-day" }
            if s % 3600 == 0 { return "\(s / 3600)-hour" }
            return "\(s / 60)-minute"
        }
    }

    public var idComponent: String? {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        case .other: nil
        }
    }
}

/// A saved Codex reset coupon (see CONTEXT.md: Banked Reset). Display only.
public struct BankedReset: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var status: String
    public var expiresAt: Date?

    public init(id: String, title: String?, status: String, expiresAt: Date?) {
        self.id = id
        self.title = title
        self.status = status
        self.expiresAt = expiresAt
    }

    public var isAvailable: Bool { status == "available" }
}

public struct Credits: Codable, Sendable, Hashable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: Double?

    public init(hasCredits: Bool, unlimited: Bool, balance: Double?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

/// Claude's pay-as-you-go spend beyond the subscription ("extra usage"), in currency units.
public struct ExtraUsageSpend: Codable, Sendable, Hashable {
    public var used: Double
    public var limit: Double?
    public var currency: String

    public init(used: Double, limit: Double?, currency: String) {
        self.used = used
        self.limit = limit
        self.currency = currency
    }
}

/// Where a snapshot came from, shown as a small hint on the card.
public enum DataSource: String, Codable, Sendable, Hashable {
    case cli        // the CLI's stored OAuth login
    case cliProcess // a short-lived official CLI process
    case browser    // browser session cookies (opt-in)
}

public struct ProviderSnapshot: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var plan: String?
    public var windows: [LimitWindow]
    public var credits: Credits?
    public var bankedResets: [BankedReset]?
    public var extraUsage: ExtraUsageSpend?
    public var source: DataSource
    public var fetchedAt: Date

    public init(
        provider: ProviderID, plan: String?, windows: [LimitWindow],
        credits: Credits? = nil, bankedResets: [BankedReset]? = nil, extraUsage: ExtraUsageSpend? = nil,
        source: DataSource = .cli, fetchedAt: Date = Date())
    {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.credits = credits
        self.bankedResets = bankedResets
        self.extraUsage = extraUsage
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    /// The CLI's login expired or was revoked. Subar never refreshes it (ADR 0001).
    case loginExpired
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Not signed in"
        case .loginExpired: "Login expired"
        case .rateLimited: "Rate limited by provider"
        case let .network(message): "Network error: \(message)"
        case let .unexpected(message): message
        }
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Whether the CLI's credentials exist on this Mac. Cheap; used for auto-detection.
    func isConfigured() -> Bool
    func fetch() async throws -> ProviderSnapshot
}
