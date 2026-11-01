import Foundation
@testable import TinybarCore
import Testing

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func window(_ id: String, used: Double, resets: TimeInterval?, hours: Int, modelSpecific: Bool = false) -> LimitWindow {
    LimitWindow(
        id: id, title: id == "session" ? "5-hour" : "Weekly", usedPercent: used,
        resetsAt: resets.map { now.addingTimeInterval($0) }, durationSeconds: hours * 3600, isModelSpecific: modelSpecific)
}

private func account(
    _ name: String, session: Double = 0, sessionReset: TimeInterval = 3600, weekly: Double = 0, weeklyReset: TimeInterval = 86400,
    error: ProviderError? = nil, active: Bool = false) -> Account
{
    Account(
        id: name, name: name, isActive: active,
        snapshot: ProviderSnapshot(provider: .claude, plan: "Max 5x", windows: [
            window("session", used: session, resets: sessionReset, hours: 5),
            window("weekly", used: weekly, resets: weeklyReset, hours: 168),
        ], fetchedAt: now),
        error: error)
}

// MARK: Identity

@Test func anIdentityIgnoresCaseAndHidesTheEmail() {
    let a = LoginIdentity(email: "Me@Example.com", organization: "ORG")
    let b = LoginIdentity(email: "me@example.com ", organization: "org")
    #expect(a.accountID == b.accountID)
    #expect(!a.accountID.contains("example"))
    #expect(a.accountID != LoginIdentity(email: "me@example.com", organization: "other").accountID)
}

@Test func claudeIdentityComesFromItsConfig() throws {
    let config = #"{"numStartups":3,"oauthAccount":{"emailAddress":"me@example.com","organizationUuid":"org-1","organizationName":"Acme"}}"#
    let identity = try #require(ClaudeCredentials.identity(fromConfig: Data(config.utf8)))
    #expect(identity.email == "me@example.com")
    #expect(identity.organization == "org-1")
    #expect(identity.organizationName == "Acme")
    #expect(ClaudeCredentials.identity(fromConfig: Data(#"{"numStartups":3}"#.utf8)) == nil)
}

@Test func claudeIdentityComesFromTheFolderTheTokenDoes() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let a = try folder("a", in: home), b = try folder("b", in: home)
    func config(_ email: String) -> Data { Data(#"{"oauthAccount":{"emailAddress":"\#(email)"}}"#.utf8) }
    try config("a@example.com").write(to: a.appendingPathComponent(".claude.json"))
    try config("b@example.com").write(to: b.appendingPathComponent(".claude.json"))
    try Data("{}".utf8).write(to: b.appendingPathComponent(".credentials.json"))
    let identity = ClaudeCredentials.identity(env: ["CLAUDE_CONFIG_DIR": "\(a.path),\(b.path)"])
    #expect(identity?.email == "b@example.com")

    // A token that can't be read doesn't count, as `load` wouldn't take it.
    let unreadable = a.appendingPathComponent(".credentials.json")
    try Data("{}".utf8).write(to: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
    #expect(ClaudeCredentials.identity(env: ["CLAUDE_CONFIG_DIR": "\(a.path),\(b.path)"])?.email == "b@example.com")
}

@Test func codexIdentityComesFromTheIdToken() throws {
    let claims = #"{"email":"me@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acct-1"}}"#
    let payload = Data(claims.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let auth = #"{"tokens":{"access_token":"a","id_token":"h.\#(payload).s"}}"#
    let identity = try #require(CodexCredentials.identity(fromAuth: Data(auth.utf8)))
    #expect(identity.email == "me@example.com")
    #expect(identity.organization == "acct-1")
    #expect(CodexCredentials.identity(fromAuth: Data(#"{"tokens":{"access_token":"a"}}"#.utf8)) == nil)
    // The account requests go out for decides, as it does for those requests.
    let stated = #"{"tokens":{"access_token":"a","account_id":"acct-2","id_token":"h.\#(payload).s"}}"#
    #expect(CodexCredentials.identity(fromAuth: Data(stated.utf8))?.organization == "acct-2")
}

@Test func aFolderLoginsKeychainItemIsNamedFromItsPath() {
    #expect(ClaudeCredentials.keychainService(folder: URL(fileURLWithPath: "/Users/me/.claude_side"))
        == "Claude Code-credentials-d5f19101")
}

// MARK: Merging

@Test func theSameLoginFoundTwiceIsOneAccount() {
    var fromSwap = Account(id: "a", name: "me@example.com", alias: "work")
    fromSwap.snapshot = account("a", weekly: 90).snapshot
    let merged = AccountRoster.merge([account("a", weekly: 10, active: true)], [], [fromSwap, Account(id: "b", name: "b")])
    #expect(merged.map(\.id) == ["a", "b"])
    // The direct read wins, and the other source lends its alias.
    #expect(merged[0].snapshot?.windows.last?.usedPercent == 10)
    #expect(merged[0].isActive)
    #expect(merged[0].displayName == "work")
}

@Test func aPreferredSourceWithNoNumbersDoesntHideAnothers() {
    let missing = Account(id: "a", name: "me@example.com", isActive: true, error: .notConfigured)
    let merged = AccountRoster.merge([missing], [account("a", weekly: 30)], [account("b")])
    #expect(merged.map(\.id) == ["a", "b"])
    #expect(merged[0].snapshot?.windows.last?.usedPercent == 30)
    #expect(merged[0].error == nil)
    #expect(merged[0].isActive)
}

@Test func aDefaultLoginThatIsntThereGoesAwayOnceAnotherExists() {
    let missing = Account(id: "default", name: "Claude", isActive: true, error: .notConfigured)
    #expect(AccountRoster.merge([missing]).count == 1)
    #expect(AccountRoster.merge([missing], [account("a")]).map(\.id) == ["a"])
}

@Test func twoOrganizationsUnderOneEmailAreToldApart() {
    let merged = AccountRoster.merge([
        Account(id: "a", name: "me@example.com", organizationName: "Acme"),
        Account(id: "b", name: "me@example.com", organizationName: "Personal"),
        Account(id: "c", name: "other@example.com", organizationName: "Acme"),
    ])
    #expect(merged.map(\.displayName) == ["me@example.com · Acme", "me@example.com · Personal", "other@example.com"])
}

@Test func claudeSwapsActiveRowIsTheDefaultLoginWhenTheirEmailsMatch() {
    let main = Account(id: "main", name: "Me@Example.com", isActive: true, snapshot: account("x").snapshot)
    let rows = [Account(id: "other-hash", name: "me@example.com", alias: "work", isActive: true), Account(id: "b", name: "b@example.com")]
    let merged = AccountRoster.merge([main], AccountRoster.swapRows(rows, defaultLogin: main, provider: .claude))
    #expect(merged.map(\.id) == ["main", "b"])
    #expect(merged[0].displayName == "work")
    #expect(merged.filter(\.isActive).map(\.id) == ["main"])

    // Mid-switch they disagree, and neither is lost.
    let elsewhere = Account(id: "c", name: "c@example.com", isActive: true)
    #expect(AccountRoster.merge([main], AccountRoster.swapRows([elsewhere], defaultLogin: main, provider: .claude)).map(\.id) == ["main", "c"])
    // Only claude-swap can say who an unreadable login is.
    let anonymous = Account(id: LoginIdentity.accountID(place: "claude"), name: "Claude", isActive: true, snapshot: account("x").snapshot)
    #expect(AccountRoster.merge([anonymous], AccountRoster.swapRows([elsewhere], defaultLogin: anonymous, provider: .claude)).count == 1)
    // Nor can an anonymous browser reading stand in for it.
    var viaBrowser = anonymous
    viaBrowser.snapshot?.source = .browser
    #expect(AccountRoster.merge([viaBrowser], AccountRoster.swapRows([elsewhere], defaultLogin: viaBrowser, provider: .claude)).count == 2)
    // A default login that isn't there leaves the row standing.
    let missing = Account(id: LoginIdentity.accountID(place: "claude"), name: "Claude", isActive: true, error: .notConfigured)
    #expect(AccountRoster.merge([missing], AccountRoster.swapRows([elsewhere], defaultLogin: missing, provider: .claude)).map(\.id) == ["c"])
}

// MARK: The Pool

@Test func oneAccountIsItsOwnPool() {
    // A passed Reset stays as read: nothing changes with one Account.
    let only = account("a", session: 40, sessionReset: -60, weekly: 30, active: true)
    let pool = Pool(provider: .claude, accounts: [only], now: now)
    #expect(pool.snapshot == only.snapshot)
    #expect(pool.snapshot?.windows.allSatisfy { $0.poolRefill == nil } == true)
    #expect(pool.error == nil)
}

@Test func aPoolAveragesWhatEachAccountHasLeft() throws {
    let pool = Pool(provider: .claude, accounts: [
        account("a", session: 38, weekly: 52, active: true),
        account("b", session: 0, weekly: 19),
        account("c", session: 92, weekly: 88),
    ], now: now)
    let snapshot = try #require(pool.snapshot)
    #expect(snapshot.plan == "3 accounts")
    #expect(snapshot.windows.map(\.id) == ["session", "weekly"])
    #expect(abs(snapshot.windows[0].remainingPercent - 56.67) < 0.01)
    #expect(abs(snapshot.windows[1].remainingPercent - 47) < 0.01)
}

@Test func aPoolAveragesOnlyTheAccountsReportingAWindow() throws {
    var weeklyOnly = account("b", weekly: 40)
    weeklyOnly.snapshot?.windows.removeAll { $0.id == "session" }
    let pool = Pool(provider: .claude, accounts: [account("a", session: 50, weekly: 20), weeklyOnly], now: now)
    let windows = try #require(pool.snapshot?.windows)
    #expect(windows.first { $0.id == "session" }?.usedPercent == 50)
    #expect(windows.first { $0.id == "weekly" }?.usedPercent == 30)
}

@Test func modelSpecificWindowsStayOnTheirAccount() throws {
    var a = account("a", weekly: 10)
    a.snapshot?.windows.append(window("fable-weekly", used: 80, resets: 86400, hours: 168, modelSpecific: true))
    let pool = Pool(provider: .claude, accounts: [a, account("b")], now: now)
    #expect(pool.snapshot?.windows.map(\.id) == ["session", "weekly"])
    #expect(pool.accounts.first { $0.id == "a" }?.snapshot?.windows.count == 3)
}

@Test func aWeekUsedUpLeavesNothingInItsFiveHours() throws {
    let pool = Pool(provider: .claude, accounts: [
        account("a", session: 0, sessionReset: 1800, weekly: 100),
        account("b", session: 50, sessionReset: 7200, weekly: 0),
    ], now: now)
    let session = try #require(pool.snapshot?.windows.first { $0.id == "session" })
    #expect(session.usedPercent == 75)
    // Account a's 5 hours resetting gives nothing back, so the next refill is b's.
    #expect(session.resetsAt == now.addingTimeInterval(7200))
    #expect(session.poolRefill == 25)
}

@Test func aBlockedFiveHoursComesBackWithItsWeek() throws {
    let pool = Pool(provider: .claude, accounts: [
        account("a", session: 0, sessionReset: 3 * 3600, weekly: 100, weeklyReset: 1800),
        account("b", session: 50, sessionReset: 7200, weekly: 0),
    ], now: now)
    let session = try #require(pool.snapshot?.windows.first { $0.id == "session" })
    // Account a's 5 hours are unused, so all of its share is back when the week resets.
    #expect(session.resetsAt == now.addingTimeInterval(1800))
    #expect(session.poolRefill == 50)

    // Its own Reset having passed changes nothing: the week is still what it waits for.
    let waiting = Pool(provider: .claude, accounts: [
        account("a", session: 0, sessionReset: -600, weekly: 100, weeklyReset: 1800),
        account("b", session: 50, sessionReset: 7200, weekly: 0),
    ], now: now)
    let passed = try #require(waiting.snapshot?.windows.first { $0.id == "session" })
    #expect(passed.resetsAt == now.addingTimeInterval(1800))
    #expect(passed.poolRefill == 50)

    // With no Reset of its own, only its unused part comes back with the week.
    var unknown = account("a", session: 40, weekly: 100, weeklyReset: 1800)
    unknown.snapshot?.windows[0].resetsAt = nil
    let partly = Pool(provider: .claude, accounts: [unknown, account("b", sessionReset: 7200)], now: now)
    #expect(partly.snapshot?.windows.first { $0.id == "session" }?.poolRefill == 30)

    // A spent 5 hours that outlasts the week comes back with itself.
    let spent = Pool(provider: .claude, accounts: [
        account("a", session: 100, sessionReset: 3 * 3600, weekly: 100, weeklyReset: 1800),
        account("b", session: 0, sessionReset: 7200),
    ], now: now)
    let later = try #require(spent.snapshot?.windows.first { $0.id == "session" })
    #expect(later.resetsAt == now.addingTimeInterval(3 * 3600))
    #expect(later.poolRefill == 50)
}

@Test func resetsLandingTogetherGiveBackTogether() throws {
    let pool = Pool(provider: .claude, accounts: [
        account("a", weekly: 60, weeklyReset: 3600),
        account("b", weekly: 20, weeklyReset: 3630),
        account("c", weekly: 40, weeklyReset: 9000),
        account("d", weekly: 0, weeklyReset: 600),
    ], now: now)
    let weekly = try #require(pool.snapshot?.windows.first { $0.id == "weekly" })
    #expect(weekly.resetsAt == now.addingTimeInterval(3600))
    #expect(weekly.poolRefill == 20)
}

@Test func aStaleAccountCountsAtItsLastValuesUntilItsResetPasses() throws {
    let expired: ProviderError = .loginExpired
    let held = Pool(provider: .claude, accounts: [
        account("a", weekly: 80, weeklyReset: 3600, error: expired),
        account("b", weekly: 20),
    ], now: now)
    #expect(held.snapshot?.windows.first { $0.id == "weekly" }?.usedPercent == 50)
    #expect(held.error == nil)

    let passed = Pool(provider: .claude, accounts: [
        account("a", weekly: 80, weeklyReset: -3600, error: expired),
        account("b", weekly: 20),
    ], now: now)
    #expect(passed.snapshot?.windows.first { $0.id == "weekly" }?.usedPercent == 10)
    let shown = try #require(passed.accounts.first { $0.id == "a" }?.snapshot?.windows.first { $0.id == "weekly" })
    #expect(shown.usedPercent == 0)
    #expect(shown.resetsAt == nil)
    #expect(passed.accounts.first { $0.id == "a" }?.isStale == true)
}

@Test func aPoolIsStaleOnlyWhenEveryAccountIs() {
    let pool = Pool(provider: .claude, accounts: [account("a", error: .loginExpired), account("b", error: .network("x"))], now: now)
    #expect(pool.error == .loginExpired)
}

@Test func theNextResetSaysHowMuchItGivesBackAndSkipsUntouchedAccounts() throws {
    let pool = Pool(provider: .claude, accounts: [
        account("a", weekly: 0, weeklyReset: 3600),
        account("b", weekly: 60, weeklyReset: 7200),
        account("c", weekly: 30, weeklyReset: 10800),
    ], now: now)
    let weekly = try #require(pool.snapshot?.windows.first { $0.id == "weekly" })
    #expect(weekly.resetsAt == now.addingTimeInterval(7200))
    #expect(weekly.poolRefill == 20)
}

@Test func aPoolHasNoRunOutTime() throws {
    let open = now.addingTimeInterval(-3 * 86400)
    let pool = Pool(provider: .claude, accounts: [account("a", weekly: 80, weeklyReset: 4 * 86400), account("b", weekly: 80, weeklyReset: 4 * 86400)], now: now)
    let weekly = try #require(pool.snapshot?.windows.first { $0.id == "weekly" })
    #expect(weekly.runOutTime(asOf: open.addingTimeInterval(3 * 86400)) == nil)
    let own = try #require(pool.accounts[0].snapshot?.windows.first { $0.id == "weekly" })
    #expect(own.runOutTime(asOf: now) != nil)
}

@Test func accountsAreListedSoonestRefillFirst() {
    let pool = Pool(provider: .claude, accounts: [
        account("late", sessionReset: 9000),
        account("soon", sessionReset: 1000),
        account("mid", sessionReset: 5000),
    ], now: now)
    #expect(pool.accounts.map(\.id) == ["soon", "mid", "late"])
}

// MARK: Limit Alerts

@Test func alertsAreTrackedPerAccount() {
    var planner = LimitAlertPlanner()
    let a = ProviderSnapshot(provider: .claude, plan: nil, windows: [window("weekly", used: 95, resets: 86400, hours: 168)], fetchedAt: now)
    let b = ProviderSnapshot(provider: .claude, plan: nil, windows: [window("weekly", used: 10, resets: 5 * 86400, hours: 168)], fetchedAt: now)
    #expect(planner.evaluate(a, account: "a", now: now).count == 1)
    // Switching to an Account with a later Reset isn't a Reset of the first, nor a new alert.
    #expect(planner.evaluate(b, account: "b", now: now).isEmpty)
    #expect(planner.evaluate(a, account: "a", now: now).isEmpty)
}

@Test func anAlertFromBeforeAccountsIsntRepeated() {
    var planner = LimitAlertPlanner()
    let week = ProviderSnapshot(provider: .claude, plan: nil, windows: [window("weekly", used: 91, resets: 86400, hours: 168)], fetchedAt: now)
    #expect(planner.evaluate(week, now: now).count == 1)
    #expect(planner.evaluate(week, account: "a", now: now).isEmpty)
    // Another Account's different window doesn't inherit it.
    var other = LimitAlertPlanner()
    _ = other.evaluate(week, now: now)
    let later = ProviderSnapshot(provider: .claude, plan: nil, windows: [window("weekly", used: 91, resets: 5 * 86400, hours: 168)], fetchedAt: now)
    #expect(other.evaluate(later, account: "b", now: now).count == 1)
    // Nor does another Account inherit it, even with a Reset close by.
    var third = LimitAlertPlanner()
    _ = third.evaluate(week, now: now)
    let close = ProviderSnapshot(provider: .claude, plan: nil, windows: [window("weekly", used: 91, resets: 86400 + 120, hours: 168)], fetchedAt: now)
    #expect(third.evaluate(close, account: "b", inheritsOldState: false, now: now).count == 1)
    #expect(third.evaluate(week, account: "a", now: now).isEmpty)
    // And it's still there for the Account it does belong to, whichever comes first.
    #expect(other.evaluate(week, account: "a", now: now).isEmpty)
}

// MARK: Login folders

private func tempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func folder(_ path: String, in home: URL) throws -> URL {
    let url = home.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func loginFoldersAreThoseHoldingALogin() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    for name in [".claude", ".claude_side", ".claude-worktrees", ".claude-swap-backup", ".codex", ".codex_alt", ".codexbar", ".config"] {
        _ = try folder(name, in: home)
    }
    FileManager.default.createFile(atPath: home.appendingPathComponent(".claude.json").path, contents: Data())
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude_link"), withDestinationURL: home.appendingPathComponent(".claude"))

    let found = LoginFolders.find(
        home: home,
        hasClaudeLogin: { $0.lastPathComponent == ".claude_side" },
        hasCodexLogin: { $0.lastPathComponent == ".codex_alt" })
    #expect(found.map(\.id) == [".claude_side", ".codex_alt"])
    #expect(found[0].loginHint == "run `CLAUDE_CONFIG_DIR=~/.claude_side claude` once to refresh")
    #expect(found[1].loginHint == "run `CODEX_HOME=~/.codex_alt codex` once to refresh")
}

@Test func theDefaultFolderIsNeverAnExtraOne() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try folder(".claude", in: home)
    _ = try folder(".claude_side", in: home)
    _ = try folder(".claude_link_target", in: home)
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude_link"), withDestinationURL: home.appendingPathComponent(".claude"))
    #expect(Paths.extraConfigDirs(.claude, home: home, env: [:]).map(\.lastPathComponent) == [".claude_link_target", ".claude_side"])
    #expect(Paths.extraConfigDirs(.cursor, home: home, env: [:]).isEmpty)

    // Pointing the CLI elsewhere makes the usual folder a login like any other.
    _ = try folder(".codex", in: home)
    _ = try folder(".codex_work", in: home)
    #expect(Paths.extraConfigDirs(.codex, home: home, env: [:]).map(\.lastPathComponent) == [".codex_work"])
    #expect(Paths.extraConfigDirs(.codex, home: home, env: ["CODEX_HOME": home.appendingPathComponent(".codex_work").path]).map(\.lastPathComponent) == [".codex"])
}

@Test func logRootsCoverFoldersAndCswapProfilesOnce() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let side = try folder(".claude_side/projects", in: home)
    let profile = try folder(".claude-swap-backup/sessions/2-me_example.com", in: home)
    try FileManager.default.createSymbolicLink(
        at: try folder(".claude-swap-backup/sessions/3-shared", in: home).appendingPathComponent("projects"),
        withDestinationURL: side)
    _ = try folder(".claude-swap-backup/sessions/2-me_example.com/projects", in: home)
    _ = try folder(".claude-worktrees/some-repo", in: home)
    let roots = Paths.claudeLogRoots(home: home, env: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path]).map(\.path)
    #expect(roots.contains(side.path))
    #expect(roots.contains(profile.appendingPathComponent("projects").path))
    // A link to logs nothing else lists is followed: the walk wouldn't go through it.
    let linked = try folder("elsewhere/projects", in: home)
    try FileManager.default.createSymbolicLink(at: try folder(".claude_linked", in: home).appendingPathComponent("projects"), withDestinationURL: linked)
    let followed = Paths.claudeLogRoots(home: home, env: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path]).map(\.path)
    #expect(followed.contains(linked.path))
    #expect(!followed.contains { $0.contains(".claude_linked") })
    // A shared-history profile links to logs already read.
    #expect(!roots.contains { $0.contains("3-shared") })
    #expect(roots.first == home.appendingPathComponent(".claude/projects").path)

    // A folder that only looks like a login's has nothing to watch.
    #expect(!roots.contains { $0.contains(".claude-worktrees") })

    _ = try folder(".codex_alt/sessions", in: home)
    _ = try folder(".codex_alt/archived_sessions", in: home)
    let codex = Paths.codexLogRoots(home: home, env: ["CODEX_HOME": home.appendingPathComponent(".codex").path]).map(\.path)
    #expect(codex.contains(home.appendingPathComponent(".codex_alt/sessions").path))
    #expect(codex.contains(home.appendingPathComponent(".codex_alt/archived_sessions").path))
}

@Test func aNewLogFolderWaitsForItsOwnImport() async throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try UsageStore(path: home.appendingPathComponent("usage.sqlite"))
    let extra = home.appendingPathComponent(".claude_side/projects")
    // What earlier versions read isn't new, whatever is added beside it.
    let defaults = Paths.defaultLogRoots()
    #expect(try await store.unreadLogRoots(defaults).isEmpty)
    #expect(try await store.unreadLogRoots(defaults + [extra]) == [extra])
    try await store.markLogRootsRead(defaults + [extra])
    #expect(try await store.unreadLogRoots(defaults + [extra]).isEmpty)
    // Marking one doesn't forget the others.
    let another = home.appendingPathComponent(".claude-swap-backup/sessions/2-x/projects")
    try await store.markLogRootsRead([another])
    #expect(try await store.unreadLogRoots(defaults + [extra, another]).isEmpty)
}

@Test func aLinkGivesWayToTheFolderItPointsAt() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let real = try folder(".config/claude/projects", in: home)
    _ = try folder(".claude", in: home)
    let link = home.appendingPathComponent(".claude/projects")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(Paths.unique([link, real]).map(\.path) == [real.path])
    #expect(Paths.unique([real, link]).map(\.path) == [real.path])
}

@Test func theSameMessageInTwoFoldersCountsOnce() async throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let line = #"{"type":"assistant","timestamp":"2026-09-25T10:00:00Z","cwd":"/nonexistent","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":100,"output_tokens":5}}}"# + "\n"
    let a = try folder(".claude/projects/p", in: home), b = try folder(".claude-swap-backup/sessions/2-x/projects/p", in: home)
    try Data(line.utf8).write(to: a.appendingPathComponent("s.jsonl"))
    try Data(line.utf8).write(to: b.appendingPathComponent("s.jsonl"))
    let store = try UsageStore(path: home.appendingPathComponent("usage.sqlite"))
    try await store.ingestClaude(roots: [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".claude-swap-backup/sessions/2-x/projects")])
    let rows = try await store.daily(since: "2026-09-01")
    #expect(rows.map(\.tokens.input).reduce(0, +) == 100)
}

// MARK: claude-swap

private let swapFixture = #"""
{
  "schemaVersion": 1,
  "activeAccountNumber": 2,
  "accounts": [
    { "number": 2, "email": "work@example.com", "organizationName": "Acme", "organizationUuid": "org-1", "isOrganization": true,
      "active": true, "usageStatus": "ok", "alias": "work", "usageFetchedAt": "2026-06-22T20:00:00Z", "usageAgeSeconds": 12.5,
      "usage": {
        "fiveHour": { "pct": 25.0, "resetsAt": "2026-06-22T23:29:59Z", "countdown": "3h", "clock": "23:29" },
        "sevenDay": { "pct": 16.0, "resetsAt": "2026-06-26T17:59:59Z", "expectedPct": 40.0, "aheadOfPace": false },
        "spend": { "used": 12.5, "limit": 100.0, "pct": 12.5, "currency": "USD" },
        "scoped": [ { "name": "Fable", "pct": 71.0, "resetsAt": "2026-06-26T17:59:59Z" }, { "pct": 3 }, "garbage" ]
      } },
    { "number": 3, "email": "side@example.com", "organizationName": "", "organizationUuid": "", "isOrganization": false,
      "active": false, "usageStatus": "token_expired", "usage": null, "lastGoodFetchedAt": "2026-06-22T10:00:00Z",
      "lastGoodUsage": { "sevenDay": { "pct": 88.0, "resetsAt": "2026-06-27T00:00:00Z" } } },
    { "number": 4, "email": "gone@example.com", "organizationName": "", "organizationUuid": "", "isOrganization": false,
      "active": false, "usageStatus": "unavailable", "usage": null, "disabled": true },
    { "number": 5, "email": "api-key-5@token.local", "organizationName": "", "organizationUuid": "", "isOrganization": false,
      "active": false, "usageStatus": "api_key", "usage": null }
  ]
}
"""#

@Test func claudeSwapRowsBecomeAccounts() throws {
    let accounts = try ClaudeSwap.parse(Data(swapFixture.utf8), now: now)
    // API-key accounts have no limits. Disabled ones stay in: that only skips them for rotation.
    #expect(accounts.map(\.name) == ["work@example.com", "side@example.com", "gone@example.com"])

    let work = accounts[0]
    #expect(work.id == LoginIdentity(email: "work@example.com", organization: "org-1").accountID)
    #expect(work.displayName == "work")
    #expect(work.organizationName == "Acme")
    #expect(work.isActive)
    #expect(work.error == nil)
    let snapshot = try #require(work.snapshot)
    #expect(snapshot.plan == nil)
    #expect(snapshot.bankedResets == nil)
    #expect(snapshot.fetchedAt == parseISODate("2026-06-22T20:00:00Z"))
    #expect(snapshot.windows.map(\.id) == ["session", "weekly", "fable-weekly"])
    #expect(snapshot.windows.map(\.usedPercent) == [25, 16, 71])
    #expect(snapshot.windows[0].kind == .session)
    #expect(snapshot.windows[1].kind == .weekly)
    #expect(snapshot.windows[2].isModelSpecific)
    #expect(snapshot.windows[2].title == "Fable Weekly")
    #expect(snapshot.extraUsage == ExtraUsageSpend(used: 12.5, limit: 100, currency: "USD"))
}

@Test func aClaudeSwapRowThatCantBeReadKeepsItsLastGoodNumbers() throws {
    let accounts = try ClaudeSwap.parse(Data(swapFixture.utf8), now: now)
    let side = accounts[1]
    #expect(side.error == .loginExpired)
    #expect(side.loginHint?.contains("cswap add") == true)
    #expect(side.snapshot?.windows.map(\.usedPercent) == [88])
    #expect(side.snapshot?.fetchedAt == parseISODate("2026-06-22T10:00:00Z"))
    let gone = accounts[2]
    #expect(gone.snapshot == nil)
    #expect(gone.isStale)
}

@Test func unknownClaudeSwapReportsAreRejected() {
    for bad in [
        #"{"schemaVersion":2,"accounts":[]}"#,
        #"{"accounts":[]}"#,
        #"{"schemaVersion":1,"error":{"type":"X","message":"no"}}"#,
        #"{"schemaVersion":1,"accounts":"nope"}"#,
        "not json",
    ] {
        #expect(throws: ProviderError.self) { try ClaudeSwap.parse(Data(bad.utf8)) }
    }
    #expect(try! ClaudeSwap.parse(Data(#"{"schemaVersion":1,"activeAccountNumber":null,"accounts":[]}"#.utf8)).isEmpty)
}

// Serialized with the other process tests: these keep a CPU busy, and those run to a deadline.
extension ProviderProcessTests {
    @Test func onlyTheListCommandIsEverRun() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("args")
        let script = home.appendingPathComponent("cswap")
        try Data("#!/bin/sh\necho \"$@\" > \"\(log.path)\"\ncat <<'JSON'\n\(swapFixture)\nJSON\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // A non-zero exit is still read: handled failures report on stdout.
        #expect(try ClaudeSwap.read(executable: script.path).count == 3)
        #expect(try String(contentsOf: log, encoding: .utf8) == "list --json\n")
    }

    @Test func cswapIsStoppedWhenItHangsOrSaysTooMuch() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("cswap")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = Date()
        let output = try ClaudeSwap.run(executable: script.path, timeout: 0.2)
        #expect(output.isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(throws: ProviderError.self) { try ClaudeSwap.parse(output) }

        try Data("#!/bin/sh\nexec yes\n".utf8).write(to: script)
        #expect(throws: ProviderError.self) { _ = try ClaudeSwap.run(executable: script.path) }

        // One that ignores being asked to stop can't hold up the refresh either.
        try Data("#!/bin/sh\ntrap '' TERM\nexec yes\n".utf8).write(to: script)
        let stubborn = Date()
        #expect(throws: ProviderError.self) { _ = try ClaudeSwap.run(executable: script.path) }
        #expect(Date().timeIntervalSince(stubborn) < 5)
    }
}

// MARK: Readings per Account

private let weekFrom = Date(timeIntervalSince1970: 1_800_000_000)

private func weekly(used: Double, resets: Date, read: Date, plan: String? = "Max 5x") -> ProviderSnapshot {
    ProviderSnapshot(provider: .claude, plan: plan, windows: [
        LimitWindow(id: "weekly", title: "Weekly", usedPercent: used, resetsAt: resets, durationSeconds: 7 * 86400),
    ], fetchedAt: read)
}

@Test func eachAccountKeepsItsOwnReadings() async throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try UsageStore(path: home.appendingPathComponent("usage.sqlite"))
    let reset = weekFrom.addingTimeInterval(5 * 86400)
    try await store.recordLimitReadings(weekly(used: 20, resets: reset, read: weekFrom), account: "a")
    try await store.recordLimitReadings(weekly(used: 50, resets: reset, read: weekFrom), account: "b")
    let readings = try await store.limitReadings(provider: .claude).sorted { $0.account < $1.account }
    #expect(readings.map(\.account) == ["a", "b"])
    #expect(readings.map(\.usedPercent) == [20, 50])
}

@Test func anAccountClaimsAReadingFromBeforeAccounts() async throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try UsageStore(path: home.appendingPathComponent("usage.sqlite"))
    let reset = weekFrom.addingTimeInterval(5 * 86400)
    try await store.recordLimitReadings(weekly(used: 20, resets: reset, read: weekFrom))
    try await store.recordLimitReadings(weekly(used: 20, resets: reset, read: weekFrom.addingTimeInterval(60)), account: "a")
    let readings = try await store.limitReadings(provider: .claude)
    #expect(readings.count == 1)
    #expect(readings[0].account == "a")
    #expect(readings[0].readAt == weekFrom)
}

@Test func accountsInAPoolLeaveOldReadingsUnclaimed() async throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try UsageStore(path: home.appendingPathComponent("usage.sqlite"))
    let reset = weekFrom.addingTimeInterval(5 * 86400)
    try await store.recordLimitReadings(weekly(used: 90, resets: reset, read: weekFrom))
    try await store.recordLimitReadings(weekly(used: 20, resets: reset, read: weekFrom), account: "a", claiming: false)
    try await store.recordLimitReadings(weekly(used: 25, resets: reset, read: weekFrom), account: "a", claiming: false)
    let readings = try await store.limitReadings(provider: .claude).sorted { $0.account < $1.account }
    #expect(readings.map(\.account) == ["", "a"])
    #expect(readings.map(\.usedPercent) == [90, 25])
}

@Test func anAccountsOwnReadingReplacesAnOldOneForTheSameWindow() {
    let reset = weekFrom.addingTimeInterval(5 * 86400)
    let old = LimitReading(windowID: "weekly", resetsAt: reset.addingTimeInterval(30), duration: 7 * 86400, plan: nil, usedPercent: 90, readAt: weekFrom)
    let olderStill = LimitReading(windowID: "weekly", resetsAt: reset.addingTimeInterval(-7 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 40, readAt: weekFrom)
    let own = LimitReading(windowID: "weekly", resetsAt: reset, duration: 7 * 86400, plan: nil, usedPercent: 20, readAt: weekFrom, account: "a")
    let other = LimitReading(windowID: "weekly", resetsAt: reset, duration: 7 * 86400, plan: nil, usedPercent: 70, readAt: weekFrom, account: "b")
    #expect(LimitReading.forOnly(account: "a", in: [old, olderStill, own, other]).map(\.usedPercent) == [20, 40])

    // Old readings don't push the total past what's kept for a window.
    let many = (1...12).map { week in
        LimitReading(windowID: "weekly", resetsAt: reset.addingTimeInterval(Double(-week) * 7 * 86400), duration: 7 * 86400, plan: nil, usedPercent: Double(week), readAt: weekFrom)
    }
    let kept = LimitReading.forOnly(account: "a", in: many + [own])
    #expect(kept.count == 8)
    #expect(kept.first?.account == "a")
    #expect(kept.last?.usedPercent == 7)
}

@Test(arguments: [7, 8]) func readingsMigrateUnclaimedFromBeforeAccounts(version: Int) async throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let url = home.appendingPathComponent("usage.sqlite")
    _ = try UsageStore(path: url)
    let db = try SQLiteDB(path: url.path)
    try db.exec("""
    DROP TABLE limit_reading;
    CREATE TABLE limit_reading (
        provider TEXT NOT NULL, window TEXT NOT NULL, resets_at INTEGER NOT NULL, duration INTEGER NOT NULL,
        plan TEXT, used_bp INTEGER NOT NULL, read_at INTEGER NOT NULL, plan_changed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (provider, window, resets_at)) WITHOUT ROWID;
    INSERT INTO limit_reading VALUES ('claude', 'weekly', 1800000000, 604800, 'Pro', 2500, 1799900000, 0);
    PRAGMA user_version = \(version);
    """)
    let store = try UsageStore(path: url)
    #expect(try db.run("PRAGMA user_version").first?.first?.int == 9)
    let readings = try await store.limitReadings(provider: .claude)
    #expect(readings.count == 1)
    #expect(readings[0].account == "")
    #expect(readings[0].usedPercent == 25)
}

// MARK: A Pool's Plan Value

private let dayOne = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private let priced = PriceTable(prices: [.claude: ["m": ModelPrice(input: 1, output: 1)]], fetchedAt: nil)

private func daySpend(_ offset: Int, _ dollars: Double) -> DailyUsage {
    DailyUsage(
        day: DayKey.string(for: dayOne.addingTimeInterval(Double(offset) * 86400), calendar: utc),
        provider: .claude, model: "m", project: "", tokens: TokenCounts(input: Int64(dollars * 1_000_000)))
}

/// A finished week that began on `from` days after `dayOne`.
private func finished(_ account: String, from: Int, used: Double, plan: String? = nil) -> LimitReading {
    let start = dayOne.addingTimeInterval(Double(from) * 86400)
    return LimitReading(
        windowID: "weekly", resetsAt: start.addingTimeInterval(7 * 86400), duration: 7 * 86400,
        plan: plan, usedPercent: used, readAt: start.addingTimeInterval(7 * 86400 - 1), account: account)
}

@Test func aPoolIsWorthItsCostOverTheSharesUsedBetweenAccounts() throws {
    // $300 over a week that took 40% of one Account and 20% of another: 100% of one is worth $500,
    // and a full week of both is $1000.
    let readings = [finished("a", from: 0, used: 40), finished("b", from: 0, used: 20)]
    let usage = (0..<3).map { daySpend($0, 100) }
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: readings, usage: usage, hours: [], prices: priced,
        now: dayOne.addingTimeInterval(20 * 86400), calendar: utc))
    #expect(abs(v.fullWindow! - 1000) < 1e-6)
    #expect(v.usedPercent == 60)
    // Without every plan there's no per-dollar figure.
    #expect(v.perDollar == nil)
    #expect(v.monthlyPrice == nil)
}

@Test func aPoolsPerDollarUsesEveryPlansPrice() throws {
    let readings = [finished("a", from: 0, used: 40), finished("b", from: 0, used: 20)]
    let usage = [daySpend(0, 300)]
    let later = dayOne.addingTimeInterval(20 * 86400)
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: ["Max 20x", "Pro"], readings: readings, usage: usage, hours: [], prices: priced, now: later, calendar: utc))
    #expect(v.monthlyPrice == 220)
    #expect(abs(v.perDollar! - 1000 * PlanValue.weeksPerMonth / 220) < 1e-6)
    let mixed = try #require(PlanValue.buildPool(
        provider: .claude, plans: ["Max 20x", nil], readings: readings, usage: usage, hours: [], prices: priced, now: later, calendar: utc))
    #expect(mixed.perDollar == nil)
    #expect(mixed.fullWindow != nil)
}

@Test func aPoolWaitsForAReadingFromEveryAccount() throws {
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: [finished("a", from: 0, used: 50)], usage: [daySpend(0, 100)], hours: [], prices: priced,
        now: dayOne.addingTimeInterval(20 * 86400), calendar: utc))
    #expect(v.fullWindow == nil)
}

@Test func aPoolStartsWhereEveryAccountHasReadings() throws {
    // Account b only appears on day 7, so a's first week and that week's spending don't count.
    let readings = [finished("a", from: 0, used: 90), finished("a", from: 7, used: 30), finished("b", from: 7, used: 30)]
    let usage = [daySpend(1, 5000), daySpend(8, 300)]
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: readings, usage: usage, hours: [], prices: priced,
        now: dayOne.addingTimeInterval(20 * 86400), calendar: utc))
    #expect(abs(v.fullWindow! - 1000) < 1e-6)
}

@Test func aPoolShowsNothingUntilTheSharesAddUpAndIgnoresOldReadings() throws {
    let usage = [daySpend(0, 100)]
    let later = dayOne.addingTimeInterval(20 * 86400)
    let few = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: [finished("a", from: 0, used: 4), finished("b", from: 0, used: 4)],
        usage: usage, hours: [], prices: priced, now: later, calendar: utc))
    #expect(few.fullWindow == nil)
    #expect(few.usedPercent == 8)
    let old = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: [finished("", from: 0, used: 90)],
        usage: usage, hours: [], prices: priced, now: later, calendar: utc))
    #expect(old.fullWindow == nil)
}

@Test func anEarlyResetEndsAPoolsWindowAtItsLastReading() throws {
    // Account a used 90% and reset early on day 2. Its old window's stated Reset is still to come,
    // but only its last reading's share and the new window count from when b appears, on day 2.
    let now = dayOne.addingTimeInterval(3 * 86400)
    let reset = dayOne.addingTimeInterval(7 * 86400)
    let old = LimitReading(windowID: "weekly", resetsAt: reset, duration: 7 * 86400, plan: nil, usedPercent: 90, readAt: dayOne.addingTimeInterval(2 * 86400), account: "a")
    let newA = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(9 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 10, readAt: now, account: "a")
    let newB = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(9 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 20, readAt: now, account: "b")
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: [old, newA, newB], usage: [daySpend(2, 300)], hours: [], prices: priced, now: now, calendar: utc))
    #expect(abs(v.usedPercent - 30) < 1e-6)
    #expect(abs(v.fullWindow! - 2000) < 1e-6)
}

@Test func aPlanChangeInTheNewWindowStillEndsTheOldOne() throws {
    let now = dayOne.addingTimeInterval(3 * 86400)
    let old = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(7 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 90, readAt: dayOne.addingTimeInterval(2 * 86400), account: "a")
    var changed = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(9 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 40, readAt: now, account: "a")
    changed.planChanged = true
    let b = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(9 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 50, readAt: now, account: "b")
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: [old, changed, b], usage: [daySpend(2, 300)], hours: [], prices: priced, now: now, calendar: utc))
    // Account a's old window ended at its last reading on day 2, so only b's share is left.
    #expect(abs(v.usedPercent - 50) < 1e-6)
}

@Test func aPoolCountsAnOpenWindowByTheTimeSoFar() throws {
    // Half of b's open week lies inside the time both Accounts have readings.
    let now = dayOne.addingTimeInterval(10 * 86400)
    let openA = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(12 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 50, readAt: now, account: "a")
    let openB = LimitReading(windowID: "weekly", resetsAt: dayOne.addingTimeInterval(13 * 86400), duration: 7 * 86400, plan: nil, usedPercent: 50, readAt: now, account: "b")
    // A's window opened on day 5 and B's on day 6, so counting starts on day 6: 4 of a's 5 days, all of b's.
    let v = try #require(PlanValue.buildPool(
        provider: .claude, plans: [nil, nil], readings: [openA, openB], usage: [daySpend(7, 90)], hours: [], prices: priced, now: now, calendar: utc))
    #expect(abs(v.usedPercent - 90) < 1e-6)
    #expect(abs(v.fullWindow! - 200) < 1e-6)
}
