import AppKit
import SubarCore
import SwiftUI

/// Owns the NSStatusItem and the popover. Redraws the menu bar only when the Pinned Limit's
/// displayed value changes; no timers or animations here.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var lastRendered: RenderKey?

    private struct RenderKey: Equatable {
        var percent: Int?
        var stale: Bool
        var hidePercent: Bool
    }

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model))
        // Size the popover to the SwiftUI content; the default is a fixed 320×320 box that
        // centers and clips the content.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        render()
        observe()
    }

    /// Re-renders whenever a value `render()` reads changes (Observation tracking, one-shot per change).
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let pinned = model.pinned
        let stale = pinned.map { model.providers[$0.0]?.isStale ?? false } ?? false
        let key = RenderKey(
            percent: pinned.map { Int($0.1.remainingPercent.rounded()) },
            stale: stale,
            hidePercent: model.settings.hidePercentage)
        guard key != lastRendered, let button = statusItem.button else { return }
        lastRendered = key

        button.image = RingIcon.image(fraction: key.percent.map { Double($0) / 100 }, dimmed: stale)
        if let percent = key.percent, !key.hidePercent {
            button.title = " \(percent)%"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        } else {
            button.title = ""
        }
        button.appearsDisabled = stale
        if let (provider, window) = pinned {
            button.toolTip = "\(provider.displayName) \(window.title): \(Int(window.remainingPercent.rounded()))% left"
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refreshOnOpen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// A small template ring showing the remaining fraction: full at 100% left, empty at 0%.
enum RingIcon {
    static func image(fraction: Double?, dimmed: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = inset.width / 2

            NSColor.black.withAlphaComponent(0.3).setStroke()
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            track.stroke()

            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: 90, endAngle: 90 - 360 * min(fraction, 1), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
