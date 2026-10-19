import Foundation
import SQLite3
@testable import TinybarCore
import Testing

private final class ResetCreditsFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let usage = request.url!.path.hasSuffix("/usage")
        let limited = !usage && request.value(forHTTPHeaderField: "Authorization") == "Bearer limited"
        let response = HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200, httpVersion: nil,
                                       headerFields: limited ? ["Retry-After": "3600"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = usage ? #"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}"# : #"{"credits":[]}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test func bankedResetBackoffDoesNotHideFreshUsage() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResetCreditsFixture.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let backoff = CodexUsageAPI.ResetBackoff()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let limited = CodexCredentials(accessToken: "limited", accountId: nil)
    let normal = CodexCredentials(accessToken: "normal", accountId: nil)
    #expect(try await CodexUsageAPI.fetchBankedResets(limited, session: session, backoff: backoff, now: { now }) == nil)
    // The fixture would return an empty (non-nil) array if this request were sent.
    #expect(try await CodexUsageAPI.fetchBankedResets(normal, session: session, backoff: backoff, now: { now.addingTimeInterval(300) }) == nil)
    let usage = try await CodexUsageAPI.fetchUsage(limited, session: session)
    #expect(CodexUsageAPI.snapshot(from: usage, bankedResets: nil).windows.first?.remainingPercent == 75)
    #expect(try await CodexUsageAPI.fetchBankedResets(normal, session: session, backoff: backoff, now: { now.addingTimeInterval(3600) }) == [])
}

@Test func cookieReadsDropExpiredRowsButKeepSessionCookies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("cookies.sqlite")
    var writer: OpaquePointer?
    #expect(sqlite3_open(db.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    let chromiumNow: Int64 = (11_644_473_600 + 100) * 1_000_000
    let sql = """
    CREATE TABLE moz_cookies(host TEXT, name TEXT, value TEXT, expiry INTEGER);
    INSERT INTO moz_cookies VALUES ('claude.ai','old','synthetic',99),('claude.ai','boundary','synthetic',100),('claude.ai','valid','synthetic',101);
    CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER);
    INSERT INTO cookies VALUES ('claude.ai','old','synthetic',X'',\(chromiumNow - 1)),
      ('claude.ai','boundary','synthetic',X'',\(chromiumNow)),
      ('claude.ai','valid','synthetic',X'',\(chromiumNow + 1_000_000)),
      ('claude.ai','session','synthetic',X'',0);
    """
    #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
    let now = Date(timeIntervalSince1970: 100)
    #expect(BrowserCookies.readRows(db: db, domain: "claude.ai", firefox: true, now: now)?.map(\.name) == ["valid"])
    #expect(BrowserCookies.readRows(db: db, domain: "claude.ai", firefox: false, now: now)?.map(\.name) == ["valid", "session"])
}

@Test func calendarInvalidTimestampsNeverBecomeValidGrantDates() throws {
    for raw in ["2026-02-31T00:00:00Z", "2026-02-29T00:00:00.123Z", "2100-02-29T00:00:00Z", "2026-04-31T00:00:00+01:00"] {
        #expect(parseUTCTimestamp(raw) == nil)
        #expect(parseISODate(raw) == nil)
    }
    for raw in ["2099-01-01T00:00:00Zgarbage", "2099-01-01T00:00:00.12345678901Zgarbage", "2099-01-01T00:00:00+01:99", "2099-01-01T00:00:00Z\n"] {
        #expect(parseUTCTimestamp(raw) == nil)
        #expect(parseISODate(raw) == nil)
    }
    #expect(parseISODate("2024-02-29T00:00:00Z") != nil)
    #expect(parseISODate("2000-02-29T00:00:00Z") != nil)
    #expect(parseISODate("2024-02-29T01:00:00+01:00") == parseISODate("2024-02-29T00:00:00Z"))
    let json = #"{"eligible":true,"grants":[{"resets_left":1,"paused":false,"ends_at":"2026-02-31T00:00:00Z"}]}"#
    let grants = try JSONDecoder().decode(ClaudeUsageAPI.ResetGrants.self, from: Data(json.utf8))
    #expect(grants.available(at: parseISODate("2026-03-01T00:00:00Z")!).isEmpty)
}
