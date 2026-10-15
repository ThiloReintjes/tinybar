import AppKit
import SwiftUI
import TinybarCore

/// Developer aid: `Tinybar --snapshot out.png` renders the popover (or with `--stats`, the Stats
/// card) with live data and exits.
enum PopoverSnapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let model = AppModel(settings: Settings())
        Task { @MainActor in
            await model.refresh(force: true)
            // `--stats [--range week|month|all] [--model <id>]` renders the Stats card instead, as
            // Copy image does.
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
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: out.deletingPathExtension().path + ".window.png"))
                }
                window.orderOut(nil)
                if let summary = await model.statsSummary(range, model: picked) {
                    for (scheme, suffix) in [(ColorScheme.dark, ".dark"), (.light, "")] {
                        guard let image = StatsCard.image(summary, scheme: scheme), let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                        else { continue }
                        try? png.write(to: URL(fileURLWithPath: out.deletingPathExtension().path + suffix + ".png"))
                    }
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
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = URL(fileURLWithPath: out.deletingPathExtension().path + suffix + ".png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                window.orderOut(nil)
            }
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }
}
