/// Which coding agent a session belongs to. Named `AgentTool` (not `Provider`,
/// which the widget already uses for something else).
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}
