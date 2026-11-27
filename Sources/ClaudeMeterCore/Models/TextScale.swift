import Foundation

/// How large the app renders text and layout, relative to its design-time sizes.
///
/// Exists because every size in the app is a hardcoded absolute, and macOS scales
/// neither those nor `@ScaledMetric` (both measured inert on macOS 26), so a
/// custom multiplier is the only mechanism available.
public enum TextScale: String, CaseIterable, Identifiable, Sendable {
    case standard
    case large
    case larger
    case largest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// Applied to every design-time font size and layout metric.
    public var multiplier: Double {
        switch self {
        case .standard: 1.0
        case .large: 1.15
        case .larger: 1.3
        case .largest: 1.5
        }
    }

    /// Maps a persisted value to a scale; nil or unrecognised falls back.
    public static func fromStored(_ raw: String?) -> TextScale {
        TextScale(rawValue: raw ?? "") ?? .standard
    }

    /// `base` scaled and rounded to a whole point; fractional font sizes render soft.
    public func scaled(_ base: Double) -> Double {
        (base * multiplier).rounded()
    }

    /// The scaled font clamped to what the menu bar can actually show, plus the
    /// vertical padding it needs.
    ///
    /// `textHeight` maps a font size to its rendered line height. It is injected
    /// because line height is an `NSFont` measurement and this target has no
    /// AppKit: `MenuBarLabel` passes the real measurement, tests pass a stub.
    /// It is not computable arithmetic: measured ratios are 1.273, 1.231, 1.267,
    /// 1.176.
    ///
    /// Starting from `scaled(base)`, returns the first candidate satisfying
    /// `textHeight(font) + 2 * padding <= thickness`, trying the preferred padding
    /// before the compressed one at each font size, then stepping the font down a
    /// point.
    ///
    /// Never returns below `base`: that is today's unconditional size, so the pill
    /// can never come out worse than it already is. When even the compressed base
    /// overflows, `(base, padding)` is returned and the overflow is accepted.
    public func menuBarMetrics(
        base: Double,
        padding: Double,
        thickness: Double,
        textHeight: (Double) -> Double,
    ) -> (font: Double, padding: Double) {
        // Compressed fallback is deliberately a fixed 1pt, not a gradual decrement from
        // `padding`; the only caller passes 2, so this has never needed to be general.
        let paddings: [Double] = padding > 1 ? [padding, 1] : [padding]
        var font = max(base, scaled(base))
        while font >= base {
            let height = textHeight(font)
            for candidate in paddings where height + 2 * candidate <= thickness {
                return (font, candidate)
            }
            font -= 1
        }
        return (base, padding)
    }
}
