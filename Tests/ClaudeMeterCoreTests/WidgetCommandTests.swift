@testable import ClaudeMeterCore
import Foundation
import Testing

struct WidgetCommandTests {
    @Test func codableRoundTrip() throws {
        let batch = WidgetCommandBatch(commands: [
            WidgetCommand(action: .disarm, sessionID: "abc"),
        ])
        let data = try JSONEncoder().encode(batch)
        let back = try JSONDecoder().decode(WidgetCommandBatch.self, from: data)
        #expect(back == batch)
    }
}
