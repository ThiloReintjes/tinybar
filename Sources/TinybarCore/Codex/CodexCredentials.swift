import Foundation

/// OAuth tokens the Codex CLI stores in `auth.json`. Read-only: Tinybar never refreshes or
/// rewrites them (ADR 0001).
public struct CodexCredentials: Sendable {
    public var accessToken: String
    public var accountId: String?

    public static func authFileURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        Paths.codexHome(env: env).appendingPathComponent("auth.json")
    }

    public static func load(from url: URL = authFileURL()) throws -> CodexCredentials {
        guard let data = try? Data(contentsOf: url) else { throw ProviderError.notConfigured }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> CodexCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpected("Codex auth.json is not valid JSON")
        }
        // An API-key login has no ChatGPT subscription limits to show.
        guard let tokens = json["tokens"] as? [String: Any],
              let access = nonEmpty(tokens["access_token"] ?? tokens["accessToken"])
        else { throw ProviderError.notConfigured }

        let accountId = nonEmpty(tokens["account_id"] ?? tokens["accountId"])
            ?? nonEmpty(tokens["id_token"] ?? tokens["idToken"]).flatMap(accountIdFromJWT)
        return CodexCredentials(accessToken: access, accountId: accountId)
    }

    /// Who is signed in, from the email in the login's `id_token`. The workspace tells apart two
    /// accounts under one email.
    public static func identity(from url: URL = authFileURL()) -> LoginIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return identity(fromAuth: data)
    }

    static func identity(fromAuth data: Data) -> LoginIdentity? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let jwt = nonEmpty(tokens["id_token"] ?? tokens["idToken"]),
              let payload = jwtPayload(jwt),
              let email = nonEmpty(payload["email"])
        else { return nil }
        // The account requests are made for, so limits are filed under whose they are.
        return LoginIdentity(email: email, organization: (try? parse(data))?.accountId)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }

    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func accountIdFromJWT(_ jwt: String) -> String? {
        guard let payload = jwtPayload(jwt) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return nonEmpty(auth?["chatgpt_account_id"]) ?? nonEmpty(payload["chatgpt_account_id"])
    }
}
