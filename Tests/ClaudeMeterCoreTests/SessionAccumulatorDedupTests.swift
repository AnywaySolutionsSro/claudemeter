@testable import ClaudeMeterCore
import Foundation
import Testing

/// Claude Code writes one JSONL entry per content block of a streamed reply, all
/// carrying the same `message.id`. The entries are NOT identical: the first one
/// holds the streaming-partial `output_tokens` (often 1) and the last one the
/// final count. Keeping the first entry undercounted output by ~50% on a real
/// corpus (2026-09-03: 17k of 57k ids differed). The largest reading must win.
struct SessionAccumulatorDedupTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func rec(_ ts: TimeInterval, output: Int, id: String) -> AssistantUsageRecord {
        AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: ts), model: "m", cwd: "/p",
                             tokens: TokenBreakdown(input: 10, output: output, cacheCreation: 5),
                             messageID: id)
    }

    @Test func repeatedIDWithLargerUsageReplacesThePartialReading() throws {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, output: 1, id: "msg_1"))
        acc.fold(rec(9_001, output: 273, id: "msg_1"))
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.tokens == TokenBreakdown(input: 10, output: 273, cacheCreation: 5))
        #expect(u.messageCount == 1)
        // The burn window also reflects the final count, not the partial one.
        let recent = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil,
                                            now: Date(timeIntervalSince1970: 9_100)))
        #expect(recent.burnRate == Double(10 + 273 + 5) / 5)
    }

    @Test func repeatedIDWithSmallerUsageIsIgnored() throws {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, output: 273, id: "msg_1"))
        acc.fold(rec(9_001, output: 1, id: "msg_1"))
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.tokens.output == 273)
        #expect(u.messageCount == 1)
    }

    @Test func mergeKeepsTheLargestReadingAcrossAccumulators() throws {
        var a = SessionAccumulator()
        a.fold(rec(9_000, output: 1, id: "msg_1"))
        var b = SessionAccumulator()
        b.fold(rec(9_001, output: 273, id: "msg_1"))
        let u = try #require(a.merged(with: b).usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.tokens.output == 273)
        #expect(u.messageCount == 1)
    }

    // `total` excludes cache reads, so a later entry that only grew `cacheRead`
    // must still land; and a field that shrank must never be pulled backwards.
    @Test func dedupIsFieldWise() throws {
        var acc = SessionAccumulator()
        acc.fold(AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: 9_000), model: "m", cwd: "/p",
                                      tokens: TokenBreakdown(input: 10, output: 5, cacheCreation: 8, cacheRead: 100),
                                      messageID: "msg_1"))
        acc.fold(AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: 9_001), model: "m", cwd: "/p",
                                      tokens: TokenBreakdown(input: 10, output: 5, cacheCreation: 8, cacheRead: 300),
                                      messageID: "msg_1"))
        acc.fold(AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: 9_002), model: "m", cwd: "/p",
                                      tokens: TokenBreakdown(input: 10, output: 40, cacheCreation: 2, cacheRead: 300),
                                      messageID: "msg_1"))
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.tokens == TokenBreakdown(input: 10, output: 40, cacheCreation: 8, cacheRead: 300))
        #expect(u.messageCount == 1)
    }
}
