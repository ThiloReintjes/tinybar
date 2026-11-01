import Foundation

/// The call OpenCode's own client makes for the Go allowance (`packages/core/src/usage-limits.ts`).
enum OpenCodeUsageAPI {
    static let noSubscription = ProviderError.unexpected("This OpenCode login has no Go subscription")

    // MARK: Wire types

    struct Report: Decodable {
        var usage: Usage?
    }

    struct Usage: Decodable {
        var rolling: Meter?
        var weekly: Meter?
        var monthly: Meter?
    }

    struct Meter: Decodable {
        var status: String?
        var percent: Double?
        var resetsAt: String?
    }

    // MARK: Fetch

    static func fetch(_ login: OpenCodeLogin, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: login.origin.appendingPathComponent("zen/go/v1/usage"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(login.token)", forHTTPHeaderField: "Authorization")
        if let workspace = login.workspaceID { request.setValue(workspace, forHTTPHeaderField: "x-opencode-org-id") }
        let data: Data
        do {
            data = try await HTTP.send(request, session: session, providerName: "OpenCode", passing: [403])
        } catch let status as HTTP.Status {
            // Go refuses a workspace the member doesn't subscribe in. A bad login is 401. The site's
            // firewall answers 403 too, for a client it blocks, with a body of its own.
            let refusal = try? JSONSerialization.jsonObject(with: status.body) as? [String: Any]
            guard refusal?["type"] as? String == "error" else {
                throw HTTP.failure(providerName: "OpenCode", status: status.code)
            }
            throw noSubscription
        }
        let report: Report?
        do {
            report = try JSONDecoder().decode(Report?.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected OpenCode usage response")
        }
        guard let usage = report?.usage else { throw noSubscription }
        return try snapshot(from: usage)
    }

    // MARK: Mapping

    /// `rolling` is the 5-hour window. Go keeps a dollar limit per model, but reports one share per
    /// window, so there are no model-specific windows.
    static func snapshot(from usage: Usage, now: Date = Date()) throws -> ProviderSnapshot {
        func window(_ meter: Meter?, id: String, seconds: Int? = nil, title: String? = nil) -> LimitWindow? {
            guard let meter, let percent = meter.percent else { return nil }
            let reset = meter.resetsAt.flatMap(parseISODate)
            return LimitWindow(
                id: id, title: title ?? WindowKind.title(durationSeconds: seconds),
                // Go refuses requests until a rate-limited window resets, whatever its share says.
                usedPercent: meter.status == "rate-limited" ? 100 : min(max(percent, 0), 100),
                resetsAt: reset, durationSeconds: seconds ?? monthSeconds(endingAt: reset))
        }
        let windows = [
            window(usage.rolling, id: "session", seconds: 5 * 3600),
            window(usage.weekly, id: "weekly", seconds: 7 * 86400),
            window(usage.monthly, id: "monthly", title: "Monthly"),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.unexpected("Unexpected OpenCode usage response") }
        return ProviderSnapshot(provider: .opencode, plan: nil, windows: windows, source: .cli, fetchedAt: now)
    }

    /// The calendar month ending at the Reset, since months differ in length.
    private static func monthSeconds(endingAt reset: Date?) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let reset, let start = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        return Int(reset.timeIntervalSince(start))
    }
}
