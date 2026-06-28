/// Where a session's transcript came from.
public enum SessionOrigin: String, Sendable, Codable, CaseIterable {
    /// Terminal `claude` CLI (`~/.claude/projects`).
    case cli
    /// Claude desktop app agent/Cowork session.
    case desktop
}
