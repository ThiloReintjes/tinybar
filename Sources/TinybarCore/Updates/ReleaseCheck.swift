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

    /// Numeric release versions, with SemVer prerelease ordering and ignored build metadata.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> (core: [Int], prerelease: [Substring])? {
            let version = version.hasPrefix("v") ? String(version.dropFirst()) : version
            let release = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = release.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            let core = components.compactMap { Int($0) }
            guard !core.isEmpty, core.count == components.count, core.allSatisfy({ $0 >= 0 }) else { return nil }
            let prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false) : []
            guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
            return (core, prerelease)
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0, y = i < b.core.count ? b.core[i] : 0
            if x != y { return x > y }
        }
        if a.prerelease.isEmpty || b.prerelease.isEmpty {
            return a.prerelease.isEmpty && !b.prerelease.isEmpty
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            let xn = x.allSatisfy(\.isNumber), yn = y.allSatisfy(\.isNumber)
            if xn != yn { return !xn }
            if xn, x.count != y.count { return x.count > y.count }
            return x > y
        }
        return a.prerelease.count > b.prerelease.count
    }
}

/// When to ask GitHub next (SPEC §11): a day after a check that got an answer, an hour after one
/// that didn't, and right away once Tinybar runs a different version than the one that last asked.
public struct UpdateSchedule: Sendable, Hashable {
    public static let interval: TimeInterval = 24 * 3600
    public static let retry: TimeInterval = 3600

    /// The last check that got an answer.
    public var lastCheck: Date?
    /// The last check, answered or not.
    public var lastAttempt: Date?
    /// The running version at the last check.
    public var version: String?

    public init(lastCheck: Date? = nil, lastAttempt: Date? = nil, version: String? = nil) {
        self.lastCheck = lastCheck
        self.lastAttempt = lastAttempt
        self.version = version
    }

    public func isDue(now: Date, version current: String) -> Bool {
        guard version == current else { return true }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retry { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= Self.interval
    }

    public mutating func attempt(at now: Date, version current: String) {
        lastAttempt = now
        version = current
    }
}
