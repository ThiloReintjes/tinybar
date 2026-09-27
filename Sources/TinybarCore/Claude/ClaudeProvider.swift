import Foundation

/// Claude limits. Source order (SPEC §4): Claude Code's OAuth login → claude.ai browser
/// session (opt-in).
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    private let session: URLSession
    private let allowBrowser: @Sendable () -> Bool

    public init(session: URLSession = .tinybar, allowBrowser: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.allowBrowser = allowBrowser
    }

    public func isConfigured() -> Bool {
        ClaudeCredentials.hasStoredLogin()
    }

    public func fetch() async throws -> ProviderSnapshot {
        do {
            let creds = try ClaudeCredentials.load()
            // An expired token would just 401. Claude Code refreshes it on its next run.
            guard !creds.isExpired else { throw ProviderError.loginExpired }
            let usage = try await ClaudeUsageAPI.fetchUsage(accessToken: creds.accessToken, session: session)
            return ClaudeUsageAPI.snapshot(from: usage, plan: creds.planName)
        } catch let error as ProviderError {
            guard error == .loginExpired || error == .notConfigured, allowBrowser() else { throw error }
            guard let found = BrowserCookies.find(domain: "claude.ai", required: ["sessionKey"]),
                  let key = found.cookies["sessionKey"]
            else { throw error }
            return try await ClaudeWebAPI.fetch(sessionKey: key, session: session)
        }
    }
}
