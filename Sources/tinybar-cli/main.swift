import Foundation
import TinybarCore

// Developer tool: exercises TinybarCore without the UI.
//   tinybar-cli limits [--browser] [--swap] [--provider=<id>]  fetch limits (optionally allowing the
//                               browser fallback, or reading claude-swap's accounts)
//   tinybar-cli cookies         check which browser holds session cookies
//   tinybar-cli ingest [db]     ingest Codex logs into a store
//   tinybar-cli usage [db]      print usage summaries

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "limits"
let dbURL = args.dropFirst().first(where: { !$0.hasPrefix("--") }).map { URL(fileURLWithPath: $0) }
    ?? Paths.appSupport.appendingPathComponent("usage.sqlite")

func printWindows(_ s: ProviderSnapshot) {
    for w in s.windows {
        let runOut = w.runOutTime(asOf: s.fetchedAt).map { "  runs out in \(Format.countdown(to: $0))" } ?? ""
        print(String(format: "  %-24@ %5.1f%% left  resets in %@%@", w.title as NSString, w.remainingPercent, Format.countdown(to: w.resetsAt) as NSString, runOut as NSString))
    }
}

func printLimits(browser: Bool, swap: Bool) async {
    let providers: [any UsageProvider] = [
        ClaudeProvider(allowBrowser: { browser }),
        CodexProvider(allowBrowser: { browser }),
        GeminiProvider(),
        CursorProvider(),
        OpenCodeProvider(),
    ]
    let only = args.first { $0.hasPrefix("--provider=") }.map { String($0.dropFirst(11)) }
    for provider in providers where only == nil || provider.id.rawValue == only {
        do {
            let s = try await provider.fetch()
            print("\(provider.id.displayName) \(s.plan ?? "") [source: \(s.source.rawValue)]")
            printWindows(s)
            if let c = s.credits, c.hasCredits { print("  credits: \(c.balance.map { String(format: "%.2f", $0) } ?? "-")") }
            if let e = s.extraUsage { print(String(format: "  extra usage: %.2f / %@ %@", e.used, e.limit.map { String(format: "%.2f", $0) } ?? "∞", e.currency)) }
            for b in s.bankedResets ?? [] where b.isAvailable {
                print("  banked reset: \(b.title ?? b.id) expires \(b.expiresAt.map { "\($0)" } ?? "never")")
            }
        } catch {
            print("\(provider.id.displayName) error: \(error.localizedDescription)")
        }
    }
    for folder in LoginFolders.find() where only == nil || only == folder.provider.rawValue {
        do {
            let s = try await folder.source.fetch()
            print("\(folder.provider.displayName) ~/\(folder.id) \(s.plan ?? "")")
            printWindows(s)
        } catch {
            print("\(folder.provider.displayName) ~/\(folder.id) error: \(error.localizedDescription)")
        }
    }
    if swap, only == nil || only == ProviderID.claude.rawValue, let cswap = ClaudeSwap.locate() {
        do {
            for account in try ClaudeSwap.read(executable: cswap) {
                print("claude-swap \(account.displayName)\(account.isActive ? " [active]" : "")\(account.error.map { " error: \($0.localizedDescription)" } ?? "")")
                if let s = account.snapshot { printWindows(s) }
            }
        } catch {
            print("claude-swap error: \(error.localizedDescription)")
        }
    }
}

func printCookies() {
    for (domain, name) in [("claude.ai", "sessionKey"), ("chatgpt.com", "__Secure-next-auth.session-token"), ("cursor.com", "WorkosCursorSessionToken")] {
        if let found = BrowserCookies.find(domain: domain, required: [name]) {
            let value = BrowserCookies.joined(name, in: found.cookies) ?? ""
            print("\(domain): found \(name) in \(found.browser) (\(value.count) chars)")
        } else {
            print("\(domain): no \(name) cookie found")
        }
    }
}

func ingest() async throws {
    let store = try UsageStore(path: dbURL)
    let start = Date()
    let r = try await store.ingestAll { p in
        if p.filesDone % 5000 < 200 || p.filesDone == p.filesTotal {
            FileHandle.standardError.write("  \(p.filesDone)/\(p.filesTotal)\n".data(using: .utf8)!)
        }
    }
    print(String(format: "files=%d bytes=%.1fMB records=%d in %.1fs",
                 r.filesScanned, Double(r.bytesRead) / 1e6, r.recordsAdded, Date().timeIntervalSince(start)))
}

func usage() async throws {
    let store = try UsageStore(path: dbURL)
    let pricing = PricingService()
    let prices = await pricing.refreshIfNeeded()
    let rows = try await store.daily(since: DayKey.daysAgo(29))
    for range in UsageRange.allCases {
        let s = UsageSummary.build(rows: rows, range: range, prices: prices)
        print("\(range.label): \(Format.tokens(s.totalTokens)) tokens, \(Format.cost(s.cost))\(s.hasUnpriced ? " (+unpriced)" : "")")
        for m in s.models.prefix(4) { print("   model   \(m.name): \(Format.tokens(m.tokens)) \(Format.cost(m.cost))") }
        for p in s.projects.prefix(4) { print("   project \(p.name): \(Format.tokens(p.tokens)) \(Format.cost(p.cost))") }
    }
}

/// Raw activity counters per provider and key since a day (default: everything), for checking
/// against an independent count of the logs.
func stats() async throws {
    let store = try UsageStore(path: dbURL)
    let since = args.first { $0.hasPrefix("--since=") }.map { String($0.dropFirst(8)) } ?? "0000"
    var totals: [String: Int64] = [:]
    for row in try await store.stats(since: since) {
        let key = row.key.hasPrefix(StatKey.hourPrefix) ? "hour.*" : row.key.hasPrefix(StatKey.hourTokensPrefix) ? "tokens.hour.*" : row.key
        if StatKey.isMaximum(row.key) {
            totals["\(row.provider.rawValue) \(key)"] = max(totals["\(row.provider.rawValue) \(key)"] ?? 0, row.value)
        } else {
            totals["\(row.provider.rawValue) \(key)", default: 0] += row.value
        }
    }
    for (k, v) in totals.sorted(by: { $0.key < $1.key }) { print("\(k) = \(v)") }
}

func backfill() async throws {
    let store = try UsageStore(path: dbURL)
    guard !(try await store.hasCompletedStatsBackfill()) else { return }
    let start = Date()
    let r = try await store.backfillStats()
    print(String(format: "backfill files=%d bytes=%.1fMB in %.1fs", r.filesScanned, Double(r.bytesRead) / 1e6, Date().timeIntervalSince(start)))
}

func backfillLong() async throws {
    let store = try UsageStore(path: dbURL)
    guard !(try await store.hasCompletedLongContextBackfill()) else { return }
    let start = Date()
    let r = try await store.backfillLongContext()
    print(String(format: "long-context files=%d bytes=%.1fMB in %.1fs", r.filesScanned, Double(r.bytesRead) / 1e6, Date().timeIntervalSince(start)))
}

func printStatus() async {
    for id in ProviderID.allCases where StatusFeed.hasFeed(id) {
        do {
            let found = try await StatusFeed.fetch(id)
            print("\(id.displayName): " + (found.isEmpty ? "no incidents" : found.map { "\($0.severity.label): \($0.title) [\($0.components.joined(separator: ", "))] \($0.url)" }.joined(separator: "; ")))
        } catch {
            print("\(id.displayName): \(error.localizedDescription)")
        }
    }
    if let r = try? await ReleaseCheck.latest() { print("latest release: \(r.version) \(r.url)") }
}

switch command {
case "limits": await printLimits(browser: args.contains("--browser"), swap: args.contains("--swap"))
case "cookies": printCookies()
case "web": await printWeb()
case "ingest": try await ingest()
case "usage": try await usage()
case "stats": try await stats()
case "backfill": try await backfill()
case "backfill-long": try await backfillLong()
case "status": await printStatus()
default: print("usage: tinybar-cli [limits [--browser] [--provider=<id>]|cookies|ingest|usage|stats|backfill|backfill-long|status] [db-path]")
}

// `tinybar-cli web`: exercises only the browser-cookie paths.
func printWeb() async {
    for provider in ProviderID.allCases where provider != .gemini && provider != .opencode {
        do {
            let (browser, s) = try await BrowserFallback.fetch(provider)
            print("\(provider.displayName) via \(browser): " + s.windows.map { "\($0.title) \(Int($0.remainingPercent))% left" }.joined(separator: ", "))
        } catch {
            print("\(provider.displayName) web: \(error.localizedDescription)")
        }
    }
}
