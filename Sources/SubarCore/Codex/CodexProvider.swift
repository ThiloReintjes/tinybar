import Foundation

/// Codex limits. Source order (SPEC §4): CLI OAuth → `codex app-server` fallback.
public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    private let session: URLSession

    public init(session: URLSession = .subar) {
        self.session = session
    }

    public func isConfigured() -> Bool {
        FileManager.default.fileExists(atPath: CodexCredentials.authFileURL().path)
    }

    public func fetch() async throws -> ProviderSnapshot {
        do {
            return try await fetchViaOAuth()
        } catch let error as ProviderError {
            // Only a login problem is worth the app-server fallback; rate limits and network
            // errors would hit the same backend again.
            guard error == .loginExpired || error == .notConfigured,
                  CodexAppServer.locateCodex() != nil
            else { throw error }
            do {
                return try await CodexAppServer.fetch()
            } catch {
                throw ProviderError.loginExpired
            }
        }
    }

    private func fetchViaOAuth() async throws -> ProviderSnapshot {
        let creds = try CodexCredentials.load()
        async let usage = CodexUsageAPI.fetchUsage(creds, session: session)
        async let banked = try? CodexUsageAPI.fetchBankedResets(creds, session: session)
        return try await CodexUsageAPI.snapshot(from: usage, bankedResets: banked)
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
