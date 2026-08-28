import Foundation

/// The terminal emulator that owns a Claude Code session's process.
public enum TerminalKind: String, Equatable, Sendable, Codable {
    case iTerm2, appleTerminal, ghostty, wezterm, warp, vscode, unknown

    /// Whether ClaudeMeter can drive this terminal in v1 (iTerm2 only).
    public var isDrivable: Bool { self == .iTerm2 }

    public var displayName: String {
        switch self {
        case .iTerm2: "iTerm2"
        case .appleTerminal: "Terminal"
        case .ghostty: "Ghostty"
        case .wezterm: "WezTerm"
        case .warp: "Warp"
        case .vscode: "VS Code"
        case .unknown: "Terminal"
        }
    }
}
