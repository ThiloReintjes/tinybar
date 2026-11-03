import Foundation

/// A CLI whose login can live in a folder other than its default one (SPEC §15). Everything that
/// differs between them is here: finding folders, checking one, the agent prompt and the fix for an
/// expired login all read this table.
public struct LoginFolderKind: Sendable {
    public let provider: ProviderID
    /// As the prompt names it.
    let cli: String
    /// What points the CLI at the folder, as the prompt names it.
    let variable: String
    /// Files the CLI keeps beside its login, to tell its folders apart before reading one.
    let files: [String]
    /// Folders directly in the home folder starting with this are found without being added.
    public let homePrefix: String?
    /// The folders the CLI uses when nothing points it elsewhere.
    let defaultFolders: @Sendable (_ home: URL, _ env: [String: String]) -> [URL]
    /// Whether the folder holds a login this kind can read.
    let hasLogin: @Sendable (URL) -> Bool
    /// Reads only that folder's login. `isAdded`: the user chose the folder, which is consent to a
    /// Keychain prompt where reading the login needs one.
    let source: @Sendable (_ folder: URL, _ isAdded: Bool) -> any UsageProvider
    /// What renews the login in `folder`, given a way to write a path for the shell.
    let renew: @Sendable (_ folder: URL, _ shell: (URL) -> String) -> String

    public static let all: [LoginFolderKind] = [
        LoginFolderKind(
            provider: .claude, cli: "Claude Code", variable: "CLAUDE_CONFIG_DIR", files: [".claude.json", ".credentials.json", ".config.json"],
            homePrefix: ".claude",
            defaultFolders: { home, env in
                // Both places the default login may be read from, as `Paths.claudeConfigDirs` has them.
                isSet("CLAUDE_CONFIG_DIR", env) ? Paths.claudeConfigDirs(env: env)
                    : [home.appendingPathComponent(".claude", isDirectory: true), home.appendingPathComponent(".config/claude", isDirectory: true)]
            },
            hasLogin: { ClaudeCredentials.hasStoredLogin(folder: $0) },
            source: { folder, _ in ClaudeProvider(folder: folder) },
            renew: { folder, shell in "run `CLAUDE_CONFIG_DIR=\(shell(folder)) claude` once to refresh" }),
        LoginFolderKind(
            provider: .codex, cli: "Codex", variable: "CODEX_HOME", files: ["auth.json"], homePrefix: ".codex",
            defaultFolders: { home, env in
                [isSet("CODEX_HOME", env) ? Paths.codexHome(env: env) : home.appendingPathComponent(".codex", isDirectory: true)]
            },
            hasLogin: { (try? CodexCredentials.load(from: $0.appendingPathComponent("auth.json"))) != nil },
            source: { folder, _ in CodexProvider(home: folder) },
            renew: { folder, shell in "run `CODEX_HOME=\(shell(folder)) codex` once to refresh" }),
        LoginFolderKind(
            provider: .grok, cli: "Grok CLI", variable: "GROK_HOME", files: ["auth.json"], homePrefix: ".grok",
            defaultFolders: { home, env in
                [isSet("GROK_HOME", env) ? Paths.grokHome(env: env) : home.appendingPathComponent(".grok", isDirectory: true)]
            },
            hasLogin: { GrokLogins(home: $0, env: ProcessInfo.processInfo.environment).find() != nil },
            source: { folder, _ in GrokProvider(logins: GrokLogins(home: folder, env: ProcessInfo.processInfo.environment)) },
            renew: { folder, shell in "run `GROK_HOME=\(shell(folder)) grok login`" }),
        LoginFolderKind(
            provider: .copilot, cli: "Copilot CLI", variable: "COPILOT_HOME", files: ["config.json"], homePrefix: ".copilot",
            defaultFolders: { home, env in
                [isSet("COPILOT_HOME", env) ? Paths.copilotHome(env: env) : home.appendingPathComponent(".copilot", isDirectory: true)]
            },
            hasLogin: { CopilotLogins.folder($0).cliUser() != nil },
            source: { folder, isAdded in CopilotProvider(logins: CopilotLogins.folder(folder), isOptedIn: { isAdded }) },
            renew: { folder, shell in "run `COPILOT_HOME=\(shell(folder)) copilot login`" }),
        // OpenCode keeps its data in `$XDG_DATA_HOME/opencode`, so the home folder names none of its folders.
        LoginFolderKind(
            provider: .opencode, cli: "OpenCode", variable: "XDG_DATA_HOME (its opencode folder)", files: ["opencode.db", "auth.json"],
            homePrefix: nil,
            // `OPENCODE_DB` can move the default login's database out of that folder.
            defaultFolders: { _, env in
                [Paths.openCodeData(env: env)] + [OpenCodeData(env: env).database?.deletingLastPathComponent()].compactMap { $0 }
            },
            // A Go key, as for the default login: a Console login may have no Go plan (ADR 0009).
            hasLogin: { OpenCodeData(folder: $0).storedLogin()?.integration == OpenCodeData.goIntegration },
            source: { folder, _ in OpenCodeProvider(data: OpenCodeData(folder: folder)) },
            renew: { folder, shell in
                // 2.x keeps the login in the database, which `OPENCODE_DB` points at wherever it is.
                folder.lastPathComponent == "opencode"
                    ? "run `XDG_DATA_HOME=\(shell(folder.deletingLastPathComponent())) opencode auth login`"
                    : "run `OPENCODE_DB=\(shell(folder.appendingPathComponent("opencode.db"))) opencode auth login`"
            }),
    ]

    public static func of(_ provider: ProviderID) -> LoginFolderKind? {
        all.first { $0.provider == provider }
    }

    /// Where the default login lives, when one folder holds it. Copilot's may come from an editor
    /// plugin or `gh` instead.
    public static func defaultFolder(of provider: ProviderID, env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        provider == .copilot ? nil : of(provider)?.defaultFolders(Paths.home, env).first
    }

    /// Whether a folder holds the files this CLI keeps beside its login. The login itself is
    /// checked later.
    func holdsFiles(_ url: URL) -> Bool {
        files.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private static func isSet(_ name: String, _ env: [String: String]) -> Bool {
        env[name]?.trimmingCharacters(in: .whitespaces).isEmpty == false
    }
}

/// A folder other than a CLI's default one, holding a login.
public struct LoginFolder: Sendable, Hashable, Identifiable {
    public var provider: ProviderID
    public var url: URL
    /// Added by the user or their agent, rather than found in the home folder.
    public var isAdded: Bool

    public init(provider: ProviderID, url: URL, isAdded: Bool = false) {
        self.provider = provider
        self.url = url
        self.isAdded = isAdded
    }

    /// `.claude_side`, unique within a home directory. An added folder can hold several CLIs'
    /// logins, so its id names the Provider too.
    public var id: String { isAdded ? "\(provider.rawValue):\(url.path)" : url.lastPathComponent }

    /// Where it is, as the user would type it.
    public var place: String { isAdded ? Paths.abbreviated(url) : "~/\(url.lastPathComponent)" }

    /// What the user runs to renew its login. Tinybar never does it for them (ADR 0001).
    public var loginHint: String {
        guard let kind = LoginFolderKind.of(provider) else { return provider.loginHint }
        return kind.renew(url) { $0 == url ? Self.shell(place) : Self.shell(Paths.abbreviated($0)) }
    }

    /// `~/.codex_alt`, quoted when it needs to be: `"$HOME/Library/Application Support/…"`. Inside
    /// the quotes only that `$HOME` expands: a `$` or backtick in the folder's name stays literal.
    static func shell(_ place: String) -> String {
        if place.allSatisfy({ $0.isLetter || $0.isNumber || "~/._-".contains($0) }) { return place }
        let inHome = place.hasPrefix("~/")
        var path = String(inHome ? place.dropFirst() : place[...])
        for special in ["\\", "\"", "$", "`"] { path = path.replacingOccurrences(of: special, with: "\\" + special) }
        return "\"" + (inHome ? "$HOME" : "") + path + "\""
    }

    /// Reads only this folder's login.
    public var source: any UsageProvider {
        LoginFolderKind.of(provider)?.source(url, isAdded) ?? ClaudeProvider(folder: url)
    }
}

/// Finds extra login folders (SPEC §15). A GUI app can't see the shell's `CODEX_HOME` and the
/// like, so it goes by the names people give them, and by the folders the user added.
public enum LoginFolders {
    /// `hasLogin` stands in for each kind's own check, for tests.
    public static func find(
        home: URL = Paths.home,
        added: [URL] = AddedLoginFolders.urls(),
        hasLogin: ((ProviderID, URL) -> Bool)? = nil
    ) -> [LoginFolder] {
        LoginFolderKind.all.flatMap { kind -> [LoginFolder] in
            let dirs = Paths.extraConfigDirsByOrigin(kind.provider, home: home, added: added)
            let folders = dirs.inHome.map { LoginFolder(provider: kind.provider, url: $0) }
                + dirs.added.map { LoginFolder(provider: kind.provider, url: $0, isAdded: true) }
            return folders.filter { hasLogin?(kind.provider, $0.url) ?? kind.hasLogin($0.url) }
        }
    }

    /// The Account a folder holds, with no limits yet.
    public static func account(for folder: LoginFolder) -> Account {
        let identity = folder.source.identity()
        return Account(
            id: identity?.accountID ?? LoginIdentity.accountID(place: folder.url.path),
            name: identity?.email ?? folder.place,
            organizationName: identity?.organizationName,
            loginHint: folder.loginHint)
    }
}

/// Login folders anywhere on the Mac, added in Settings or by the user's agent with
/// `defaults write <domain> addedLoginFolders -array-add <path>` (SPEC §15). Read afresh on every
/// check, so a folder added from outside shows up on the next one.
public enum AddedLoginFolders {
    public static let key = "addedLoginFolders"

    /// Absolute paths, `~` expanded, each once. Anything else in the list is ignored.
    public static func urls(_ defaults: UserDefaults = .standard) -> [URL] {
        urls(from: defaults.array(forKey: key) ?? [])
    }

    public static func urls(from values: [Any]) -> [URL] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    /// Which CLIs a folder holds a login for, if any: the check made before adding one.
    public static func providers(in url: URL, hasLogin: ((ProviderID, URL) -> Bool)? = nil) -> [ProviderID] {
        LoginFolderKind.all.filter { $0.holdsFiles(url) && (hasLogin?($0.provider, url) ?? $0.hasLogin(url)) }.map(\.provider)
    }

    /// What the user pastes into their agent to find logins Tinybar can't, and add them. `domain`
    /// is where Tinybar keeps its settings.
    public static func agentPrompt(domain: String) -> String {
        let kinds = LoginFolderKind.all
        let homes = kinds.compactMap { $0.homePrefix.map { "~/\($0)*" } }.joined(separator: ", ")
        let lines = kinds.map { "- \($0.cli): \($0.variable), holding \($0.files.joined(separator: " or "))" }.joined(separator: "\n")
        return """
        Find every login folder on this Mac for the CLIs below that Tinybar doesn't read yet, and \
        add it. Tinybar already reads each CLI's default folder and \(homes).

        \(lines)

        Search for those variables in shell startup files, aliases and launch agents, and for app \
        and account-switcher folders under ~/Library/Application Support, ~/.config and \
        ~/.local/share. Test for the files by name only (`test -e`): they hold login tokens.

        Add each folder, in single quotes so the shell leaves its name alone: \
        defaults write \(domain) \(key) -array-add '<absolute path>'

        Finish by listing each folder added and where you found it.
        """
    }
}
