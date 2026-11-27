import AppKit
import ClaudeMeterCore

/// The battery pill: Claude alone, or Claude and Codex side by side. Geometry is pure in
/// `BatteryPill`; this only measures the font and draws.
extension MenuBarLabel {
    private static let batteryLineWidth: CGFloat = 1
    /// Gap between the outline and the fill, like the system battery icon.
    private static let batteryInset: CGFloat = 1
    private static let batteryCellPadding: CGFloat = 4
    private static let batteryCornerRadius: CGFloat = 4.5
    private static let batteryDividerWidth: CGFloat = 1
    private static let batteryNubGap: CGFloat = 1
    private static let batteryNubWidth: CGFloat = 2
    private static let batteryNubHeightRatio: CGFloat = 0.4

    /// Claude alone: the whole body is Claude's, filled from the left.
    static func battery(claudeLeft: Double?, scale: TextScale) -> NSImage {
        drawBattery(BatteryPill.single(claudeLeft: claudeLeft, metrics: batteryMetrics(for: scale)), scale: scale)
    }

    /// Claude on the left, Codex on the right, both fills anchored at the divider.
    static func dualBattery(claudeLeft: Double?, codexLeft: Double?, scale: TextScale) -> NSImage {
        let metrics = batteryMetrics(for: scale)
        return drawBattery(BatteryPill.dual(claudeLeft: claudeLeft, codexLeft: codexLeft, metrics: metrics),
                           scale: scale)
    }

    /// Fixed status-item width for the battery at `scale`; it never depends on a reading.
    static func batterySlotWidth(dual: Bool, for scale: TextScale) -> CGFloat {
        let metrics = batteryMetrics(for: scale)
        let layout = dual
            ? BatteryPill.dual(claudeLeft: nil, codexLeft: nil, metrics: metrics)
            : BatteryPill.single(claudeLeft: nil, metrics: metrics)
        return ceil(CGFloat(layout.width) + 4)
    }

    /// Semibold so the white figures hold up over a coloured fill at the smallest size;
    /// same size as the other pills, so the height is unchanged.
    private static func batteryFont(for scale: TextScale) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: metrics(for: scale).font.pointSize, weight: .semibold)
    }

    private static func batteryMetrics(for scale: TextScale) -> BatteryMetrics {
        let (font, verticalPadding) = metrics(for: scale)
        let bold = batteryFont(for: scale)
        let textWidth = BatteryPill.references
            .map { ceil(($0 as NSString).size(withAttributes: [.font: bold]).width) }
            .max() ?? 0
        let textHeight = ceil(("0" as NSString).size(withAttributes: [.font: font]).height)
        return BatteryMetrics(
            height: Double(textHeight + verticalPadding * 2), cellTextWidth: Double(textWidth),
            cellPadding: Double(batteryCellPadding), lineWidth: Double(batteryLineWidth),
            inset: Double(batteryInset), cornerRadius: Double(batteryCornerRadius),
            dividerWidth: Double(batteryDividerWidth), nubGap: Double(batteryNubGap),
            nubWidth: Double(batteryNubWidth), nubHeightRatio: Double(batteryNubHeightRatio),
        )
    }

    private static func drawBattery(_ layout: BatteryLayout, scale: TextScale) -> NSImage {
        let font = batteryFont(for: scale)
        return draw(width: CGFloat(layout.width), height: CGFloat(layout.height)) {
            drawCells(layout)
            drawOutline(layout)
            for cell in layout.cells {
                drawFigure(cell, font: font)
            }
        }
    }

    /// Each cell's faint track, then its fill, clipped to the rounded inner area so the
    /// outer ends follow the body's corners while the divider edge stays square.
    private static func drawCells(_ layout: BatteryLayout) {
        NSGraphicsContext.saveGraphicsState()
        let radius = CGFloat(layout.innerRadius)
        NSBezierPath(roundedRect: nsRect(layout.inner), xRadius: radius, yRadius: radius).addClip()
        for cell in layout.cells {
            let color = NSColor(tool: cell.tool)
            trackColor(color).setFill()
            nsRect(cell.area).fill()
            if cell.fill.width > 0 {
                color.setFill()
                nsRect(cell.fill).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The drained part: the tool's colour darkened and see-through, so it reads as
    /// "empty" in both menu bars and the white figure keeps its contrast over it.
    private static func trackColor(_ color: NSColor) -> NSColor {
        (color.blended(withFraction: 0.55, of: .black) ?? color).withAlphaComponent(0.5)
    }

    private static func drawOutline(_ layout: BatteryLayout) {
        let outlineColor = NSColor.labelColor.withAlphaComponent(0.55)
        let half = batteryLineWidth / 2
        let body = nsRect(layout.body).insetBy(dx: half, dy: half)
        let radius = batteryCornerRadius - half
        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        outline.lineWidth = batteryLineWidth
        outlineColor.setStroke()
        outline.stroke()

        outlineColor.setFill()
        let nub = nsRect(layout.nub)
        let nubRadius = min(nub.width, nub.height / 2)
        NSBezierPath(roundedRect: nub, xRadius: nubRadius, yRadius: nubRadius).fill()
        if let divider = layout.divider {
            nsRect(divider).fill()
        }
    }

    /// White, with a soft dark halo so it stays legible over the faint empty track in a
    /// light menu bar as well as over the fill.
    private static func drawFigure(_ cell: BatteryCell, font: NSFont) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white, .shadow: shadow,
        ]
        let text = cell.text as NSString
        let size = text.size(withAttributes: attributes)
        let origin = BatteryPill.textOrigin(textWidth: Double(size.width), textHeight: Double(size.height),
                                            in: cell.area)
        text.draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: attributes)
    }

    private static func nsRect(_ rect: PillRect) -> NSRect {
        NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
