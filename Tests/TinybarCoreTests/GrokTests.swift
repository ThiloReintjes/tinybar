import Foundation
@testable import TinybarCore
import Testing

// Fixtures are real shapes, not guesses. `liveOne` and `liveShares` are what users of CodexBar captured
// from live accounts (its GrokCreditsProxyFetcherTests), and the 401 is what the live endpoint answered
// an invalid token on 2026-11-02. `Scripts/verify-grok.py` runs the real CLI over the same shapes.

private let liveOne = #"""
{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-20T18:42:45.537749+00:00",
 "end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":1.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},
 "productUsage":[{"product":"GrokBuild","usagePercent":1.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},
 "topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-09-20T18:42:45.537749+00:00",
 "billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}
"""#

private let liveShares = #"""
{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-20T18:42:45.537749+00:00",
 "end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":6.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},
 "productUsage":[{"product":"GrokChat","usagePercent":4.0},{"product":"GrokBuild","usagePercent":2.0}],
 "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
 "billingPeriodStart":"2026-09-20T18:42:45.537749+00:00","billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}
"""#

private let weekly = #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-01T00:00:00Z","end":"2026-11-08T00:00:00Z"}"#
private let monthly = #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"}"#

/// Inside the live reports' week and before the other fixtures' periods, so none of them expire.
private let fixtureNow = Date(timeIntervalSince1970: 1_790_298_000)  // 2026-09-25T01:00:00Z

private func read(_ json: String, plan: String? = nil, now: Date = fixtureNow) throws -> ProviderSnapshot {
    try GrokUsageAPI.snapshot(from: JSONDecoder().decode(GrokUsageAPI.Report.self, from: Data(json.utf8)), plan: plan, now: now)
}

private func date(_ raw: String) throws -> Date {
    try #require(parseISODate(raw))
}

// MARK: Limits

@Test func liveReportBecomesOneWeeklyWindow() throws {
    let s = try read(liveOne, plan: "SuperGrok")
    #expect(s.provider == .grok && s.plan == "SuperGrok" && s.source == .cli)
    let w = try #require(s.windows.first)
    #expect(s.windows.count == 1)
    #expect(w.id == "weekly" && w.title == "Weekly" && w.kind == .weekly)
    #expect(w.usedPercent == 1 && w.remainingPercent == 99)
    #expect(w.durationSeconds == 7 * 86400)
    #expect(w.resetsAt == (try date("2026-09-27T18:42:45.537749+00:00")))
    #expect(s.extraUsage == nil && s.credits == nil, "a zero pair and an empty wallet are nothing to show")
}

/// Everything Grok does draws on one pool, so the shares aren't limits of their own.
@Test func productSharesAreNotWindows() throws {
    let s = try read(liveShares)
    #expect(s.windows.map(\.usedPercent) == [6])
}

/// The microseconds and `+00:00` are what the live endpoint sends.
@Test func readsTheLiveTimestamps() throws {
    let at = try date("2026-09-27T18:42:45.537749+00:00")
    #expect(abs(at.timeIntervalSince(try date("2026-09-27T18:42:45Z")) - 0.537749) < 0.01)
    #expect(parseISODate("2026-11-05T13:42:40.123456789Z") != nil, "as chrono writes `expires_at`")
}

@Test func aLeftOutPercentIsZeroWithinAWholePeriod() throws {
    #expect(try read(#"{"config":{\#(weekly)}}"#).windows.map(\.usedPercent) == [0])
    #expect(try read(#"{"config":{\#(monthly)}}"#).windows.map(\.id) == ["monthly"])
    let backwards = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-08T00:00:00Z","end":"2026-11-01T00:00:00Z"}}}"#
    let open = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-08T00:00:00Z"}}}"#
    let unknownType = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_DAILY","start":"2026-11-01T00:00:00Z","end":"2026-11-02T00:00:00Z"}}}"#
    // As the CLI's own test has it: use is in `used`, so the missing percent isn't a zero.
    let legacy = #"{"config":{"monthlyLimit":{"val":2000},"used":{"val":1234},"billingPeriodStart":"2026-11-01T00:00:00Z","billingPeriodEnd":"2026-12-01T00:00:00Z"}}"#
    let unknownWeek = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_NEW","start":"2026-11-01T00:00:00Z","end":"2026-11-08T00:00:00Z"}}}"#
    for json in [backwards, open, unknownType, unknownWeek, legacy, #"{"config":{}}"#] {
        #expect(throws: GrokUsageAPI.noLimit) { try read(json) }
    }
}

@Test func noConfigIsNoLimit() {
    for json in ["{}", #"{"config":null}"#] {
        #expect(throws: GrokUsageAPI.noLimit) { try read(json) }
    }
}

@Test func anUnreadablePercentNeverReadsAsZero() {
    for bad in [#""12""#, "null", "true"] {
        #expect(throws: (any Error).self) { try read(#"{"config":{"creditUsagePercent":\#(bad),\#(weekly)}}"#) }
    }
}

@Test func monthlyPeriods() throws {
    let w = try #require(try read(#"{"config":{"creditUsagePercent":42.5,\#(monthly)}}"#).windows.first)
    #expect(w.id == "monthly" && w.title == "Monthly" && w.usedPercent == 42.5)
    #expect(w.durationSeconds == 30 * 86400)
    // With the start lost, the calendar month ending there.
    let open = #"{"config":{"creditUsagePercent":1,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-12-01T00:00:00Z"}}}"#
    #expect(try read(open).windows.first?.durationSeconds == 30 * 86400)
}

/// Older accounts send only the deprecated bounds, which the CLI says to fall back to.
@Test func fallsBackToTheBillingPeriod() throws {
    let week = #"{"config":{"creditUsagePercent":5,"billingPeriodStart":"2026-11-01T00:00:00Z","billingPeriodEnd":"2026-11-08T00:00:00Z"}}"#
    #expect(try read(week).windows.first?.id == "weekly")
    let month = #"{"config":{"creditUsagePercent":5,"billingPeriodStart":"2026-11-01T00:00:00Z","billingPeriodEnd":"2026-12-01T00:00:00Z"}}"#
    #expect(try read(month).windows.first?.id == "monthly")
    let invalid = #"{"config":{"creditUsagePercent":5,"currentPeriod":{"start":"2026-01-01T00:00:00Z","end":"never"},"billingPeriodStart":"2026-11-01T00:00:00Z","billingPeriodEnd":"2026-11-08T00:00:00Z"}}"#
    let w = try #require(try read(invalid).windows.first)
    let reset = try date("2026-11-08T00:00:00Z")
    #expect(w.durationSeconds == 7 * 86400 && w.resetsAt == reset, "bounds aren't mixed")
    let wrongType = #"{"config":{"creditUsagePercent":5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"never"},"billingPeriodStart":"2026-11-01T00:00:00Z","billingPeriodEnd":"2026-12-01T00:00:00Z"}}"#
    let billed = try #require(try read(wrongType).windows.first)
    #expect(billed.id == "monthly" && billed.durationSeconds == 30 * 86400, "a rejected period's type goes with it")
}

@Test func anyOtherPeriodIsStillABar() throws {
    let w = try #require(try read(#"{"config":{"creditUsagePercent":5,"currentPeriod":{"start":"2026-11-01T00:00:00Z","end":"2026-11-03T00:00:00Z"}}}"#).windows.first)
    #expect(w.id == "credits" && w.title == "Credits" && w.durationSeconds == 2 * 86400)
    let bare = try #require(try read(#"{"config":{"creditUsagePercent":5}}"#).windows.first)
    #expect(bare.id == "credits" && bare.resetsAt == nil && bare.durationSeconds == nil)
}

/// A single Account skips the Pool's rule for a passed Reset, so this can't read as a fresh number.
@Test func anEndedPeriodIsNoReading() throws {
    let ended = try date("2026-09-27T18:42:45.537749+00:00")
    #expect(throws: GrokUsageAPI.periodEnded) { try read(liveOne, now: ended) }
    #expect(throws: GrokUsageAPI.periodEnded) { try read(liveOne, now: ended.addingTimeInterval(86400)) }
    #expect(throws: GrokUsageAPI.periodEnded) { try read(#"{"config":{\#(weekly)}}"#, now: try date("2026-11-09T00:00:00Z")) }
    #expect(try read(liveOne, now: ended.addingTimeInterval(-60)).windows.count == 1)
    #expect(try read(#"{"config":{"creditUsagePercent":5}}"#, now: ended).windows.count == 1, "no end, nothing to have passed")
}

@Test func percentsStayInRange() throws {
    #expect(try read(#"{"config":{"creditUsagePercent":104.2,\#(weekly)}}"#).windows.first?.usedPercent == 100)
    #expect(try read(#"{"config":{"creditUsagePercent":-3.5,\#(weekly)}}"#).windows.first?.usedPercent == 0)
}

@Test func onDemandSpendIsInCents() throws {
    let spend = try read(#"{"config":{"creditUsagePercent":1,\#(weekly),"onDemandCap":{"val":5000},"onDemandUsed":{"val":300}}}"#).extraUsage
    #expect(spend == ExtraUsageSpend(used: 3, limit: 50, currency: "USD"))
    let noCap = try read(#"{"config":{"creditUsagePercent":1,\#(weekly),"onDemandCap":{},"onDemandUsed":{"val":125}}}"#).extraUsage
    #expect(noCap == ExtraUsageSpend(used: 1.25, limit: nil, currency: "USD"), "proto3 sends zero as {}")
    let unused = try read(#"{"config":{"creditUsagePercent":1,\#(weekly),"onDemandCap":{"val":500},"onDemandUsed":{}}}"#).extraUsage
    #expect(unused == ExtraUsageSpend(used: 0, limit: 5, currency: "USD"))
    let odd = try read(#"{"config":{"creditUsagePercent":9,\#(weekly),"onDemandCap":"wrong","onDemandUsed":{"val":"x"}}}"#)
    #expect(odd.extraUsage == nil && odd.windows.first?.usedPercent == 9, "money changing shape doesn't lose the bar")
    let oneOdd = try read(#"{"config":{"creditUsagePercent":9,\#(weekly),"onDemandCap":{"val":5000},"onDemandUsed":{"val":"300"}}}"#)
    #expect(oneOdd.extraUsage == nil, "an unreadable amount isn't a zero")
    let absent = try read(#"{"config":{"creditUsagePercent":9,\#(weekly),"onDemandCap":{"val":5000}}}"#).extraUsage
    #expect(absent == ExtraUsageSpend(used: 0, limit: 50, currency: "USD"), "proto3 leaves a zero out entirely too")
}

// MARK: The login

// Spelled out, as the CLI's installer has them: a typo in the code must not pass.
private let scope = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
private let legacyScope = "https://accounts.x.ai/sign-in"

private struct Files {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString)")
    var home: URL { dir.appendingPathComponent("home", isDirectory: true) }
    var system: URL { dir.appendingPathComponent("etc", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    }

    func write(_ text: String, _ name: String = "auth.json", in folder: URL? = nil) throws {
        try text.write(to: (folder ?? home).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func logins(env: [String: String] = [:]) -> GrokLogins {
        GrokLogins(home: home, system: system, env: env)
    }

    func auth(_ entries: [String: [String: Any]]) throws {
        try write(String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self))
    }
}

/// What the CLI keeps, down to the fields Tinybar has no use for.
private func entry(_ token: String = "tok", mode: String = "oidc", extra: [String: Any] = [:]) -> [String: Any] {
    ["key": token, "auth_mode": mode, "create_time": "2026-11-02T12:42:40Z", "user_id": "u1", "email": "me@example.com",
     "refresh_token": "never-sent", "oidc_issuer": "https://auth.x.ai", "team_id": "personal"].merging(extra) { $1 }
}

@Test func readsTheCLIsLogin() throws {
    let f = try Files()
    try f.auth([scope: entry(extra: ["expires_at": "2026-11-05T13:42:40Z"])])
    let login = try #require(f.logins().find())
    #expect(login.token == "tok" && login.email == "me@example.com")
    #expect(login.expiresAt == (try date("2026-11-05T13:42:40Z")))
    #expect(login.team == nil, "every account has a team_id, its own personal one included")
    #expect(GrokProvider(logins: f.logins()).isConfigured())
    let identity = try #require(GrokProvider(logins: f.logins()).identity())
    #expect(identity.email == "me@example.com" && identity.organization == nil)
}

@Test func thereIsNoLoginWithoutTheFile() throws {
    let f = try Files()
    #expect(f.logins().find() == nil)
    #expect(!GrokProvider(logins: f.logins()).isConfigured())
    try f.write("not json")
    #expect(f.logins().find() == nil)
    try f.write("[]")
    #expect(f.logins().find() == nil)
}

@Test func theCurrentLoginComesBeforeTheOldOne() throws {
    let f = try Files()
    try f.auth([legacyScope: entry("old"), scope: entry("new")])
    #expect(f.logins().find()?.token == "new")
    try f.auth([legacyScope: entry("old")])
    #expect(f.logins().find()?.token == "old")
    try f.auth([legacyScope: entry("old"), scope: ["auth_mode": "oidc"]])
    #expect(f.logins().find()?.token == "old", "a partial entry doesn't hide a usable one")
    try f.auth([legacyScope: entry("old"), scope: entry("new", mode: "web_login")])
    #expect(f.logins().find() == nil, "as the CLI: a login it refuses isn't a reason to try the older one")
}

/// Another deployment's entry can sit in the same file, and may not be a grok.com login at all.
@Test func neverPicksAnArbitraryAccount() throws {
    let f = try Files()
    try f.auth(["https://idp.example.com::client": entry("theirs"), "xai::api_key": entry("key", mode: "api_key")])
    #expect(f.logins().find() == nil)
}

@Test func skipsLoginsThatCantReadLimits() throws {
    let f = try Files()
    // An API key bills elsewhere. The CLI ignores old web logins, under either name.
    for mode in ["api_key", "web_login", "grok"] {
        try f.auth([scope: entry(mode: mode)])
        #expect(f.logins().find() == nil, "\(mode)")
    }
    try f.auth([scope: entry("   ")])
    #expect(f.logins().find() == nil)
}

@Test func leavesCustomDeploymentsToTheCLI() throws {
    let f = try Files()
    try f.auth([scope: entry()])
    for name in ["GROK_OIDC_ISSUER", "GROK_AUTH_PROVIDER_COMMAND", "GROK_MODELS_BASE_URL", "GROK_CONFIG", "GROK_AUTH", "GROK_AUTH_PATH"] {
        #expect(f.logins(env: [name: "x"]).find() == nil, "\(name)")
        #expect(f.logins(env: [name: "  "]).find() != nil, "\(name) blank")
    }
    for section in ["[grok_com_config.oidc]\nissuer = \"x\"", "[[endpoints]]", "[auth]", "auth.provider = \"x\"", "  grok_com_config = {}"] {
        for (file, folder) in [("config.toml", f.home), ("requirements.toml", f.home), ("managed_config.toml", f.system), ("requirements.toml", f.system)] {
            try f.write(section, file, in: folder)
            #expect(f.logins().find() == nil, "\(section) in \(file)")
            try FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
    // What the CLI writes itself, and what its installer adds.
    try f.write("[marketplace]\ndefault_skills_installs_purged = true\n\n[cli]\ninstaller = \"internal\"\n# [auth] isn't set\nauthor = \"me\"\n", "config.toml")
    #expect(f.logins().find() != nil)
}

@Test func aLoginGoesOnlyToGrokOrThisMac() throws {
    let f = try Files()
    try f.auth([scope: entry()])
    #expect(f.logins().apiBase == URL(string: "https://cli-chat-proxy.grok.com/v1"))
    let base = "GROK_CLI_CHAT_PROXY_BASE_URL"
    #expect(f.logins(env: [base: "http://127.0.0.1:8123/v1"]).apiBase == URL(string: "http://127.0.0.1:8123/v1"))
    #expect(f.logins(env: [base: "http://127.0.0.1:8123/v1"]).find() != nil)
    for elsewhere in ["https://evil.example.com/v1", "http://cli-chat-proxy.grok.com/v1", "https://127.0.0.1.evil.example.com", "nonsense"] {
        #expect(f.logins(env: [base: elsewhere]).apiBase == nil, "\(elsewhere)")
        #expect(f.logins(env: [base: elsewhere]).find() == nil, "\(elsewhere)")
    }
}

@Test func namesATeam() throws {
    let f = try Files()
    try f.auth([scope: entry(extra: ["principal_type": "Team", "team_id": "t1", "team_name": "Acme"])])
    let identity = try #require(GrokProvider(logins: f.logins()).identity())
    #expect(identity.organization == "t1" && identity.organizationName == "Acme")
    try f.auth([scope: entry(extra: ["principal_type": "User", "team_id": "t1", "team_name": "Acme"])])
    #expect(f.logins().find()?.team == nil)
}

// MARK: The request

private final class XAIServer: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func seen() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// The token picks the answer. A request that isn't what the CLI's own carries is a 400.
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = String(auth.dropFirst(7))
        let isBilling = url.path == "/v1/billing" && url.query == "format=credits"
        let isSettings = url.path == "/v1/settings" && url.query == nil
        let valid = request.httpMethod == "GET" && (isBilling || isSettings) && auth.hasPrefix("Bearer ")
            && request.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli"
            && request.value(forHTTPHeaderField: "User-Agent") == "Tinybar"
            && request.value(forHTTPHeaderField: "Cookie") == nil
        var status = 200
        var headers: [String: String] = [:]
        var body = isSettings ? #"{"subscription_tier_display":"SuperGrok Heavy","models":[{"a":1}]}"# : liveOne.replacingOccurrences(of: "2026-09", with: "2999-09")
        switch token {
        case _ where !valid: status = 400; body = ""
        case "bad": status = 401; body = #"{"error":"Invalid or expired credentials (auth_kind=bearer, x_xai_token_auth=xai-grok-cli, upstream=Unauthenticated, reason=no auth context)"}"#
        case "denied": status = 403; body = #"{"error":"Forbidden"}"#
        case "refused": status = 400; body = #"{"error":"Bad request"}"#
        case "missing": status = 404; body = #"{"error":"Not found"}"#
        case "busy": status = 429; headers["Retry-After"] = "120"; body = ""
        case "down": status = 500; body = "oops"
        case "html": if isBilling { body = "<html></html>" }
        case "garbled": if isBilling { body = #"{"config":"#  }
        case "noplan": if isSettings { status = 500; body = "oops" }
        case "blankplan": if isSettings { body = #"{"subscription_tier_display":"  "}"# }
        case "weirdplan": if isSettings { body = #"{"subscription_tier_display":5}"# }
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func fetch(_ token: String, _ extra: [String: Any] = [:]) async throws -> ProviderSnapshot {
    let f = try Files()
    try f.auth([scope: entry(token, extra: extra)])
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [XAIServer.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    return try await GrokProvider(logins: f.logins(), session: session).fetch()
}

/// The serialized suite keeps `XAIServer.seen()` to one test at a time.
@Suite(.serialized)
struct GrokRequestTests {
    @Test func fetchesLikeTheCLI() async throws {
        let s = try await fetch("good-token")
        #expect(s.plan == "SuperGrok Heavy" && s.windows.map(\.usedPercent) == [1])
        let hosts = Set(XAIServer.seen().compactMap(\.url?.host))
        #expect(hosts == ["cli-chat-proxy.grok.com"])
        #expect(XAIServer.seen().contains { $0.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits" })
        #expect(XAIServer.seen().contains { $0.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/settings" })
        #expect(XAIServer.seen().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer good-token" })
    }

    @Test func thePlanIsOptional() async throws {
        for token in ["noplan", "blankplan", "weirdplan"] {
            let s = try await fetch(token)
            #expect(s.plan == nil && s.windows.count == 1, "\(token)")
        }
    }

    @Test func mapsFailures() async throws {
        await #expect(throws: ProviderError.loginExpired) { try await fetch("bad") }
        await #expect(throws: ProviderError.loginExpired) { try await fetch("denied") }
        await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) { try await fetch("busy") }
        await #expect(throws: ProviderError.unexpected("Grok API returned HTTP 500")) { try await fetch("down") }
        await #expect(throws: ProviderError.unexpected("Unexpected Grok usage response")) { try await fetch("html") }
        await #expect(throws: ProviderError.unexpected("Unexpected Grok usage response")) { try await fetch("garbled") }
    }

    @Test func aTeamIsToldApartFromADeadLogin() async throws {
        let team: [String: Any] = ["principal_type": "Team", "team_id": "t1"]
        for token in ["denied", "refused", "missing"] {
            await #expect(throws: GrokUsageAPI.noTeamUsage) { try await fetch(token, team) }
        }
        await #expect(throws: ProviderError.loginExpired) { try await fetch("bad", team) }
        #expect(try await fetch("good", team).windows.count == 1, "if xAI starts to answer, that shows")
    }

    /// Only the CLI renews it, so there's nothing to gain by asking.
    @Test func sendsNothingWithAnExpiredLogin() async throws {
        let before = XAIServer.seen().count
        await #expect(throws: ProviderError.loginExpired) { try await fetch("old", ["expires_at": "2020-01-01T00:00:00Z"]) }
        #expect(XAIServer.seen().count == before)
        #expect(try await fetch("fresh", ["expires_at": "2999-01-01T00:00:00Z"]).windows.count == 1)
        #expect(try await fetch("odd-date", ["expires_at": "soon"]).windows.count == 1, "the server decides what a bad date can't")
    }

    @Test func aTokenThatCantBeAHeaderIsntSent() async throws {
        let before = XAIServer.seen().count
        await #expect(throws: ProviderError.loginExpired) { try await fetch("two words") }
        #expect(XAIServer.seen().count == before)
    }
}

// MARK: Status page

private let statusBase = URL(string: "https://status.x.ai")!

private func statusPage(grokCom: String = "available", imagine: String = "available") -> Data {
    Data(#"""
    {"updated_at":"2026-11-02T13:42:02.855Z","overall":{"status":"available"},"products":[
     {"id":"grok","name":"Grok","status":"available","components":[
       {"id":"grok-com","name":"grok.com","status":"\#(grokCom)"},
       {"id":"ios-app","name":"Grok (iOS)","status":"available"},
       {"id":"imagine","name":"Imagine","status":"\#(imagine)"}]},
     {"id":"api","name":"API","status":"available","components":[{"id":"api-global","name":"Global (api.x.ai)","status":"available"}]}]}
    """#.utf8)
}

@Test func grokIsAProvider() {
    #expect(ProviderID.allCases.last == .grok, "new Providers go last, keeping tab shortcuts")
    #expect(StatusFeed.hasFeed(.grok) && !ProviderID.grok.hasBrowserFallback && !ProviderID.grok.hasActivity)
    #expect(ProviderID.grok.loginHint == "run `grok` once to refresh, or `grok login`")
    #expect(ProviderID.grok.displayName == "Grok" && ProviderID.grok.cliCommand == "grok")
    #expect(Paths.grokHome(env: ["GROK_HOME": "/tmp/g"]).path == "/tmp/g")
    #expect(Paths.grokHome(env: [:]).lastPathComponent == ".grok")
}

@Test func onlyGrokComCounts() throws {
    #expect(try StatusFeed.xAI(statusPage(), base: statusBase).isEmpty)
    #expect(try StatusFeed.xAI(statusPage(imagine: "major_outage"), base: statusBase).isEmpty, "image generation isn't coding")
    let incident = try #require(try StatusFeed.xAI(statusPage(grokCom: "degraded"), base: statusBase).first)
    #expect(incident.severity == .degraded && incident.provider == .grok && incident.components == ["grok.com"])
    #expect(incident.title == "grok.com: degraded" && incident.page == "status.x.ai")
    #expect(incident.updatedAt != nil)
}

@Test func readsTheWordsOtherPagesUse() throws {
    let expected: [(String, Incident.Severity)] = [
        ("degraded_performance", .degraded), ("partial_outage", .partialOutage), ("major_outage", .majorOutage),
        ("outage", .majorOutage), ("unavailable", .majorOutage), ("under_maintenance", .maintenance),
    ]
    for (word, severity) in expected {
        #expect(try StatusFeed.xAI(statusPage(grokCom: word), base: statusBase).first?.severity == severity, "\(word)")
    }
    #expect(try StatusFeed.xAI(statusPage(grokCom: "operational"), base: statusBase).isEmpty)
}

/// A page that can't be read keeps its last answer, so a word nobody knows isn't an all-clear.
@Test func anUnknownPageIsNoAnswer() {
    #expect(throws: (any Error).self) { try StatusFeed.xAI(statusPage(grokCom: "wobbly"), base: statusBase) }
    #expect(throws: (any Error).self) { try StatusFeed.xAI(Data(#"{"products":[]}"#.utf8), base: statusBase) }
    #expect(throws: (any Error).self) { try StatusFeed.xAI(Data("<html>".utf8), base: statusBase) }
}
