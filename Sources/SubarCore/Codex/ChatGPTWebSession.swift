import Foundation

/// Browser fallback for Codex: exchanges the chatgpt.com session cookie for the short-lived
/// access token the ChatGPT web app itself uses (`/api/auth/session`), then calls the same
/// read-only usage endpoints as the CLI path.
enum ChatGPTWebSession {
    static let cookieName = "__Secure-next-auth.session-token"

    static func accessToken(cookies: [String: String], session: URLSession) async throws -> CodexCredentials {
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/api/auth/session")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue(cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await HTTP.send(request, session: session, providerName: "chatgpt.com")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty,
              // e.g. "RefreshAccessTokenError": the token is stale until the browser itself
              // reloads chatgpt.com. We never refresh it on the browser's behalf.
              json["error"] == nil || json["error"] is NSNull
        else { throw ProviderError.loginExpired }
        let account = (json["account"] as? [String: Any])?["id"] as? String
        return CodexCredentials(accessToken: token, accountId: account)
    }

    /// Only the auth cookies: sending a browser's entire jar would add nothing and leak more.
    static func cookieHeader(_ cookies: [String: String]) -> String {
        cookies
            .filter { $0.key.hasPrefix(cookieName) || $0.key == "__Secure-next-auth.callback-url" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }
}
