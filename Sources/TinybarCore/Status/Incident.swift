import Foundation

/// A problem a Provider reports on its own public status page that affects what Tinybar tracks
/// (see CONTEXT.md: Incident).
public struct Incident: Sendable, Hashable, Codable {
    public enum Severity: Int, Sendable, Hashable, Codable, Comparable {
        /// Planned work in progress.
        case maintenance
        case degraded
        case partialOutage
        case majorOutage

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .maintenance: "Maintenance"
            case .degraded: "Degraded"
            case .partialOutage: "Partial outage"
            case .majorOutage: "Major outage"
            }
        }
    }

    public var provider: ProviderID
    public var title: String
    public var severity: Severity
    /// The affected parts Tinybar cares about, as the status page names them ("Claude Code").
    public var components: [String]
    public var url: URL
    public var updatedAt: Date?

    public init(provider: ProviderID, title: String, severity: Severity, components: [String], url: URL, updatedAt: Date?) {
        self.provider = provider
        self.title = title
        self.severity = severity
        self.components = components
        self.url = url
        self.updatedAt = updatedAt
    }

    /// The status page it's from, by name ("status.claude.com"); `url` may be a short link.
    public var page: String {
        guard let source = StatusFeed.source(provider) else { return url.host ?? "" }
        switch source {
        case let .statuspage(base, _), let .incidentIO(base, _): return base.host ?? ""
        }
    }
}

/// Reads each Provider's public status page: no login, one or two small GETs per poll (SPEC §6).
/// Only the parts of a page that matter for a coding subscription count: Claude's Console or
/// OpenAI's image models being down is not Tinybar's business.
public enum StatusFeed {
    enum Source {
        /// A statuspage.io page. `components` are name prefixes that count; nil counts all.
        case statuspage(URL, components: [String]?)
        /// An incident.io page (OpenAI), counting one component group.
        case incidentIO(URL, group: String)
    }

    static func source(_ id: ProviderID) -> Source? {
        switch id {
        case .claude: .statuspage(URL(string: "https://status.claude.com")!, components: ["claude.ai", "Claude API", "Claude Code"])
        case .codex: .incidentIO(URL(string: "https://status.openai.com")!, group: "Codex")
        case .cursor: .statuspage(URL(string: "https://status.cursor.com")!, components: nil)
        // Antigravity has no status page; Google's Workspace feed covers the Gemini app instead.
        case .gemini: nil
        }
    }

    public static func hasFeed(_ id: ProviderID) -> Bool { source(id) != nil }

    /// The Provider's open Incidents, worst first.
    public static func fetch(_ id: ProviderID, session: URLSession = .tinybar) async throws -> [Incident] {
        switch source(id) {
        case nil:
            return []
        case let .statuspage(base, components):
            let data = try await get(base.appendingPathComponent("api/v2/summary.json"), session)
            return try statuspage(data, provider: id, base: base, components: components)
        case let .incidentIO(base, group):
            let proxy = try await get(base.appendingPathComponent("proxy/\(base.host ?? "")"), session)
            let affected = try incidentIOAffected(proxy, group: group)
            guard !affected.isEmpty else { return [] }
            // The native feed names the affected components; the incident titles come from the
            // page's statuspage-style summary.
            let summary = try? await get(base.appendingPathComponent("api/v2/summary.json"), session)
            return incidentIO(affected: affected, summary: summary, provider: id, base: base, group: group)
        }
    }

    private static func get(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        return try await HTTP.send(request, session: session, providerName: url.host ?? "Status page")
    }

    static func severity(componentStatus: String) -> Incident.Severity? {
        switch componentStatus {
        case "degraded_performance": .degraded
        case "partial_outage": .partialOutage
        case "major_outage", "full_outage": .majorOutage
        case "under_maintenance": .maintenance
        default: nil
        }
    }

    static func severity(impact: String?) -> Incident.Severity? {
        switch impact {
        case "minor": .degraded
        case "major": .partialOutage
        case "critical": .majorOutage
        case "maintenance": .maintenance
        default: nil
        }
    }

    // MARK: statuspage.io

    /// `summary.json`: unresolved incidents and in-progress maintenance, each with the components
    /// it affects. An incident that names no component counts when it has an impact.
    static func statuspage(_ data: Data, provider: ProviderID, base: URL, components: [String]?) throws -> [Incident] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let incidents = root["incidents"] as? [[String: Any]] else {
            throw ProviderError.unexpected("Unexpected status page response")
        }
        func counts(_ name: String) -> Bool {
            components?.contains { name.hasPrefix($0) } ?? true
        }
        let maintenance = (root["scheduled_maintenances"] as? [[String: Any]] ?? [])
            .filter { $0["status"] as? String == "in_progress" }
        var out: [Incident] = []
        for (entry, planned) in incidents.map({ ($0, false) }) + maintenance.map({ ($0, true) }) {
            guard let title = entry["name"] as? String, entry["status"] as? String != "resolved" else { continue }
            let affected = (entry["components"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String).map(counts) ?? false }
            let named = !(entry["components"] as? [Any] ?? []).isEmpty
            if named && affected.isEmpty { continue }
            let fromComponents = affected.compactMap { ($0["status"] as? String).flatMap(severity(componentStatus:)) }.max()
            guard let level = planned ? .maintenance : fromComponents ?? severity(impact: entry["impact"] as? String)
            else { continue }
            let link = (entry["shortlink"] as? String).flatMap(URL.init(string:))
                ?? (entry["id"] as? String).map { base.appendingPathComponent("incidents/\($0)") } ?? base
            out.append(Incident(
                provider: provider, title: title, severity: level,
                components: affected.compactMap { $0["name"] as? String },
                url: link, updatedAt: (entry["updated_at"] as? String).flatMap(parseISODate)))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    // MARK: incident.io

    /// The group's components that the native feed lists as affected, with their worst status.
    static func incidentIOAffected(_ data: Data, group: String) throws -> [(name: String, severity: Incident.Severity)] {
        guard let summary = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["summary"] as? [String: Any],
              let items = (summary["structure"] as? [String: Any])?["items"] as? [[String: Any]],
              let affected = summary["affected_components"] as? [[String: Any]]
        else { throw ProviderError.unexpected("Unexpected status page response") }
        var names: [String: String] = [:]
        for item in items {
            guard let g = item["group"] as? [String: Any], g["name"] as? String == group else { continue }
            for c in g["components"] as? [[String: Any]] ?? [] {
                // "CLI" alone reads as anything; the page means Codex's.
                let name = c["name"] as? String ?? group
                if let id = c["component_id"] as? String { names[id] = name.contains(group) ? name : "\(group) \(name)" }
            }
        }
        var worst: [String: Incident.Severity] = [:]
        for c in affected {
            guard let id = c["component_id"] as? String, let name = names[id],
                  let level = (c["status"] as? String).flatMap(severity(componentStatus:))
            else { continue }
            worst[name] = max(worst[name] ?? level, level)
        }
        return worst.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    /// One Incident for the group, titled after the open incident that names it (or the first
    /// open one with an impact).
    static func incidentIO(
        affected: [(name: String, severity: Incident.Severity)], summary: Data?, provider: ProviderID, base: URL, group: String
    ) -> [Incident] {
        guard let level = affected.map(\.severity).max() else { return [] }
        let open = ((summary.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["incidents"]
            as? [[String: Any]] ?? [])
            .filter { $0["status"] as? String != "resolved" }
        let pick = open.first { ($0["name"] as? String)?.localizedCaseInsensitiveContains(group) == true }
            ?? open.first { ($0["impact"] as? String).map { $0 != "none" } ?? false }
        let title = pick?["name"] as? String ?? "\(group) \(level.label.lowercased())"
        let url = (pick?["id"] as? String).map { base.appendingPathComponent("incidents/\($0)") } ?? base
        return [Incident(
            provider: provider, title: title, severity: level, components: affected.map(\.name),
            url: url, updatedAt: (pick?["updated_at"] as? String).flatMap(parseISODate))]
    }
}
