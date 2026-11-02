import Foundation
@testable import TinybarCore
import Testing

// Fixtures are real shapes, not guesses. `liveEnded` is what api.github.com answered this repo's
// owner on 2026-11-02. The others are what users of CodexBar posted from live accounts (#2593, #1258,
// #690), or follow the Copilot SDK's types and VS Code's `parseQuotas`, whose real client
// `Scripts/verify-copilot.py` runs against the same responses.

private let liveEnded = #"""
{"id":1,"login":"someone","access_type_sku":"subscription_ended","assigned_date":null,"can_signup_for_limited":true,
 "chat_enabled":false,"cli_enabled":false,"copilot_plan":"individual","organization_list":[],
 "endpoints":{"api":"https://api.individual.githubcopilot.com"},"can_upgrade_plan":false,"te":false}
"""#

/// CodexBar #2593: a Business seat billed by tokens.
private let businessCredits = #"""
{"copilot_plan":"business","access_type_sku":"copilot_for_business_seat_quota","token_based_billing":true,
 "quota_reset_date":"2026-09-01","quota_snapshots":{
 "premium_interactions":{"unlimited":true,"entitlement":0,"remaining":0,"percent_remaining":100.0,"quota_remaining":0.0,
   "credits_used":31,"token_based_billing":true,"overage_permitted":true},
 "chat":{"unlimited":true,"entitlement":0,"credits_used":0},"completions":{"unlimited":true,"entitlement":0,"credits_used":0}}}
"""#

/// CodexBar #1258: the same seat before `unlimited` and `credits_used` were sent.
private let businessBlank = #"""
{"copilot_plan":"business","access_type_sku":"copilot_for_business_seat_quota","token_based_billing":true,
 "quota_snapshots":{"chat":{"entitlement":0,"remaining":0,"percent_remaining":100},
 "completions":{"entitlement":0,"remaining":0,"percent_remaining":100},
 "premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100}}}
"""#

/// CodexBar #690: live numbers from a Pro+ account.
private let proPlus = #"""
{"copilot_plan":"individual_pro","access_type_sku":"monthly_subscriber_quota","assigned_date":"2026-03-22T16:03:34-07:00",
 "quota_reset_date":"2026-05-01","quota_reset_date_utc":"2026-05-01T00:00:00.000Z","quota_snapshots":{
 "chat":{"entitlement":0,"percent_remaining":100.0,"remaining":0,"unlimited":true,"quota_id":"chat"},
 "completions":{"entitlement":0,"percent_remaining":100.0,"remaining":0,"unlimited":true,"quota_id":"completions"},
 "premium_interactions":{"entitlement":1500,"remaining":1139,"percent_remaining":75.9,"unlimited":false,"overage_permitted":true,
   "credits_used":0,"quota_id":"premium_interactions"}}}
"""#

private let legacyFree = #"""
{"copilot_plan":"individual","access_type_sku":"free_limited_copilot","limited_user_reset_date":"2026-12-01",
 "monthly_quotas":{"chat":500,"completions":4000},"limited_user_quotas":{"chat":125,"completions":3000}}
"""#

private func report(_ json: String) throws -> CopilotUsageAPI.Report {
    try JSONDecoder().decode(CopilotUsageAPI.Report.self, from: Data(json.utf8))
}

private func snapshot(_ json: String) throws -> ProviderSnapshot {
    try CopilotUsageAPI.snapshot(from: try report(json))
}

// MARK: Reading the report

@Test func aPaidPlanShowsItsPremiumShareAndSkipsWhatsUnlimited() throws {
    let s = try snapshot(proPlus)
    #expect(s.provider == .copilot)
    #expect(s.plan == "Pro+")
    #expect(s.windows.map(\.id) == ["premium"])
    let premium = try #require(s.windows.first)
    #expect(premium.title == "Premium")
    #expect(abs(premium.usedPercent - 24.1) < 0.001)
    #expect(premium.resetsAt == parseISODate("2026-05-01T00:00:00Z"))
    #expect(premium.durationSeconds == 30 * 86400)
    // GitHub reports 0 credits on a metered plan whatever it has used.
    #expect(s.creditsUsed == nil)
}

@Test func aSeatBilledByTokensHasCreditsAndNoWindow() throws {
    let s = try snapshot(businessCredits)
    #expect(s.plan == "Business")
    #expect(s.windows.isEmpty)
    #expect(s.creditsUsed == 31)
}

@Test func aSeatThatReportsNothingStillShowsItsPlan() throws {
    let s = try snapshot(businessBlank)
    #expect(s.plan == "Business")
    #expect(s.windows.isEmpty)
    #expect(s.creditsUsed == nil)
}

@Test func anEndedSubscriptionSaysSo() throws {
    #expect(throws: CopilotUsageAPI.ended) { try snapshot(liveEnded) }
}

@Test func anAccountWithoutAPlanSaysSo() throws {
    #expect(throws: CopilotUsageAPI.noPlan) { try snapshot(#"{"can_signup_for_limited":true,"copilot_plan":"individual"}"#) }
    #expect(throws: CopilotUsageAPI.noPlan) { try snapshot("{}") }
}

@Test func olderFreeAccountsReportWhatsLeftOfTheMonth() throws {
    let s = try snapshot(legacyFree)
    #expect(s.plan == "Free")
    #expect(s.windows.map(\.id) == ["chat", "completions"])
    #expect(s.windows[0].usedPercent == 75)
    #expect(s.windows[1].usedPercent == 25)
    #expect(s.windows[0].resetsAt == parseISODate("2026-12-01T00:00:00Z"))
}

@Test func freePremiumWithNoEntitlementIsLeftOut() throws {
    let s = try snapshot(#"""
    {"access_type_sku":"free_limited_copilot","quota_reset_date_utc":"2026-12-01T00:00:00.000Z","quota_snapshots":{
     "premium_interactions":{"entitlement":0,"percent_remaining":0,"remaining":0,"unlimited":false},
     "chat":{"entitlement":500,"percent_remaining":80,"remaining":400,"unlimited":false}}}
    """#)
    #expect(s.windows.map(\.id) == ["chat"])
    #expect(s.windows[0].usedPercent == 20)
}

@Test func anExplicitlyUnlimitedSnapshotBeatsTheLegacyCounts() throws {
    let s = try snapshot(#"""
    {"copilot_plan":"individual","monthly_quotas":{"chat":500},"limited_user_quotas":{"chat":100},
     "quota_snapshots":{"chat":{"unlimited":true,"entitlement":0}}}
    """#)
    #expect(s.windows.isEmpty)
}

@Test func tokenBilledAllowanceIsCalledAICreditsAndIgnoresHasQuota() throws {
    // Under token billing `has_quota` is always false, so it can't mean used up.
    let s = try snapshot(#"""
    {"copilot_plan":"individual","token_based_billing":true,"quota_reset_date_utc":"2026-12-01T00:00:00.000Z","quota_snapshots":{
     "premium_interactions":{"entitlement":1000,"remaining":600,"percent_remaining":60,"has_quota":false,"credits_used":400}}}
    """#)
    let window = try #require(s.windows.first)
    #expect(window.title == "AI Credits")
    #expect(window.usedPercent == 40)
    #expect(s.creditsUsed == nil)
}

@Test func aDepletedPoolShowsNoCreditsFigure() throws {
    let s = try snapshot(#"""
    {"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{
     "premium_interactions":{"unlimited":true,"entitlement":0,"has_quota":false,"credits_used":99}}}
    """#)
    #expect(s.creditsUsed == nil)
}

@Test func overageStaysAtAllUsedAndOddNumbersAreSafe() throws {
    let s = try snapshot(#"""
    {"copilot_plan":"individual","quota_snapshots":{
     "premium_interactions":{"entitlement":300,"remaining":-75,"percent_remaining":-25,"overage_count":75,"overage_permitted":true},
     "chat":{"entitlement":-1,"percent_remaining":100},
     "completions":{"entitlement":"2000","remaining":"500"}}}
    """#)
    #expect(s.windows.map(\.id) == ["premium", "completions"])
    #expect(s.windows[0].usedPercent == 100)
    #expect(s.windows[1].usedPercent == 75)
}

@Test func anUnlimitedSentinelCountsAsAPlan() throws {
    let s = try snapshot(#"{"copilot_plan":"individual","quota_snapshots":{"chat":{"entitlement":-1,"percent_remaining":100}}}"#)
    #expect(s.plan == "Pro")
    #expect(s.windows.isEmpty)
}

@Test func aNullOrBrokenQuotaLosesOnlyItself() throws {
    let s = try snapshot(#"""
    {"copilot_plan":"individual","monthly_quotas":{"chat":null},"limited_user_quotas":{"chat":null},"quota_snapshots":{
     "chat":null,"completions":7,"premium_interactions":{"entitlement":300,"percent_remaining":50}}}
    """#)
    #expect(s.windows.map(\.id) == ["premium"])
    #expect(try snapshot(#"{"copilot_plan":"individual","token_based_billing":true,"quota_snapshots":null}"#).windows.isEmpty)
}

@Test func aWrongTypeInOneFieldDoesntLoseTheReport() throws {
    let s = try snapshot(#"""
    {"copilot_plan":"individual","quota_snapshots":{
     "premium_interactions":{"entitlement":300,"percent_remaining":50,"credits_used":{"a":1},"quota_reset_at":"soon"}}}
    """#)
    #expect(s.windows.first?.usedPercent == 50)
}

@Test func aSnapshotsOwnResetWinsThenUTCThenTheDay() throws {
    func reset(_ extra: String, _ snapshotExtra: String = "") throws -> Date? {
        try snapshot(#"{"copilot_plan":"individual",\#(extra)"quota_snapshots":{"premium_interactions":{\#(snapshotExtra)"entitlement":10,"percent_remaining":5}}}"#)
            .windows.first?.resetsAt
    }
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try reset(#""quota_reset_date_utc":"2026-12-01T00:00:00.000Z","#, #""quota_reset_at":1800000000,"#) == at)
    #expect(try reset(#""quota_reset_date_utc":"2026-12-01T00:00:00.000Z","quota_reset_date":"2026-11-15","#) == parseISODate("2026-12-01T00:00:00Z"))
    #expect(try reset(#""quota_reset_date":"2026-11-15","#) == parseISODate("2026-11-15T00:00:00Z"))
    #expect(try reset(#""quota_reset_date":"soon","#) == nil)
    #expect(try reset("") == nil)
}

@Test func plansHaveTheNamesGitHubSells() throws {
    func plan(_ plan: String, sku: String = "x") throws -> String? {
        try snapshot(#"{"copilot_plan":"\#(plan)","access_type_sku":"\#(sku)","token_based_billing":true}"#).plan
    }
    #expect(try plan("individual") == "Pro")
    #expect(try plan("individual_pro") == "Pro+")
    #expect(try plan("individual_max") == "Max")
    #expect(try plan("individual_edu") == "Education")
    #expect(try plan("enterprise") == "Enterprise")
    #expect(try plan("something_new") == nil)
    #expect(try plan("individual", sku: "free_educational_quota") == "Education")
}

// MARK: Where a token may go

@Test func aTokenOnlyGoesToGitHubOrThisMac() {
    func origin(_ host: String) -> String? { CopilotUsageAPI.origin(host: host)?.absoluteString }
    #expect(origin("https://github.com") == "https://api.github.com")
    #expect(origin("github.com") == "https://api.github.com")
    #expect(origin("https://acme.ghe.com") == "https://api.acme.ghe.com")
    #expect(origin("https://api.acme.ghe.com") == "https://api.acme.ghe.com")
    #expect(origin("http://127.0.0.1:8080") == "http://127.0.0.1:8080")
    for refused in [
        "http://github.com", "https://github.com:8443", "https://github.com.evil.example", "https://evilghe.com",
        "http://acme.ghe.com", "https://acme.ghe.com:8443", "https://example.com", "ftp://127.0.0.1", "", "https://",
    ] {
        #expect(origin(refused) == nil, "\(refused)")
    }
}

// MARK: Which login

private struct Fixture {
    let dir: URL
    var cli: URL { dir.appendingPathComponent("copilot") }
    var editor: URL { dir.appendingPathComponent("editor") }
    var gh: URL { dir.appendingPathComponent("gh") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString)")
        for folder in [cli, editor, gh] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }

    func write(_ text: String, _ folder: URL, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func logins(
        gh: @escaping @Sendable (String, String?) -> String? = { _, _ in nil },
        keychain: @escaping @Sendable (String) -> String? = { _ in nil }) -> CopilotLogins
    {
        CopilotLogins(cliHome: cli, editorConfig: editor, ghConfig: self.gh, gh: gh, keychain: keychain)
    }
}

/// What Copilot CLI 1.0.105 wrote after a real login, but for the host and the user.
private let cliConfig = #"""
// User settings belong in settings.json.
// This file is managed automatically.
{
  "firstLaunchAt": "2026-11-02T08:35:18.630Z",
  "loggedInUsers": [
    {
      "host": "https://github.com",
      "login": "cli-user",
      "kind": "proxima"
    }
  ],
  "lastLoggedInUser": {
    "host": "https://github.com",
    "login": "cli-user"
  }
}
"""#

/// What Copilot CLI 0.0.419 wrote on this repo's owner's Mac, but for the user.
private let olderCLIConfig = #"""
{"banner":"never","last_logged_in_user":{"host":"https://github.com","login":"cli-user"},
 "logged_in_users":[{"host":"https://github.com","login":"cli-user"}]}
"""#

/// The real file's shape, from `gh` on this repo's owner's Mac.
private let ghHosts = """
github.com:
    git_protocol: https
    users:
        gh-active:
            oauth_token: gho_secret
        Cli-User:
    user: gh-active
    oauth_token: gho_secret
acme.ghe.com:
    users:
        other:
    user: other
"""

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func add(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    init(_ answers: [String?]) { self.answers = answers }
    func next() -> String? { lock.lock(); defer { lock.unlock() }; return answers.removeFirst() }
}

@Test func nothingOnThisMacFindsNothing() throws {
    let f = try Fixture()
    defer { f.remove() }
    #expect(f.logins().find(optedIn: true) == nil)
    #expect(CopilotProvider(logins: f.logins()).isConfigured() == false)
}

@Test func aCLIUserGhAlsoHoldsIsDetectedAndNeedsNoKeychain() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(cliConfig, f.cli, "config.json")
    try f.write(ghHosts, f.gh, "hosts.yml")
    let calls = Calls()
    let logins = f.logins(
        gh: { host, user in calls.add("gh \(host) \(user ?? "-")"); return "gho_token" },
        keychain: { calls.add("keychain \($0)"); return "unwanted" })
    let login = try #require(logins.find(optedIn: false))
    #expect(login.source == .cli)
    #expect(login.name == "cli-user")
    #expect(logins.token(for: login, optedIn: true) == "gho_token")
    // The CLI's user, not `gh`'s active one, spelled as `gh` has it: its lookup minds the case.
    #expect(calls.all == ["gh github.com Cli-User"])
}

@Test func bothGenerationsOfTheCLIsFileAreRead() throws {
    let f = try Fixture()
    defer { f.remove() }
    for config in [cliConfig, olderCLIConfig, #"{"loggedInUsers":[{"host":"https://github.com","login":"cli-user"}]}"#] {
        try f.write(config, f.cli, "config.json")
        #expect(f.logins().find(optedIn: true)?.name == "cli-user", "\(config)")
    }
}

@Test func theKeychainPromptNeedsTheUserToOptIn() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(cliConfig, f.cli, "config.json")
    let calls = Calls()
    let logins = f.logins(keychain: { calls.add($0); return "gho_keychain" })
    // Without `gh` holding that user, auto-detection stays out of it.
    #expect(logins.find(optedIn: false) == nil)
    #expect(calls.all.isEmpty)

    let login = try #require(logins.find(optedIn: true))
    #expect(logins.token(for: login, optedIn: false) == nil)
    #expect(calls.all.isEmpty)
    #expect(logins.token(for: login, optedIn: true) == "gho_keychain")
    #expect(calls.all == ["https://github.com:cli-user"])
}

@Test func aRefusedPromptIsntShownAgain() {
    let calls = Calls()
    let answers = Answers(["gho_allowed", nil, "gho_later"])
    let keychain = CopilotLogins.untilRefused { calls.add($0); return answers.next() }
    #expect(keychain("a") == "gho_allowed")
    #expect(keychain("a") == nil)
    #expect(keychain("a") == nil)
    #expect(calls.all.count == 2)
    // Another account still gets asked.
    #expect(keychain("b") == "gho_later")
    #expect(calls.all == ["a", "a", "b"])
}

@Test func anEditorLoginForAnUnsupportedHostDoesntHideAGoodOne() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(#"""
    {"a-server.example:Iv1.x":{"user":"elsewhere","oauth_token":"ghu_elsewhere"},
     "github.com:Iv1.x":{"user":"editor-user","oauth_token":"ghu_good"}}
    """#, f.editor, "apps.json")
    #expect(f.logins().find(optedIn: false)?.storedToken == "ghu_good")
    try f.write(#"{"a-server.example:Iv1.x":{"user":"elsewhere","oauth_token":"ghu_elsewhere"}}"#, f.editor, "apps.json")
    #expect(f.logins().find(optedIn: true) == nil)
}

@Test func aChildProcessAnswersOrGivesUp() {
    func run(_ script: String, timeout: TimeInterval = 5) -> String? {
        ChildProcess.output(of: "/bin/sh", ["-c", script], timeout: timeout)
    }
    #expect(run("echo '  token  '") == "token")
    #expect(run("echo token; exit 3") == nil)
    // More than any answer would be.
    #expect(run("head -c 300000 /dev/zero | tr '\\0' x") == nil)
    #expect(run("head -c 200000 /dev/zero | tr '\\0' x")?.count == 200_000)
    // Gone, but something it left behind keeps stdout open, past the timeout.
    let start = Date()
    #expect(run("sleep 20 & exit 0", timeout: 0.5) == nil)
    #expect(Date().timeIntervalSince(start) < 5)
    // Hanging itself.
    #expect(run("exec sleep 20", timeout: 0.5) == nil)
}

@Test func aCLIUserGhDoesntHoldCostsNoGhProcess() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(cliConfig, f.cli, "config.json")
    let calls = Calls()
    let logins = f.logins(gh: { _, _ in calls.add("gh"); return "t" }, keychain: { _ in "gho_keychain" })
    let login = try #require(logins.find(optedIn: true))
    #expect(logins.token(for: login, optedIn: true) == "gho_keychain")
    #expect(calls.all.isEmpty)
}

@Test func aCLITokenInTheFileIsUsedAsIs() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(#"""
    {"last_logged_in_user":{"host":"https://github.com","login":"cli-user"},
     "copilot_tokens":{"https://github.com:someone-else":"gho_other","https://github.com:cli-user":"gho_plain"}}
    """#, f.cli, "config.json")
    let calls = Calls()
    let logins = f.logins(gh: { _, _ in calls.add("gh"); return nil })
    let login = try #require(logins.find(optedIn: false))
    #expect(logins.token(for: login, optedIn: false) == "gho_plain")
    #expect(calls.all.isEmpty)
    try f.write(#"""
    {"lastLoggedInUser":{"host":"https://github.com","login":"cli-user"},"copilotTokens":{"https://github.com:cli-user":"gho_camel"}}
    """#, f.cli, "config.json")
    #expect(logins.find(optedIn: false)?.storedToken == "gho_camel")
}

@Test func anEditorPluginsLoginIsDetected() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(#"{"github.com":{"user":"old","oauth_token":"gho_old"}}"#, f.editor, "hosts.json")
    #expect(f.logins().find(optedIn: false)?.storedToken == "gho_old")
    try f.write(#"""
    {"github.com:Iv1.b507a08c87ecfe98":{"user":"editor-user","oauth_token":"ghu_new","githubAppId":"Iv1.b507a08c87ecfe98"}}
    """#, f.editor, "apps.json")
    let login = try #require(f.logins().find(optedIn: false))
    #expect(login.source == .editor)
    #expect(login.host == "https://github.com")
    #expect(login.name == "editor-user")
    #expect(login.storedToken == "ghu_new")
}

@Test func ghAloneWaitsForTheUserToOptIn() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(ghHosts, f.gh, "hosts.yml")
    let calls = Calls()
    let logins = f.logins(gh: { host, user in calls.add("\(host) \(user ?? "-")"); return "gho_gh" })
    #expect(logins.find(optedIn: false) == nil)
    let login = try #require(logins.find(optedIn: true))
    #expect(login.source == .gh)
    #expect(login.name == "gh-active")
    #expect(logins.token(for: login, optedIn: true) == "gho_gh")
    #expect(calls.all == ["github.com gh-active"])
}

@Test func aLoginYAMLHadToQuoteStillMatches() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(#"{"lastLoggedInUser":{"host":"https://github.com","login":"123"}}"#, f.cli, "config.json")
    try f.write(#"""
    github.com:
        users:
            "123":
                oauth_token: gho_secret
            'null':
        user: "null"
    """#, f.gh, "hosts.yml")
    let calls = Calls()
    let logins = f.logins(gh: { _, user in calls.add(user ?? "-"); return "t" })
    let login = try #require(logins.find(optedIn: false))
    #expect(logins.token(for: login, optedIn: false) == "t")
    #expect(calls.all == ["123"])
    try f.write("{}", f.cli, "config.json")
    #expect(logins.find(optedIn: true)?.name == "null")
}

@Test func optedInGhUsesAnEnterpriseHostWhenItsTheOnlyOne() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("""
    acme.ghe.com:
        users:
            other:
        user: other
    self-hosted.example:
        user: nope
    """, f.gh, "hosts.yml")
    var login = try #require(f.logins().find(optedIn: true))
    #expect(login.host == "https://acme.ghe.com")
    #expect(login.name == "other")
    try f.write(ghHosts, f.gh, "hosts.yml")
    login = try #require(f.logins().find(optedIn: true))
    #expect(login.host == "https://github.com")
    try f.write("self-hosted.example:\n    user: nope\n", f.gh, "hosts.yml")
    #expect(f.logins().find(optedIn: true) == nil)
}

@Test func ghDoesntVouchForAUserOnAnotherHost() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(#"{"last_logged_in_user":{"host":"https://acme.ghe.com","login":"gh-active"}}"#, f.cli, "config.json")
    try f.write(ghHosts, f.gh, "hosts.yml")
    #expect(f.logins().find(optedIn: false) == nil)
}

@Test func unreadableFilesCountAsNoLogin() throws {
    let f = try Fixture()
    defer { f.remove() }
    for bad in ["", "[]", "not json", #"{"last_logged_in_user":"me"}"#, #"{"last_logged_in_user":{"host":"","login":"me"}}"#] {
        try f.write(bad, f.cli, "config.json")
        #expect(f.logins().find(optedIn: true) == nil, "\(bad)")
    }
    try f.write(#"{"github.com":"token","x":{"oauth_token":7},"y":{"oauth_token":""}}"#, f.editor, "apps.json")
    #expect(f.logins().find(optedIn: true) == nil)
}

@Test func identityIsTheLoginNameAndReadsNoToken() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(cliConfig, f.cli, "config.json")
    try f.write(ghHosts, f.gh, "hosts.yml")
    let calls = Calls()
    let provider = CopilotProvider(logins: f.logins(gh: { _, _ in calls.add("gh"); return "t" }, keychain: { _ in calls.add("kc"); return "t" }))
    #expect(provider.isConfigured())
    #expect(provider.identity()?.email == "cli-user")
    #expect(calls.all.isEmpty)
}

@Test func theSameNameOnAnotherHostIsAnotherAccount() throws {
    let f = try Fixture()
    defer { f.remove() }
    func accountID(_ host: String) throws -> String? {
        try f.write(#"{"lastLoggedInUser":{"host":"\#(host)","login":"me"},"copilotTokens":{"\#(host):me":"t"}}"#, f.cli, "config.json")
        return CopilotProvider(logins: f.logins()).identity()?.accountID
    }
    let github = try accountID("https://github.com")
    #expect(github != nil)
    #expect(github != (try accountID("https://acme.ghe.com")))
}

// MARK: The request

private final class GitHubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hosts = Set<String>()
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// The token picks the answer. A request that isn't what GitHub's clients send is a 400.
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.hosts.insert(url.host ?? ""); Self.lock.unlock()
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let valid = request.httpMethod == "GET" && url.path == "/copilot_internal/user" && url.query == nil
            && token.hasPrefix("Bearer ") && request.value(forHTTPHeaderField: "User-Agent") == "Tinybar"
            && request.value(forHTTPHeaderField: "Cookie") == nil
        var status = 200
        var headers: [String: String] = [:]
        var body = proPlus
        switch String(token.dropFirst(7)) {
        case _ where !valid: status = 400; body = ""
        case "bad": status = 401; body = #"{"message":"Bad credentials","status":"401"}"#
        case "limited": status = 403; body = #"{"message":"API rate limit exceeded for user ID 1."}"#
        case "sso": status = 403; body = #"{"message":"Resource protected by organization SAML enforcement."}"#
        case "none": status = 404; body = #"{"message":"Not Found"}"#
        case "busy": status = 429; headers["Retry-After"] = "120"; body = ""
        case "down": status = 500; body = "oops"
        case "html": body = "<html></html>"
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func fetch(token: String, host: String = "https://github.com") async throws -> ProviderSnapshot {
    let f = try Fixture()
    defer { f.remove() }
    let tokens = try String(data: JSONSerialization.data(withJSONObject: ["\(host):me": token]), encoding: .utf8)!
    try f.write(#"{"last_logged_in_user":{"host":"\#(host)","login":"me"},"copilot_tokens":\#(tokens)}"#, f.cli, "config.json")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GitHubServer.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    return try await CopilotProvider(logins: f.logins(), session: session).fetch()
}

@Test func fetchesLikeGitHubsOwnClients() async throws {
    #expect(try await fetch(token: "good").windows.map(\.id) == ["premium"])
    #expect(GitHubServer.hosts.contains("api.github.com"))
}

@Test func statusesMeanWhatTheySay() async throws {
    await #expect(throws: ProviderError.loginExpired) { try await fetch(token: "bad") }
    await #expect(throws: ProviderError.loginExpired) { try await fetch(token: "sso") }
    await #expect(throws: ProviderError.rateLimited(retryAfter: nil)) { try await fetch(token: "limited") }
    await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) { try await fetch(token: "busy") }
    await #expect(throws: CopilotUsageAPI.noPlan) { try await fetch(token: "none") }
    await #expect(throws: ProviderError.unexpected("GitHub API returned HTTP 500")) { try await fetch(token: "down") }
    await #expect(throws: ProviderError.unexpected("Unexpected Copilot usage response")) { try await fetch(token: "html") }
}

@Test func aBrokenTokenOrAStrangeHostNeverLeaves() async throws {
    await #expect(throws: ProviderError.loginExpired) { try await fetch(token: "has space\r\nX-Evil: 1") }
    await #expect(throws: CopilotUsageAPI.refusedHost) { try await fetch(token: "good", host: "https://evil.example") }
    #expect(!GitHubServer.hosts.contains("evil.example"))
    #expect(!GitHubServer.hosts.contains("api.evil.example"))
}

@Test func noUsableLoginIsNotSignedIn() async throws {
    let f = try Fixture()
    defer { f.remove() }
    await #expect(throws: ProviderError.notConfigured) { try await CopilotProvider(logins: f.logins()).fetch() }
    try f.write(cliConfig, f.cli, "config.json")
    try f.write(ghHosts, f.gh, "hosts.yml")
    // `gh` lost the user since the check, and the Keychain isn't on the table.
    await #expect(throws: ProviderError.notConfigured) { try await CopilotProvider(logins: f.logins()).fetch() }
}

// MARK: Status page

@Test func copilotIsAProvider() {
    #expect(ProviderID.allCases.suffix(2) == [.opencode, .copilot], "new Providers go last, keeping tab shortcuts")
    #expect(StatusFeed.hasFeed(.copilot) && !ProviderID.copilot.hasBrowserFallback && !ProviderID.copilot.hasActivity)
    #expect(ProviderID.copilot.loginHint == "run `copilot login` or `gh auth login`")
}

@Test func onlyCopilotsComponentsCount() throws {
    guard case let .statuspage(base, components) = StatusFeed.source(.copilot) else {
        Issue.record("Expected GitHub's statuspage")
        return
    }
    #expect(base.host == "www.githubstatus.com")
    func incidents(_ component: String) throws -> [Incident] {
        let data = Data(#"{"incidents":[{"name":"Trouble","status":"investigating","components":[{"name":"\#(component)","status":"partial_outage"}]}]}"#.utf8)
        return try StatusFeed.statuspage(data, provider: .copilot, base: base, components: components)
    }
    #expect(try incidents("Copilot").count == 1)
    #expect(try incidents("Copilot AI Model Providers").count == 1)
    #expect(try incidents("Actions").isEmpty)
}
