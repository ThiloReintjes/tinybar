import Foundation
import SubarCore

// Developer tool: exercises SubarCore without the UI.
//   subar-cli limits          fetch Codex limits
//   subar-cli ingest [db]     ingest Codex logs into a store
//   subar-cli usage [db]      print usage summaries

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "limits"
let dbURL = args.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? Paths.appSupport.appendingPathComponent("usage.sqlite")

func printLimits() async {
    do {
        let s = try await CodexProvider().fetch()
        print("Codex \(s.plan ?? "")")
        for w in s.windows {
            print(String(format: "  %-24@ %5.1f%%  resets in %@", w.title as NSString, w.usedPercent, Format.countdown(to: w.resetsAt) as NSString))
        }
        if let c = s.credits { print("  credits: \(c.balance.map { String(format: "%.2f", $0) } ?? "-") unlimited=\(c.unlimited)") }
        for b in s.bankedResets ?? [] {
            print("  banked reset: \(b.title ?? b.id) [\(b.status)] expires \(b.expiresAt.map { "\($0)" } ?? "never")")
        }
    } catch {
        print("Codex error: \(error.localizedDescription)")
    }
}

func ingest() async throws {
    let store = try UsageStore(path: dbURL)
    let start = Date()
    let r = try await store.ingestCodex { p in
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
case "limits": await printLimits()
case "ingest": try await ingest()
case "usage": try await usage()
default: print("usage: subar-cli [limits|ingest|usage] [db-path]")
}
