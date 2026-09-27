import Foundation

/// USD per million tokens.
public struct ModelPrice: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?

    public func cost(_ t: TokenCounts) -> Double {
        let m = 1_000_000.0
        return Double(t.input) * input / m
            + Double(t.output) * output / m
            + Double(t.cacheRead) * (cacheRead ?? input) / m
            + Double(t.cacheWrite) * (cacheWrite ?? input) / m
    }
}

/// Current API prices from models.dev (SPEC §10). No bundled table: an unknown model has no
/// price and the UI shows "—".
public struct PriceTable: Sendable {
    public var prices: [ProviderID: [String: ModelPrice]]
    public var fetchedAt: Date?

    public static let empty = PriceTable(prices: [:], fetchedAt: nil)

    public func price(provider: ProviderID, model: String) -> ModelPrice? {
        guard let table = prices[provider] else { return nil }
        let key = ModelName.normalize(model)
        if let exact = table[key] { return exact }
        // Dated snapshots ("claude-x-20250101") price like their base id.
        if let dash = key.lastIndex(of: "-"), key[key.index(after: dash)...].allSatisfy(\.isNumber) {
            return table[String(key[..<dash])]
        }
        return nil
    }

    public func cost(provider: ProviderID, model: String, tokens: TokenCounts) -> Double? {
        price(provider: provider, model: model)?.cost(tokens)
    }

    /// models.dev provider ids for each Provider.
    static let sourceProviders: [ProviderID: String] = [.codex: "openai", .claude: "anthropic"]

    static func parse(_ data: Data, fetchedAt: Date?) throws -> PriceTable {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpected("models.dev: unexpected JSON")
        }
        var prices: [ProviderID: [String: ModelPrice]] = [:]
        for (provider, key) in sourceProviders {
            guard let models = (root[key] as? [String: Any])?["models"] as? [String: Any] else { continue }
            var table: [String: ModelPrice] = [:]
            for (id, value) in models {
                guard let cost = (value as? [String: Any])?["cost"] as? [String: Any],
                      let input = (cost["input"] as? NSNumber)?.doubleValue,
                      let output = (cost["output"] as? NSNumber)?.doubleValue
                else { continue }
                table[ModelName.normalize(id)] = ModelPrice(
                    input: input,
                    output: output,
                    cacheRead: (cost["cache_read"] as? NSNumber)?.doubleValue,
                    cacheWrite: (cost["cache_write"] as? NSNumber)?.doubleValue)
            }
            prices[provider] = table
        }
        return PriceTable(prices: prices, fetchedAt: fetchedAt)
    }
}

/// Fetches models.dev at most once per 24 h and keeps only the providers Tinybar needs on disk.
public actor PricingService {
    public static let sourceURL = URL(string: "https://models.dev/api.json")!
    private let cacheURL: URL
    private let session: URLSession
    private var table: PriceTable?

    public init(cacheURL: URL = Paths.appSupport.appendingPathComponent("prices.json"), session: URLSession = .tinybar) {
        self.cacheURL = cacheURL
        self.session = session
    }

    public func current() -> PriceTable {
        if let table { return table }
        let loaded = loadCache() ?? .empty
        table = loaded
        return loaded
    }

    /// Refreshes if the cache is older than `maxAge`. Failures keep the cached table.
    @discardableResult
    public func refreshIfNeeded(maxAge: TimeInterval = 24 * 3600) async -> PriceTable {
        let cached = current()
        if let at = cached.fetchedAt, Date().timeIntervalSince(at) < maxAge { return cached }
        do {
            var request = URLRequest(url: Self.sourceURL, timeoutInterval: 30)
            request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return cached }
            let fresh = try PriceTable.parse(data, fetchedAt: Date())
            table = fresh
            saveCache(fresh)
            return fresh
        } catch {
            return cached
        }
    }

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var prices: [String: [String: ModelPrice]]
    }

    private func loadCache() -> PriceTable? {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return nil }
        var prices: [ProviderID: [String: ModelPrice]] = [:]
        for (k, v) in file.prices { if let p = ProviderID(rawValue: k) { prices[p] = v } }
        return PriceTable(prices: prices, fetchedAt: file.fetchedAt)
    }

    private func saveCache(_ t: PriceTable) {
        let file = CacheFile(
            fetchedAt: t.fetchedAt ?? Date(),
            prices: Dictionary(uniqueKeysWithValues: t.prices.map { ($0.key.rawValue, $0.value) }))
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
