import Foundation

/// Which tools the user wants to see (Settings → General → Show Claude / Show Codex),
/// resolved so the app never shows nothing: a hidden Claude comes back whenever Codex
/// isn't shown (not available on this Mac, or hidden too).
public struct ToolVisibility: Equatable, Sendable {
    /// Claude's surfaces (dropdown, battery, widget, alerts, auto-resume) are on.
    public let showsClaude: Bool
    /// Codex's surfaces are on. Never true while Codex is unavailable.
    public let showsCodex: Bool

    /// - Parameter codexAvailable: Codex is present (transcripts found) or signed in to
    ///   ChatGPT — the moment the toggles appear in Settings.
    public init(showClaude: Bool, showCodex: Bool, codexAvailable: Bool) {
        let codex = showCodex && codexAvailable
        showsCodex = codex
        showsClaude = showClaude || !codex
    }

    public func shows(_ tool: AgentTool) -> Bool {
        switch tool {
        case .claude: showsClaude
        case .codex: showsCodex
        }
    }

    /// The tools switched off, for the widget (`SessionSnapshot.hiddenTools`).
    public var hiddenTools: [AgentTool] {
        AgentTool.allCases.filter { !shows($0) }
    }

    /// Whether `tool`'s toggle may be switched off: only while the other one is on, so
    /// the last remaining toggle is disabled and both are never hidden. Claude also needs
    /// Codex connected (its limits visible), or hiding it would leave only a "Sign in" pill.
    public static func canHide(_ tool: AgentTool, showClaude: Bool, showCodex: Bool,
                               codexConnected: Bool) -> Bool {
        switch tool {
        case .claude: showCodex && codexConnected
        case .codex: showClaude
        }
    }

    /// The tools whose limits the menu-bar battery and the widget's gauges show:
    /// shown **and** connected (Claude signed in; Codex signed in to ChatGPT), Claude
    /// first. One tool = its own whole-body battery; none = the "Sign in" pill.
    public func limitTools(claudeSignedIn: Bool, codexConnected: Bool) -> [AgentTool] {
        var tools: [AgentTool] = []
        if showsClaude, claudeSignedIn { tools.append(.claude) }
        if showsCodex, codexConnected { tools.append(.codex) }
        return tools
    }
}

/// One block of the dropdown, between its header and its footer.
public enum DropdownSection: Equatable, Sendable {
    /// Claude's limits, extra usage and insights.
    case claudeUsage
    /// Codex's live limits (signed in to ChatGPT).
    case codexUsage
    /// Only the "Connect Claude account" button (or a login in progress).
    case connectClaude
    /// Only the "Connect Codex account" button (or a login in progress).
    case connectCodex
}

/// What the dropdown shows for given sign-in states. Connected tools' data comes
/// first and connect buttons last, just above the one footer (Quit always last).
public struct DropdownPlan: Equatable, Sendable {
    public let sections: [DropdownSection]
    /// The "● Claude" heading over Claude's usage — only when Codex appears too, so a
    /// Claude-only dropdown looks as it always did (Codex's section always has its own).
    public let showsToolHeaders: Bool
    /// The footer's "Updated …" line and Refresh (Claude's usage poll).
    public let showsRefresh: Bool

    /// Connected tools' data, shown first (API spend follows them).
    public var dataSections: [DropdownSection] {
        sections.filter { $0 == .claudeUsage || $0 == .codexUsage }
    }

    /// The connect buttons, directly above the footer.
    public var connectSections: [DropdownSection] {
        sections.filter { $0 == .connectClaude || $0 == .connectCodex }
    }

    public static func make(visibility: ToolVisibility, claudeSignedIn: Bool, codexConnected: Bool) -> DropdownPlan {
        var usage: [DropdownSection] = []
        var connect: [DropdownSection] = []
        if visibility.showsClaude {
            if claudeSignedIn { usage.append(.claudeUsage) } else { connect.append(.connectClaude) }
        }
        if visibility.showsCodex {
            if codexConnected { usage.append(.codexUsage) } else { connect.append(.connectCodex) }
        }
        return DropdownPlan(
            sections: usage + connect,
            showsToolHeaders: visibility.showsClaude && visibility.showsCodex,
            showsRefresh: usage.contains(.claudeUsage),
        )
    }
}
