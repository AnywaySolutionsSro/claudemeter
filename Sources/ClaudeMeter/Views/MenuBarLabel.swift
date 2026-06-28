import AppKit
import ClaudeMeterCore

/// Renders the menu-bar item per the selected `DisplayMode`. Colours are resolved against the
/// menu bar's appearance by the caller.
enum MenuBarLabel {
    /// Claude brand orange (#D97757).
    static let claudeOrange = NSColor(srgbRed: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0, alpha: 1)

    static func image(
        mode: DisplayMode,
        signedIn: Bool,
        snapshot: UsageSnapshot?,
        burn: BurnEstimate?,
        errorMessage: String?,
        now: Date
    ) -> NSImage {
        guard signedIn else {
            return pill(text: "Sign in", textColor: .labelColor, borderColor: claudeOrange)
        }
        guard let bucket = snapshot?.primary else {
            return glyph(errorMessage == nil ? "…" : "⚠︎",
                         color: errorMessage == nil ? .labelColor : .systemRed)
        }

        let remaining = bucket.percentRemaining
        let textColor = color(forRemaining: remaining)
        let borderColor: NSColor = remaining < 10 ? .systemRed : claudeOrange

        let reset = bucket.timeUntilReset(now: now)

        switch mode {
        case .classic:
            var text = Formatting.percent(remaining)
            if let reset { text += " · " + Formatting.countdown(reset) }
            return gaugePill(text: text, remaining: remaining)

        case .burnRate:
            // Only show an ETA when the limit would actually be hit before the window resets.
            if let burn, burn.isBurning, let eta = burn.etaToLimit, let reset, eta < reset {
                return pill(text: "🔥 " + Formatting.countdown(eta), textColor: textColor, borderColor: borderColor)
            }
            return pill(text: Formatting.percent(remaining), textColor: textColor, borderColor: borderColor)

        case .mood:
            return pill(text: "\(Personality.moodEmoji(remaining: remaining)) \(Formatting.percent(remaining))",
                        textColor: textColor, borderColor: borderColor)

        case .pet:
            let pet = Personality.petEmoji(Personality.petState(remaining: remaining))
            return pill(text: "\(pet) \(Formatting.percent(remaining))", textColor: textColor, borderColor: borderColor)

        case .fuelGauge:
            return fuelGauge(remaining: remaining)
        }
    }

    private static func color(forRemaining remaining: Double) -> NSColor {
        switch remaining {
        case ..<10: return .systemRed
        case ..<25: return .systemOrange
        default: return .labelColor
        }
    }

    // MARK: - Drawing

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2
    private static let lineWidth: CGFloat = 1.25
    private static let cornerRadius: CGFloat = 4

    private static func pill(text: String, textColor: NSColor, borderColor: NSColor) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = ceil(textSize.width) + horizontalPadding * 2
        let height = ceil(textSize.height) + verticalPadding * 2

        return draw(width: width, height: height) {
            let inset = lineWidth / 2
            let rect = NSRect(x: inset, y: inset, width: width - lineWidth, height: height - lineWidth)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = lineWidth
            borderColor.setStroke()
            path.stroke()

            let origin = NSPoint(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    /// A car-style fuel gauge: a 120° dial with E…F, tick marks, and a needle pointing at the
    /// remaining level (echoes the speedometer app icon).
    /// Width of the fixed menu-bar slot, sized to the widest Classic content so the item never
    /// resizes (which would shift the button and misalign the popover).
    static func recommendedSlotWidth() -> CGFloat {
        let reference = "100% · 4h59m"
        let textWidth = (reference as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth + horizontalPadding * 2 + lineWidth * 2 + 4)
    }

    /// Classic pill whose border is a receding "fuel ring": a faint full track plus a coloured
    /// arc spanning the remaining fraction (green ≥50 %, yellow ≥20 %, red below).
    private static func gaugePill(text: String, remaining: Double) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = ceil(textSize.width) + horizontalPadding * 2
        let height = ceil(textSize.height) + verticalPadding * 2

        let level = max(0, min(1, remaining / 100))
        let progressColor: NSColor = remaining >= 50 ? .systemGreen : (remaining >= 20 ? .systemYellow : .systemRed)

        return draw(width: width, height: height) {
            let inset = lineWidth / 2
            let rect = NSRect(x: inset, y: inset, width: width - lineWidth, height: height - lineWidth)
            let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineCapStyle = .round

            path.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            path.stroke()

            if level > 0.001 {
                let perimeter = roundedRectPerimeter(rect: rect, radius: radius)
                path.lineWidth = lineWidth + 0.6
                path.setLineDash([perimeter * level, perimeter + 1], count: 2, phase: 0)
                progressColor.setStroke()
                path.stroke()
            }

            let origin = NSPoint(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    private static func roundedRectPerimeter(rect: NSRect, radius: CGFloat) -> CGFloat {
        let straight = 2 * (rect.width - 2 * radius) + 2 * (rect.height - 2 * radius)
        let corners = 2 * .pi * radius
        return straight + corners
    }

    private static func fuelGauge(remaining: Double) -> NSImage {
        let width: CGFloat = 40, height: CGFloat = 18
        let pivot = NSPoint(x: width / 2, y: 4)
        let radius: CGFloat = 12.5
        let startAngle: CGFloat = 150   // E, upper-left
        let endAngle: CGFloat = 30      // F, upper-right
        let level = CGFloat(min(100, max(0, remaining)))
        let needleColor: NSColor = remaining < 10 ? .systemRed : (remaining < 25 ? .systemOrange : .systemGreen)

        func point(angle: CGFloat, radius r: CGFloat) -> NSPoint {
            let rad = angle * .pi / 180
            return NSPoint(x: pivot.x + cos(rad) * r, y: pivot.y + sin(rad) * r)
        }

        return draw(width: width, height: height) {
            let track = NSBezierPath()
            track.appendArc(withCenter: pivot, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            track.lineWidth = 1.3
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            track.stroke()

            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            for angle in [startAngle, 90, endAngle] {
                let tick = NSBezierPath()
                tick.move(to: point(angle: angle, radius: radius - 2.5))
                tick.line(to: point(angle: angle, radius: radius))
                tick.lineWidth = 1
                tick.stroke()
            }

            let needleAngle = startAngle - level / 100 * (startAngle - endAngle)
            let needle = NSBezierPath()
            needle.move(to: pivot)
            needle.line(to: point(angle: needleAngle, radius: radius - 1.5))
            needle.lineWidth = 1.6
            needle.lineCapStyle = .round
            needleColor.setStroke()
            needle.stroke()

            let hub = NSBezierPath(ovalIn: NSRect(x: pivot.x - 1.7, y: pivot.y - 1.7, width: 3.4, height: 3.4))
            NSColor.labelColor.setFill()
            hub.fill()

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
            ]
            ("E" as NSString).draw(at: NSPoint(x: 1, y: 0), withAttributes: labelAttrs)
            ("F" as NSString).draw(at: NSPoint(x: width - 6.5, y: 0), withAttributes: labelAttrs)
        }
    }

    private static func glyph(_ glyph: String, color: NSColor) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (glyph as NSString).size(withAttributes: attributes)
        return draw(width: ceil(size.width) + 4, height: ceil(size.height) + verticalPadding * 2) {
            (glyph as NSString).draw(at: NSPoint(x: 2, y: verticalPadding), withAttributes: attributes)
        }
    }

    private static func draw(width: CGFloat, height: CGFloat, _ body: () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        body()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
