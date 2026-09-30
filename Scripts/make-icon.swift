// Draws Resources/AppIcon.icns: the menu bar ring, grown up. Two concentric rings, like a
// Provider's rings in the popover: the outer (weekly) mostly left, the inner (5-hour) less so.
// Run from the repo root: swift Scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// An arc from 12 o'clock, clockwise, fading from `from` to `to` along its length.
func ring(_ cg: CGContext, radius: CGFloat, width: CGFloat, fraction: CGFloat, from: NSColor, to: NSColor, track: NSColor) {
    let c = CGPoint(x: size / 2, y: size / 2)
    cg.setLineWidth(width)
    cg.setStrokeColor(track.cgColor)
    cg.addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()

    // Clip to the arc once, then fill overlapping wedges inside it: stroking each step instead
    // re-antialiases the edges and leaves a moiré.
    let steps = 720
    let start = CGFloat.pi / 2
    let sweep = fraction * .pi * 2
    cg.saveGState()
    cg.addArc(center: c, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    cg.replacePathWithStrokedPath()
    cg.clip()
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a0 = start - sweep * t + 0.01, a1 = start - sweep * (t + 1 / CGFloat(steps)) - 0.01
        cg.setFillColor(from.blended(withFraction: t, of: to)!.cgColor)
        cg.move(to: c)
        cg.addArc(center: c, radius: radius + width, startAngle: a0, endAngle: a1, clockwise: true)
        cg.closePath()
        cg.fillPath()
    }
    cg.restoreGState()
    // Round caps, drawn as dots so each end keeps its own colour.
    for (angle, col) in [(start, from), (start - sweep, to)] {
        let p = CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
        cg.setFillColor(col.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
    }
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext

    // The macOS icon grid: an 824 pt body centred on 1024, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.3).cgColor)
    cg.addPath(shape); cg.setFillColor(color(0xF4F5F8).cgColor); cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape); cg.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [color(0xFFFFFF).cgColor, color(0xE3E5EB).cgColor] as CFArray,
                        locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // A bright rim where light catches the top edge.
    cg.addPath(shape); cg.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor); cg.setLineWidth(6); cg.strokePath()

    ring(cg, radius: 262, width: 96, fraction: 0.74,
         from: color(0xF2A06A), to: color(0xD9572F), track: color(0x1B1D24, 0.07))
    ring(cg, radius: 142, width: 76, fraction: 0.42,
         from: color(0x6AB6FF), to: color(0x2F6FE0), track: color(0x1B1D24, 0.07))
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, px: Int) -> Data {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])!
}

let master = render()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try png(master, px: pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try png(master, px: pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try png(master, px: 1024).write(to: URL(fileURLWithPath: "docs/icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
