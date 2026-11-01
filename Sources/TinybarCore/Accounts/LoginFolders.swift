import Foundation

/// A `CLAUDE_CONFIG_DIR` or `CODEX_HOME` folder other than the default one, holding a login.
public struct LoginFolder: Sendable, Hashable, Identifiable {
    public var provider: ProviderID
    public var url: URL

    public init(provider: ProviderID, url: URL) {
        self.provider = provider
        self.url = url
    }

    /// `.claude_side`, unique within a home directory.
    public var id: String { url.lastPathComponent }

    /// What the user runs to renew its login. Tinybar never does it for them (ADR 0001).
    public var loginHint: String {
        switch provider {
        case .codex: "run `CODEX_HOME=~/\(id) codex` once to refresh"
        default: "run `CLAUDE_CONFIG_DIR=~/\(id) claude` once to refresh"
        }
    }

    /// Reads only this folder's login.
    public var source: any UsageProvider {
        provider == .codex ? CodexProvider(home: url) : ClaudeProvider(folder: url)
    }
}

/// Finds extra login folders in the home directory (SPEC §15). A GUI app can't see the shell's
/// `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, so it goes by the names people give them.
public enum LoginFolders {
    public static func find(
        home: URL = Paths.home,
        hasClaudeLogin: (URL) -> Bool = { ClaudeCredentials.hasStoredLogin(folder: $0) },
        hasCodexLogin: (URL) -> Bool = { (try? CodexCredentials.load(from: $0.appendingPathComponent("auth.json"))) != nil }
    ) -> [LoginFolder] {
        let claude = Paths.extraConfigDirs(.claude, home: home).filter(hasClaudeLogin)
            .map { LoginFolder(provider: .claude, url: $0) }
        let codex = Paths.extraConfigDirs(.codex, home: home).filter(hasCodexLogin)
            .map { LoginFolder(provider: .codex, url: $0) }
        return claude + codex
    }

    /// The Account a folder holds, with no limits yet.
    public static func account(for folder: LoginFolder) -> Account {
        let identity = folder.source.identity()
        return Account(
            id: identity?.accountID ?? LoginIdentity.accountID(place: folder.url.path),
            name: identity?.email ?? folder.id,
            organizationName: identity?.organizationName,
            loginHint: folder.loginHint)
    }
}
