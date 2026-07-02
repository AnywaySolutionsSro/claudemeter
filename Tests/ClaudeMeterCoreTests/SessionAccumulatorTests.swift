import Foundation
import Testing
@testable import ClaudeMeterCore

/// The accumulator is the incremental heart of the scan pipeline: records fold
/// in one at a time (so a file can be resumed from a byte offset without
/// re-reading), message.id dedup happens at fold time, and two accumulators can
/// merge (parent transcript + its subagent transcripts).
@Suite struct SessionAccumulatorTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func rec(_ ts: TimeInterval, _ t: TokenBreakdown, model: String? = "m",
                     cwd: String? = "/c/proj", messageID: String? = nil) -> AssistantUsageRecord {
        AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: ts), model: model, cwd: cwd,
                             tokens: t, messageID: messageID)
    }

    @Test func emptyAccumulatorYieldsNilUsage() {
        let acc = SessionAccumulator()
        #expect(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now) == nil)
        #expect(acc.isEmpty)
    }

    @Test func foldAccumulatesTokensModelsAndTimestamps() throws {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, TokenBreakdown(input: 10, output: 1, cacheCreation: 2, cacheRead: 100), model: "a"))
        acc.fold(rec(9_500, TokenBreakdown(input: 20, output: 3, cacheCreation: 4, cacheRead: 200), model: "b"))
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: "T", now: now))
        #expect(u.tokens == TokenBreakdown(input: 30, output: 4, cacheCreation: 6, cacheRead: 300))
        #expect(u.models == ["a", "b"])
        #expect(u.messageCount == 2)
        #expect(u.firstActivity == Date(timeIntervalSince1970: 9_000))
        #expect(u.lastActivity == Date(timeIntervalSince1970: 9_500))
        #expect(u.title == "T")
    }

    @Test func duplicateMessageIDsFoldOnce() throws {
        var acc = SessionAccumulator()
        let t = TokenBreakdown(input: 5)
        acc.fold(rec(9_000, t, messageID: "msg_1"))
        acc.fold(rec(9_001, t, messageID: "msg_1"))
        acc.fold(rec(9_002, t, messageID: "msg_2"))
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.tokens == TokenBreakdown(input: 10))
        #expect(u.messageCount == 2)
    }

    @Test func nilMessageIDsAlwaysCount() throws {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, TokenBreakdown(input: 1)))
        acc.fold(rec(9_001, TokenBreakdown(input: 1)))
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.tokens == TokenBreakdown(input: 2))
    }

    @Test func emptyProjectPathFallsBackToFirstRecordCwd() throws {
        var acc = SessionAccumulator()
        acc.fold(rec(9_000, TokenBreakdown(input: 1), cwd: "/real/path"))
        acc.fold(rec(9_001, TokenBreakdown(input: 1), cwd: "/other"))
        let u = try #require(acc.usage(id: "s", projectPath: "", origin: .cli, title: nil, now: now))
        #expect(u.projectPath == "/real/path")
    }

    @Test func burnRateCountsOnlyTrailingWindow() throws {
        var acc = SessionAccumulator(burnWindow: 300)
        acc.fold(rec(now.timeIntervalSince1970 - 600, TokenBreakdown(input: 1000)))  // outside
        acc.fold(rec(now.timeIntervalSince1970 - 60, TokenBreakdown(input: 50)))     // inside
        let u = try #require(acc.usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.burnRate == 10)  // 50 tokens / 5 min
    }

    @Test func mergedCombinesParentAndSubagentUsage() throws {
        var parent = SessionAccumulator(burnWindow: 300)
        parent.fold(rec(9_000, TokenBreakdown(input: 10), model: "a", cwd: "/parent"))
        var sub = SessionAccumulator(burnWindow: 300)
        sub.fold(rec(9_500, TokenBreakdown(output: 20), model: "b", cwd: "/sub-worktree"))

        let u = try #require(parent.merged(with: sub)
            .usage(id: "s", projectPath: "", origin: .cli, title: nil, now: now))
        #expect(u.tokens == TokenBreakdown(input: 10, output: 20))
        #expect(u.models == ["a", "b"])
        #expect(u.messageCount == 2)
        #expect(u.firstActivity == Date(timeIntervalSince1970: 9_000))
        #expect(u.lastActivity == Date(timeIntervalSince1970: 9_500))
        // The parent transcript's cwd wins: it is what the process probe matches.
        #expect(u.projectPath == "/parent")
    }

    @Test func mergedBurnRateSpansBothSides() throws {
        var parent = SessionAccumulator(burnWindow: 300)
        parent.fold(rec(now.timeIntervalSince1970 - 60, TokenBreakdown(input: 30)))
        var sub = SessionAccumulator(burnWindow: 300)
        sub.fold(rec(now.timeIntervalSince1970 - 30, TokenBreakdown(output: 20)))
        let u = try #require(parent.merged(with: sub)
            .usage(id: "s", projectPath: "/p", origin: .cli, title: nil, now: now))
        #expect(u.burnRate == 10)  // 50 tokens / 5 min
    }
}
