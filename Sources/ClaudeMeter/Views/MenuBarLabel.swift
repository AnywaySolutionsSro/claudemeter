import AppKit
import ClaudeMeterCore

/// Renders the menu-bar content as an image: the `37% · 2h14m` text inside a rounded
/// **Claude-orange** outline (a "pill"). The border turns red when the window is nearly
/// exhausted. Colours are resolved against the current appearance by the caller, so the
/// text adapts to light/dark menu bars.
enum MenuBarLabel {
    /// Claude brand orange (#D97757).
    static let claudeOrange = NSColor(srgbRed: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0, alpha: 1)

    static func image(signedIn: Bool, snapshot: UsageSnapshot?, errorMessage: String?, now: Date) -> NSImage {
        guard signedIn else {
            return pill(text: "Sign in", textColor: .labelColor, borderColor: claudeOrange)
        }

        guard let bucket = snapshot?.primary else {
            // Before the first successful fetch, show a bare glyph with no pill.
            return glyph(errorMessage == nil ? "…" : "⚠︎",
                         color: errorMessage == nil ? .labelColor : .systemRed)
        }

        var text = Formatting.percent(bucket.percentRemaining)
        if let remaining = bucket.timeUntilReset(now: now) {
            text += " · " + Formatting.countdown(remaining)
        }

        let remaining = bucket.percentRemaining
        let isCritical = remaining < 10
        let isWarning = remaining < 25

        let textColor: NSColor = isCritical ? .systemRed : (isWarning ? .systemOrange : .labelColor)
        let borderColor: NSColor = isCritical ? .systemRed : claudeOrange

        return pill(text: text, textColor: textColor, borderColor: borderColor)
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

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let inset = lineWidth / 2
        let borderRect = NSRect(x: inset, y: inset, width: width - lineWidth, height: height - lineWidth)
        let path = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = lineWidth
        borderColor.setStroke()
        path.stroke()

        let origin = NSPoint(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func glyph(_ glyph: String, color: NSColor) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (glyph as NSString).size(withAttributes: attributes)

        let image = NSImage(size: NSSize(width: ceil(size.width) + 4, height: ceil(size.height) + verticalPadding * 2))
        image.lockFocus()
        (glyph as NSString).draw(at: NSPoint(x: 2, y: verticalPadding), withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
