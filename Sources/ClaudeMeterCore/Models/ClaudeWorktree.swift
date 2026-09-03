import Foundation

/// Claude Code keeps its git worktrees under `<repo>/.claude/worktrees/<name>`.
/// Worktree tools stamp that path as the `cwd` of transcript records while the
/// CLI process itself keeps running from `<repo>` — so for process matching, a
/// hop into a worktree is not a move.
public enum ClaudeWorktree {
    public static let marker = "/.claude/worktrees/"

    public static func isWorktreePath(_ path: String) -> Bool {
        path.contains(marker)
    }

    /// True when `next` is a worktree path and the session already has a real
    /// folder to be matched by — the record reflects a tool's working directory,
    /// not where the session lives.
    public static func isHop(from current: String?, to next: String) -> Bool {
        guard let current, !isWorktreePath(current) else { return false }
        return isWorktreePath(next)
    }
}
