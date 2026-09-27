import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable, Comparable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The CLI the user runs to refresh this Provider's login.
    public var cliCommand: String { rawValue }

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

public struct ProviderSnapshot: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var plan: String?
    public var windows: [LimitWindow]
    public var credits: Credits?
    public var bankedResets: [BankedReset]?
    public var fetchedAt: Date

    public init(
        provider: ProviderID, plan: String?, windows: [LimitWindow],
        credits: Credits? = nil, bankedResets: [BankedReset]? = nil, fetchedAt: Date = Date())
    {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.credits = credits
        self.bankedResets = bankedResets
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
