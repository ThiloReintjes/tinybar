import Foundation

/// A published Tinybar version.
public struct Release: Sendable, Hashable, Codable {
    public var version: String
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Asks GitHub for the latest release: one unauthenticated GET, at most once a day (SPEC §11).
public enum ReleaseCheck {
    static let latestURL = URL(string: "https://api.github.com/repos/ThiloReintjes/tinybar/releases/latest")!

    public static func latest(session: URLSession = .tinybar) async throws -> Release {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        let data = try await HTTP.send(request, session: session, providerName: "GitHub")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let url = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { throw ProviderError.unexpected("Unexpected GitHub release response") }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url)
    }

    /// Compares dotted versions numerically, so 0.10.0 is newer than 0.9.1.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
