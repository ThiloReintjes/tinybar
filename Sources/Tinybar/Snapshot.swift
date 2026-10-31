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
            await model.refresh(force: true)
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
