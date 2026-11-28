@testable import ClaudeMeterCore
import Foundation
import Testing

struct ToolVisibilityTests {
    private func vis(_ claude: Bool, _ codex: Bool, available: Bool = true) -> ToolVisibility {
        ToolVisibility(showClaude: claude, showCodex: codex, codexAvailable: available)
    }

    // MARK: Resolving the toggles

    @Test func bothShownByDefault() {
        let both = vis(true, true)
        #expect(both.showsClaude && both.showsCodex)
        #expect(both.hiddenTools.isEmpty)
    }

    @Test func hidingOneLeavesTheOther() {
        #expect(vis(false, true).hiddenTools == [.claude])
        #expect(vis(true, false).hiddenTools == [.codex])
        #expect(vis(false, true).shows(.codex))
        #expect(!vis(false, true).shows(.claude))
    }

    @Test func neverBothHidden() {
        let none = vis(false, false)
        #expect(none.showsClaude)
        #expect(!none.showsCodex)
    }

    @Test func codexUnavailableBringsClaudeBack() {
        // Claude hidden, then Codex vanished from the Mac: the toggles are gone, so
        // Claude must not stay hidden with nothing left to show.
        let gone = vis(false, true, available: false)
        #expect(gone.showsClaude)
        #expect(!gone.showsCodex)
        #expect(gone.hiddenTools == [.codex])
    }

    @Test func theLastRemainingToggleCannotBeSwitchedOff() {
        #expect(ToolVisibility.canHide(.claude, showClaude: true, showCodex: true, codexConnected: true))
        #expect(ToolVisibility.canHide(.codex, showClaude: true, showCodex: true, codexConnected: true))
        #expect(!ToolVisibility.canHide(.claude, showClaude: true, showCodex: false, codexConnected: true))
        #expect(!ToolVisibility.canHide(.codex, showClaude: false, showCodex: true, codexConnected: true))
    }

    /// Hiding Claude while Codex shows no limits would leave only a "Sign in" pill.
    @Test func claudeCannotBeHiddenUntilCodexIsConnected() {
        #expect(!ToolVisibility.canHide(.claude, showClaude: true, showCodex: true, codexConnected: false))
        #expect(ToolVisibility.canHide(.codex, showClaude: true, showCodex: true, codexConnected: false))
    }

    // MARK: Menu-bar battery and widget gauges: connected and shown

    @Test(arguments: [
        // claudeSignedIn, codexConnected, showClaude, showCodex → tools
        (true, true, true, true, [AgentTool.claude, .codex]),
        (true, false, true, true, [.claude]),
        (false, true, true, true, [.codex]),
        (false, false, true, true, []),
        (true, true, false, true, [.codex]),
        (true, true, true, false, [.claude]),
        (false, true, true, false, []),
        (true, false, false, true, []),
        (true, true, false, false, [.claude]),
    ])
    func limitTools(claudeIn: Bool, codexIn: Bool, showClaude: Bool, showCodex: Bool, expected: [AgentTool]) {
        let visibility = vis(showClaude, showCodex)
        #expect(visibility.limitTools(claudeSignedIn: claudeIn, codexConnected: codexIn) == expected)
    }

    // MARK: Dropdown

    @Test func connectedDataFirstConnectButtonsLast() {
        let plan = DropdownPlan.make(visibility: vis(true, true), claudeSignedIn: false, codexConnected: true)
        #expect(plan.sections == [.codexUsage, .connectClaude])
        #expect(plan.dataSections == [.codexUsage])
        #expect(plan.connectSections == [.connectClaude])
        #expect(!plan.showsRefresh)
        #expect(plan.showsToolHeaders)
    }

    @Test func bothSignedOutAreTwoConnectButtons() {
        let plan = DropdownPlan.make(visibility: vis(true, true), claudeSignedIn: false, codexConnected: false)
        #expect(plan.sections == [.connectClaude, .connectCodex])
        #expect(plan.dataSections.isEmpty)
    }

    @Test func bothConnectedShowBothUsages() {
        let plan = DropdownPlan.make(visibility: vis(true, true), claudeSignedIn: true, codexConnected: true)
        #expect(plan.sections == [.claudeUsage, .codexUsage])
        #expect(plan.showsRefresh)
    }

    @Test func claudeConnectedCodexNotConnected() {
        let plan = DropdownPlan.make(visibility: vis(true, true), claudeSignedIn: true, codexConnected: false)
        #expect(plan.sections == [.claudeUsage, .connectCodex])
    }

    @Test func claudeOnlyUserSeesTheOldDropdown() {
        let plan = DropdownPlan.make(visibility: vis(true, true, available: false),
                                     claudeSignedIn: true, codexConnected: false)
        #expect(plan.sections == [.claudeUsage])
        #expect(!plan.showsToolHeaders)
    }

    @Test func hiddenToolLeavesTheDropdown() {
        let noClaude = DropdownPlan.make(visibility: vis(false, true), claudeSignedIn: true, codexConnected: false)
        #expect(noClaude.sections == [.connectCodex])
        #expect(!noClaude.showsToolHeaders)
        #expect(!noClaude.showsRefresh)
        let noCodex = DropdownPlan.make(visibility: vis(true, false), claudeSignedIn: true, codexConnected: true)
        #expect(noCodex.sections == [.claudeUsage])
    }

    // MARK: Widget

    private func gauge(_ label: String) -> UsageGauge {
        UsageGauge(label: label, percentLeft: 50, resetsAt: nil)
    }

    private func session(_ id: String, tool: AgentTool?) -> SessionUsage {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return SessionUsage(id: id, origin: .cli, projectPath: "/code/\(id)", models: [],
                            tokens: TokenBreakdown(input: 1), messageCount: 1,
                            firstActivity: now, lastActivity: now, burnRate: 0, running: .running, tool: tool)
    }

    private func snapshot(hidden: [AgentTool]?) -> SessionSnapshot {
        SessionSnapshot(generatedAt: Date(timeIntervalSince1970: 0),
                        sessions: [session("a", tool: nil), session("b", tool: .codex)],
                        totalTokens: 2, runningCount: 2, usageGauges: [gauge("Weekly")],
                        codexGauges: [gauge("Weekly")], hiddenTools: hidden)
    }

    @Test func widgetLeavesOutHiddenTools() {
        let noCodex = snapshot(hidden: [.codex])
        #expect(noCodex.ringGauges(limit: 4).map(\.tool) == [.claude])
        #expect(noCodex.visibleSessions.map(\.id) == ["a"])
        #expect(!noCodex.includesCodex)
        let noClaude = snapshot(hidden: [.claude])
        #expect(noClaude.ringGauges(limit: 4).map(\.tool) == [.codex])
        #expect(noClaude.visibleSessions.map(\.id) == ["b"])
    }

    @Test func olderSnapshotHidesNothing() {
        let old = snapshot(hidden: nil)
        #expect(old.visibleSessions.count == 2)
        #expect(old.ringGauges(limit: 4).count == 2)
    }

    @Test func hiddenToolsRoundTrip() throws {
        let data = try JSONEncoder().encode(snapshot(hidden: [.codex]))
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.hiddenTools == [.codex])
        let legacy = Data(#"{"generatedAt":0,"sessions":[],"totalTokens":0,"runningCount":0}"#.utf8)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: legacy).hiddenTools == nil)
    }
}
