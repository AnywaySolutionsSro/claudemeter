@testable import ClaudeMeterCore
import Foundation
import Testing

/// Loads redacted Codex fixtures (all conversation text replaced with "x").
enum CodexFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codex", isDirectory: true)

    static let tuiSessionID = "01a219dd-6e0d-7240-bbe2-21402e5d53a4"
    static let importedSessionID = "01a21d81-9d50-77f2-81db-d7c5e4dc50e9"

    static var tuiURL: URL {
        directory.appendingPathComponent("rollout-2026-11-26T22-57-51-\(tuiSessionID).jsonl")
    }

    static var importedURL: URL {
        directory.appendingPathComponent("rollout-2026-11-27T15-56-03-\(importedSessionID).jsonl")
    }

    static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

struct CodexTranscriptParserTests {
    private func tokenCount(
        at timestamp: String = "2026-11-27T10:00:00.000Z",
        input: Int, cached: Int, output: Int, rateLimits: String = "null",
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(input + output)}},\
        "rate_limits":\(rateLimits)}}
        """
    }

    private let weeklyLimits = """
    {"limit_id":"codex","primary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1796332812},\
    "secondary":null,"plan_type":"prolite","rate_limit_reached_type":null}
    """

    @Test func testCumulativeTokensLastWins() {
        let state = CodexSessionState().folding([
            tokenCount(input: 100, cached: 40, output: 10),
            tokenCount(input: 300, cached: 200, output: 30),
        ])
        #expect(state.tokens == TokenBreakdown(input: 100, output: 30, cacheRead: 200))
    }

    @Test func testTokenMapping() {
        let state = CodexSessionState().folding([
            tokenCount(input: 26_160_392, cached: 25_716_736, output: 92706),
        ])
        #expect(state.tokens.input == 443_656)
        #expect(state.tokens.cacheRead == 25_716_736)
        #expect(state.tokens.output == 92706)
        #expect(state.tokens.cacheCreation == 0)
    }

    @Test func testRateLimitsParsed() throws {
        let state = CodexSessionState().folding([
            tokenCount(input: 10, cached: 0, output: 1, rateLimits: weeklyLimits),
        ])
        let reading = try #require(state.latestLimits)
        #expect(reading.limitID == "codex")
        #expect(reading.reachedType == nil)
        #expect(reading.observedAt == ISODate.parse("2026-11-27T10:00:00Z"))
        #expect(reading.windows == [CodexWindowReading(
            usedPercent: 4.0, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1_796_332_812),
        )])
    }

    @Test func testMalformedLinesIgnored() {
        let state = CodexSessionState().folding([
            "not json",
            "",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":\"oops\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":7}}}",
            "[1,2,3]",
            tokenCount(input: 5, cached: 1, output: 2),
        ])
        #expect(state.tokens == TokenBreakdown(input: 4, output: 2, cacheRead: 1))
        #expect(state.latestLimits == nil)
    }

    @Test func nullInfoKeepsTokensButStillReadsLimits() {
        let nullInfo = """
        {"timestamp":"2026-11-27T11:00:00Z","type":"event_msg","payload":{"type":"token_count",\
        "info":null,"rate_limits":\(weeklyLimits)}}
        """
        let state = CodexSessionState().folding([tokenCount(input: 5, cached: 1, output: 2), nullInfo])
        #expect(state.tokens == TokenBreakdown(input: 4, output: 2, cacheRead: 1))
        #expect(state.latestLimits?.observedAt == ISODate.parse("2026-11-27T11:00:00Z"))
    }

    // `used_percent: 0` must not be mistaken for a JSON boolean (NSNumber bridging),
    // while a real boolean is still refused.
    @Test func zeroIsANumberButABooleanIsNot() {
        let zero = """
        {"limit_id":"codex","primary":{"used_percent":0,"window_minutes":10080,"resets_at":1796332812}}
        """
        let boolean = """
        {"limit_id":"codex","primary":{"used_percent":true,"window_minutes":10080,"resets_at":1796332812}}
        """
        let zeroState = CodexSessionState().folding([tokenCount(input: 1, cached: 1, output: 0, rateLimits: zero)])
        #expect(zeroState.latestLimits?.windows.first?.usedPercent == 0)
        #expect(zeroState.tokens.cacheRead == 1)
        let boolState = CodexSessionState().folding([tokenCount(input: 1, cached: 0, output: 0, rateLimits: boolean)])
        #expect(boolState.latestLimits == nil)
    }

    @Test func secondaryWindowAndReachedTypeParsed() throws {
        let limits = """
        {"limit_id":"codex","primary":{"used_percent":100,"window_minutes":300,"resets_at":1796000000},\
        "secondary":{"used_percent":55.5,"window_minutes":10080,"resets_at":null},\
        "rate_limit_reached_type":"usage_limit_reached"}
        """
        let state = CodexSessionState().folding([tokenCount(input: 1, cached: 0, output: 1, rateLimits: limits)])
        let reading = try #require(state.latestLimits)
        #expect(reading.reachedType == "usage_limit_reached")
        #expect(reading.windows.map(\.windowMinutes) == [300, 10080])
        #expect(reading.windows[1].resetsAt == nil)
    }

    @Test func foldingIsIncrementalAndPure() throws {
        let lines = try CodexFixtures.lines(CodexFixtures.tuiURL)
        let whole = CodexSessionState().folding(lines)
        let start = CodexSessionState()
        let half = start.folding(Array(lines.prefix(30)))
        #expect(start == CodexSessionState())
        #expect(half.folding(Array(lines.dropFirst(30))) == whole)
    }

    @Test func realTUISessionFixture() throws {
        let state = try CodexSessionState().folding(CodexFixtures.lines(CodexFixtures.tuiURL))
        #expect(state.id == CodexFixtures.tuiSessionID)
        #expect(state.originator == "codex-tui")
        #expect(state.cwd == "/Users/dev/project")
        #expect(state.model == "gpt-6.2-sol")
        #expect(state.models == ["gpt-6.2-sol"])
        #expect(state.tokens == TokenBreakdown(input: 469_197 - 437_888, output: 3426, cacheRead: 437_888))
        #expect(state.latestLimits?.limitID == "codex")
        #expect(state.firstActivity == ISODate.parse("2026-11-26T21:58:15Z"))
        #expect(state.lastActivity != nil)
        #expect(state.turnCount == 3)
        #expect(!state.isImportedLegacy)
        #expect(state.isCodexWork)
    }

    @Test func testImportedLegacyThreadsSkipped() throws {
        let lines = try CodexFixtures.lines(CodexFixtures.importedURL)
        let imported: Set = [CodexFixtures.importedSessionID]

        let state = CodexSessionState().folding(lines, importedIDs: imported)
        #expect(state.isLegacyHistory)
        #expect(state.isImportedLegacy)
        #expect(!state.isCodexWork)

        // Legacy history alone (not in the imports file) is not an import.
        #expect(!CodexSessionState().folding(lines).isImportedLegacy)

        // Later zero-token counts keep it an import; real Codex tokens make it Codex work.
        let stillImport = state.folding([tokenCount(input: 0, cached: 0, output: 0)], importedIDs: imported)
        #expect(stillImport.isImportedLegacy)
        let resumed = state.folding([tokenCount(input: 50, cached: 10, output: 5)], importedIDs: imported)
        #expect(!resumed.isImportedLegacy)
        #expect(resumed.isCodexWork)
        #expect(resumed.tokens == TokenBreakdown(input: 40, output: 5, cacheRead: 10))
    }
}
