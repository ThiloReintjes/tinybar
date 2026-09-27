import Foundation
import SubarCore

// Developer tool: exercises SubarCore without the UI.
//   subar-cli limits [--browser]  fetch limits (optionally allowing the browser fallback)
//   subar-cli cookies         check which browser holds session cookies
//   subar-cli ingest [db]     ingest Codex logs into a store
//   subar-cli usage [db]      print usage summaries

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "limits"
let dbURL = args.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? Paths.appSupport.appendingPathComponent("usage.sqlite")

func printLimits(browser: Bool) async {
    let providers: [any UsageProvider] = [
        ClaudeProvider(allowBrowser: { browser }),
        CodexProvider(allowBrowser: { browser }),
        GeminiProvider(),
        CursorProvider(),
    ]
    for provider in providers {
        do {
            let s = try await provider.fetch()
            print("\(provider.id.displayName) \(s.plan ?? "") [source: \(s.source.rawValue)]")
            for w in s.windows {
                print(String(format: "  %-24@ %5.1f%% left  resets in %@", w.title as NSString, w.remainingPercent, Format.countdown(to: w.resetsAt) as NSString))
            }
            if let c = s.credits, c.hasCredits { print("  credits: \(c.balance.map { String(format: "%.2f", $0) } ?? "-")") }
            if let e = s.extraUsage { print(String(format: "  extra usage: %.2f / %@ %@", e.used, e.limit.map { String(format: "%.2f", $0) } ?? "∞", e.currency)) }
            for b in s.bankedResets ?? [] where b.isAvailable {
                print("  banked reset: \(b.title ?? b.id) expires \(b.expiresAt.map { "\($0)" } ?? "never")")
            }
        } catch {
            print("\(provider.id.displayName) error: \(error.localizedDescription)")
        }
    }
}

func printCookies() {
    for (domain, name) in [("claude.ai", "sessionKey"), ("chatgpt.com", "__Secure-next-auth.session-token"), ("cursor.com", "WorkosCursorSessionToken")] {
        if let found = BrowserCookies.find(domain: domain, required: [name]) {
            let value = BrowserCookies.joined(name, in: found.cookies) ?? ""
            print("\(domain): found \(name) in \(found.browser) (\(value.count) chars, prefix \(value.prefix(7))…)")
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

switch command {
case "limits": await printLimits(browser: args.contains("--browser"))
case "cookies": printCookies()
case "web": await printWeb()
case "ingest": try await ingest()
case "usage": try await usage()
default: print("usage: subar-cli [limits [--browser]|cookies|ingest|usage] [db-path]")
}

// `subar-cli web`: exercises only the browser-cookie paths.
func printWeb() async {
    for provider in ProviderID.allCases where provider != .gemini {
        do {
            let (browser, s) = try await BrowserFallback.fetch(provider)
            print("\(provider.displayName) via \(browser): " + s.windows.map { "\($0.title) \(Int($0.remainingPercent))% left" }.joined(separator: ", "))
        } catch {
            print("\(provider.displayName) web: \(error.localizedDescription)")
        }
    }
}
