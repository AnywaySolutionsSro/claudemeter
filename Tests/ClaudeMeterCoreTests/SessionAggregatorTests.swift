@testable import ClaudeMeterCore
import Foundation
import Testing

struct SessionAggregatorTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func rec(_ ts: TimeInterval, _ model: String?, _ t: TokenBreakdown,
                     messageID: String? = nil) -> AssistantUsageRecord
    {
        AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: ts), model: model, cwd: "/c/proj",
                             tokens: t, messageID: messageID)
    }

    @Test func emptyRecordsProduceNil() {
        let agg = SessionAggregator()
        #expect(agg.aggregate(ParsedTranscript(records: [], malformedLineCount: 0),
                              id: "x", projectPath: "/c/proj", origin: .cli, title: nil, now: now) == nil)
    }

    @Test func sumsTokensAndCollectsMetadata() throws {
        let agg = SessionAggregator()
        let parsed = ParsedTranscript(records: [
            rec(9_000, "claude-opus-4-8", TokenBreakdown(input: 10, output: 1, cacheCreation: 2, cacheRead: 100)),
            rec(9_500, "claude-sonnet-4-6", TokenBreakdown(input: 20, output: 3, cacheCreation: 4, cacheRead: 200)),
        ], malformedLineCount: 0)
        let s = try #require(agg.aggregate(
            parsed,
            id: "sid",
            projectPath: "/c/proj",
            origin: .cli,
            title: "T",
            now: now,
        ))
        #expect(s.id == "sid")
        #expect(s.title == "T")
        #expect(s.tokens == TokenBreakdown(input: 30, output: 4, cacheCreation: 6, cacheRead: 300))
        #expect(s.totalTokens == 40)
        #expect(s.models == ["claude-opus-4-8", "claude-sonnet-4-6"])
        #expect(s.messageCount == 2)
        #expect(s.firstActivity == Date(timeIntervalSince1970: 9_000))
        #expect(s.lastActivity == Date(timeIntervalSince1970: 9_500))
    }

    @Test func emptyProjectPathFallsBackToRecordCwd() throws {
        let agg = SessionAggregator()
        let parsed = ParsedTranscript(records: [rec(9_000, "m", TokenBreakdown(input: 1))], malformedLineCount: 0)
        let s = try #require(agg.aggregate(parsed, id: "sid", projectPath: "", origin: .cli, title: nil, now: now))
        #expect(s.projectPath == "/c/proj")
    }

    // Claude Code writes one JSONL entry per content block of an API message; every
    // entry repeats the same message.id and the identical usage object. Counting them
    // all inflates totals 2-4x, so only the first record per message.id may count.
    @Test func duplicateMessageIDsCountOnce() throws {
        let agg = SessionAggregator(burnWindow: 300)
        let usage = TokenBreakdown(input: 10, output: 5, cacheCreation: 20, cacheRead: 100)
        let parsed = ParsedTranscript(records: [
            rec(now.timeIntervalSince1970 - 60, "m", usage, messageID: "msg_1"),
            rec(now.timeIntervalSince1970 - 59, "m", usage, messageID: "msg_1"),
            rec(now.timeIntervalSince1970 - 58, "m", usage, messageID: "msg_1"),
            rec(now.timeIntervalSince1970 - 30, "m", usage, messageID: "msg_2"),
        ], malformedLineCount: 0)
        let s = try #require(agg.aggregate(
            parsed,
            id: "sid",
            projectPath: "/c/proj",
            origin: .cli,
            title: nil,
            now: now,
        ))
        #expect(s.tokens == usage + usage)
        #expect(s.messageCount == 2)
        // Burn rate over the deduped records only: 2 x 35 tokens over 5 min.
        #expect(s.burnRate == Double(2 * usage.total) / 5)
    }

    @Test func recordsWithoutMessageIDAllCount() throws {
        let agg = SessionAggregator()
        let usage = TokenBreakdown(input: 1)
        let parsed = ParsedTranscript(records: [
            rec(9_000, "m", usage),
            rec(9_001, "m", usage),
        ], malformedLineCount: 0)
        let s = try #require(agg.aggregate(
            parsed,
            id: "sid",
            projectPath: "/c/proj",
            origin: .cli,
            title: nil,
            now: now,
        ))
        #expect(s.tokens == TokenBreakdown(input: 2))
        #expect(s.messageCount == 2)
    }

    @Test func burnRateCountsOnlyRecordsInTrailingWindow() throws {
        let agg = SessionAggregator(burnWindow: 300) // 5 min
        let parsed = ParsedTranscript(records: [
            rec(now.timeIntervalSince1970 - 600, "m", TokenBreakdown(input: 1000)), // outside window
            rec(now.timeIntervalSince1970 - 60, "m", TokenBreakdown(input: 50)), // inside: total 50
        ], malformedLineCount: 0)
        let s = try #require(agg.aggregate(
            parsed,
            id: "sid",
            projectPath: "/c/proj",
            origin: .cli,
            title: nil,
            now: now,
        ))
        // 50 tokens over a 5-minute window => 10 tokens/min
        #expect(s.burnRate == 10)
    }
}
