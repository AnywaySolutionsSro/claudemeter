import AppKit
import ClaudeMeterCore

/// What one tool's menu-bar figure shows, independent of how big it is drawn: the
/// single Claude pill and each line of the Claude/Codex stack render the same content.
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
    /// The content for one tool's `bucket` in `mode`.
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

    // MARK: - Two-line stack (Claude above Codex)

    /// Design-time size of a stacked line; `TextScale` raises it, the bar's height caps it.
    private static let stackBaseFont: Double = 9
    /// Below this the digits stop being legible; accepted even if it overflows.
    private static let stackMinimumFont: Double = 7
    /// Tool dot diameter, as a share of the line height.
    private static let dotRatio: CGFloat = 0.5
    private static let dotGap: CGFloat = 3
    /// The widest stacked line (Classic), so the slot never resizes between scans.
    private static let stackReference = "100% · 4h59m"

    /// Claude's line above Codex's, each a tool dot plus its content shrunk to half
    /// the menu bar. The dot is the tool colour (red under 10% left), so the lines
    /// stay told apart without a border that two lines have no room for.
    static func stackedImage(claude: MenuBarContent, codex: MenuBarContent, scale: TextScale) -> NSImage {
        let (font, lineHeight) = stackMetrics(for: scale)
        let lines = [line(claude, tool: .claude, font: font, lineHeight: lineHeight),
                     line(codex, tool: .codex, font: font, lineHeight: lineHeight)]
        let width = lines.map(\.size.width).max() ?? 0
        let height = lineHeight * CGFloat(lines.count)
        return draw(width: width, height: height) {
            for (index, image) in lines.enumerated() {
                let y = height - lineHeight * CGFloat(index + 1)
                image.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    /// Fixed slot width for the stack at `scale`, sized to the widest Classic line.
    static func stackedSlotWidth(for scale: TextScale) -> CGFloat {
        let (font, lineHeight) = stackMetrics(for: scale)
        let textWidth = (stackReference as NSString).size(withAttributes: [.font: font]).width
        return ceil(lineHeight * dotRatio + dotGap + textWidth + horizontalPadding)
    }

    private static func stackMetrics(for scale: TextScale) -> (font: NSFont, lineHeight: CGFloat) {
        func measured(_ size: Double) -> CGFloat {
            let candidate = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(size), weight: .regular)
            return ceil(("0" as NSString).size(withAttributes: [.font: candidate]).height)
        }
        let size = scale.stackedMenuBarFont(
            base: stackBaseFont, minimum: stackMinimumFont, lines: 2,
            thickness: Double(NSStatusBar.system.thickness), textHeight: { Double(measured($0)) },
        )
        return (NSFont.monospacedDigitSystemFont(ofSize: CGFloat(size), weight: .regular), measured(size))
    }

    /// One stacked line: the tool dot, then the content's text (or a small dial).
    private static func line(_ content: MenuBarContent, tool: AgentTool,
                             font: NSFont, lineHeight: CGFloat) -> NSImage {
        let lineText = lineText(content)
        let text = lineText.text
        let dotColor: NSColor = (lineText.remaining ?? 100) < 10 ? .systemRed : NSColor(tool: tool)
        let dot = lineHeight * dotRatio
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: lineText.color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let dial: NSImage? = if case let .fuel(level) = content {
            fuelGauge(remaining: level)
        } else {
            nil
        }
        let dialWidth = dial.map { $0.size.width * lineHeight / $0.size.height } ?? 0
        let textX = dot + dotGap + (dial == nil ? 0 : dialWidth + dotGap)
        let width = ceil(textX + textSize.width)

        return draw(width: width, height: lineHeight) {
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: (lineHeight - dot) / 2, width: dot, height: dot)).fill()
            if let dial {
                dial.draw(in: NSRect(x: dot + dotGap, y: 0, width: dialWidth, height: lineHeight))
            }
            (text as NSString).draw(at: NSPoint(x: textX, y: (lineHeight - textSize.height) / 2),
                                    withAttributes: attributes)
        }
    }

    private struct LineText {
        let text: String
        let color: NSColor
        /// % left, when the line shows a figure (its dot turns red under 10%).
        let remaining: Double?
    }

    private static func lineText(_ content: MenuBarContent) -> LineText {
        switch content {
        case .signIn: LineText(text: "Sign in", color: .labelColor, remaining: nil)
        case let .glyph(text, color): LineText(text: text, color: color, remaining: nil)
        case let .gauge(text, remaining): LineText(
                text: text,
                color: color(forRemaining: remaining),
                remaining: remaining,
            )
        case let .pill(text, textColor, remaining): LineText(text: text, color: textColor, remaining: remaining)
        case let .fuel(remaining):
            LineText(text: Formatting.percent(remaining), color: color(forRemaining: remaining), remaining: remaining)
        }
    }
}
