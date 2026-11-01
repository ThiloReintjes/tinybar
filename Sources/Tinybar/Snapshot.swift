import AppKit
import SwiftUI
import TinybarCore

/// Developer aid: `Tinybar --snapshot out.png` renders the popover (or with `--stats`, the Stats
/// card) with live data and exits.
enum PopoverSnapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return }
        guard i + 1 < args.count, !args[i + 1].isEmpty, !args[i + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("--snapshot requires an output path\n".utf8))
            exit(2)
        }
        let out = URL(fileURLWithPath: args[i + 1])
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue
        else { fail("Output directory does not exist.") }
        let model = AppModel(settings: Settings())
        Task { @MainActor in
            // `--incident claude:partialOutage` stands in for a status page reporting one.
            if let i = args.firstIndex(of: "--incident"), i + 1 < args.count {
                let parts = args[i + 1].split(separator: ":").map(String.init)
                if let name = parts.first, let id = ProviderID(rawValue: name) {
                    let severity: Incident.Severity = switch parts.count > 1 ? parts[1] : "" {
                    case "degraded": .degraded
                    case "majorOutage": .majorOutage
                    case "maintenance": .maintenance
                    default: .partialOutage
                    }
                    model.showForSnapshot(Incident(
                        provider: id, title: "Elevated errors for Claude Opus 5.5", severity: severity,
                        components: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"],
                        url: URL(string: "https://stspg.io/bzc81gbv1b99")!, updatedAt: Date().addingTimeInterval(-1800)))
                }
            }
            // `--menubar` renders the status item's icon at 4x, with and without an incident light.
            if args.contains("--menubar") {
                for dark in [false, true] {
                    var row: [NSImage] = []
                    for alert in [nil, NSColor.systemOrange, .systemRed] {
                        row.append(RingIcon.image(fraction: 0.62, label: "62%", tint: RingIcon.tint(.claude), dark: dark, alert: alert))
                        row.append(RingIcon.image(fraction: 0.62, label: nil, tint: nil, dark: dark, alert: alert))
                    }
                    let scale: CGFloat = 4, pad: CGFloat = 8
                    let w = row.reduce(pad) { $0 + $1.size.width + pad }, h = (row.map(\.size.height).max() ?? 16) + 2 * pad
                    let canvas = NSImage(size: NSSize(width: w * scale, height: h * scale), flipped: false) { r in
                        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                        r.fill()
                        var x = pad
                        for img in row {
                            img.draw(in: NSRect(x: x * scale, y: pad * scale, width: img.size.width * scale, height: img.size.height * scale))
                            x += img.size.width + pad
                        }
                        return true
                    }
                    guard let tiff = canvas.tiffRepresentation else { fail("Couldn't render the menu bar.") }
                    write(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                          to: URL(fileURLWithPath: out.deletingPathExtension().path + (dark ? ".menubar.dark.png" : ".menubar.png")))
                }
                exit(0)
            }
            // `--accounts one|stack|many` stands in for several logins, with made-up names and limits.
            // It needs no limits from anyone, so it doesn't spend a Provider's rate limit.
            if let a = args.firstIndex(of: "--accounts") {
                await model.refreshUsageForSnapshot()
                let kind = a + 1 < args.count ? args[a + 1] : "stack"
                AccountsDemo.show(in: model, kind: kind)
            } else {
                await model.refresh(force: true)
            }
            // `--update 0.5.0[:preparing|:failed]` shows the update pill.
            if let u = args.firstIndex(of: "--update"), u + 1 < args.count {
                let parts = args[u + 1].split(separator: ":").map(String.init)
                guard let version = parts.first else { exit(2) }
                let r = Release(version: version, url: URL(string: "https://github.com/ThiloReintjes/tinybar/releases")!)
                model.updater.showForSnapshot(parts.count < 2 ? .available(r)
                    : parts[1] == "preparing" ? .preparing(r) : .failed(r, "Homebrew doesn't list \(version) yet."))
            }
            // `--stats [--range week|month|all] [--model <id>] [--page commands|models|languages|plans]`
            // renders a Stats card instead, as Copy image does.
            if args.contains("--stats") {
                var range = StatsRange.month
                if let r = args.firstIndex(of: "--range"), r + 1 < args.count { range = StatsRange(rawValue: args[r + 1]) ?? .month }
                let picked = args.firstIndex(of: "--model").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                // `--hover x,y` renders the tip for that point of the card, as if pointed at.
                if let h = args.firstIndex(of: "--hover"), h + 1 < args.count {
                    let xy = args[h + 1].split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2 { StatsCard.snapshotHover = CGPoint(x: xy[0], y: xy[1]) }
                }
                // The window too, chrome included, as `<out>.window.png`.
                UserDefaults.standard.set(range.rawValue, forKey: "statsRange")
                let page = args.firstIndex(of: "--page").flatMap { $0 + 1 < args.count ? StatsPage(rawValue: args[$0 + 1]) : nil } ?? .overview
                UserDefaults.standard.set(page.rawValue, forKey: "statsPage")
                let host = NSHostingView(rootView: StatsView(model: model, picked: picked))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(900))
                if StatsCard.snapshotHover != nil {
                    NotificationCenter.default.post(name: StatsCard.snapshotHoverNotification, object: nil)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("Couldn't render the Stats window.") }
                host.cacheDisplay(in: host.bounds, to: rep)
                write(rep.representation(using: .png, properties: [:]),
                      to: URL(fileURLWithPath: out.deletingPathExtension().path + ".window.png"))
                window.orderOut(nil)
                guard let summary = await model.statsSummary(range, model: picked) else { fail("Couldn't load Stats.") }
                for (scheme, suffix) in [(ColorScheme.dark, ".dark"), (.light, "")] {
                    guard let image = StatsCard.image(summary, page: page, plans: model.plans, scheme: scheme), let tiff = image.tiffRepresentation
                    else { fail("Couldn't render the Stats card.") }
                    write(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                          to: URL(fileURLWithPath: out.deletingPathExtension().path + suffix + ".png"))
                }
                exit(0)
            }
            // `--page claude` or `--page settings` renders that page instead of the overview.
            var page = Page.overview
            if let p = args.firstIndex(of: "--page"), p + 1 < args.count {
                page = args[p + 1] == "settings" ? .settings : args[p + 1] == "about" ? .about : ProviderID(rawValue: args[p + 1]).map(Page.provider) ?? .overview
            }
            // `--backdrop` stands in for the worst case behind the glass: a bright window under a
            // dark popover, a dark one under a light popover.
            let backdrop = args.contains("--backdrop")
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ".dark"), (.aqua, "")] {
                let fill = !backdrop ? Color(nsColor: .windowBackgroundColor)
                    : appearance == .darkAqua ? Color(white: 0.58) : Color(white: 0.22)
                let host = NSHostingView(rootView: PopoverView(model: model, page: page).background(fill))
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.backgroundColor = .windowBackgroundColor
                window.contentView = host
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("Couldn't render the popover.") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: out.deletingPathExtension().path + suffix + ".png")
                write(rep.representation(using: .png, properties: [:]), to: url)
                window.orderOut(nil)
            }
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    private static func write(_ data: Data?, to url: URL) {
        guard let data else { fail("Couldn't encode the image.") }
        do { try data.write(to: url, options: .atomic) }
        catch { fail(error.localizedDescription) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Snapshot failed: \(message)\n".utf8))
        exit(1)
    }
}

/// Made-up Accounts for `--snapshot --accounts`, so several can be seen without several logins.
@MainActor
private enum AccountsDemo {
    static func show(in model: AppModel, kind: String) {
        func account(
            _ provider: ProviderID, _ name: String, plan: String? = nil, active: Bool = false,
            session: Double?, sessionIn: Double = 2, weekly: Double, weeklyIn: Double = 72, fable: Double? = nil,
            error: ProviderError? = nil, hint: String? = nil) -> Account
        {
            let now = Date()
            var windows: [LimitWindow] = []
            if let session {
                windows.append(LimitWindow(id: "session", title: "5-hour", usedPercent: session,
                                           resetsAt: now.addingTimeInterval(sessionIn * 3600), durationSeconds: 5 * 3600))
            }
            windows.append(LimitWindow(id: "weekly", title: "Weekly", usedPercent: weekly,
                                       resetsAt: now.addingTimeInterval(weeklyIn * 3600), durationSeconds: 7 * 86400))
            if let fable {
                windows.append(LimitWindow(id: "fable-weekly", title: "Fable Weekly", usedPercent: fable,
                                           resetsAt: now.addingTimeInterval(weeklyIn * 3600), durationSeconds: 7 * 86400, isModelSpecific: true))
            }
            return Account(
                id: LoginIdentity(email: name).accountID, name: name, isActive: active,
                snapshot: ProviderSnapshot(provider: provider, plan: plan, windows: windows, fetchedAt: now.addingTimeInterval(-60)),
                error: error, loginHint: hint)
        }
        var cursor = account(.cursor, "me@example.com", plan: "Pro", active: true, session: nil, weekly: 36, weeklyIn: 288)
        cursor.snapshot?.windows = [LimitWindow(
            id: "plan", title: "Total usage", usedPercent: 36, resetsAt: Date().addingTimeInterval(288 * 3600), durationSeconds: 30 * 86400)]
        let work = account(.claude, "work@example.com", plan: "Max 20x", active: true, session: 38, sessionIn: 1.3, weekly: 52, weeklyIn: 98, fable: 29)
        let main = account(.codex, "me@example.com", plan: "Pro", active: true, session: 24, sessionIn: 3.1, weekly: 42, weeklyIn: 76)
        var defaults: [ProviderID: Account] = [.claude: work, .codex: main, .cursor: cursor]
        var folders: [LoginFolder: Account] = [:]
        var swap: [Account] = []
        var readings: [LimitReading] = []
        func folder(_ provider: ProviderID, _ name: String) -> LoginFolder {
            LoginFolder(provider: provider, url: Paths.home.appendingPathComponent(name, isDirectory: true))
        }
        if kind != "one" {
            folders[folder(.claude, ".claude_personal")] = account(.claude, "personal@example.com", plan: "Max 5x", session: 0, weekly: 19, weeklyIn: 55)
            folders[folder(.codex, ".codex_alt")] = account(.codex, "alt@example.com", plan: "Plus", session: 0, weekly: 77, weeklyIn: 129)
        }
        let side = folder(.claude, ".claude_side")
        switch kind {
        case "one":
            defaults[.claude] = account(.claude, "work@example.com", plan: "Max 5x", active: true, session: 12, weekly: 19)
        case "many":
            folders[side] = account(.claude, "side@example.com", session: 92, sessionIn: 3.7, weekly: 88, weeklyIn: 145,
                                    error: .loginExpired, hint: side.loginHint)
            swap = [
                account(.claude, "client-a@example.com", session: 0, weekly: 10, weeklyIn: 27),
                account(.claude, "client-b@example.com", session: 26, sessionIn: 4, weekly: 35, weeklyIn: 122),
                account(.claude, "research@example.com", session: 59, sessionIn: 2.5, weekly: 67, weeklyIn: 80),
            ]
        default:
            folders[side] = account(.claude, "side@example.com", plan: "Pro", session: 92, sessionIn: 3.7, weekly: 88, weeklyIn: 145)
            // Three weeks, for the Plans page: the logs' cost against made-up shares of each limit.
            let start = Date().addingTimeInterval(-21 * 86400)
            for (i, name) in ["work@example.com", "personal@example.com", "side@example.com"].enumerated() {
                for week in 0..<3 {
                    let begins = start.addingTimeInterval(Double(week) * 7 * 86400)
                    readings.append(LimitReading(
                        windowID: "weekly", resetsAt: begins.addingTimeInterval(7 * 86400), duration: 7 * 86400, plan: nil,
                        usedPercent: [55, 20, 45][i], readAt: begins.addingTimeInterval(7 * 86400 - 60),
                        account: LoginIdentity(email: name).accountID))
                }
            }
        }
        model.showForSnapshot(defaults: defaults, folders: folders, swap: swap, readings: readings)
    }
}
