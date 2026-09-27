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
            button.imagePosition = .imageOnly
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

        // Ring and percentage are drawn as one template image: a titled status item gets wider
        // padding than an icon-only one, which left a visible gap to the neighbouring icon.
        button.image = RingIcon.image(
            fraction: key.percent.map { Double($0) / 100 },
            label: key.hidePercent ? nil : key.percent.map { "\($0)%" })
        button.title = ""
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

/// A small template ring showing the remaining fraction (full at 100% left, empty at 0%),
/// optionally followed by the percentage text.
@MainActor
enum RingIcon {
    static let ringSize: CGFloat = 14
    static let spacing: CGFloat = 3
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)

    static func image(fraction: Double?, label: String?) -> NSImage {
        let text = label.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let textSize = text?.size() ?? .zero
        let width = ringSize + (text == nil ? 0 : spacing + ceil(textSize.width))
        let height = max(ringSize, ceil(textSize.height))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let ringRect = NSRect(x: 0, y: (rect.height - ringSize) / 2, width: ringSize, height: ringSize)
            let inset = ringRect.insetBy(dx: 1.5, dy: 1.5)
            let center = NSPoint(x: inset.midX, y: inset.midY)

            NSColor.black.withAlphaComponent(0.3).setStroke()
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            track.stroke()

            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: inset.width / 2,
                    startAngle: 90, endAngle: 90 - 360 * min(fraction, 1), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }

            if let text {
                text.draw(at: NSPoint(x: ringSize + spacing, y: (rect.height - textSize.height) / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
