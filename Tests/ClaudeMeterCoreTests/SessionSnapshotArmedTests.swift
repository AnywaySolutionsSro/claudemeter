import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionSnapshotArmedTests {
    private func session(_ id: String) -> SessionUsage {
        SessionUsage(id: id, origin: .cli, projectPath: "/p/\(id)", models: ["m"],
                     tokens: TokenBreakdown(input: 1), messageCount: 1,
                     firstActivity: Date(timeIntervalSince1970: 0),
                     lastActivity: Date(timeIntervalSince1970: 0), burnRate: 0, running: .running)
    }

    @Test func makeCarriesArmedAndArmableIDs() {
        let snap = SessionSnapshot.make(
            from: [session("a"), session("b")], now: Date(timeIntervalSince1970: 0),
            armedSessionIDs: ["a"], armableSessionIDs: ["a", "b"])
        #expect(snap.armedSessionIDs == ["a"])
        #expect(snap.armableSessionIDs == ["a", "b"])
    }

    @Test func decodesLegacySnapshotWithoutNewFields() throws {
        // A snapshot encoded before these fields existed must still decode.
        let legacy = #"{"generatedAt":0,"sessions":[],"totalTokens":0,"runningCount":0}"#
        let data = Data(legacy.utf8)
        let decoder = JSONDecoder()
        let snap = try decoder.decode(SessionSnapshot.self, from: data)
        #expect(snap.armedSessionIDs.isEmpty)
        #expect(snap.armableSessionIDs.isEmpty)
    }
}
