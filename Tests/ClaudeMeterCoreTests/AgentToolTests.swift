@testable import ClaudeMeterCore
import Foundation
import Testing

struct AgentToolTests {
    private func make(tool: AgentTool?, origin: SessionOrigin = .codexCLI) -> SessionUsage {
        SessionUsage(
            id: "abc", origin: origin, projectPath: "/a/b", models: ["gpt-6.2-sol"],
            tokens: TokenBreakdown(input: 10, output: 5), messageCount: 1,
            firstActivity: .init(timeIntervalSince1970: 0),
            lastActivity: .init(timeIntervalSince1970: 60), burnRate: 0, tool: tool,
        )
    }

    @Test func testLegacySessionDecodesAsClaude() throws {
        // A snapshot written before `tool` existed: no key at all.
        let json = """
        {"id":"s1","origin":"cli","projectPath":"/a","models":[],"tokens":{"input":1,"output":2,
         "cacheCreation":0,"cacheRead":0},"messageCount":1,"firstActivity":0,"lastActivity":60,
         "burnRate":0,"running":"idle"}
        """
        let session = try JSONDecoder().decode(SessionUsage.self, from: Data(json.utf8))
        #expect(session.tool == nil)
        #expect(session.effectiveTool == .claude)
    }

    @Test func testToolSurvivesCopies() throws {
        let session = make(tool: .codex)
        #expect(session.effectiveTool == .codex)
        #expect(session.withRunning(.running).tool == .codex)
        #expect(session.withProjectPath("/c/d").tool == .codex)
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(SessionUsage.self, from: data).tool == .codex)
    }

    @Test func toolRawValuesAreStable() {
        #expect(AgentTool(rawValue: "claude") == .claude)
        #expect(AgentTool(rawValue: "codex") == .codex)
    }

    @Test func codexOriginsRoundTripAndKnowTheirTool() {
        #expect(SessionOrigin(rawValue: "codexCLI") == .codexCLI)
        #expect(SessionOrigin(rawValue: "codexDesktop") == .codexDesktop)
        #expect(SessionOrigin.codexCLI.isTerminal)
        #expect(SessionOrigin.cli.isTerminal)
        #expect(!SessionOrigin.codexDesktop.isTerminal)
        #expect(!SessionOrigin.desktop.isTerminal)
    }

    @Test func runningResolverLeavesCodexSessionsAlone() {
        let codex = make(tool: .codex).withRunning(.running)
        let resolved = RunningResolver().resolve(
            sessions: [codex], liveCwdCounts: [:], desktopAppRunning: false, now: Date(),
        )
        #expect(resolved.first?.running == .running)
    }
}
