import AppKit
import SwiftUI
import SubarCore

/// Developer aid: `Subar --snapshot out.png` renders the popover with live data and exits.
enum PopoverSnapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let model = AppModel(settings: Settings())
        Task { @MainActor in
            await model.refresh(force: true)
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ".dark"), (.aqua, "")] {
                let host = NSHostingView(rootView: PopoverView(model: model).background(Color(nsColor: .windowBackgroundColor)))
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
