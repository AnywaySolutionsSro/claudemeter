import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SnapshotStoreTests {
    private let now = Date(timeIntervalSince1970: 7_000)
    private let store = SnapshotStore()

    private func sampleSnapshot() -> SessionSnapshot {
        let s = SessionUsage(id: "a", origin: .cli, projectPath: "/p/a", models: ["m"],
                             tokens: TokenBreakdown(input: 10), messageCount: 1,
                             firstActivity: now, lastActivity: now, burnRate: 0, running: .running)
        return SessionSnapshot.make(from: [s], now: now)
    }

    @Test func encodeThenDecodeRoundTrips() throws {
        let snap = sampleSnapshot()
        #expect(try store.decode(store.encode(snap)) == snap)
    }

    @Test func writeThenReadRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let snap = sampleSnapshot()
        try store.write(snap, to: url)
        #expect(store.read(from: url) == snap)
    }

    @Test func readMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(store.read(from: url) == nil)
    }
}
