@testable import ClaudeMeterCore
import Foundation
import Testing

struct SessionUsageTests {
    private func make(path: String) -> SessionUsage {
        SessionUsage(
            id: "abc", origin: .cli, projectPath: path, title: nil,
            models: ["claude-opus-4-8"], tokens: TokenBreakdown(input: 10, output: 5, cacheRead: 99),
            messageCount: 1, firstActivity: .init(timeIntervalSince1970: 0),
            lastActivity: .init(timeIntervalSince1970: 60), burnRate: 0,
        )
    }

    @Test func projectNameIsLastPathComponent() {
        #expect(make(path: "/Users/x/code/movixtar").projectName == "movixtar")
    }

    @Test func projectNameFallsBackToRawPath() {
        #expect(make(path: "movixtar").projectName == "movixtar")
    }

    @Test func totalsDelegateToTokenBreakdown() {
        let s = make(path: "/a/b")
        #expect(s.totalTokens == 15)
        #expect(s.cacheReadTokens == 99)
    }

    @Test func withRunningReturnsUpdatedCopy() {
        let s = make(path: "/a/b")
        #expect(s.running == .idle)
        #expect(s.withRunning(.running).running == .running)
    }

    @Test func roundTripsThroughCodable() throws {
        let s = make(path: "/a/b")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(SessionUsage.self, from: data) == s)
    }
}
