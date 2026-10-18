import Foundation

enum HTTP {
    /// A status the caller asked to handle itself (see `send(_:session:providerName:passing:)`).
    struct Status: Error {
        var code: Int
    }

    /// Sends a request and maps status codes to ProviderError. Codes in `passing` are thrown as
    /// `Status` instead, for callers that retry them differently.
    static func send(
        _ request: URLRequest, session: URLSession, providerName: String, passing: Set<Int> = []) async throws -> Data
    {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unexpected("No HTTP response") }
        if passing.contains(http.statusCode) { throw Status(code: http.statusCode) }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.loginExpired
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retry)
        default: throw ProviderError.unexpected("\(providerName) API returned HTTP \(http.statusCode)")
        }
    }
}
