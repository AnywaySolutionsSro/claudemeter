@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexLimitsTests {
    private let observed = Date(timeIntervalSince1970: 1_796_000_000)
    private var resets: Date { observed.addingTimeInterval(3600) }

    private func reading(
        _ windows: [CodexWindowReading], limitID: String = "codex", at: Date? = nil,
    ) -> CodexLimitReading {
        CodexLimitReading(limitID: limitID, observedAt: at ?? observed, windows: windows, reachedType: nil)
    }

    private func weekly(_ used: Double, resetsAt: Date?) -> CodexWindowReading {
        CodexWindowReading(usedPercent: used, windowMinutes: 10080, resetsAt: resetsAt)
    }

    @Test func testWeeklyOnlyPlan() {
        let snapshot = CodexLimits.snapshot(from: reading([weekly(4, resetsAt: resets)]), now: observed)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == UsageBucket(utilization: 4, resetsAt: resets))
        #expect(snapshot.fetchedAt == observed)
        #expect(snapshot.limitWindows.map(\.id) == ["Weekly"])
    }

    @Test func sessionAndWeeklyMapByWindowLengthNotPosition() {
        let session = CodexWindowReading(usedPercent: 30, windowMinutes: 300, resetsAt: resets)
        let snapshot = CodexLimits.snapshot(from: reading([weekly(10, resetsAt: resets), session]), now: observed)
        #expect(snapshot.fiveHour?.utilization == 30)
        #expect(snapshot.sevenDay?.utilization == 10)
    }

    @Test func otherWindowLengthsFillWeeklyOnlyWhenFree() {
        let daily = CodexWindowReading(usedPercent: 50, windowMinutes: 1440, resetsAt: resets)
        let alone = CodexLimits.snapshot(from: reading([daily]), now: observed)
        #expect(alone.sevenDay?.utilization == 50)
        let taken = CodexLimits.snapshot(from: reading([daily, weekly(7, resetsAt: resets)]), now: observed)
        #expect(taken.sevenDay?.utilization == 7)
        let takenFirst = CodexLimits.snapshot(from: reading([weekly(7, resetsAt: resets), daily]), now: observed)
        #expect(takenFirst.sevenDay?.utilization == 7)
    }

    @Test func testPassedResetReadsAsFull() {
        let stale = reading([weekly(100, resetsAt: resets)])
        let days = CodexLimits.snapshot(from: stale, now: resets.addingTimeInterval(3 * 86400))
        #expect(days.sevenDay?.utilization == 0)
        #expect(days.sevenDay?.percentRemaining == 100)
        #expect(days.fetchedAt == observed)
        // Exactly at the reset counts as passed; a second before does not.
        #expect(CodexLimits.snapshot(from: stale, now: resets).sevenDay?.utilization == 0)
        #expect(CodexLimits.snapshot(from: stale, now: resets.addingTimeInterval(-1)).sevenDay?.utilization == 100)
        // A full window after its reset crosses no alert threshold.
        let before = CodexLimits.snapshot(from: stale, now: observed)
        let after = CodexLimits.snapshot(from: stale, now: resets.addingTimeInterval(60))
        #expect(UsageStats.crossedWindows(
            previous: before.limitWindows, current: after.limitWindows, thresholds: [80, 90, 100],
        ).isEmpty)
    }

    @Test func isPastReset() {
        let window = weekly(100, resetsAt: resets)
        #expect(!CodexLimits.isPastReset(window, now: observed))
        #expect(CodexLimits.isPastReset(window, now: resets))
        #expect(!CodexLimits.isPastReset(weekly(100, resetsAt: nil), now: .distantFuture))
    }

    @Test func testRefillDetectedWhenResetPasses() {
        let exhausted = reading([weekly(100, resetsAt: resets)])
        let before = CodexLimits.snapshot(from: exhausted, now: resets.addingTimeInterval(-60))
        let after = CodexLimits.snapshot(from: exhausted, now: resets.addingTimeInterval(60))
        let refilled = UsageStats.refilledWindows(previous: before.limitWindows, current: after.limitWindows)
        #expect(refilled.map(\.id) == ["Weekly"])
    }

    @Test func testNewestPerLimitID() {
        let old = reading([weekly(10, resetsAt: resets)], at: observed)
        let new = reading([weekly(20, resetsAt: resets)], at: observed.addingTimeInterval(60))
        let otherNewer = reading([weekly(90, resetsAt: resets)], limitID: "codex_other",
                                 at: observed.addingTimeInterval(600))
        #expect(CodexLimits.newest([old, otherNewer, new]) == new)
        #expect(CodexLimits.newest([otherNewer]) == otherNewer)
        #expect(CodexLimits.newest([]) == nil)
    }
}
