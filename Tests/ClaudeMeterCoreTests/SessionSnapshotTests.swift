@testable import ClaudeMeterCore
import Foundation
import Testing

struct SessionSnapshotTests {
    private let now = Date(timeIntervalSince1970: 5_000)

    private func session(_ id: String, total: Int, running: RunningState) -> SessionUsage {
        SessionUsage(id: id, origin: .cli, projectPath: "/p/\(id)", models: ["m"],
                     tokens: TokenBreakdown(input: total), messageCount: 1,
                     firstActivity: now, lastActivity: now, burnRate: 0, running: running)
    }

    @Test func sortsByTotalDescAndAppliesLimit() {
        let snap = SessionSnapshot.make(from: [
            session("a", total: 10, running: .idle),
            session("b", total: 30, running: .running),
            session("c", total: 20, running: .idle),
        ], now: now, limit: 2)
        #expect(snap.sessions.map(\.id) == ["b", "c"])
    }

    @Test func totalsAndRunningCountSpanAllSessions() {
        let snap = SessionSnapshot.make(from: [
            session("a", total: 10, running: .running),
            session("b", total: 30, running: .running),
            session("c", total: 20, running: .idle),
        ], now: now, limit: 1)
        #expect(snap.totalTokens == 60) // all three, not just the kept one
        #expect(snap.runningCount == 2)
        #expect(snap.generatedAt == now)
    }

    @Test func runningOnlyKeepsOnlyRunningButCountsAllForTotals() {
        let snap = SessionSnapshot.make(from: [
            session("a", total: 10, running: .running),
            session("b", total: 30, running: .idle),
            session("c", total: 20, running: .running),
        ], now: now, limit: 5, runningOnly: true)
        #expect(snap.sessions.map(\.id) == ["c", "a"]) // only running, by total desc
        #expect(snap.totalTokens == 60) // still across all
        #expect(snap.runningCount == 2)
    }

    @Test func roundTripsThroughCodable() throws {
        let snap = SessionSnapshot.make(from: [session("a", total: 10, running: .idle)], now: now)
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: data) == snap)
    }

    @Test func oldSnapshotDecodesWithoutClockStyle() throws {
        let json = #"{"generatedAt":0,"sessions":[],"totalTokens":0,"runningCount":0}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.clockStyle == nil)
    }

    @Test func clockStyleRoundTrips() throws {
        let snap = SessionSnapshot(generatedAt: now, sessions: [], totalTokens: 0, runningCount: 0,
                                   clockStyle: .twelve)
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: data).clockStyle == .twelve)
    }

    @Test func testSnapshotDecodesWithoutCodexFields() throws {
        let json = #"{"generatedAt":0,"sessions":[{"id":"a","origin":"cli","projectPath":"/p","models":[],"#
            + #""tokens":{"input":1,"output":0,"cacheCreation":0,"cacheRead":0},"messageCount":1,"#
            + #""firstActivity":0,"lastActivity":0,"burnRate":0,"running":"idle"}],"#
            + #""totalTokens":1,"runningCount":0,"usageGauges":[{"label":"Weekly","percentLeft":40}]}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.codexGauges == nil)
        #expect(snap.codexAsOf == nil)
        #expect(snap.usageGauges.map(\.label) == ["Weekly"])
        #expect(snap.sessions.first?.tool == nil)
        #expect(snap.sessions.first?.effectiveTool == .claude)
    }

    @Test func testCodexGaugesRoundTrip() throws {
        let codex = [UsageGauge(label: "Weekly", percentLeft: 96, resetsAt: now.addingTimeInterval(600))]
        let snap = SessionSnapshot(
            generatedAt: now, sessions: [], totalTokens: 0, runningCount: 0,
            usageGauges: [UsageGauge(label: "Weekly", percentLeft: 51, resetsAt: nil)],
            codexGauges: codex, codexAsOf: now.addingTimeInterval(-7200),
        )
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
        #expect(decoded.codexGauges == codex)
        #expect(decoded.codexAsOf == now.addingTimeInterval(-7200))
        // Claude and Codex both have a "Weekly" window; they stay in separate collections.
        #expect(decoded.usageGauges.first?.percentLeft == 51)
    }
}
