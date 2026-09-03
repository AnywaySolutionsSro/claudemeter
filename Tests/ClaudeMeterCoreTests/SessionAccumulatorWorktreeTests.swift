@testable import ClaudeMeterCore
import Foundation
import Testing

/// A session's records carry the cwd of whatever the CLI was doing at the time —
/// and worktree tools (EnterWorktree, agents with worktree isolation) stamp
/// `<repo>/.claude/worktrees/<name>` on records while the *process* cwd stays at
/// `<repo>`. Following those hops made the live session unmatchable for minutes
/// at a time, so an ended session in the same folder was shown as the running
/// one (2026-09-03: "mbx 90K fable-5" instead of the real 810K fable-5-1 session).
struct SessionAccumulatorWorktreeTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func rec(_ ts: TimeInterval, cwd: String) -> AssistantUsageRecord {
        AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: ts), model: "m", cwd: cwd,
                             tokens: TokenBreakdown(input: 1), messageID: nil)
    }

    private func path(_ acc: SessionAccumulator) -> String? {
        acc.usage(id: "s", projectPath: "", origin: .cli, title: nil, now: now)?.projectPath
    }

    @Test func worktreeHopsDoNotMoveTheProjectPath() {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, cwd: "/r/mbx"))
        acc.fold(rec(9_001, cwd: "/r/mbx/.claude/worktrees/iap56-prep"))
        acc.fold(rec(9_002, cwd: "/r/mbx/.claude/worktrees/iap9-main/functions"))
        #expect(path(acc) == "/r/mbx")
    }

    @Test func sessionBornInsideAWorktreeKeepsIt() {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, cwd: "/r/mbx/.claude/worktrees/feature"))
        acc.fold(rec(9_001, cwd: "/r/mbx/.claude/worktrees/feature/functions"))
        #expect(path(acc) == "/r/mbx/.claude/worktrees/feature/functions")
    }

    @Test func aRealMoveIsStillFollowed() {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, cwd: "/r/mbx"))
        acc.fold(rec(9_001, cwd: "/r/mbx/.claude/worktrees/x"))
        acc.fold(rec(9_002, cwd: "/elsewhere"))
        #expect(path(acc) == "/elsewhere")
    }

    @Test func leavingAWorktreeForARealFolderIsFollowed() {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, cwd: "/r/mbx/.claude/worktrees/feature"))
        acc.fold(rec(9_001, cwd: "/r/mbx"))
        #expect(path(acc) == "/r/mbx")
    }
}
