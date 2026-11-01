import Foundation
@testable import TinybarCore
import Testing

// Fixtures come from real runs, not from guesses. `Scripts/verify-opencode.py` produces the same
// rows: OpenCode 1.18.31 and 2.2.5 against a local mock of the Go API, which answered with 1,200 prompt
// tokens (200 cached) and 340 completion tokens (40 reasoning). The usage report is the shape in
// OpenCode's own `packages/core/test/usage-limits.test.ts`, which 2.2.5's client accepted from the mock.

private let v1Row = #"""
{"parentID":"msg_19881fde6001MHnUqPoWRzg7Y7","role":"assistant","mode":"build","agent":"build","path":{"cwd":"/private/tmp/oc1-home/work","root":"/private/tmp/oc1-home/work"},"cost":0.002948,"tokens":{"total":1540,"input":1000,"output":300,"reasoning":40,"cache":{"write":0,"read":200}},"modelID":"glm-5.2","providerID":"opencode-go","time":{"created":1793560018784,"completed":1793560021850},"finish":"stop"}
"""#

private let v2Row = #"""
{"time":{"created":1793560031406,"streamed":1793560031487,"completed":1793560031499},"agent":"build","model":{"id":"glm-5.2","providerID":"opencode-go","variant":"default"},"content":[{"type":"text","text":"Mock reply."}],"snapshot":{"start":"4b825dc642cb6eb9a060e54bf8d69288fbee4904","end":"4b825dc642cb6eb9a060e54bf8d69288fbee4904","files":[]},"finish":"stop","rawFinish":"stop","cost":0.002948,"tokens":{"input":1000,"output":300,"reasoning":40,"cache":{"read":200,"write":0}}}
"""#

private let v2Compaction = #"""
{"time":{"created":1793560349460},"status":"completed","reason":"manual","model":{"id":"glm-5.2","providerID":"opencode-go","variant":"default"},"summary":"## Objective\nMock.\n","cost":0.002948,"tokens":{"input":1000,"output":300,"reasoning":40,"cache":{"read":200,"write":0}}}
"""#

private let v2FailedCompaction = #"""
{"time":{"created":1793560307704},"status":"failed","reason":"manual","error":{"type":"compaction.failed","message":"Compaction summary did not match the required template"},"cost":0.005896,"tokens":{"input":2000,"output":600,"reasoning":80,"cache":{"read":400,"write":0}}}
"""#

/// What the live endpoint answered without a valid key, on 2026-11-01.
private let liveUnauthorized = #"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#

/// What the site's firewall answered a blocked client, on the same day.
private let liveFirewallBlock = #"{"type":"https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/","title":"Error 1010: Access denied","status":403}"#

private let reset = "2026-10-24T17:00:00.000Z"

private func report(_ rolling: String = "ok", _ percent: Double = 42) -> String {
    #"""
    {"usage":{"rolling":{"status":"\#(rolling)","percent":\#(percent),"resetsAt":"\#(reset)"},
     "weekly":{"status":"ok","percent":18,"resetsAt":"\#(reset)"},
     "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-01T00:00:00.000Z"}}}
    """#
}

/// A throwaway OpenCode data directory holding the tables of the given version.
private struct Fixture {
    let dir: URL
    var data: OpenCodeData { OpenCodeData(database: database, authFile: dir.appendingPathComponent("auth.json")) }
    var database: URL { dir.appendingPathComponent("opencode.db") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }

    /// Real columns: 1.x has a `credential` table it doesn't use, and `session_message` for another purpose.
    static let credentialTable = """
    CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL, value TEXT NOT NULL,
        connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
    """
    static let v1Tables = credentialTable + """
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL, data TEXT NOT NULL, seq INTEGER NOT NULL);
    """
    static let v2SessionTables = """
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    """
    static let v2Tables = credentialTable + v2SessionTables

    func open() throws -> SQLiteDB { try SQLiteDB(path: database.path) }

    func setUp(_ tables: String) throws {
        try open().exec(tables)
    }

    func addCredential(_ db: SQLiteDB, id: String, integration: String, active: Int64?, created: Int64, value: String) throws {
        try db.run(
            "INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated) VALUES (?, ?, 'x', ?, ?, ?, ?)",
            [.text(id), .text(integration), .text(value), active.map { .int($0) } ?? .null, .int(created), .int(created)])
    }

    func addV1(_ db: SQLiteDB, id: String, updated: Int64 = 1_793_560_021_851, data: String = v1Row) throws {
        try db.run("INSERT INTO message VALUES (?, 'ses', 1793560018784, ?, ?)", [.text(id), .int(updated), .text(data)])
    }

    func addV2(_ db: SQLiteDB, id: String, type: String = "assistant", session: String = "ses", seq: Int64, updated: Int64 = 1_793_560_031_500, data: String = v2Row) throws {
        try db.run(
            "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES (?, ?, ?, ?, 1793560031406, ?, ?)",
            [.text(id), .text(session), .text(type), .int(seq), .int(updated), .text(data)])
    }

    var storePath: URL { dir.appendingPathComponent("tinybar.sqlite") }

    func store() throws -> UsageStore {
        try UsageStore(path: storePath)
    }
}

// MARK: Usage report

private func snapshot(_ json: String) throws -> ProviderSnapshot {
    let usage = try #require(try JSONDecoder().decode(OpenCodeUsageAPI.Report.self, from: Data(json.utf8)).usage)
    return try OpenCodeUsageAPI.snapshot(from: usage)
}

@Test func mapsOpenCodeGoUsage() throws {
    let s = try snapshot(report())
    #expect(s.provider == .opencode && s.source == .cli && s.plan == nil)
    #expect(s.windows.map(\.id) == ["session", "weekly", "monthly"])
    #expect(s.windows.map(\.title) == ["5-hour", "Weekly", "Monthly"])
    #expect(s.windows.map(\.remainingPercent) == [58, 82, 0])
    #expect(s.windows.map(\.kind) == [.session, .weekly, .other])
    #expect(s.windows.allSatisfy { !$0.isModelSpecific })
    #expect(s.windows[0].resetsAt == parseISODate(reset))
    #expect(s.windows[2].durationSeconds == 31 * 86400)  // October, ending at the Reset
}

@Test func rateLimitedOpenCodeWindowHasNothingLeft() throws {
    // Go refuses requests until such a window resets, even with a share below 100.
    #expect(try snapshot(report("rate-limited", 97)).windows[0].remainingPercent == 0)
}

@Test func toleratesPartialOpenCodeUsage() throws {
    // The shape in CodexBar's fixtures: no weekly, no resets.
    let s = try snapshot(#"{"usage":{"rolling":{"percent":0},"monthly":{"percent":100}}}"#)
    #expect(s.windows.map(\.id) == ["session", "monthly"])
    #expect(s.windows[0].resetsAt == nil && s.windows[1].durationSeconds == nil)
    // Out-of-range shares are clamped; a bad date is unknown rather than a failure.
    let odd = try snapshot(#"{"usage":{"rolling":{"percent":250,"resetsAt":"soon"},"weekly":{"percent":-5}}}"#)
    #expect(odd.windows.map(\.remainingPercent) == [0, 100])
    #expect(odd.windows[0].resetsAt == nil)
    #expect(throws: ProviderError.self) { try snapshot(#"{"usage":{"rolling":{"status":"ok"}}}"#) }
}

// MARK: Request and errors

private final class OpenCodeServer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// The token picks the answer. A request that isn't what OpenCode's client sends is a 400.
    override func startLoading() {
        let url = request.url!
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let valid = request.httpMethod == "GET" && url.path == "/zen/go/v1/usage" && url.query == nil
            && token.hasPrefix("Bearer ") && request.value(forHTTPHeaderField: "Accept") == "application/json"
            && request.value(forHTTPHeaderField: "User-Agent") == "Tinybar"
            && request.value(forHTTPHeaderField: "Cookie") == nil
        var status = 200
        var headers: [String: String] = [:]
        var body = report()
        switch String(token.dropFirst(7)) {
        case _ where !valid: status = 400; body = ""
        case "workspace" where request.value(forHTTPHeaderField: "x-opencode-org-id") != "wrk_anomaly": status = 400; body = ""
        case "unauthorized": status = 401; body = liveUnauthorized
        case "no-go": status = 403; body = #"{"type":"error"}"#
        case "blocked": status = 403; body = liveFirewallBlock
        case "busy": status = 429; headers["Retry-After"] = "120"; body = ""
        case "down": status = 500; body = "oops"
        case "html": body = "<html></html>"
        case "null": body = "null"
        case "empty": body = #"{"usage":{}}"#
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func mockedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OpenCodeServer.self]
    return URLSession(configuration: config)
}

private func fetch(key: String) async throws -> ProviderSnapshot {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try #"{"opencode-go":{"type":"api","key":"\#(key)"}}"#.write(to: fixture.data.authFile, atomically: true, encoding: .utf8)
    let session = mockedSession()
    defer { session.invalidateAndCancel() }
    return try await OpenCodeProvider(data: fixture.data, session: session).fetch()
}

@Test func fetchesWithOpenCodesOwnRequest() async throws {
    #expect(try await fetch(key: "good").windows.count == 3)
}

@Test func mapsOpenCodeFailuresToProviderErrors() async throws {
    await #expect(throws: ProviderError.loginExpired) { try await fetch(key: "unauthorized") }
    await #expect(throws: OpenCodeUsageAPI.noSubscription) { try await fetch(key: "no-go") }
    await #expect(throws: OpenCodeUsageAPI.noSubscription) { try await fetch(key: "null") }
    await #expect(throws: ProviderError.unexpected("OpenCode API returned HTTP 403"), "a firewall block isn't about the plan") { try await fetch(key: "blocked") }
    await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) { try await fetch(key: "busy") }
    await #expect(throws: ProviderError.unexpected("OpenCode API returned HTTP 500")) { try await fetch(key: "down") }
    await #expect(throws: ProviderError.unexpected("Unexpected OpenCode usage response")) { try await fetch(key: "html") }
    await #expect(throws: ProviderError.unexpected("Unexpected OpenCode usage response")) { try await fetch(key: "empty") }
}

@Test func sendsTheWorkspaceOfAConsoleLogin() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v2Tables)
    try fixture.addCredential(
        try fixture.open(), id: "c", integration: "opencode", active: 1, created: 1,
        value: #"{"type":"key","key":"workspace","metadata":{"server":"https://opencode.ai/console","orgID":"wrk_anomaly"}}"#)
    let session = mockedSession()
    defer { session.invalidateAndCancel() }
    #expect(try await OpenCodeProvider(data: fixture.data, session: session).fetch().windows.count == 3)
}

// MARK: Login

private func login(_ value: String, integration: String = "opencode-go") throws -> OpenCodeLogin {
    try OpenCodeLogin(.init(integration: integration, value: Data(value.utf8)), now: Date(timeIntervalSince1970: 1_900_000_000))
}

@Test func readsTheLoginOpenCodeKeeps() throws {
    #expect(try login(#"{"type":"key","key":"k"}"#).token == "k")
    #expect(try login(#"{"type":"api","key":"k"}"#).token == "k")  // 1.x
    let oauth = try login(#"{"type":"oauth","methodID":"device","access":"a","refresh":"r","expires":1900000061000,"metadata":{"server":"https://opencode.ai/console","orgID":"wrk_x"}}"#)
    #expect(oauth.token == "a" && oauth.workspaceID == "wrk_x" && oauth.origin.absoluteString == "https://opencode.ai")
}

@Test(arguments: [
    #"{"type":"oauth","access":"a","refresh":"r","expires":1900000059000}"#,  // about to expire
    #"{"type":"oauth","access":"a"}"#,
    #"{"type":"external","methodID":"m"}"#,
    #"{"type":"key"}"#,
    #"{"type":"key","key":12}"#,
    #"{"type":"key","key":"a\nheader"}"#,
    #"{"type":"key","key":""}"#,
    "{",
])
func unusableOpenCodeLoginCountsAsExpired(value: String) throws {
    #expect(throws: ProviderError.loginExpired) { try login(value) }
}

@Test func openCodeLoginIsOnlySentToOpenCode() throws {
    func origin(_ server: String) -> String? { OpenCodeLogin.origin(server: server)?.absoluteString }
    #expect(OpenCodeLogin.origin(server: nil)?.absoluteString == "https://opencode.ai")
    #expect(origin("https://opencode.ai/console") == "https://opencode.ai")
    #expect(origin("https://dev.opencode.ai/console") == "https://dev.opencode.ai")
    #expect(origin("https://console.opencode.ai") == "https://opencode.ai")  // retired host
    #expect(origin("http://127.0.0.1:4242/console") == "http://127.0.0.1:4242")
    for bad in ["http://opencode.ai", "https://evil.example", "https://opencode.ai.evil.example", "https://evilopencode.ai", "ftp://127.0.0.1", "not a url"] {
        #expect(origin(bad) == nil, "\(bad)")
    }
    #expect(OpenCodeLogin.origin(server: 12) == nil)
    #expect(throws: ProviderError.self) { try login(#"{"type":"key","key":"k","metadata":{"server":"https://evil.example"}}"#) }
}

@Test func picksTheSameCredentialAsOpenCode() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v2Tables)
    let db = try fixture.open()
    func key() -> String? {
        fixture.data.storedLogin().map { String(decoding: $0.value, as: UTF8.self) }
    }
    #expect(key() == nil)

    // A switch leaves the old row with active = 0.
    try fixture.addCredential(db, id: "a", integration: "opencode-go", active: 0, created: 1, value: "old")
    try fixture.addCredential(db, id: "b", integration: "opencode-go", active: 1, created: 2, value: "selected")
    try fixture.addCredential(db, id: "z", integration: "opencode-go", active: 0, created: 3, value: "newer but unselected")
    #expect(key() == "selected")

    // A Go key names the subscription, ahead of a Console login.
    try fixture.addCredential(db, id: "c", integration: "opencode", active: 1, created: 4, value: "console")
    try fixture.addCredential(db, id: "d", integration: "another", active: 1, created: 5, value: "unrelated")
    #expect(key() == "selected")
    #expect(fixture.data.storedLogin()?.integration == "opencode-go")
    #expect(OpenCodeProvider(data: fixture.data).isConfigured())

    try db.exec("DELETE FROM credential WHERE integration_id = 'opencode-go'")
    #expect(key() == "console")
    #expect(!OpenCodeProvider(data: fixture.data).isConfigured(), "a Console login may have no Go plan")
}

@Test func upgradedLoginHasNoActiveFlag() throws {
    // 2.x converts auth.json into a row with active NULL; the newest such row is the selected one.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v2Tables)
    let db = try fixture.open()
    try fixture.addCredential(db, id: "a", integration: "opencode-go", active: nil, created: 1, value: "older")
    try fixture.addCredential(db, id: "b", integration: "opencode-go", active: nil, created: 2, value: "newest")
    #expect(fixture.data.storedLogin().map { String(decoding: $0.value, as: UTF8.self) } == "newest")
}

@Test func onlyOpenCode1UsesAuthFile() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try #"{"openai":{"type":"oauth"},"opencode-go":{"type":"api","key":"from-file"}}"#.write(to: fixture.data.authFile, atomically: true, encoding: .utf8)

    // No database yet, and none gets created.
    #expect(try OpenCodeLogin(#require(fixture.data.storedLogin())).token == "from-file")
    #expect(!FileManager.default.fileExists(atPath: fixture.database.path))

    // 1.x, as observed on 1.18.31: an empty `credential` table and the key in auth.json.
    try fixture.setUp(Fixture.v1Tables)
    #expect(try OpenCodeLogin(#require(fixture.data.storedLogin())).token == "from-file")
    #expect(OpenCodeProvider(data: fixture.data).isConfigured())

    // 2.x leaves auth.json behind, and logging out only empties the table.
    try fixture.open().exec("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT NOT NULL)")
    #expect(fixture.data.storedLogin() == nil)

    // Other providers in auth.json are nothing to OpenCode Go.
    let other = try Fixture()
    defer { other.remove() }
    try #"{"openai":{"type":"oauth"}}"#.write(to: other.data.authFile, atomically: true, encoding: .utf8)
    #expect(other.data.storedLogin() == nil)
}

@Test func malformedAuthFileEntryIsNoLogin() throws {
    // Foundation raises an exception Swift can't catch on serializing a bare string.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try #"{"opencode-go":"x"}"#.write(to: fixture.data.authFile, atomically: true, encoding: .utf8)
    #expect(fixture.data.storedLogin() == nil)
}

@Test(arguments: ["not a database, or a damaged one", ""])
func unknownDatabaseDoesNotBringBackAuthFile(contents: String) throws {
    // It may be 2.x, where the key in auth.json was logged out or belongs to another account.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try #"{"opencode-go":{"type":"api","key":"stale"}}"#.write(to: fixture.data.authFile, atomically: true, encoding: .utf8)
    try String(repeating: contents, count: 200).write(to: fixture.database, atomically: true, encoding: .utf8)
    #expect(fixture.data.storedLogin() == nil)
}

@Test func findsOpenCodeData() {
    #expect(OpenCodeData(env: ["XDG_DATA_HOME": "/x"]).database?.path == "/x/opencode/opencode.db")
    #expect(OpenCodeData(env: ["XDG_DATA_HOME": "/x"]).authFile.path == "/x/opencode/auth.json")
    #expect(OpenCodeData(env: ["XDG_DATA_HOME": "relative"]).database?.path.hasSuffix("/.local/share/opencode/opencode.db") == true)
    #expect(OpenCodeData(env: ["OPENCODE_DB": "/y/channel.db"]).database?.path == "/y/channel.db")
    #expect(OpenCodeData(env: ["XDG_DATA_HOME": "/x", "OPENCODE_DB": "channel.db"]).database?.path == "/x/opencode/channel.db")
    #expect(OpenCodeData(env: ["OPENCODE_DB": ":memory:"]).database == nil)
}

// MARK: Token history

private func totals(_ store: UsageStore) async throws -> (count: Int, tokens: TokenCounts) {
    let rows = try await store.daily(since: "0000", provider: .opencode)
    var sum = TokenCounts()
    for row in rows { sum += row.tokens }
    return (rows.count, sum)
}

private let oneResponse = TokenCounts(input: 1000, output: 340, cacheWrite: 0, cacheRead: 200)

@Test func countsOpenCode1Responses() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "msg_a")
    let store = try fixture.store()

    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
    let rows = try await store.daily(since: "0000")
    #expect(rows.count == 1)
    #expect(rows[0].provider == .opencode && rows[0].model == "glm-5.2")
    #expect(rows[0].day == DayKey.string(for: Date(timeIntervalSince1970: 1_793_560_018.784)))
    // `output` excludes reasoning, which is billed as output.
    #expect(rows[0].tokens == oneResponse)

    #expect(try await store.ingestOpenCode(database: fixture.database) == 0, "reading again adds nothing")
    #expect(try await totals(store).tokens == oneResponse)
}

@Test func countsOpenCode2Responses() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v2Tables)
    let db = try fixture.open()
    let project = fixture.dir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try db.run("INSERT INTO session_v2 VALUES ('ses', ?)", [.text(project.path)])
    try fixture.addV2(db, id: "msg_a", seq: 1)
    try fixture.addV2(db, id: "msg_user", type: "user", seq: 2, data: #"{"time":{"created":1793560031383},"text":"\"say hi\"","files":[]}"#)
    try fixture.addV2(db, id: "msg_compact", type: "compaction", seq: 3, data: v2Compaction)
    try fixture.addV2(db, id: "msg_failed", type: "compaction", seq: 4, data: v2FailedCompaction)
    let store = try fixture.store()

    #expect(try await store.ingestOpenCode(database: fixture.database) == 2)
    let rows = try await store.daily(since: "0000", provider: .opencode)
    #expect(rows.count == 1)
    #expect(rows[0].tokens == TokenCounts(input: 2000, output: 680, cacheWrite: 0, cacheRead: 400))
    #expect(ProjectResolver.displayName(rows[0].project) == "repo")
}

@Test func openCodeForkAndUpgradeCountOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    // After the real upgrade both tables hold the message. A fork copies it under a new id in
    // another session, with the same time and tokens, in 1.x and 2.x alike.
    try fixture.setUp(Fixture.v1Tables.replacingOccurrences(of: "CREATE TABLE session_message", with: "CREATE TABLE session_message_old") + Fixture.v2SessionTables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "msg_a")
    try fixture.addV1(db, id: "msg_fork_v1", updated: 1_793_560_218_921)
    let converted = #"{"time":{"created":1793560018784,"completed":1793560021850},"model":{"id":"glm-5.2","providerID":"opencode-go","variant":"default"},"cost":0.002948,"tokens":{"input":1000,"output":300,"reasoning":40,"cache":{"read":200,"write":0}}}"#
    try fixture.addV2(db, id: "msg_a", seq: 1, data: converted)
    try fixture.addV2(db, id: "msg_a_7", session: "fork", seq: 1, data: converted)
    let store = try fixture.store()

    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
    #expect(try await totals(store).tokens == oneResponse)
}

@Test func eachOpenCodeStepCounts() async throws {
    // A turn with a tool call writes one row per step, with the same tokens if the model reports so.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "step1", data: v1Row.replacingOccurrences(of: "1793560018784", with: "1793560338190"))
    try fixture.addV1(db, id: "step2", data: v1Row.replacingOccurrences(of: "1793560018784", with: "1793560340331"))
    let store = try fixture.store()
    #expect(try await store.ingestOpenCode(database: fixture.database) == 2)
}

@Test func skipsWhatIsNotAFinishedGoResponse() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "chatgpt", data: v1Row.replacingOccurrences(of: "\"opencode-go\"", with: "\"openai\""))
    try fixture.addV1(db, id: "zen", data: v1Row.replacingOccurrences(of: "\"opencode-go\"", with: "\"opencode\""))
    try fixture.addV1(db, id: "streaming", data: v1Row.replacingOccurrences(of: ",\"completed\":1793560021850", with: ""))
    try fixture.addV1(db, id: "user", data: #"{"role":"user","time":{"created":1793560018407},"model":{"providerID":"opencode-go","modelID":"glm-5.2"}}"#)
    try fixture.addV1(db, id: "empty", data: v1Row.replacingOccurrences(of: #""input":1000,"output":300,"reasoning":40"#, with: #""input":0,"output":0,"reasoning":0"#).replacingOccurrences(of: #""read":200"#, with: #""read":0"#))
    try fixture.addV1(db, id: "broken", data: "{")
    try fixture.addV1(db, id: "wrong", data: v1Row.replacingOccurrences(of: #""input":1000"#, with: #""input":"many""#).replacingOccurrences(of: #""modelID":"glm-5.2""#, with: #""modelID":null"#))
    let store = try fixture.store()
    #expect(try await store.ingestOpenCode(database: fixture.database) == 0)
    #expect(try await totals(store).count == 0)
}

@Test func picksUpOpenCodeRowsLater() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    let store = try fixture.store()
    let streaming = v1Row.replacingOccurrences(of: ",\"completed\":1793560021850", with: "")
    try fixture.addV1(db, id: "msg_a", updated: 1_793_560_020_000, data: streaming)
    #expect(try await store.ingestOpenCode(database: fixture.database) == 0)

    // The same row, finished. A later row from another session sets the cursor past it first.
    let later = v1Row.replacingOccurrences(of: "1793560018784", with: "1793560900000")
    try fixture.addV1(db, id: "msg_b", updated: 1_793_560_900_000, data: later)
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
    try db.run("UPDATE message SET data = ?, time_updated = ? WHERE id = 'msg_a'", [.text(v1Row), .int(1_793_560_800_000)])
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1, "committed late, inside the overlap")

    // Far behind the cursor it would no longer be read, which is what keeps polls cheap.
    let old = v1Row.replacingOccurrences(of: "1793560018784", with: "1793000000000")
    try fixture.addV1(db, id: "msg_old", updated: 1_793_000_000_000, data: old)
    #expect(try await store.ingestOpenCode(database: fixture.database) == 0)
}

@Test func openCodeRowsOfOtherProvidersMoveTheCursorToo() async throws {
    // Otherwise someone without Go would scan every message on every poll, for good.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "chatgpt", updated: 1_793_560_900_000, data: v1Row.replacingOccurrences(of: "\"opencode-go\"", with: "\"openai\""))
    let store = try fixture.store()
    try await store.ingestOpenCode(database: fixture.database)
    #expect(OpenCodeHistory.read(database: fixture.database, after: 0)?.newest == 1_793_560_900_000)
    let cursor = try SQLiteDB(path: fixture.storePath.path)
        .run("SELECT value FROM meta WHERE key = 'opencode_cursor'").first?.first?.text
    #expect(cursor == "1793560900000")
}

@Test func unsettledOpenCodeReadDoesNotMoveOn() async throws {
    // A checkpoint between copying the database and its WAL: the copy shows a newer row but not an
    // older one, far enough back that the overlap wouldn't reach it from the newer row.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    nonisolated(unsafe) let db = try fixture.open()
    let older = v1Row.replacingOccurrences(of: "1793560018784", with: "1793000000000")
    let newer = v1Row.replacingOccurrences(of: "1793560018784", with: "1793560900000")
    try fixture.addV1(db, id: "newer", updated: 1_793_560_900_000, data: newer)
    let store = try fixture.store()
    #expect(try await store.ingestOpenCode(database: fixture.database) { database, seen in
        let reading = OpenCodeHistory.read(database: database, after: seen)
        try? fixture.addV1(db, id: "older", updated: 1_793_000_000_000, data: older)
        return reading
    } == 1)
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1, "still reads from before the older row")
    #expect(try await totals(store).tokens.input == 2000)
}

@Test func failedOpenCodeWriteIsRetried() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    try fixture.addV1(try fixture.open(), id: "msg_a")
    let store = try fixture.store()
    let tinybar = try SQLiteDB(path: fixture.storePath.path)
    try tinybar.exec("CREATE TRIGGER fail_write BEFORE INSERT ON opencode_message BEGIN SELECT RAISE(ABORT, 'injected'); END;")
    await #expect(throws: (any Error).self) { try await store.ingestOpenCode(database: fixture.database) }
    try tinybar.exec("DROP TRIGGER fail_write")
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1, "the unchanged database is read again")
}

@Test func impossibleOpenCodeTokenCountsAreSkipped() async throws {
    // Adding these would trap, which Swift can't recover from: the whole app would go down.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "huge", data: v1Row.replacingOccurrences(of: #""output":300"#, with: #""output":9223372036854775807"#))
    try fixture.addV1(db, id: "fine", data: v1Row.replacingOccurrences(of: "1793560018784", with: "1793560900000"))
    let store = try fixture.store()
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
    #expect(try await totals(store).tokens == oneResponse)
}

@Test func openCodeRowFromTheFutureDoesNotHideLaterOnes() async throws {
    // A wrong clock or corruption, on any provider's row.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "future", updated: .max, data: v1Row.replacingOccurrences(of: "\"opencode-go\"", with: "\"openai\""))
    let store = try fixture.store()
    try await store.ingestOpenCode(database: fixture.database)
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try fixture.addV1(db, id: "fine", updated: now, data: v1Row)
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)

    // A store whose cursor is already past now, as after the clock was set back.
    let tinybar = try SQLiteDB(path: fixture.storePath.path)
    try tinybar.run("UPDATE meta SET value = '9223372036854775807' WHERE key = 'opencode_cursor'")
    let reopened = try fixture.store()
    try fixture.addV1(db, id: "later", updated: now, data: v1Row.replacingOccurrences(of: "1793560018784", with: "1793560900000"))
    #expect(try await reopened.ingestOpenCode(database: fixture.database) == 1)
}

@Test func upgradedStoreImportsOpenCodeOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    try fixture.addV1(try fixture.open(), id: "msg_a")
    #expect(try await fixture.store().hasCompletedOpenCodeImport(), "a new store's first import covers it")

    try SQLiteDB(path: fixture.storePath.path).exec("DELETE FROM meta WHERE key = 'opencode_import'")
    let upgraded = try fixture.store()
    #expect(try await !upgraded.hasCompletedOpenCodeImport())
    try await upgraded.importOpenCode(database: fixture.database)
    #expect(try await upgraded.hasCompletedOpenCodeImport())
    #expect(try await totals(upgraded).tokens == oneResponse)
}

@Test func openCodeImportIsOnlyDoneAfterAWholeRead() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try fixture.store()
    let tinybar = try SQLiteDB(path: fixture.storePath.path)
    func notDoneYet() throws { try tinybar.exec("DELETE FROM meta WHERE key = 'opencode_import'") }

    // There's nothing to read without OpenCode.
    try notDoneYet()
    try await store.importOpenCode(database: fixture.database)
    #expect(try await store.hasCompletedOpenCodeImport())

    // A database in a shape it can't read stays to do, and doesn't count as read.
    try notDoneYet()
    try fixture.setUp("CREATE TABLE message (id TEXT PRIMARY KEY, payload TEXT);")
    await #expect(throws: ProviderError.self) { try await store.importOpenCode(database: fixture.database) }
    #expect(try await !store.hasCompletedOpenCodeImport())

    let db = try fixture.open()
    try db.exec("DROP TABLE message;" + Fixture.v1Tables)
    try fixture.addV1(db, id: "msg_a")
    try await store.importOpenCode(database: fixture.database)
    #expect(try await store.hasCompletedOpenCodeImport())
    #expect(try await totals(store).tokens == oneResponse)
}

@Test func replacedOpenCodeDatabaseIsReadFromTheStart() async throws {
    // A restored backup: its rows are far behind the cursor. Those already counted stay once.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "msg_a")
    let later = v1Row.replacingOccurrences(of: "1793560018784", with: "1793560900000")
    try fixture.addV1(db, id: "msg_b", updated: 1_793_560_900_000, data: later)
    let store = try fixture.store()
    #expect(try await store.ingestOpenCode(database: fixture.database) == 2)

    let restored = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: restored) }
    let copy = try SQLiteDB(path: restored.path)
    try copy.exec(Fixture.v1Tables + "PRAGMA journal_mode = DELETE;")
    try copy.run("INSERT INTO message VALUES ('msg_a', 'ses', 1793560018784, 1793560021851, ?)", [.text(v1Row)])
    let unseen = v1Row.replacingOccurrences(of: "1793560018784", with: "1793000000000")
    try copy.run("INSERT INTO message VALUES ('msg_c', 'ses', 1793000000000, 1793000000000, ?)", [.text(unseen)])
    #expect(try await store.ingestOpenCode(database: restored) == 1)
    #expect(try await totals(store).tokens.input == 3000)
}

@Test func openCodeDatabaseThatWentBackIsReadFromTheStart() async throws {
    // A backup restored over the same file keeps its inode.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    let later = v1Row.replacingOccurrences(of: "1793560018784", with: "1793560900000")
    try fixture.addV1(db, id: "latest", updated: 1_793_560_900_000, data: later)
    let store = try fixture.store()
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
    try db.exec("DELETE FROM message")
    let older = v1Row.replacingOccurrences(of: "1793560018784", with: "1793000000000")
    try fixture.addV1(db, id: "unseen", updated: 1_793_000_000_000, data: older)
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
}

@Test func openCodeHistorySurvivesDeletedSessions() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "msg_a")
    let store = try fixture.store()
    try await store.ingestOpenCode(database: fixture.database)
    try db.exec("DELETE FROM message")
    try await store.ingestOpenCode(database: fixture.database)
    #expect(try await totals(store).tokens == oneResponse)
}

@Test func readsOpenCodeRowsStillInTheWAL() async throws {
    // The live state: OpenCode holds the database open, with recent rows only in its WAL.
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let writer = try fixture.open()
    try writer.exec("PRAGMA wal_autocheckpoint = 0; PRAGMA wal_checkpoint(TRUNCATE);")
    try fixture.addV1(writer, id: "msg_a")
    let before = try FileManager.default.contentsOfDirectory(atPath: fixture.dir.path).sorted()
    let bytes = try Data(contentsOf: fixture.database)
    #expect(before.contains("opencode.db-wal"))

    let store = try UsageStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("tinybar-\(UUID().uuidString).sqlite"))
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.dir.path).sorted() == before)
    #expect(try Data(contentsOf: fixture.database) == bytes, "OpenCode's database is only read")
    #expect(try await totals(store).tokens == oneResponse)
}

@Test func openCodeDatabaseThatChangedShapeAddsNothingAndRetries() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try fixture.store()
    // No database at all.
    #expect(try await store.ingestOpenCode(database: fixture.database) == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.database.path))
    try await store.ingestOpenCode(database: nil)
    // A future schema: nothing counted, no cursor moved, and it doesn't throw out of `ingestAll`.
    try fixture.setUp("CREATE TABLE message (id TEXT PRIMARY KEY, payload TEXT);")
    #expect(try await store.ingestOpenCode(database: fixture.database) == 0)

    let db = try fixture.open()
    try db.exec("DROP TABLE message;" + Fixture.v1Tables)
    try fixture.addV1(db, id: "msg_a")
    #expect(try await store.ingestOpenCode(database: fixture.database) == 1)
}

@Test func openCodeLongRequestsGetLongContextPrices() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    let db = try fixture.open()
    try fixture.addV1(db, id: "long", data: v1Row.replacingOccurrences(of: #""input":1000"#, with: #""input":300000"#))
    let store = try fixture.store()
    try await store.ingestOpenCode(database: fixture.database)
    let rows = try await store.daily(since: "0000", provider: .opencode)
    #expect(rows[0].long[272_000]?.input == 300_000)
}

// MARK: Status page

private func openCodeStatus(go: String, reason: String = "none", free: String = "operational", stale: String = "false") throws -> [Incident] {
    // Trimmed from the live https://status.opencode.ai/api/status, whose every other field is unused.
    let page = #"""
    {"updatedAt":1793561186343,"since":1792028534694,"stale":\#(stale),"status":"operational","components":[
     {"service":"console","status":"operational","reason":"none","since":1793490025265,"models":[],"breakdown":[],"speed":{}},
     {"service":"inference","status":"operational","reason":"none","since":1793490025265,"models":[],"breakdown":[],"speed":{}},
     {"service":"go","status":"\#(go)","reason":"\#(reason)","since":1793538505265,"models":[],"breakdown":[{"id":"gpt-6-luna","status":"operational","reason":"none","speed":{"ttft":3275,"tps":195}}],"speed":{}},
     {"service":"free","status":"\#(free)","reason":"upstream","since":1793545225299,"models":[],"breakdown":[],"speed":{}}],
     "incidents":[{"id":"inference-1792769057267","event":"inference-1792769057267","service":"inference","startedAt":1792769057267,"resolvedAt":1792770017267,"status":"degraded","reason":"availability","models":[]}],"notes":[],"history":[]}
    """#
    return try StatusFeed.openCode(Data(page.utf8), base: URL(string: "https://status.opencode.ai")!)
}

@Test func readsOpenCodesStatusPage() throws {
    #expect(try openCodeStatus(go: "operational").isEmpty)
    #expect(try openCodeStatus(go: "operational", free: "degraded").isEmpty, "free models say nothing about Go")

    let slow = try #require(try openCodeStatus(go: "degraded", reason: "latency").first)
    #expect(slow.provider == .opencode && slow.severity == .degraded)
    #expect(slow.title == "OpenCode Go is responding slowly")
    #expect(slow.page == "status.opencode.ai" && slow.url.absoluteString == "https://status.opencode.ai")
    #expect(slow.updatedAt == Date(timeIntervalSince1970: 1_793_538_505.265))

    #expect(try openCodeStatus(go: "degraded", reason: "errors").first?.title == "OpenCode Go has elevated errors")
    #expect(try openCodeStatus(go: "degraded", reason: "new").first?.title == "OpenCode Go is degraded")
    #expect(try openCodeStatus(go: "outage", reason: "availability").first?.severity == .majorOutage)
    #expect(try openCodeStatus(go: "outage", reason: "availability").first?.title == "OpenCode Go is down")
}

@Test func openCodeStatusThatCantBeTrustedKeepsTheLastAnswer() {
    #expect(throws: ProviderError.self) { try openCodeStatus(go: "operational", stale: "true") }
    #expect(throws: ProviderError.self) { try openCodeStatus(go: "on fire") }
    #expect(throws: ProviderError.self) { try StatusFeed.openCode(Data(#"{"components":[]}"#.utf8), base: URL(string: "https://x.invalid")!) }
    #expect(throws: (any Error).self) { try StatusFeed.openCode(Data("<html>".utf8), base: URL(string: "https://x.invalid")!) }
}

// MARK: Prices and the rest of the app

/// OpenCode's recorded cost (0.002948) comes from the same models.dev prices. Matching it shows
/// the tokens are the ones it billed, with reasoning as output.
@Test func theoreticalCostMatchesWhatOpenCodeRecorded() throws {
    let models = #"""
    {"opencode-go":{"models":{"glm-5.2":{"id":"glm-5.2","cost":{"input":1.4,"output":4.4,"cache_read":0.26}}}}}
    """#
    let table = try PriceTable.parse(Data(models.utf8), fetchedAt: nil)
    let cost = try #require(table.cost(provider: .opencode, model: "glm-5.2", tokens: oneResponse))
    #expect(abs(cost - 0.002948) < 1e-9)
}

@Test func statsLeavesOutProvidersWithoutActivity() {
    let day = DayKey.string(for: Date())
    func row(_ provider: ProviderID, _ tokens: Int64) -> DailyUsage {
        DailyUsage(day: day, provider: provider, model: "m", project: "", tokens: TokenCounts(input: tokens))
    }
    let summary = StatsSummary.build(
        usage: [row(.claude, 10), row(.opencode, 1000)], stats: [], allDays: [day], range: .week, prices: .empty)
    #expect(summary.tokens == 10)
    #expect(summary.tokensByProvider[.opencode] == nil)
    #expect(summary.activityCoverage[.opencode] == nil)
}

@Test func statsDaysLeaveOutProvidersWithoutActivity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setUp(Fixture.v1Tables)
    try fixture.addV1(try fixture.open(), id: "msg_a")
    let store = try fixture.store()
    try await store.ingestOpenCode(database: fixture.database)
    #expect(try await totals(store).count == 1)
    #expect(try await store.activeDays().isEmpty)
    #expect(try await store.activeDays(model: "glm-5.2").isEmpty)
}

@Test func openCodeSubscriptionIsAProvider() {
    #expect(ProviderID.allCases.last == .opencode, "new Providers go last, keeping tab shortcuts")
    #expect(StatusFeed.hasFeed(.opencode) && !ProviderID.opencode.hasBrowserFallback && !ProviderID.opencode.hasActivity)
    #expect(ProviderID.opencode.loginHint == "run `opencode auth login`")
}

@Test func addingOpenCodeTableLeavesOtherHistoryAlone() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.store()
    let db = try SQLiteDB(path: fixture.storePath.path)
    // A store from 0.7.0, whose long-context rows must not be rebuilt from `claude_message`.
    try db.exec("""
    DROP TABLE opencode_message;
    PRAGMA user_version = 7;
    INSERT INTO claude_message VALUES ('m', '2026-09-25', 'claude', 'test', '', 300000, 1, 0, 0, '{}');
    INSERT INTO daily_long_context VALUES ('2026-09-25', 'codex', 'kept', '', 272000, 5, 5, 5, 5);
    """)
    _ = try fixture.store()
    #expect(try db.run("PRAGMA user_version").first?.first?.int == 8)
    #expect(try db.run("SELECT count(*) FROM opencode_message").first?.first?.int == 0)
    #expect(try db.run("SELECT model FROM daily_long_context").map { $0[0].text } == ["kept"])
}
