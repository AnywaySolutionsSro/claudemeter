@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexHistoryBackfillTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var weekReset: Date { t0.addingTimeInterval(5 * 86400) }

    private func reading(at offset: TimeInterval, weekly: Double, reset: Date? = nil,
                         id: String = "codex") -> CodexLimitReading {
        CodexLimitReading(limitID: id, observedAt: t0.addingTimeInterval(offset),
                          windows: [CodexWindowReading(usedPercent: weekly, windowMinutes: 10080,
                                                       resetsAt: reset ?? weekReset)],
                          reachedType: nil)
    }

    private func sample(at offset: TimeInterval, weekly: Double) -> UsageSample {
        UsageSample(timestamp: t0.addingTimeInterval(offset), sessionUtilization: nil, sessionResetsAt: nil,
                    weeklyUtilization: weekly, weeklyResetsAt: weekReset)
    }

    @Test func readingsBecomeSortedSamplesUnderTheUsualRules() {
        // Out of order (two sessions), one unchanged repeat inside 5 min, and another limit id.
        let readings = [reading(at: 7200, weekly: 6), reading(at: 0, weekly: 2), reading(at: 60, weekly: 2),
                        reading(at: 3600, weekly: 4), reading(at: 1800, weekly: 99, id: "other")]
        let merged = CodexHistory.backfilled(readings: readings, now: t0.addingTimeInterval(8000), history: [])
        #expect(merged.map(\.timestamp) == [0, 3600, 7200].map { t0.addingTimeInterval($0) })
        #expect(merged.map(\.trackedUtilization) == [2, 4, 6])
    }

    @Test func existingSamplesWinAndTheResultIsMergedAndCapped() {
        let existing = [sample(at: 3600, weekly: 4.5), sample(at: 9000, weekly: 7)]
        let readings = [reading(at: 0, weekly: 2), reading(at: 3600, weekly: 4)]
        let merged = CodexHistory.backfilled(readings: readings, now: t0.addingTimeInterval(9000), history: existing)
        #expect(merged.map(\.trackedUtilization) == [2, 4.5, 7])
        let capped = CodexHistory.backfilled(readings: readings, now: t0.addingTimeInterval(9000),
                                             history: existing, cap: 2)
        #expect(capped.map(\.trackedUtilization) == [4.5, 7])
        // Idempotent.
        #expect(CodexHistory.backfilled(readings: readings, now: t0.addingTimeInterval(9000),
                                        history: merged) == merged)
    }

    @Test func aResetBetweenReadingsAddsOneResetPoint() {
        let firstReset = t0.addingTimeInterval(3600)
        let readings = [reading(at: 0, weekly: 80, reset: firstReset),
                        reading(at: 7200, weekly: 3, reset: t0.addingTimeInterval(7 * 86400))]
        let merged = CodexHistory.backfilled(readings: readings, now: t0.addingTimeInterval(7300), history: [])
        #expect(merged.map(\.trackedUtilization) == [80, 0, 3])
        #expect(merged[1].timestamp == firstReset)
    }

    @Test func onlyOtherLimitIDsAreUsedWhenNoMainOneExists() {
        let merged = CodexHistory.backfilled(readings: [reading(at: 0, weekly: 9, id: "other")],
                                             now: t0, history: [])
        #expect(merged.map(\.trackedUtilization) == [9])
        #expect(CodexHistory.backfilled(readings: [], now: t0, history: []).isEmpty)
    }

    @Test func backfillIsNeededWhenTheWindowStartIsMissing() {
        let current = reading(at: 3 * 86400, weekly: 11)
        #expect(CodexHistory.needsBackfill(history: [], reading: nil))
        #expect(CodexHistory.needsBackfill(history: [sample(at: 3 * 86400 - 1380, weekly: 10)], reading: current))
        // The week began two days before t0: history from before then is enough.
        #expect(!CodexHistory.needsBackfill(history: [sample(at: -3 * 86400, weekly: 0)], reading: current))
        #expect(!CodexHistory.needsBackfill(history: [sample(at: 0, weekly: 0)], reading: nil))
    }

    @Test func withoutAResetDateADayOfHistoryIsEnough() {
        let noReset = CodexLimitReading(limitID: "codex", observedAt: t0,
                                        windows: [CodexWindowReading(usedPercent: 5, windowMinutes: 10080,
                                                                     resetsAt: nil)],
                                        reachedType: nil)
        #expect(CodexHistory.needsBackfill(history: [sample(at: 0, weekly: 1), sample(at: 600, weekly: 2)],
                                           reading: noReset))
        #expect(!CodexHistory.needsBackfill(history: [sample(at: 0, weekly: 1), sample(at: 90000, weekly: 2)],
                                            reading: noReset))
    }

    @Test func sessionStateKeepsOneReadingPerMinute() {
        var history: [CodexLimitReading] = []
        for second in stride(from: 0, to: 180, by: 20) {
            history = CodexSessionState.keeping(reading(at: Double(second), weekly: Double(second)), in: history)
        }
        // t0 is on a minute boundary: the newest reading of each of three minutes.
        #expect(history.map(\.observedAt) == [40, 100, 160].map { t0.addingTimeInterval($0) })
        let many = (0 ..< CodexSessionState.maxLimitHistory + 5).reduce(into: [CodexLimitReading]()) { acc, minute in
            acc = CodexSessionState.keeping(reading(at: Double(minute) * 60, weekly: 1), in: acc)
        }
        #expect(many.count == CodexSessionState.maxLimitHistory)
        #expect(many.first?.observedAt == t0.addingTimeInterval(5 * 60))
    }
}
