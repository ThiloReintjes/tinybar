import Foundation
@testable import TinybarCore
import Testing

private final class FailedPricesProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var count: Int { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func failedPriceFetchesAreThrottledAcrossCallsAndRestarts() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = dir.appendingPathComponent("prices.json")
    // A legacy cache still supplies rates but must fetch tiers immediately, despite its fresh date.
    let old = #"{"fetchedAt":\#(Date().timeIntervalSinceReferenceDate),"prices":{"codex":{"m":{"input":2,"output":10}}}}"#
    try Data(old.utf8).write(to: cache)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FailedPricesProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = PricingService(cacheURL: cache, session: session)
    let initial = await service.current()
    #expect(initial.fetchedAt == nil)
    #expect(initial.price(provider: .codex, model: "m")?.input == 2)
    async let first = service.refreshIfNeeded()
    async let second = service.refreshIfNeeded()
    let tables = await [first, second]
    #expect(tables.allSatisfy { $0.price(provider: .codex, model: "m")?.input == 2 })
    #expect(FailedPricesProtocol.count == 1)
    let restarted = PricingService(cacheURL: cache, session: session)
    let retained = await restarted.refreshIfNeeded()
    #expect(retained.price(provider: .codex, model: "m")?.input == 2)
    #expect(retained.fetchedAt == nil)
    #expect(FailedPricesProtocol.count == 1)

    var expired = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
    expired["lastAttempt"] = Date().addingTimeInterval(-25 * 3600).timeIntervalSinceReferenceDate
    try JSONSerialization.data(withJSONObject: expired).write(to: cache)
    let retry = PricingService(cacheURL: cache, session: session)
    _ = await retry.refreshIfNeeded()
    #expect(FailedPricesProtocol.count == 2)

    let cold = PricingService(cacheURL: dir.appendingPathComponent("empty.json"), session: session)
    _ = await cold.refreshIfNeeded()
    let coldRestart = PricingService(cacheURL: dir.appendingPathComponent("empty.json"), session: session)
    _ = await coldRestart.refreshIfNeeded()
    #expect(FailedPricesProtocol.count == 3)
}
