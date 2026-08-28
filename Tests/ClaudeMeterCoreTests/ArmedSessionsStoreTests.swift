@testable import ClaudeMeterCore
import Foundation
import Testing

struct ArmedSessionsStoreTests {
    private let store = ArmedSessionsStore()

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("armedtests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test func roundTripsArmedSet() throws {
        let url = tmp("armed.json")
        try store.write(["a", "b", "c"], to: url)
        #expect(store.read(from: url) == ["a", "b", "c"])
    }

    @Test func readsEmptyWhenMissing() {
        #expect(store.read(from: tmp("none.json")).isEmpty)
    }

    @Test func appendAndDrainCommands() throws {
        let url = tmp("commands.json")
        try store.appendCommand(WidgetCommand(action: .arm, sessionID: "x"), to: url)
        try store.appendCommand(WidgetCommand(action: .disarm, sessionID: "y"), to: url)
        let drained = store.drainCommands(at: url)
        #expect(drained == [WidgetCommand(action: .arm, sessionID: "x"),
                            WidgetCommand(action: .disarm, sessionID: "y")])
        // Draining removes the file, so a second drain is empty.
        #expect(store.drainCommands(at: url).isEmpty)
    }
}
