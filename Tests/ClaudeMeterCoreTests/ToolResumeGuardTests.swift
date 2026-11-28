@testable import ClaudeMeterCore
import Foundation
import Testing

struct ToolResumeGuardTests {
    private let at = Date(timeIntervalSince1970: 1000)

    private func session(_ id: String, _ tool: AgentTool?) -> SessionUsage {
        SessionUsage(id: id, origin: tool == .codex ? .codexCLI : .cli, projectPath: "/p/\(id)", models: [],
                     tokens: .zero, messageCount: 0, firstActivity: at, lastActivity: at, burnRate: 0,
                     tool: tool)
    }

    private func proc(_ pid: Int32, tty: String?, cwd: String = "/p") -> LiveProcess {
        LiveProcess(pid: pid, cwd: cwd, tty: tty, ppid: 1)
    }

    // MARK: partition

    @Test func partitionKeepsOnlyTheToolsSessionsAndDropsTheOtherToolsArmedIDs() {
        let sessions = [session("c1", .claude), session("legacy", nil), session("x1", .codex)]
        let armed: Set = ["c1", "x1", "gone"]
        let claude = ToolResumeGuard.partition(tool: .claude, sessions: sessions, armedIDs: armed)
        #expect(claude.sessions.map(\.id) == ["c1", "legacy"])
        // An armed ID no longer listed stays with Claude, exactly as before Codex existed.
        #expect(claude.armedIDs == ["c1", "gone"])
        let codex = ToolResumeGuard.partition(tool: .codex, sessions: sessions, armedIDs: armed)
        #expect(codex.sessions.map(\.id) == ["x1"])
        #expect(codex.armedIDs == ["x1", "gone"])
    }

    @Test func partitionWithoutCodexIsTheIdentityForClaude() {
        let sessions = [session("a", nil), session("b", .claude)]
        let armed: Set = ["a", "zzz"]
        let claude = ToolResumeGuard.partition(tool: .claude, sessions: sessions, armedIDs: armed)
        #expect(claude.sessions == sessions)
        #expect(claude.armedIDs == armed)
    }

    // MARK: tty verification

    @Test func sameProcessOnTTYIsClear() {
        #expect(ToolResumeGuard.verifyTTY("/dev/ttys001", expectedPID: 10, expectedCwd: "/p",
                                          own: [proc(10, tty: "/dev/ttys001")], other: []) == .clear)
    }

    @Test func bothToolsOnOneTTYIsSkipped() {
        #expect(ToolResumeGuard.verifyTTY(
            "/dev/ttys001", expectedPID: 10, expectedCwd: "/p",
            own: [proc(10, tty: "/dev/ttys001")], other: [proc(20, tty: "/dev/ttys001")],
        ) == .sharedWithOtherTool)
    }

    @Test func otherToolOnAnotherTTYIsIgnored() {
        #expect(ToolResumeGuard.verifyTTY(
            "/dev/ttys001", expectedPID: 10, expectedCwd: "/p",
            own: [proc(10, tty: "/dev/ttys001")], other: [proc(20, tty: "/dev/ttys002"), proc(21, tty: nil)],
        ) == .clear)
    }

    @Test func changedOrAmbiguousTTYIsSkipped() {
        let tty = "/dev/ttys001"
        #expect(ToolResumeGuard.verifyTTY(tty, expectedPID: 10, expectedCwd: "/p",
                                          own: [], other: []) == .terminalChanged)
        #expect(ToolResumeGuard.verifyTTY(tty, expectedPID: 10, expectedCwd: "/p",
                                          own: [proc(11, tty: tty)], other: []) == .terminalChanged)
        #expect(ToolResumeGuard.verifyTTY(tty, expectedPID: 10, expectedCwd: "/p",
                                          own: [proc(10, tty: tty, cwd: "/q")], other: []) == .terminalChanged)
        #expect(ToolResumeGuard.verifyTTY(tty, expectedPID: 10, expectedCwd: "/p",
                                          own: [proc(10, tty: tty), proc(12, tty: tty)], other: []) == .terminalChanged)
    }
}
