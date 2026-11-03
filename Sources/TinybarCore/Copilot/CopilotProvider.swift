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

    /// Any login readable without a prompt, the current CLI user's or another's.
    public func isConfigured() -> Bool {
        !logins.all(optedIn: false).isEmpty
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

    /// Every other user the Copilot CLI or `gh` is signed in as, each read on its own (SPEC §15).
    /// The same opt-in applies as to the main login.
    public func otherUsers() -> [CopilotUser] {
        let optedIn = isOptedIn()
        let main = logins.find(optedIn: optedIn)
        return logins.all(optedIn: optedIn).filter { !$0.isSameLogin(as: main) }.map { login in
            var pinned = logins
            pinned.pinned = login
            return CopilotUser(
                provider: CopilotProvider(logins: pinned, isOptedIn: isOptedIn, session: session),
                place: "\(login.source == .gh ? "gh" : "Copilot CLI") · \(login.hostName)")
        }
    }
}

/// Another user the Copilot CLI or `gh` holds.
public struct CopilotUser: Sendable {
    public let provider: CopilotProvider
    /// Which program holds the login, and for which host.
    public let place: String

    /// Its Account's id, known before asking for any numbers, so a rate limit can be waited out.
    /// Only an editor plugin's login can lack a name, and there is one of those: it gets the id it
    /// has as the main login, so a pin on it holds whichever role it's in.
    public var accountID: String {
        provider.identity()?.accountID ?? LoginIdentity.accountID(place: ProviderID.copilot.rawValue)
    }

    /// Its Account with fresh numbers, or nil when the user has no Copilot plan or it ended, which
    /// makes it no subscription at all: a GitHub account `gh` holds for other work. A token that
    /// can't be read stays an Account, Stale, so one read before keeps its numbers and its pin.
    public func account() async -> Account? {
        var account = blank()
        do {
            account.snapshot = try await provider.fetch()
        } catch let error as ProviderError {
            if error == CopilotUsageAPI.noPlan || error == CopilotUsageAPI.ended { return nil }
            account.error = error
        } catch {
            account.error = .unexpected(error.localizedDescription)
        }
        return account
    }

    /// Its Account while it waits out a rate limit: Stale, without asking for numbers.
    public func waitingAccount() -> Account {
        var account = blank()
        account.error = .rateLimited(retryAfter: nil)
        return account
    }

    private func blank() -> Account {
        Account(id: accountID, name: provider.identity()?.email ?? place, loginHint: ProviderID.copilot.loginHint)
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

        /// GitHub ignores the case of a login.
        func isSameUser(as other: Login?) -> Bool {
            guard let other, let name, let otherName = other.name else { return false }
            return hostName.lowercased() == other.hostName.lowercased() && name.caseInsensitiveCompare(otherName) == .orderedSame
        }

        /// The same user, or, as an editor plugin's login may have no name, the same token.
        func isSameLogin(as other: Login?) -> Bool {
            guard let other else { return false }
            if self == other || isSameUser(as: other) { return true }
            return storedToken != nil && storedToken == other.storedToken && hostName.lowercased() == other.hostName.lowercased()
        }

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
    /// Only the Copilot CLI's own user counts: a folder other than the default one.
    var cliOnly = false
    /// The one login to read, for another user than the one `find` would pick.
    var pinned: Login?

    static let keychainService = "copilot-cli"

    /// The Copilot CLI's user comes first, as T3 Code runs Copilot through that CLI, then an editor
    /// plugin's login. A CLI user whose token needs the Keychain, and `gh` when nothing says Copilot
    /// is in use, wait for the user to opt in: one shows a macOS prompt, the other would put a "no
    /// Copilot plan" card in front of everyone signed in to GitHub.
    func find(optedIn: Bool) -> Login? {
        // `gh`'s users wait for the opt-in, which can be withdrawn while they are read one by one.
        if let pinned { return pinned.source == .gh && !optedIn ? nil : pinned }
        // A folder's user is named either way: its token is the only thing that may need a prompt.
        if cliOnly { return cliUser() }
        if let cli = cliUser(), isUsable(cli, optedIn: optedIn) { return cli }
        return editorLogin() ?? (optedIn ? ghActiveLogin() : nil)
    }

    private func isUsable(_ cli: Login, optedIn: Bool) -> Bool {
        cli.storedToken != nil || optedIn || ghName(for: cli) != nil
    }

    /// Every login that can read Copilot's limits, in `find`'s order: each user the Copilot CLI is
    /// signed in as, an editor plugin's, then each user `gh` holds for a host Copilot answers on.
    /// A user found twice counts once.
    func all(optedIn: Bool) -> [Login] {
        var logins = cliUsers().filter { isUsable($0, optedIn: optedIn) }
        if !cliOnly {
            logins += [editorLogin()].compactMap { $0 }
            if optedIn { logins += ghLogins() }
        }
        // A user found twice is read through the copy whose token needs no program or prompt.
        var seen: [Login] = []
        for login in logins {
            if let i = seen.firstIndex(where: { $0.isSameLogin(as: login) }) {
                if seen[i].storedToken == nil, login.storedToken != nil { seen[i] = login }
            } else {
                seen.append(login)
            }
        }
        return seen
    }

    /// The Copilot CLI's user alone, in a folder other than the default one. No editor plugin or
    /// `gh` login stands in for it there: that would be the default login's account again.
    static func folder(_ url: URL) -> CopilotLogins {
        var logins = CopilotLogins()
        logins.cliHome = url
        logins.cliOnly = true
        return logins
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
    func cliUser() -> Login? {
        guard let config = Self.json(cliHome.appendingPathComponent("config.json")) else { return nil }
        let user = (config["lastLoggedInUser"] ?? config["last_logged_in_user"]) as? [String: Any]
            ?? ((config["loggedInUsers"] ?? config["logged_in_users"]) as? [[String: Any]])?.first
        return Self.cliLogin(user, in: config)
    }

    /// Everyone the CLI is signed in as, its current user first.
    private func cliUsers() -> [Login] {
        guard let config = Self.json(cliHome.appendingPathComponent("config.json")) else { return [] }
        let users = ((config["loggedInUsers"] ?? config["logged_in_users"]) as? [[String: Any]]) ?? []
        return [cliUser()].compactMap { $0 } + users.compactMap { Self.cliLogin($0, in: config) }
    }

    /// A user as `config.json` lists one, with its token where the file holds it.
    private static func cliLogin(_ user: [String: Any]?, in config: [String: Any]) -> Login? {
        guard let host = text(user?["host"]), let name = text(user?["login"]) else { return nil }
        let tokens = (config["copilotTokens"] ?? config["copilot_tokens"]) as? [String: Any]
        return Login(source: .cli, host: host, name: name, storedToken: text(tokens?["\(host):\(name)"]))
    }

    // MARK: Editor plugins

    /// JetBrains, Neovim and others keep `{"github.com:<app>": {"user", "oauth_token"}}`, in
    /// `apps.json`, or with the host alone as the key in the older `hosts.json`.
    private func editorLogin() -> Login? {
        for file in ["apps.json", "hosts.json"] {
            guard let entries = Self.json(editorConfig.appendingPathComponent(file)) else { continue }
            for key in entries.keys.sorted() {
                guard let entry = entries[key] as? [String: Any], let token = Self.text(entry["oauth_token"]),
                      let host = key.split(separator: ":").first,
                      CopilotUsageAPI.origin(host: "https://\(host)") != nil
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

    /// Every user `gh` holds for github.com and GitHub Enterprise Cloud hosts, active ones first.
    private func ghLogins() -> [Login] {
        let hosts = ghLines?.filter { !$0.hasPrefix(" ") && $0.hasSuffix(":") }.map { String($0.dropLast()) } ?? []
        return hosts.filter { $0 == "github.com" || $0.hasSuffix(".ghe.com") }.flatMap { host -> [Login] in
            guard let users = ghUsers(host: host) else { return [] }
            return ([users.active].compactMap { $0 } + users.all).map { Login(source: .gh, host: "https://\(host)", name: $0) }
        }
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
        keychain = Self.keychainUntilRefused
    }

    /// Its access list holds only the Copilot CLI, so this asks the user. Give them time to answer.
    /// One for the whole app: a folder's logins are made afresh on every fetch, and a refusal must
    /// outlast them.
    private static let keychainUntilRefused = untilRefused { account in
        ChildProcess.output(of: "/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", account, "-w"], timeout: 60)
    }

    /// A prompt that was refused or left unanswered isn't shown again for that account until the next
    /// launch, rather than every 5 minutes.
    static func untilRefused(_ read: @escaping @Sendable (String) -> String?) -> @Sendable (String) -> String? {
        let refused = RefusedAccounts()
        return { account in
            guard !refused.contains(account) else { return nil }
            let token = read(account)
            if token == nil { refused.insert(account) }
            return token
        }
    }

    private final class RefusedAccounts: @unchecked Sendable {
        private let lock = NSLock()
        private var accounts = Set<String>()
        func contains(_ account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return accounts.contains(account) }
        func insert(_ account: String) { lock.lock(); accounts.insert(account); lock.unlock() }
    }
}
