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

        switch mode {
        case .percentage:
            var text = Formatting.percent(remaining)
            if let reset = bucket.timeUntilReset(now: now) { text += " · " + Formatting.countdown(reset) }
            return pill(text: text, textColor: textColor, borderColor: borderColor)

        case .burnRate:
            if let burn, burn.isBurning, let eta = burn.etaToLimit {
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
            return battery(remaining: remaining)
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

    private static func battery(remaining: Double) -> NSImage {
        let bodyWidth: CGFloat = 30, height: CGFloat = 13, nub: CGFloat = 2.5
        let width = bodyWidth + nub + 2

        let fillColor: NSColor = remaining < 10 ? .systemRed : (remaining < 25 ? .systemOrange : .systemGreen)

        return draw(width: width, height: height) {
            let body = NSRect(x: 1, y: 1, width: bodyWidth, height: height - 2)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1
            NSColor.labelColor.setStroke()
            outline.stroke()

            // Terminal nub.
            let nubRect = NSRect(x: bodyWidth + 1, y: height / 2 - 2.5, width: nub, height: 5)
            let nubPath = NSBezierPath(roundedRect: nubRect, xRadius: 1, yRadius: 1)
            NSColor.labelColor.setFill()
            nubPath.fill()

            // Fill proportional to remaining.
            let inset: CGFloat = 2.5
            let maxFill = bodyWidth - inset * 2
            let fillWidth = max(0, maxFill * CGFloat(remaining / 100))
            let fill = NSRect(x: inset + 0.5, y: inset, width: fillWidth, height: height - inset * 2)
            let fillPath = NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5)
            fillColor.setFill()
            fillPath.fill()
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
