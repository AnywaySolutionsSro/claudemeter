// Generates Resources/AppIcon.icns — a speedometer gauge in Claude orange.
// Run: swift Resources/make_icon.swift
import AppKit
import Foundation

let cream = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.93, alpha: 1)
let darkBrown = NSColor(srgbRed: 0.20, green: 0.12, blue: 0.08, alpha: 1)

func drawIcon() {
    // Rounded-square background with a vertical Claude-orange gradient.
    let padding: CGFloat = 100
    let side: CGFloat = 1024 - padding * 2
    let bgRect = NSRect(x: padding, y: padding, width: side, height: side)
    let background = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.93, green: 0.62, blue: 0.45, alpha: 1),
        ending: NSColor(srgbRed: 0.78, green: 0.36, blue: 0.20, alpha: 1)
    )!
    gradient.draw(in: background, angle: -90)

    let center = NSPoint(x: 512, y: 476)
    let radius: CGFloat = 250
    let arcWidth: CGFloat = 78
    let startAngle: CGFloat = 225          // down-left
    let totalSweep: CGFloat = 270          // opening at the bottom

    // Track (unused portion).
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle - totalSweep, clockwise: true)
    track.lineWidth = arcWidth
    track.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.30).setStroke()
    track.stroke()

    // Value (used portion) ~68%.
    let value: CGFloat = 0.68
    let valueEnd = startAngle - totalSweep * value
    let valueArc = NSBezierPath()
    valueArc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: valueEnd, clockwise: true)
    valueArc.lineWidth = arcWidth
    valueArc.lineCapStyle = .round
    cream.setStroke()
    valueArc.stroke()

    // Tick marks just inside the track.
    NSColor(white: 1, alpha: 0.55).setStroke()
    for i in 0...8 {
        let angle = (startAngle - CGFloat(i) * (totalSweep / 8)) * .pi / 180
        let inner = radius - arcWidth / 2 - 20
        let outer = radius - arcWidth / 2 - 4
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        tick.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        tick.lineWidth = 6
        tick.lineCapStyle = .round
        tick.stroke()
    }

    // Needle pointing at the value, plus a hub.
    let needleAngle = valueEnd * .pi / 180
    let tip = NSPoint(x: center.x + cos(needleAngle) * radius * 0.86, y: center.y + sin(needleAngle) * radius * 0.86)
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: tip)
    needle.lineWidth = 30
    needle.lineCapStyle = .round
    darkBrown.setStroke()
    needle.stroke()

    for (r, color) in [(48.0 as CGFloat, cream), (20.0 as CGFloat, darkBrown)] {
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        color.setFill()
        hub.fill()
    }
}

func renderPNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024.0)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    let url = iconset.appendingPathComponent("\(variant.name).png")
    try! renderPNG(size: variant.size).write(to: url)
}
print("Wrote \(iconset.path)")
