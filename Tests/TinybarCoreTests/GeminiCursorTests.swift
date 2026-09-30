import Foundation
@testable import TinybarCore
import Testing

// MARK: Gemini (agy /usage report)

private let agyReport = #"""
{"conversation_id":"","status":"SUCCESS","response":"…","command":{"name":"usage","data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.8,"reset_time":"2026-10-07T11:50:26Z"},
  {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.25,"reset_time":"2026-09-30T16:50:26Z"}]},
 {"name":"Claude and GPT models","buckets":[
  {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-07T11:50:26Z"},
  {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.5}]}]}}}
"""#

@Test func mapsAntigravityUsageReport() throws {
    let s = try AntigravityCLI.snapshot(fromUsageReport: Data(agyReport.utf8))
    #expect(s.provider == .gemini)
    #expect(s.source == .cliProcess)
    #expect(s.windows.map(\.id) == ["session", "weekly", "third-party-session", "third-party-weekly"])
    #expect(s.windows[0].kind == .session && !s.windows[0].isModelSpecific)
    #expect(s.windows[0].remainingPercent == 25)
    #expect(s.windows[1].remainingPercent == 80)
    #expect(s.windows[2].title == "Claude & GPT 5-hour" && s.windows[2].isModelSpecific)
    #expect(s.windows[2].resetsAt == nil)
    #expect(s.windows[1].resetsAt == parseISODate("2026-10-07T11:50:26Z"))
}

@Test func antigravityFailureIsNotASnapshot() {
    let signedOut = #"{"status":"ERROR","response":"Please sign in to continue"}"#
    #expect(throws: ProviderError.loginExpired) { try AntigravityCLI.snapshot(fromUsageReport: Data(signedOut.utf8)) }
    #expect(throws: ProviderError.self) { try AntigravityCLI.snapshot(fromUsageReport: Data("not json".utf8)) }
}

// MARK: Cursor (usage-summary)

private func cursorSummary(_ json: String) throws -> ProviderSnapshot {
    CursorUsageAPI.snapshot(from: try JSONDecoder().decode(CursorUsageAPI.Summary.self, from: Data(json.utf8)))
}

@Test func mapsCursorPlanUsage() throws {
    let s = try cursorSummary(#"""
    {"membershipType":"pro","billingCycleStart":"2026-09-23T10:27:04.000Z","billingCycleEnd":"2026-10-23T10:27:04.000Z",
     "individualUsage":{"plan":{"enabled":true,"used":388,"limit":2000,"totalPercentUsed":19.4,"autoPercentUsed":2.5,"apiPercentUsed":36.3},
                        "onDemand":{"enabled":true,"used":450,"limit":1000}}}
    """#)
    #expect(s.plan == "Pro")
    #expect(s.windows.map(\.id) == ["monthly", "monthly-auto", "monthly-api"])
    #expect(abs(s.windows[0].remainingPercent - 80.6) < 0.001)
    #expect(s.windows[0].resetsAt == parseISODate("2026-10-23T10:27:04.000Z"))
    #expect(s.windows[0].durationSeconds == 30 * 86400)
    #expect(s.windows[0].kind == .other)
    #expect(s.windows[1].isModelSpecific && s.windows[2].isModelSpecific)
    #expect(s.extraUsage == ExtraUsageSpend(used: 4.5, limit: 10, currency: "USD"))
}

@Test func cursorFallsBackToCentsAndTeamPool() throws {
    let cents = try cursorSummary(#"{"individualUsage":{"plan":{"used":500,"limit":2000}}}"#)
    #expect(cents.windows.map(\.remainingPercent) == [75])
    let pooled = try cursorSummary(#"{"membershipType":"enterprise","teamUsage":{"pooled":{"used":100,"limit":400}}}"#)
    #expect(pooled.windows.map(\.remainingPercent) == [75])
    #expect(pooled.plan == "Enterprise")
    let unlimited = try cursorSummary(#"{"isUnlimited":true,"individualUsage":{"plan":{"totalPercentUsed":10}}}"#)
    #expect(unlimited.windows.isEmpty)
}

@Test func cursorAppTokenBecomesSessionCookie() {
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    let token = "h.\(b64(#"{"sub":"auth0|user_ABC123","exp":4102444800}"#)).sig"
    #expect(CursorAppAuth.cookieHeader(accessToken: token) == "WorkosCursorSessionToken=user_ABC123%3A%3A\(token)")
    let bad = "h.\(b64(#"{"sub":"auth0|x;y"}"#)).sig"
    #expect(CursorAppAuth.cookieHeader(accessToken: bad) == nil)
    #expect(CursorAppAuth.decode(Data("\"tok\"".utf8)) == "tok")
    #expect(CursorAppAuth.decode("tok".data(using: .utf16LittleEndian)!) == "tok")
}
