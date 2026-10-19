import Foundation

/// USD per million tokens.
public struct ModelPrice: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    /// Long-context Prices: a whole request whose context is over `size` tokens costs these
    /// instead (CONTEXT.md). Smallest size first.
    public var tiers: [Tier]?

    public struct Tier: Sendable, Hashable, Codable {
        public var size: Int64
        public var price: ModelPrice
    }

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, tiers: [Tier]? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tiers = tiers
    }

    var isValid: Bool {
        [input, output, cacheRead, cacheWrite].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
            && (tiers?.allSatisfy { $0.size > 0 && $0.price.isValid } ?? true)
            && (tiers?.map(\.size) == tiers?.map(\.size).sorted())
    }

    public func cost(_ t: TokenCounts) -> Double {
        let m = 1_000_000.0
        return Double(t.input) * input / m
            + Double(t.output) * output / m
            + Double(t.cacheRead) * (cacheRead ?? input) / m
            + Double(t.cacheWrite) * (cacheWrite ?? input) / m
    }

    /// `total` priced at the base rates, except the long requests in it: `long` holds their
    /// tokens by Context Band, and each band takes the highest tier its requests all exceed.
    public func cost(_ total: TokenCounts, long: [Int64: TokenCounts]) -> Double {
        var c = cost(total)
        var remaining = total
        for (band, raw) in long.sorted(by: { $0.key < $1.key }) {
            // Old or corrupt band rows must not price more tokens than the daily total holds.
            let t = TokenCounts(
                input: min(max(raw.input, 0), max(remaining.input, 0)),
                output: min(max(raw.output, 0), max(remaining.output, 0)),
                cacheWrite: min(max(raw.cacheWrite, 0), max(remaining.cacheWrite, 0)),
                cacheRead: min(max(raw.cacheRead, 0), max(remaining.cacheRead, 0)))
            remaining += -t
            guard let tier = tiers?.last(where: { $0.size <= band }) else { continue }
            c += tier.price.cost(t) - cost(t)
        }
        return c
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
        // Dated snapshots use their base id; providers spell dates as YYYYMMDD or YYYY-MM-DD.
        if let date = key.range(of: #"-(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})$"#, options: .regularExpression) {
            return table[String(key[..<date.lowerBound])]
        }
        return nil
    }

    public func cost(provider: ProviderID, model: String, tokens: TokenCounts, long: [Int64: TokenCounts] = [:]) -> Double? {
        price(provider: provider, model: model)?.cost(tokens, long: long)
    }

    public func cost(_ row: DailyUsage) -> Double? {
        cost(provider: row.provider, model: row.model, tokens: row.tokens, long: row.long)
    }

    /// models.dev provider ids for each Provider.
    static let sourceProviders: [ProviderID: String] = [.codex: "openai", .claude: "anthropic"]

    private static func rates(_ cost: [String: Any]) throws -> ModelPrice? {
        func number(_ key: String) throws -> Double? {
            guard let raw = cost[key], !(raw is NSNull) else { return nil }
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0 else {
                throw ProviderError.unexpected("models.dev: invalid price")
            }
            return n.doubleValue
        }
        guard let input = try number("input"), let output = try number("output") else { return nil }
        return try ModelPrice(input: input, output: output, cacheRead: number("cache_read"), cacheWrite: number("cache_write"))
    }

    static func parse(_ data: Data, fetchedAt: Date?) throws -> PriceTable {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpected("models.dev: unexpected JSON")
        }
        var prices: [ProviderID: [String: ModelPrice]] = [:]
        for (provider, key) in sourceProviders {
            guard let models = (root[key] as? [String: Any])?["models"] as? [String: Any] else { continue }
            var table: [String: ModelPrice] = [:]
            for (id, value) in models {
                do {
                    guard let cost = (value as? [String: Any])?["cost"] as? [String: Any], var price = try rates(cost)
                    else { continue }
                    // `tiers` lists context tiers; older entries only carry `context_over_200k`.
                    var tiers: [ModelPrice.Tier] = []
                    guard let listed = (cost["tiers"] ?? []) as? [[String: Any]] else {
                        throw ProviderError.unexpected("models.dev: invalid tiers")
                    }
                    for tier in listed {
                        guard let spec = tier["tier"] as? [String: Any], let type = spec["type"] as? String else {
                            throw ProviderError.unexpected("models.dev: invalid tier")
                        }
                        guard type == "context" else { continue }
                        guard let n = spec["size"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                              n.doubleValue.isFinite,
                              let size = Int64(n.stringValue) ?? Int64(exactly: n.doubleValue), size > 0 else {
                            throw ProviderError.unexpected("models.dev: invalid context size")
                        }
                        guard let p = try rates(tier) else {
                            throw ProviderError.unexpected("models.dev: incomplete context price")
                        }
                        tiers.append(.init(size: size, price: p))
                    }
                    if tiers.isEmpty, let raw = cost["context_over_200k"] {
                        guard let over = raw as? [String: Any], let p = try rates(over) else {
                            throw ProviderError.unexpected("models.dev: incomplete context price")
                        }
                        tiers.append(.init(size: 200_000, price: p))
                    }
                    price.tiers = tiers.isEmpty ? nil : tiers.sorted { $0.size < $1.size }
                    table[ModelName.normalize(id)] = price
                } catch { continue }
            }
            prices[provider] = table
        }
        guard prices.values.contains(where: { !$0.isEmpty }) else {
            throw ProviderError.unexpected("models.dev: no model prices")
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
    private var lastAttempt: Date?

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
        let now = Date()
        if let at = cached.fetchedAt, now.timeIntervalSince(at) < maxAge { return cached }
        if let at = lastAttempt, now.timeIntervalSince(at) < maxAge { return cached }
        lastAttempt = now
        saveCache(cached)
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

    /// One malformed model must not discard every other cached price.
    private struct CachedModel: Codable {
        var price: ModelPrice?
        init(_ price: ModelPrice) { self.price = price }
        init(from decoder: Decoder) throws { price = try? ModelPrice(from: decoder) }
        func encode(to encoder: Encoder) throws { try price.encode(to: encoder) }
    }

    private struct CacheFile: Codable {
        var fetchedAt: Date?
        var lastAttempt: Date?
        var prices: [String: [String: CachedModel]]
        /// 2 since Long-context Prices. An older cache is used but fetched again right away.
        var format: Int?
    }

    private func loadCache() -> PriceTable? {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return nil }
        var prices: [ProviderID: [String: ModelPrice]] = [:]
        var valid = true
        for (k, v) in file.prices {
            guard let provider = ProviderID(rawValue: k) else { continue }
            let checked = v.compactMapValues { $0.price }.filter { $0.value.isValid }
            if checked.count != v.count { valid = false }
            prices[provider] = checked
        }
        if file.fetchedAt != nil, !prices.values.contains(where: { !$0.isEmpty }) { valid = false }
        lastAttempt = valid && file.format == 2 ? file.lastAttempt : nil
        return PriceTable(prices: prices, fetchedAt: valid && file.format == 2 ? file.fetchedAt : nil)
    }

    private func saveCache(_ t: PriceTable) {
        let file = CacheFile(
            fetchedAt: t.fetchedAt, lastAttempt: lastAttempt,
            prices: Dictionary(uniqueKeysWithValues: t.prices.map { ($0.key.rawValue, $0.value.mapValues(CachedModel.init)) }),
            format: 2)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
