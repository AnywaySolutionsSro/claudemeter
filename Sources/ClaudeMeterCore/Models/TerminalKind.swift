import Foundation

/// The terminal emulator that owns a Claude Code session's process.
public enum TerminalKind: String, Equatable, Sendable, Codable {
    case iTerm2, appleTerminal, ghostty, wezterm, warp, vscode, unknown

    /// Whether ClaudeMeter can drive this terminal in v1 (iTerm2 only).
    public var isDrivable: Bool { self == .iTerm2 }

    public var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .wezterm: return "WezTerm"
        case .warp: return "Warp"
        case .vscode: return "VS Code"
        case .unknown: return "Terminal"
        }
    }
}
