import Foundation

/// Grok limits, with the login `grok login` keeps. Only the CLI ever renews it: a refresh token can
/// be used once, so doing that here could sign the user out (ADR 0001, ADR 0012).
public struct GrokProvider: UsageProvider {
    public let id = ProviderID.grok
    private let logins: GrokLogins
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.init(logins: GrokLogins(), session: session)
    }

    init(logins: GrokLogins, session: URLSession = .tinybar) {
        self.logins = logins
        self.session = session
    }

    public func isConfigured() -> Bool {
        logins.find() != nil
    }

    public func identity() -> LoginIdentity? {
        logins.find().flatMap { login in
            login.email.map { LoginIdentity(email: $0, organization: login.team?.id, organizationName: login.team?.name) }
        }
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let login = logins.find(), let base = logins.apiBase else { throw ProviderError.notConfigured }
        if let ends = login.expiresAt, ends <= Date() { throw ProviderError.loginExpired }
        guard HTTP.isHeaderSafe(login.token) else { throw ProviderError.loginExpired }
        return try await GrokUsageAPI.fetch(base: base, login: login, session: session)
    }
}

/// The login on this Mac that can read Grok's limits, if the CLI would use it for grok.com.
struct GrokLogins: Sendable {
    struct Login: Equatable {
        struct Team: Equatable {
            var id: String
            var name: String?
        }

        /// A secret, so it stays out of logs and errors.
        var token: String
        var email: String?
        var team: Team?
        var expiresAt: Date?
    }

    /// The CLI's own login, as its installer names it, then the one older versions kept.
    static let scopes = ["https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828", "https://accounts.x.ai/sign-in"]
    /// An API key bills elsewhere, and the CLI itself ignores the old web logins (`grok` was their old name).
    private static let unusableModes: Set<String> = ["api_key", "web_login", "grok"]
    /// Any of these can make the CLI use another account or server than the file's grok.com login.
    private static let customDeploymentVariables = [
        "GROK_OIDC_ISSUER", "GROK_OIDC_CLIENT_ID", "GROK_OAUTH2_ISSUER", "GROK_OAUTH2_CLIENT_ID",
        "GROK_OAUTH2_PRINCIPAL_TYPE", "GROK_OAUTH2_PRINCIPAL_ID", "GROK_AUTH_PROVIDER_COMMAND",
        "GROK_LOCAL_AUTH", "GROK_MODELS_BASE_URL", "GROK_CONFIG", "GROK_CONFIG_PATH", "GROK_AUTH", "GROK_AUTH_PATH",
    ]
    private static let customDeploymentSection = #"(?m)^\s*(?:\[\[?\s*)?["']?(?:auth|grok_com_config|endpoints)["']?\s*[.\]=]"#

    var home: URL
    /// Where an admin's managed config goes.
    var system = URL(fileURLWithPath: "/etc/grok", isDirectory: true)
    var env: [String: String] = [:]

    /// nil when the CLI points at a server that isn't grok.com or this Mac: a login isn't sent there
    /// (SECURITY.md). The variable is the CLI's own, so `Scripts/verify-grok.py` can point both at a mock.
    var apiBase: URL? {
        guard let custom = env["GROK_CLI_CHAT_PROXY_BASE_URL"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty
        else { return GrokUsageAPI.defaultBase }
        guard let c = URLComponents(string: custom), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              HTTP.isLoopback(scheme: scheme, host: host)
        else { return nil }
        return c.url
    }

    /// A custom deployment is left to the CLI, as T3 Code does: the file's login may not be its account.
    func find() -> Login? {
        guard apiBase != nil, !isCustomDeployment,
              let raw = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let entries = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        // The first entry with a token is the login. If the CLI won't use that one, it doesn't try the next.
        let entry = Self.scopes.lazy.compactMap { entries[$0] as? [String: Any] }.first { Self.text($0["key"]) != nil }
        return entry.flatMap(Self.login)
    }

    private var isCustomDeployment: Bool {
        if Self.customDeploymentVariables.contains(where: { env[$0]?.trimmingCharacters(in: .whitespaces).isEmpty == false }) {
            return true
        }
        let configs = [
            home.appendingPathComponent("config.toml"), home.appendingPathComponent("managed_config.toml"),
            home.appendingPathComponent("requirements.toml"), system.appendingPathComponent("managed_config.toml"),
            system.appendingPathComponent("requirements.toml"),
        ]
        return configs.contains { config in
            (try? String(contentsOf: config, encoding: .utf8))?.range(of: Self.customDeploymentSection, options: .regularExpression) != nil
        }
    }

    private static func login(_ entry: [String: Any]) -> Login? {
        guard let token = text(entry["key"]), !unusableModes.contains(text(entry["auth_mode"]) ?? "") else { return nil }
        // As the CLI tells them apart. Every account has a `team_id`, its own personal one included.
        var team: Login.Team?
        if text(entry["principal_type"])?.caseInsensitiveCompare("team") == .orderedSame, let id = text(entry["team_id"]) {
            team = Login.Team(id: id, name: text(entry["team_name"]))
        }
        return Login(token: token, email: text(entry["email"]), team: team, expiresAt: text(entry["expires_at"]).flatMap(parseISODate))
    }

    static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

extension GrokLogins {
    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(home: Paths.grokHome(env: env), env: env)
    }
}
