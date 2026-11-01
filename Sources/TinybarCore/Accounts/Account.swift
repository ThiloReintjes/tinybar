import CryptoKit
import Foundation

/// One login with a Provider (see CONTEXT.md: Account).
public struct Account: Sendable, Identifiable {
    /// A hash of who the login belongs to (`LoginIdentity`). Pins, alert state and limit readings
    /// store this rather than the email.
    public var id: String
    /// The login's email, else the folder it lives in.
    public var name: String
    /// The name the user gave it in claude-swap.
    public var alias: String?
    public var organizationName: String?
    public var isActive: Bool
    public var snapshot: ProviderSnapshot?
    public var error: ProviderError?
    /// What the user runs to renew an expired login, when it isn't the Provider's own hint.
    public var loginHint: String?

    public init(
        id: String, name: String, alias: String? = nil, organizationName: String? = nil, isActive: Bool = false,
        snapshot: ProviderSnapshot? = nil, error: ProviderError? = nil, loginHint: String? = nil)
    {
        self.id = id
        self.name = name
        self.alias = alias
        self.organizationName = organizationName
        self.isActive = isActive
        self.snapshot = snapshot
        self.error = error
        self.loginHint = loginHint
    }

    public var isStale: Bool { error != nil }
    public var displayName: String { alias ?? name }
}

/// Who a login belongs to, read from what the CLI keeps beside its token. Two logins with the same
/// identity are one Account.
public struct LoginIdentity: Sendable, Hashable {
    public var email: String
    public var organization: String?
    public var organizationName: String?

    public init(email: String, organization: String? = nil, organizationName: String? = nil) {
        self.email = email
        self.organization = organization
        self.organizationName = organizationName
    }

    public var accountID: String {
        Self.hash(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            + "|" + (organization ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// For a login with no readable email: the folder it lives in, or the Provider's default login.
    public static func accountID(place: String) -> String {
        hash("place|" + place)
    }

    /// Short: this only tells a user's few Accounts apart.
    static func hash(_ text: String) -> String {
        sha256Hex(text).prefix(16).description
    }
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Puts a Provider's Accounts from every source into one list (SPEC §15).
public enum AccountRoster {
    /// claude-swap's rows as they stand beside the default login. Its active row is that login when
    /// their emails match, or when the login's email can't be read and only claude-swap can say so.
    /// Numbers from the browser fallback are another matter: that session may be someone else's.
    public static func swapRows(_ rows: [Account], defaultLogin main: Account?, provider: ProviderID) -> [Account] {
        rows.map { row in
            var row = row
            if row.isActive, let main, main.error != .notConfigured,
               (main.id == LoginIdentity.accountID(place: provider.rawValue) && main.snapshot?.source != .browser)
                || main.name.lowercased() == row.name.lowercased()
            {
                row.id = main.id
            }
            row.isActive = false
            return row
        }
    }

    /// Sources in order of preference: the same identity found twice is one Account, and the first
    /// wins. A later one still lends its alias. A default login that doesn't exist goes away once
    /// another Account does.
    public static func merge(_ sources: [Account]...) -> [Account] {
        var merged: [Account] = []
        for account in sources.joined() {
            if let i = merged.firstIndex(where: { $0.id == account.id }) {
                merged[i].alias = merged[i].alias ?? account.alias
                merged[i].organizationName = merged[i].organizationName ?? account.organizationName
                // A preferred source with no numbers doesn't hide another's for the same login.
                if merged[i].snapshot == nil, account.snapshot != nil {
                    merged[i].snapshot = account.snapshot
                    merged[i].error = account.error
                    merged[i].loginHint = account.loginHint
                }
            } else {
                merged.append(account)
            }
        }
        if merged.count > 1 {
            merged.removeAll { $0.snapshot == nil && $0.error == .notConfigured }
        }
        // Two organizations under one email need telling apart.
        let names = merged.map(\.displayName)
        for i in merged.indices where merged[i].alias == nil && names.filter({ $0 == merged[i].name }).count > 1 {
            if let organization = merged[i].organizationName, !organization.isEmpty {
                merged[i].name += " · \(organization)"
            }
        }
        return merged
    }
}
