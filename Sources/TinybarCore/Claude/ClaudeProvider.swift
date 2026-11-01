import Foundation

/// Claude limits. Source order (SPEC §4): Claude Code's OAuth login → claude.ai browser
/// session (opt-in). With `folder`, only the login in that config folder (SPEC §15).
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    private let session: URLSession
    private let allowBrowser: @Sendable () -> Bool
    private let folder: URL?

    public init(session: URLSession = .tinybar, folder: URL? = nil, allowBrowser: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.folder = folder
        self.allowBrowser = allowBrowser
    }

    public func isConfigured() -> Bool {
        ClaudeCredentials.hasStoredLogin(folder: folder)
    }

    public func identity() -> LoginIdentity? {
        ClaudeCredentials.identity(folder: folder)
    }

    public func fetch() async throws -> ProviderSnapshot {
        do {
            let creds = try ClaudeCredentials.load(folder: folder)
            // An expired token would just 401. Claude Code refreshes it on its next run.
            guard !creds.isExpired else { throw ProviderError.loginExpired }
            let usage = try await ClaudeUsageAPI.fetchUsage(accessToken: creds.accessToken, session: session)
            return ClaudeUsageAPI.snapshot(from: usage, plan: creds.planName)
        } catch let error as ProviderError {
            guard folder == nil, error == .loginExpired || error == .notConfigured, allowBrowser() else { throw error }
            guard let found = BrowserCookies.find(domain: "claude.ai", required: ["sessionKey"]),
                  let key = found.cookies["sessionKey"]
            else { throw error }
            return try await ClaudeWebAPI.fetch(sessionKey: key, session: session)
        }
    }
}
