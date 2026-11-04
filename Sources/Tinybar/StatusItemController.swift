import AppKit
import TinybarCore
import SwiftUI

/// Owns the NSStatusItem and the popover. Redraws the menu bar only when the Pinned Limit's
/// displayed value changes; no timers or animations here.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var lastRendered: RenderKey?
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var stats = StatsWindowController(model: model)

    private struct RenderKey: Equatable {
        var percent: Int?
        var provider: ProviderID?
        var stale: Bool
        var hidePercent: Bool
        var dark: Bool
        var alert: Incident.Severity?
    }

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            // The ring is coloured, so it is not a template image: redraw when the menu bar
            // switches between light and dark (wallpaper, appearance setting).
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }
        render()
        observe()
        model.showPopover = { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.togglePopover()
        }
        model.openStats = { [weak self] in
            self?.popover.performClose(nil)
            self?.stats.show()
        }
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
        let stale = model.isPinnedStale
        guard let button = statusItem.button else { return }
        let showsUsed = model.settings.showsUsedPercentage
        let key = RenderKey(
            percent: pinned.map { Int(shownPercent(left: $0.1.remainingPercent, used: showsUsed).rounded()) },
            provider: pinned?.0,
            stale: stale,
            hidePercent: model.settings.hidePercentage,
            dark: button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            alert: model.disruption?.severity)
        let owner = model.pinnedAccount.map { " (\($0.displayName))" } ?? ""
        var tip = pinned.map {
            "\($0.0.displayName)\(owner) \($0.1.title): \(PercentText.phrase(left: $0.1.remainingPercent, used: showsUsed))"
        }
        if let incident = model.disruption {
            tip = [tip, "\(incident.provider.displayName): \(incident.title)"].compactMap { $0 }.joined(separator: "\n")
        }
        button.toolTip = tip
        // The image carries the incident's light; VoiceOver gets it from the label.
        button.setAccessibilityLabel(tip)

        guard key != lastRendered else { return }
        lastRendered = key

        // Ring and percentage are drawn as one image: a titled status item gets wider padding
        // than an icon-only one, which left a visible gap to the neighbouring icon.
        button.image = RingIcon.image(
            fraction: key.percent.map { Double($0) / 100 },
            label: key.hidePercent ? nil : key.percent.map { "\($0)%" },
            tint: key.stale ? nil : key.provider.flatMap(RingIcon.tint),
            dark: key.dark,
            alert: key.alert?.nsColor)
        button.title = ""
        button.appearsDisabled = stale
    }

    /// The SwiftUI tree is dropped on close and built again on the next open, so a closed popover
    /// holds none of it.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refreshOnOpen()
            if popover.contentViewController == nil {
                let host = NSHostingController(rootView: PopoverView(model: model))
                // Size the popover to the SwiftUI content; the default is a fixed 320×320 box
                // that centers and clips the content.
                host.sizingOptions = .preferredContentSize
                popover.contentViewController = host
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// A small ring showing the remaining fraction (full at 100% left, empty at 0%), or the used one
/// with "Show percentages as used", optionally followed by the percentage text. The arc takes the
/// pinned Provider's colour; the track and text follow the menu bar like a template image would.
@MainActor
enum RingIcon {
    static let ringSize: CGFloat = 14
    static let spacing: CGFloat = 3
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)

    /// Colour stops for the arc, clockwise from the top. nil keeps it monochrome.
    enum Tint {
        case solid(NSColor)
        /// Gemini's spark: red top, blue right, green bottom, yellow left.
        case sweep([NSColor])
    }

    static func tint(_ id: ProviderID) -> Tint? {
        switch id {
        case .claude: .solid(NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        case .gemini: .sweep([
            NSColor(srgbRed: 0.97, green: 0.38, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 0.24, green: 0.62, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.76, blue: 0.49, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.77, blue: 0.12, alpha: 1),
            NSColor(srgbRed: 0.97, green: 0.38, blue: 0.35, alpha: 1),
        ])
        // Codex (OpenAI's mark), Cursor, OpenCode, Copilot and Grok are monochrome, like the menu bar itself.
        case .codex, .cursor, .opencode, .copilot, .grok: nil
        }
    }

    /// `alert` puts a status light on the ring's top right (an Incident somewhere).
    static func image(fraction: Double?, label: String?, tint: Tint?, dark: Bool, alert: NSColor? = nil) -> NSImage {
        let ink: NSColor = dark ? .white : .black
        let text = label.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: ink]) }
        let textSize = text?.size() ?? .zero
        let width = ringSize + (text == nil ? 0 : spacing + ceil(textSize.width))
        let height = max(ringSize, ceil(textSize.height))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let ringRect = NSRect(x: 0, y: (rect.height - ringSize) / 2, width: ringSize, height: ringSize)
            let inset = ringRect.insetBy(dx: 1.5, dy: 1.5)
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = inset.width / 2

            ink.withAlphaComponent(0.3).setStroke()
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            track.stroke()

            if let fraction, fraction > 0 {
                let sweep = 360 * min(fraction, 1)
                switch tint {
                case let .sweep(stops):
                    // Short segments, each coloured by its angle, approximate a conic gradient.
                    // All edges go down first so no segment's edge covers its neighbour's colour.
                    let steps = max(Int(sweep / 6), 1)
                    for edge in [true, false] {
                        for i in 0..<steps {
                            let a0 = sweep * Double(i) / Double(steps)
                            let a1 = sweep * Double(i + 1) / Double(steps)
                            let seg = NSBezierPath()
                            seg.appendArc(withCenter: center, radius: radius,
                                          startAngle: 90 - a0, endAngle: 90 - a1 - (i + 1 < steps ? 0.5 : 0), clockwise: true)
                            seg.lineCapStyle = (i == 0 || i == steps - 1) ? .round : .butt
                            let tone = color(in: stops, at: (a0 + a1) / 2 / 360)
                            stroke(seg, color: edge ? deeper(tone, dark: dark) : tone, width: edge ? 2 + 2 * edgeWidth : 2)
                        }
                    }
                case let .solid(color):
                    let path = arc(center: center, radius: radius, sweep: sweep)
                    stroke(path, color: deeper(color, dark: dark), width: 2 + 2 * edgeWidth)
                    stroke(path, color: color, width: 2)
                case nil:
                    stroke(arc(center: center, radius: radius, sweep: sweep), color: ink, width: 2)
                }
            }

            if let alert {
                // Punch a gap into the ring so the light reads as its own mark, then draw it.
                let light = NSRect(x: ringRect.maxX - 5, y: ringRect.maxY - 5, width: 5.5, height: 5.5)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: light.insetBy(dx: -1.25, dy: -1.25)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                alert.setFill()
                NSBezierPath(ovalIn: light).fill()
            }

            if let text {
                text.draw(at: NSPoint(x: ringSize + spacing, y: (rect.height - textSize.height) / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func arc(center: NSPoint, radius: CGFloat, sweep: Double) -> NSBezierPath {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        arc.lineCapStyle = .round
        return arc
    }

    private static func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    /// A coloured arc gets a hairline edge in a slightly deeper shade of its own colour, so it still
    /// reads on a menu bar tinted close to that colour (an orange wallpaper behind Claude's ring).
    /// The shade moves away from the text colour: darker on a dark bar, lighter on a light one,
    /// which keeps the edge all but invisible where the colour already stands out.
    private static let edgeWidth: CGFloat = 0.5
    private static let edgeShade: CGFloat = 0.12

    private static func deeper(_ color: NSColor, dark: Bool) -> NSColor {
        color.blended(withFraction: edgeShade, of: dark ? .black : .white) ?? color
    }

    /// Linear interpolation between evenly spaced stops, t in 0...1.
    private static func color(in stops: [NSColor], at t: Double) -> NSColor {
        let x = min(max(t, 0), 1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return stops[i].blended(withFraction: x - Double(i), of: stops[i + 1]) ?? stops[i]
    }
}
