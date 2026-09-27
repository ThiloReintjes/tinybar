import Foundation

enum HTTP {
    /// Sends a request and maps status codes to ProviderError.
    static func send(_ request: URLRequest, session: URLSession, providerName: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unexpected("No HTTP response") }
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
