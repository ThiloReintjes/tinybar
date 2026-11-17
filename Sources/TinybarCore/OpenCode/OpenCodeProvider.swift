import Foundation

/// OpenCode Go limits, with the login the OpenCode CLI keeps. It is only read; an expired one is
/// never refreshed (ADR 0001). OpenCode's other offers have no Limit Window to show (ADR 0009).
public struct OpenCodeProvider: UsageProvider {
    public let id = ProviderID.opencode
    private let data: OpenCodeData
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.init(data: OpenCodeData(), session: session)
    }

    init(data: OpenCodeData, session: URLSession = .tinybar) {
        self.data = data
        self.session = session
    }

    /// Auto-enabled only with a Go key. A Console login may have no Go plan, so it is opt-in via
    /// Settings, like Cursor's browser session.
    public func isConfigured() -> Bool {
        data.hasGoKey
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let stored = data.storedLogin() else { throw ProviderError.notConfigured }
        return try await OpenCodeUsageAPI.fetch(OpenCodeLogin(stored), session: session)
    }
}

/// Where OpenCode keeps its data. 2.x stores logins in `opencode.db`; 1.x (which has an unused
/// `credential` table too) in `auth.json`.
struct OpenCodeData: Sendable {
    static let goIntegration = "opencode-go"
    static let consoleIntegration = "opencode"

    var database: URL?
    var authFile: URL

    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        let dir = Paths.openCodeData(env: env)
        authFile = dir.appendingPathComponent("auth.json")
        switch env["OPENCODE_DB"]?.trimmingCharacters(in: .whitespaces) {
        case nil, "": database = dir.appendingPathComponent("opencode.db")
        case ":memory:": database = nil
        case let custom?:
            let path = (custom as NSString).expandingTildeInPath
            database = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        }
    }

    /// A data folder, as `$XDG_DATA_HOME/opencode` names one.
    init(folder: URL) {
        self.init(database: folder.appendingPathComponent("opencode.db"), authFile: folder.appendingPathComponent("auth.json"))
    }

    init(database: URL?, authFile: URL) {
        self.database = database
        self.authFile = authFile
    }

    struct StoredLogin {
        var integration: String
        /// The credential's JSON. Holds a secret, so it stays out of logs and errors.
        var value: Data

        /// A Console login names its workspace; without one, OpenCode reads no Go usage with it.
        var hasWorkspace: Bool {
            let json = try? JSONSerialization.jsonObject(with: value) as? [String: Any]
            return (json?["metadata"] as? [String: Any])?["orgID"] is String
        }
    }

    struct StoredLogins {
        var go: StoredLogin?
        var console: StoredLogin?

        /// What the usage request sends. OpenCode reads Go usage with its Console login and that
        /// login's workspace, never a Go key, and the endpoint can refuse a Go key (#37).
        var forUsage: StoredLogin? {
            if let console, console.hasWorkspace { return console }
            return go ?? console
        }
    }

    func storedLogin() -> StoredLogin? { storedLogins().forUsage }

    /// What auto-enables OpenCode: a Console login may have no Go plan (ADR 0009).
    var hasGoKey: Bool { storedLogins().go != nil }

    /// The logins OpenCode itself would pick, one per integration. `auth.json` stays behind after
    /// the upgrade to 2.x and even after logging out, so it only counts without a database or with
    /// one known to be 1.x, and holds only a Go key.
    func storedLogins() -> StoredLogins {
        let stored = database.flatMap { db in
            CredentialDatabase.read(db) { handle -> (logins: StoredLogins, isV1: Bool)? in
                guard let tables = SQLiteDB.rows(handle, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('message', 'session_v2')")?
                    .compactMap({ $0[0].text })
                else { return nil }
                func login(_ integration: String) -> StoredLogin? {
                    Self.activeCredential(integration, in: handle).map { StoredLogin(integration: integration, value: $0) }
                }
                return (StoredLogins(go: login(Self.goIntegration), console: login(Self.consoleIntegration)), tables == ["message"])
            }
        }
        if let stored {
            if stored.logins.go != nil || stored.logins.console != nil || !stored.isV1 { return stored.logins }
        } else if let database, FileManager.default.fileExists(atPath: database.path) {
            return StoredLogins()
        }
        guard let raw = try? Data(contentsOf: authFile),
              let entries = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let entry = entries[Self.goIntegration] as? [String: Any],
              let value = try? JSONSerialization.data(withJSONObject: entry)
        else { return StoredLogins() }
        return StoredLogins(go: StoredLogin(integration: Self.goIntegration, value: value))
    }

    /// OpenCode's own order. Migrated rows have no `active` flag, and the newest of them counts.
    private static func activeCredential(_ integration: String, in handle: OpaquePointer) -> Data? {
        let sql = "SELECT CAST(value AS TEXT) FROM credential WHERE integration_id = ? ORDER BY active DESC, time_created DESC, id DESC LIMIT 1"
        return SQLiteDB.rows(handle, sql, [.text(integration)])?.first?.first?.text.map { Data($0.utf8) }
    }
}

/// A usable login: what the usage request sends, and where to.
struct OpenCodeLogin {
    var token: String
    var origin: URL
    var workspaceID: String?

    /// A credential that is expired, malformed or managed elsewhere counts as an expired login.
    /// Another account is never tried in its place.
    init(_ stored: OpenCodeData.StoredLogin, now: Date = Date()) throws {
        guard let value = try? JSONSerialization.jsonObject(with: stored.value) as? [String: Any],
              let secret = Self.secret(value, now: now),
              HTTP.isHeaderSafe(secret)
        else { throw ProviderError.loginExpired }
        let metadata = value["metadata"] as? [String: Any]
        guard let origin = Self.origin(server: metadata?["server"]) else {
            throw ProviderError.unexpected("This OpenCode login is for a server Tinybar won't send it to")
        }
        token = secret
        self.origin = origin
        workspaceID = (metadata?["orgID"] as? String).flatMap { HTTP.isHeaderSafe($0) ? $0 : nil }
    }

    /// What a fetch header drops from both ends of its value, and nothing else.
    private static let httpWhitespace = CharacterSet(charactersIn: " \t\r\n")

    /// OpenCode keeps a pasted key as typed, and its client sends it trimmed, since a fetch header
    /// drops surrounding whitespace. So a key with a stray space or newline works there, and here too.
    private static func secret(_ value: [String: Any], now: Date) -> String? {
        let secret: String?
        switch value["type"] as? String {
        case "key", "api":
            secret = value["key"] as? String
        case "oauth":
            // Skipped within 60 s of expiry, like Cursor's token. 0 means the issuer gave no lifetime.
            guard let number = value["expires"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  case let expires = number.doubleValue,
                  expires == 0 || Date(timeIntervalSince1970: expires / 1000) > now.addingTimeInterval(60)
            else { return nil }
            secret = value["access"] as? String
        default:
            return nil
        }
        return secret?.trimmingCharacters(in: httpWhitespace)
    }

    /// OpenCode sends a credential to the Console it signed in to. Tinybar does the same for
    /// opencode.ai and a Console on this Mac (development, `Scripts/verify-opencode.py`), and
    /// nowhere else (SECURITY.md).
    static func origin(server: Any?) -> URL? {
        let fallback = URL(string: "https://opencode.ai")!
        guard let server else { return fallback }
        guard let raw = server as? String, let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased()
        else { return nil }
        if host == "console.opencode.ai" { return fallback }  // retired, maps onto opencode.ai
        let isLocal = HTTP.isLoopback(scheme: scheme, host: host)
        let isOpenCode = scheme == "https" && (host == "opencode.ai" || host.hasSuffix(".opencode.ai"))
        guard isLocal || isOpenCode else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = c.host
        origin.port = c.port
        return origin.url
    }
}
