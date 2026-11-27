import AppKit
import ClaudeMeterCore

/// What Claude's single-line menu-bar label shows in the selected display mode,
/// independent of how it is drawn.
enum MenuBarContent: Equatable {
    case signIn
    case glyph(String, NSColor)
    /// Classic: "% · countdown" with the receding fuel ring.
    case gauge(text: String, remaining: Double)
    /// Burn rate / mood / pet: text in a pill whose border turns red under 10%.
    case pill(text: String, textColor: NSColor, remaining: Double)
    case fuel(remaining: Double)
}

extension MenuBarLabel {
    /// The content for `bucket` (Claude's primary window) in `mode`.
    static func content(
        mode: DisplayMode,
        signedIn: Bool,
        bucket: UsageBucket?,
        burn: BurnEstimate?,
        errorMessage: String?,
        now: Date,
    ) -> MenuBarContent {
        guard signedIn else { return .signIn }
        guard let bucket else {
            return .glyph(errorMessage == nil ? "…" : "⚠︎", errorMessage == nil ? .labelColor : .systemRed)
        }
        let remaining = bucket.percentRemaining
        let textColor = color(forRemaining: remaining)
        let reset = bucket.timeUntilReset(now: now)
        let percent = Formatting.percent(remaining)

        switch mode {
        case .classic:
            var text = percent
            if let reset { text += " · " + Formatting.countdown(reset) }
            return .gauge(text: text, remaining: remaining)
        case .burnRate:
            // Only show an ETA when the limit would actually be hit before the window resets.
            if let burn, burn.isBurning, let eta = burn.etaToLimit, let reset, eta < reset {
                return .pill(text: "🔥 " + Formatting.countdown(eta), textColor: textColor, remaining: remaining)
            }
            return .pill(text: percent, textColor: textColor, remaining: remaining)
        case .mood:
            return .pill(text: "\(Personality.moodEmoji(remaining: remaining)) \(percent)",
                         textColor: textColor, remaining: remaining)
        case .pet:
            let pet = Personality.petEmoji(Personality.petState(remaining: remaining))
            return .pill(text: "\(pet) \(percent)", textColor: textColor, remaining: remaining)
        case .fuelGauge:
            return .fuel(remaining: remaining)
        }
    }
}
