import Foundation

enum HTTP {
    /// Each optional endpoint keeps its own deadline without hiding fresh primary usage, and per
    /// login where it can have several.
    actor Backoff {
        private var until: [String: Date] = [:]
        func permitsRequest(at now: Date, for login: String = "") -> Bool { now >= until[login, default: .distantPast] }
        func deferRequests(until date: Date, for login: String = "") { until[login] = max(until[login, default: .distantPast], date) }
    }

    /// Explicit Cookie headers survive URLSession redirects, even with its cookie jar disabled.
    private final class CredentialRedirectGuard: NSObject, URLSessionTaskDelegate {
        let origin: URL
        init(origin: URL) { self.origin = origin }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
            guard let url = request.url,
                  url.scheme?.lowercased() == origin.scheme?.lowercased(),
                  url.host?.lowercased() == origin.host?.lowercased(), port(url) == port(origin)
            else { completionHandler(nil); return }
            completionHandler(request)
        }
    }

    /// A status the caller asked to handle itself (see `send(_:session:providerName:passing:)`).
    struct Status: Error {
        var code: Int
        var body = Data()
    }

    static func retryAfter(_ value: String, now: Date = Date()) -> TimeInterval? {
        if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Sends a request and maps status codes to ProviderError. Codes in `passing` are thrown as
    /// `Status` instead, for callers that retry them differently.
    static func send(
        _ request: URLRequest, session: URLSession, providerName: String, passing: Set<Int> = []) async throws -> Data
    {
        let data: Data
        let response: URLResponse
        do {
            let authenticated = request.value(forHTTPHeaderField: "Cookie") != nil
                || request.value(forHTTPHeaderField: "Authorization") != nil
            let redirectGuard = authenticated ? request.url.map(CredentialRedirectGuard.init) : nil
            (data, response) = try await session.data(for: request, delegate: redirectGuard)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unexpected("No HTTP response") }
        if passing.contains(http.statusCode) { throw Status(code: http.statusCode, body: data) }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.loginExpired
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { retryAfter($0) }
            throw ProviderError.rateLimited(retryAfter: retry)
        default: throw failure(providerName: providerName, status: http.statusCode)
        }
    }

    static func failure(providerName: String, status: Int) -> ProviderError {
        .unexpected("\(providerName) API returned HTTP \(status)")
    }
}
