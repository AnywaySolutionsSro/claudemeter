/// Where a session's transcript came from.
public enum SessionOrigin: String, Sendable, Codable, CaseIterable {
    /// Terminal `claude` CLI (`~/.claude/projects`).
    case cli
    /// Claude desktop app agent/Cowork session.
    case desktop
    /// Terminal `codex` CLI (`~/.codex/sessions`, originator `codex-tui`).
    case codexCLI
    /// Codex Desktop (ChatGPT.app) session — monitored, never resumable.
    case codexDesktop

    /// A session driven from a terminal process (the only kind auto-resume can reach).
    public var isTerminal: Bool {
        switch self {
        case .cli, .codexCLI: true
        case .desktop, .codexDesktop: false
        }
    }

    /// The agent this origin belongs to.
    public var tool: AgentTool {
        switch self {
        case .cli, .desktop: .claude
        case .codexCLI, .codexDesktop: .codex
        }
    }
}
