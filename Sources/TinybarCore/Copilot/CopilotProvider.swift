import Foundation

/// GitHub Copilot limits, with a login something else keeps: the Copilot CLI's, an editor plugin's
/// or `gh`'s. Tinybar has no login of its own and never refreshes one (ADR 0001, ADR 0011).
public struct CopilotProvider: UsageProvider {
    public let id = ProviderID.copilot
    private let logins: CopilotLogins
    private let isOptedIn: @Sendable () -> Bool
    private let session: URLSession

    /// `isOptedIn`: the user turned Copilot on themselves, which is the consent for the sources
    /// auto-detection must not touch (see `CopilotLogins.find`).
    public init(isOptedIn: @escaping @Sendable () -> Bool = { false }, session: URLSession = .tinybar) {
        self.init(logins: CopilotLogins(), isOptedIn: isOptedIn, session: session)
    }

    init(logins: CopilotLogins, isOptedIn: @escaping @Sendable () -> Bool = { false }, session: URLSession = .tinybar) {
        self.logins = logins
        self.isOptedIn = isOptedIn
        self.session = session
    }

    public func isConfigured() -> Bool {
        logins.find(optedIn: false) != nil
    }

    public func identity() -> LoginIdentity? {
        logins.find(optedIn: isOptedIn()).flatMap { login in
            login.name.map { LoginIdentity(email: $0, organization: login.hostName) }
        }
    }

    public func fetch() async throws -> ProviderSnapshot {
        let optedIn = isOptedIn()
        guard let login = logins.find(optedIn: optedIn) else { throw ProviderError.notConfigured }
        guard let origin = CopilotUsageAPI.origin(host: login.host) else {
            throw CopilotUsageAPI.refusedHost
        }
        // May wait on `gh` or on the user answering a Keychain prompt.
        let logins = logins
        let token = await Task.detached(priority: .utility) { logins.token(for: login, optedIn: optedIn) }.value
        guard let token else { throw ProviderError.notConfigured }
        guard HTTP.isHeaderSafe(token) else { throw ProviderError.loginExpired }
        return try await CopilotUsageAPI.fetch(origin: origin, token: token, session: session)
    }
}

/// The logins on this Mac that can read Copilot's limits.
struct CopilotLogins: Sendable {
    /// Which login to use, before any token that takes a program to read.
    struct Login: Equatable {
        enum Source { case cli, editor, gh }
        var source: Source
        /// Like `https://github.com`, or as an editor plugin's file names it.
        var host: String
        var name: String?
        /// Holds a secret, so it stays out of logs and errors.
        var storedToken: String?

        /// As `gh` names a host.
        var hostName: String {
            guard let c = URLComponents(string: host), let name = c.host else { return host }
            return c.port.map { "\(name):\($0)" } ?? name
        }
    }

    var cliHome: URL
    var editorConfig: URL
    var ghConfig: URL
    /// `gh auth token`: the host without a scheme, and the user if it has to be that one.
    var gh: @Sendable (_ host: String, _ user: String?) -> String? = { _, _ in nil }
    /// The Copilot CLI's Keychain item, by its account (`host:login`).
    var keychain: @Sendable (_ account: String) -> String? = { _ in nil }

    static let keychainService = "copilot-cli"

    /// The Copilot CLI's user comes first, as T3 Code runs Copilot through that CLI, then an editor
    /// plugin's login. A CLI user whose token needs the Keychain, and `gh` when nothing says Copilot
    /// is in use, wait for the user to opt in: one shows a macOS prompt, the other would put a "no
    /// Copilot plan" card in front of everyone signed in to GitHub.
    func find(optedIn: Bool) -> Login? {
        if let cli = cliUser(), cli.storedToken != nil || optedIn || ghName(for: cli) != nil { return cli }
        return editorLogin() ?? (optedIn ? ghActiveLogin() : nil)
    }

    /// nil when no source can give the login's token any more.
    func token(for login: Login, optedIn: Bool) -> String? {
        if let stored = login.storedToken { return stored }
        if login.source == .gh { return gh(login.hostName, login.name) }
        if let user = ghName(for: login), let token = gh(login.hostName, user) { return token }
        guard optedIn, let name = login.name else { return nil }
        return keychain("\(login.host):\(name)")
    }

    // MARK: Copilot CLI

    /// `config.json` names the current user. Its token is in the Keychain, or in the same file where
    /// there is no Keychain. 1.x starts the file with `//` comments and renamed the keys to camelCase.
    private func cliUser() -> Login? {
        guard let config = Self.json(cliHome.appendingPathComponent("config.json")) else { return nil }
        let user = (config["lastLoggedInUser"] ?? config["last_logged_in_user"]) as? [String: Any]
            ?? ((config["loggedInUsers"] ?? config["logged_in_users"]) as? [[String: Any]])?.first
        guard let host = Self.text(user?["host"]), let name = Self.text(user?["login"]) else { return nil }
        let tokens = (config["copilotTokens"] ?? config["copilot_tokens"]) as? [String: Any]
        return Login(source: .cli, host: host, name: name, storedToken: Self.text(tokens?["\(host):\(name)"]))
    }

    // MARK: Editor plugins

    /// JetBrains, Neovim and others keep `{"github.com:<app>": {"user", "oauth_token"}}`, in
    /// `apps.json`, or with the host alone as the key in the older `hosts.json`.
    private func editorLogin() -> Login? {
        for file in ["apps.json", "hosts.json"] {
            guard let entries = Self.json(editorConfig.appendingPathComponent(file)) else { continue }
            for key in entries.keys.sorted() {
                guard let entry = entries[key] as? [String: Any], let token = Self.text(entry["oauth_token"]),
                      let host = key.split(separator: ":").first
                else { continue }
                return Login(source: .editor, host: "https://\(host)", name: Self.text(entry["user"]), storedToken: token)
            }
        }
        return nil
    }

    // MARK: gh

    private var ghLines: [String]? {
        (try? String(contentsOf: ghConfig.appendingPathComponent("hosts.yml"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `gh`'s `hosts.yml`, by host: its active user and the others it holds. Only names are taken.
    /// nil without an entry for that host. Tokens are left to `gh auth token`, wherever they live.
    private func ghUsers(host: String) -> (active: String?, all: [String])? {
        guard let lines = ghLines, let start = lines.firstIndex(of: "\(host):") else { return nil }
        let block = lines[(start + 1)...].prefix { $0.hasPrefix(" ") }
        let active = block.first { $0.hasPrefix("    user:") }.map { Self.yamlName($0.dropFirst(9)) }
        // gh writes the users as the only keys this deep: `users:`, then 8 spaces and the name.
        let listed = block.filter { $0.hasPrefix(String(repeating: " ", count: 8)) && $0.dropFirst(8).first != " " && $0.hasSuffix(":") }
            .map { Self.yamlName($0.dropLast()) }
        return (active, listed + [active].compactMap { $0 })
    }

    /// YAML quotes a name that would read as something else, like the login `123`.
    private static func yamlName(_ raw: Substring) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let isQuoted = name.count >= 2 && name.first == name.last && (name.first == "\"" || name.first == "'")
        return isQuoted ? String(name.dropFirst().dropLast()) : name
    }

    /// The login as `gh` spells it: GitHub ignores case, but `gh auth token --user` doesn't.
    private func ghName(for login: Login) -> String? {
        guard let name = login.name else { return nil }
        return ghUsers(host: login.hostName)?.all.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// github.com's active user, else that of the first GitHub Enterprise Cloud host `gh` holds.
    private func ghActiveLogin() -> Login? {
        let hosts = ghLines?.filter { !$0.hasPrefix(" ") && $0.hasSuffix(":") }.map { String($0.dropLast()) } ?? []
        guard let host = hosts.first(where: { $0 == "github.com" }) ?? hosts.first(where: { $0.hasSuffix(".ghe.com") }) else { return nil }
        return Login(source: .gh, host: "https://\(host)", name: ghUsers(host: host)?.active)
    }

    // MARK: Helpers

    private static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: raw, options: .json5Allowed)) as? [String: Any]
    }
}

extension CopilotLogins {
    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            cliHome: Paths.copilotHome(env: env),
            editorConfig: Paths.xdgConfig(env: env).appendingPathComponent("github-copilot", isDirectory: true),
            ghConfig: Paths.ghConfig(env: env))
        gh = { host, user in
            guard let gh = Paths.locateCLI("gh") else { return nil }
            // A newer `gh` renews an expiring token when asked for it, which Tinybar must not cause
            // (ADR 0001). An older one has no such flag, and doesn't renew. Not knowing which, no token.
            guard let help = ChildProcess.output(of: gh, ["auth", "token", "--help"], timeout: 10) else { return nil }
            let arguments = ["auth", "token", "--hostname", host] + (user.map { ["--user", $0] } ?? [])
                + (help.contains("--no-refresh") ? ["--no-refresh"] : [])
            return ChildProcess.output(of: gh, arguments, timeout: 10)
        }
        // Its access list holds only the Copilot CLI, so this asks the user. Give them time to answer.
        keychain = Self.untilRefused { account in
            ChildProcess.output(of: "/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-a", account, "-w"], timeout: 60)
        }
    }

    /// A prompt that was refused or left unanswered isn't shown again until the next launch, rather
    /// than every 5 minutes.
    static func untilRefused(_ read: @escaping @Sendable (String) -> String?) -> @Sendable (String) -> String? {
        let refused = RefusedFlag()
        return { account in
            guard !refused.isSet else { return nil }
            let token = read(account)
            if token == nil { refused.set() }
            return token
        }
    }

    private final class RefusedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}
