import Foundation

/// Keeps Claude's and Codex's auto-resume plans apart: each plan sees only its own
/// tool's sessions and armed IDs, and `continue` is never typed into a tty that the
/// other tool also sits on.
public enum ToolResumeGuard {
    /// One tool's share of a scan.
    public struct Partition: Equatable, Sendable {
        public let sessions: [SessionUsage]
        public let armedIDs: Set<String>
    }

    /// `tool`'s sessions (untagged = Claude), and the armed set minus IDs the scan lists
    /// under another tool. An armed ID no longer listed at all stays in every partition,
    /// so each tool's window-expiry summary counts it exactly as it did before Codex.
    public static func partition(tool: AgentTool, sessions: [SessionUsage], armedIDs: Set<String>) -> Partition {
        let others = Set(sessions.filter { $0.effectiveTool != tool }.map(\.id))
        return Partition(sessions: sessions.filter { $0.effectiveTool == tool },
                         armedIDs: armedIDs.subtracting(others))
    }

    /// Result of the last check before typing into a tty.
    public enum TTYCheck: Equatable, Sendable {
        case clear
        /// The tty no longer maps to exactly the process the plan chose (tty reuse).
        case terminalChanged
        /// A process of the other tool is on the same tty: never guess which one reads stdin.
        case sharedWithOtherTool
    }

    /// The tty-reuse defense: `own` must hold exactly one process on `tty`, the expected
    /// pid and cwd, and `other` (the other tool's live processes) none.
    public static func verifyTTY(_ tty: String, expectedPID: Int32, expectedCwd: String,
                                 own: [LiveProcess], other: [LiveProcess]) -> TTYCheck {
        let onTTY = own.filter { $0.tty == tty }
        guard onTTY.count == 1, onTTY[0].pid == expectedPID, onTTY[0].cwd == expectedCwd else {
            return .terminalChanged
        }
        return other.contains { $0.tty == tty } ? .sharedWithOtherTool : .clear
    }
}
