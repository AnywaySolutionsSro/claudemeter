import AppKit
import ClaudeMeterCore

extension MenuBarLabel {
    /// Ring stroke: thick enough for both rings to read at the smallest text size.
    private static let ringLineWidth: CGFloat = 1.5
    /// Clear space between the outer (Claude) and inner (Codex) strokes.
    private static let ringGap: CGFloat = 1
    /// Text clearance inside the inner ring, left and right.
    private static let ringTextInset: CGFloat = 3
    private static let ringCornerRadius: CGFloat = 5

    /// The pill with Codex present: Claude's fuel ring outside, Codex's inside, and
    /// "68% · 96%" in the tools' colours. Same height as the single pill; always as
    /// wide as "100% · 100%", so it never changes width between scans.
    static func dualRingPill(claudeLeft: Double?, codexLeft: Double?, scale: TextScale) -> NSImage {
        let (font, verticalPadding) = metrics(for: scale)
        let text = attributedText(DualRingPill.text(claudeLeft: claudeLeft, codexLeft: codexLeft),
                                  claudeLeft: claudeLeft, codexLeft: codexLeft, font: font)
        let textSize = text.size()
        let width = dualRingPillWidth(font: font)
        let height = ceil(textSize.height) + verticalPadding * 2
        let rings = DualRingPill.rings(width: Double(width), height: Double(height),
                                       lineWidth: Double(ringLineWidth), gap: Double(ringGap),
                                       cornerRadius: Double(ringCornerRadius))

        return draw(width: width, height: height) {
            stroke(rings.outer, level: DualRingPill.level(percentLeft: claudeLeft), color: NSColor(tool: .claude))
            stroke(rings.inner, level: DualRingPill.level(percentLeft: codexLeft), color: NSColor(tool: .codex))
            text.draw(at: NSPoint(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2))
        }
    }

    /// Fixed status-item width for the two-ring pill at `scale`.
    static func dualRingSlotWidth(for scale: TextScale) -> CGFloat {
        ceil(dualRingPillWidth(font: metrics(for: scale).font) + 4)
    }

    private static func dualRingPillWidth(font: NSFont) -> CGFloat {
        let textWidth = (DualRingPill.reference as NSString).size(withAttributes: [.font: font]).width
        let band = CGFloat(DualRingPill.band(lineWidth: Double(ringLineWidth), gap: Double(ringGap)))
        return ceil(textWidth) + (band + ringTextInset) * 2
    }

    /// A faint full track, then the tool's colour over the share still left.
    private static func stroke(_ ring: RingRect, level: Double, color: NSColor) {
        let rect = NSRect(x: ring.x, y: ring.y, width: ring.width, height: ring.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: ring.radius, yRadius: ring.radius)
        path.lineWidth = ringLineWidth
        path.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        path.stroke()
        guard level > 0.001 else { return }
        let perimeter = CGFloat(ring.perimeter)
        path.setLineDash([perimeter * CGFloat(level), perimeter + 1], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    private static func attributedText(_ text: DualRingPillText, claudeLeft: Double?, codexLeft: Double?,
                                       font: NSFont) -> NSAttributedString {
        func part(_ string: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        }
        func figureColor(_ left: Double?, tool: AgentTool) -> NSColor {
            DualRingPill.isWarning(percentLeft: left) ? .systemRed : NSColor(tool: tool)
        }
        let result = NSMutableAttributedString()
        result.append(part(text.claude, figureColor(claudeLeft, tool: .claude)))
        result.append(part(text.separator, .tertiaryLabelColor))
        result.append(part(text.codex, figureColor(codexLeft, tool: .codex)))
        return result
    }
}
