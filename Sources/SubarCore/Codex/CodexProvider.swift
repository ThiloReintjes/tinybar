import Foundation

/// Codex limits. Source order (SPEC §4): CLI OAuth → `codex app-server` → chatgpt.com
/// browser session (opt-in).
public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    private let session: URLSession
    private let allowBrowser: @Sendable () -> Bool

    public init(session: URLSession = .subar, allowBrowser: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.allowBrowser = allowBrowser
    }

    public func isConfigured() -> Bool {
        FileManager.default.fileExists(atPath: CodexCredentials.authFileURL().path)
    }

    public func fetch() async throws -> ProviderSnapshot {
        var lastError: ProviderError
        do {
            return try await fetch(with: CodexCredentials.load(), source: .cli)
        } catch let error as ProviderError {
            // Only a login problem is worth a fallback; rate limits and network errors would
            // hit the same backend again.
            guard error == .loginExpired || error == .notConfigured else { throw error }
            lastError = error
        }

        if CodexAppServer.locateCodex() != nil, let snapshot = try? await CodexAppServer.fetch() {
            return snapshot
        }

        if allowBrowser(),
           let found = BrowserCookies.find(domain: "chatgpt.com", required: [ChatGPTWebSession.cookieName])
        {
            do {
                let creds = try await ChatGPTWebSession.accessToken(cookies: found.cookies, session: session)
                return try await fetch(with: creds, source: .browser)
            } catch let error as ProviderError {
                lastError = error
            }
        }
        throw lastError == .notConfigured ? ProviderError.notConfigured : ProviderError.loginExpired
    }

    private func fetch(with creds: CodexCredentials, source: DataSource) async throws -> ProviderSnapshot {
        async let usage = CodexUsageAPI.fetchUsage(creds, session: session)
        async let banked = try? CodexUsageAPI.fetchBankedResets(creds, session: session)
        var snapshot = try await CodexUsageAPI.snapshot(from: usage, bankedResets: banked)
        snapshot.source = source
        return snapshot
    }
}

extension URLSession {
    /// Ephemeral: no cookie jar, no URL cache on disk.
    public static let subar: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
