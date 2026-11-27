import Foundation

/// A rounded rect a ring is stroked along (its stroke's centre line), in points.
public struct RingRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let radius: Double

    public init(x: Double, y: Double, width: Double, height: Double, radius: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.radius = radius
    }

    /// Length of the stroke: the straight sides plus the four quarter-circle corners.
    public var perimeter: Double {
        2 * (width - 2 * radius) + 2 * (height - 2 * radius) + 2 * .pi * radius
    }
}

/// The figures inside the two-tool pill, kept apart so each can take its tool's colour.
public struct DualRingPillText: Equatable, Sendable {
    public let claude: String
    public let separator: String
    public let codex: String

    public var string: String { claude + separator + codex }
}

/// The menu-bar pill with Codex present: one Classic-style pill with two concentric
/// "fuel rings" — the outer one Claude's, the inner one Codex's — each draining with
/// that tool's % left over its own faint track, and "68% · 96%" inside. The pure
/// geometry and text; `MenuBarLabel` does the drawing.
public enum DualRingPill {
    /// The widest text, which sizes the pill so it never changes width between scans.
    public static let reference = "100% · 100%"
    public static let separator = " · "
    /// Below this % left a figure turns red, like the single pill.
    public static let warningBelow: Double = 10

    /// Share of the ring to draw (0...1); an unknown figure draws only the track.
    public static func level(percentLeft: Double?) -> Double {
        guard let percentLeft else { return 0 }
        return max(0, min(1, percentLeft / 100))
    }

    /// `68%`, or `—` without a reading.
    public static func figure(percentLeft: Double?) -> String {
        percentLeft.map(Formatting.percent) ?? "—"
    }

    public static func text(claudeLeft: Double?, codexLeft: Double?) -> DualRingPillText {
        DualRingPillText(claude: figure(percentLeft: claudeLeft), separator: separator,
                         codex: figure(percentLeft: codexLeft))
    }

    public static func isWarning(percentLeft: Double?) -> Bool {
        guard let percentLeft else { return false }
        return percentLeft < warningBelow
    }

    /// How far in from each edge the two rings reach (both strokes and the gap).
    public static func band(lineWidth: Double, gap: Double) -> Double {
        2 * lineWidth + gap
    }

    /// The outer (Claude) and inner (Codex) rings of a `width`×`height` pill, with
    /// `gap` points clear between the two strokes. The inner corner shrinks by the
    /// same inset so the rings stay parallel.
    public static func rings(
        width: Double, height: Double, lineWidth: Double, gap: Double, cornerRadius: Double,
    ) -> (outer: RingRect, inner: RingRect) {
        func ring(inset: Double, radius: Double) -> RingRect {
            let w = width - 2 * inset, h = height - 2 * inset
            return RingRect(x: inset, y: inset, width: w, height: h,
                            radius: max(0, min(radius, w / 2, h / 2)))
        }
        let outerInset = lineWidth / 2
        let step = lineWidth + gap
        return (ring(inset: outerInset, radius: cornerRadius),
                ring(inset: outerInset + step, radius: cornerRadius - step))
    }
}
