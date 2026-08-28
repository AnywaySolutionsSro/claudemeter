import ClaudeMeterCore
import SwiftUI

extension EnvironmentValues {
    /// How large this subtree renders. Set by whichever view owns `Settings`;
    /// read by every view with hardcoded design sizes.
    @Entry var textScale: TextScale = .standard
}

extension TextScale {
    /// A system font at the scaled size.
    ///
    /// Returns a `Font` value rather than wrapping the view in a `ViewModifier`
    /// so each call site stays a one-for-one replacement of the
    /// `.font(.system(size:))` it replaces, and so the two hierarchies that
    /// re-render every second gain no extra layers.
    ///
    /// Existing `.monospacedDigit()` chains keep working untouched: it is an
    /// environment transform applied after font resolution, independent of
    /// nesting depth.
    func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight)
    }

    /// A scaled layout metric: padding, spacing, corner radius, frame.
    ///
    /// Deliberately unrounded, unlike `font()`. Fractional layout is fine, and
    /// rounding every metric would introduce drift that whole-point font sizes
    /// need but layout does not.
    func pt(_ value: Double) -> CGFloat {
        CGFloat(value * multiplier)
    }
}
