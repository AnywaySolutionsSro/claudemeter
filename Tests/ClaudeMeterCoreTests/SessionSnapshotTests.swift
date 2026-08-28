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
}
