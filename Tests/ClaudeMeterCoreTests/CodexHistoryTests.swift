@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(at offset: TimeInterval, session: Double?, sessionReset: TimeInterval = 3600,
                         weekly: Double? = 40, weeklyReset: TimeInterval = 86400 * 3) -> CodexLimitReading {
        var windows: [CodexWindowReading] = []
        if let session {
            windows.append(CodexWindowReading(usedPercent: session, windowMinutes: 300,
                                              resetsAt: t0.addingTimeInterval(sessionReset)))
        }
        if let weekly {
            windows.append(CodexWindowReading(usedPercent: weekly, windowMinutes: 10080,
                                              resetsAt: t0.addingTimeInterval(weeklyReset)))
        }
        return CodexLimitReading(limitID: "codex", observedAt: t0.addingTimeInterval(offset),
                                 windows: windows, reachedType: nil)
    }

    @Test func noReadingRecordsNothing() {
        #expect(CodexHistory.samplesToRecord(reading: nil, now: t0, history: []).isEmpty)
    }

    @Test func aNewReadingIsRecordedAtItsObservationTime() {
        let samples = CodexHistory.samplesToRecord(reading: reading(at: 0, session: 20),
                                                   now: t0.addingTimeInterval(5), history: [])
        #expect(samples.count == 1)
        #expect(samples.first?.timestamp == t0)
        #expect(samples.first?.sessionUtilization == 20)
        #expect(samples.first?.weeklyUtilization == 40)
        #expect(samples.first?.tracksSession == true)
    }

    @Test func theSameReadingIsRecordedOnlyOnceAcrossScans() {
        let first = reading(at: 0, session: 20)
        var history: [UsageSample] = []
        for scan in 0 ..< 6 {
            history += CodexHistory.samplesToRecord(reading: first, now: t0.addingTimeInterval(Double(scan) * 10),
                                                    history: history)
        }
        #expect(history.count == 1)
        history += CodexHistory.samplesToRecord(reading: reading(at: 120, session: 25),
                                                now: t0.addingTimeInterval(130), history: history)
        #expect(history.map(\.sessionUtilization) == [20, 25])
    }

    /// Live polling sees an unchanged figure every minute; that must not fill the
    /// 4000-sample history in under three days.
    @Test func anUnchangedLiveFigureIsRecordedAtMostEveryFiveMinutes() {
        var history: [UsageSample] = []
        for minute in 0 ..< 12 {
            let offset = Double(minute) * 60
            history += CodexHistory.samplesToRecord(reading: reading(at: offset, session: 20),
                                                    now: t0.addingTimeInterval(offset), history: history)
        }
        #expect(history.map(\.timestamp) == [t0, t0.addingTimeInterval(300), t0.addingTimeInterval(600)])
        // A changed figure is recorded at once.
        history += CodexHistory.samplesToRecord(reading: reading(at: 660, session: 21),
                                                now: t0.addingTimeInterval(660), history: history)
        #expect(history.last?.sessionUtilization == 21)
    }

    @Test func weeklyIsTrackedWithoutASessionWindow() {
        let samples = CodexHistory.samplesToRecord(reading: reading(at: 0, session: nil, weekly: 55),
                                                   now: t0, history: [])
        #expect(samples.first?.tracksSession == false)
        #expect(samples.first?.trackedUtilization == 55)
    }

    @Test func anOldReadingIsRecordedAsObservedNotAsFull() {
        // First seen hours later, after its session reset: the observed figure stands,
        // then one reset point follows.
        let samples = CodexHistory.samplesToRecord(reading: reading(at: 0, session: 80),
                                                   now: t0.addingTimeInterval(7200), history: [])
        #expect(samples.map(\.sessionUtilization) == [80, 0])
        #expect(samples.map(\.timestamp) == [t0, t0.addingTimeInterval(3600)])
    }

    @Test func aPassedResetRecordsOneResetPointInANewWindow() {
        let observed = reading(at: 0, session: 80)
        var history = CodexHistory.samplesToRecord(reading: observed, now: t0, history: [])
        for scan in 1 ... 20 {
            history += CodexHistory.samplesToRecord(reading: observed,
                                                    now: t0.addingTimeInterval(3600 + Double(scan) * 10),
                                                    history: history)
        }
        #expect(history.count == 2)
        let resetPoint = history[1]
        #expect(resetPoint.sessionUtilization == 0)
        #expect(resetPoint.timestamp == t0.addingTimeInterval(3600))
        #expect(!resetPoint.isSameWindow(as: history[0]))
        // The weekly window has not reset, so it keeps its figure and identity.
        #expect(resetPoint.weeklyUtilization == 40)
        #expect(resetPoint.weeklyResetsAt == history[0].weeklyResetsAt)
    }

    @Test func aResetOfAnUntrackedWindowRecordsNothing() {
        let observed = reading(at: 0, session: 30, sessionReset: 86400 * 5, weeklyReset: 3600)
        let history = CodexHistory.samplesToRecord(reading: observed, now: t0, history: [])
        let later = CodexHistory.samplesToRecord(reading: observed, now: t0.addingTimeInterval(7200),
                                                 history: history)
        #expect(later.isEmpty)
    }

    @Test func aReadingWithoutWindowsRecordsNothing() {
        let empty = CodexLimitReading(limitID: "codex", observedAt: t0, windows: [], reachedType: nil)
        #expect(CodexHistory.samplesToRecord(reading: empty, now: t0, history: []).isEmpty)
    }

    @Test func appendingTrimsTheOldestBeyondTheCap() {
        let samples = (0 ..< 5).map {
            UsageSample(timestamp: t0.addingTimeInterval(Double($0)), sessionUtilization: Double($0),
                        sessionResetsAt: nil, weeklyUtilization: nil)
        }
        let trimmed = CodexHistory.appending(Array(samples.suffix(2)), to: Array(samples.prefix(3)), cap: 4)
        #expect(trimmed.map(\.sessionUtilization) == [1, 2, 3, 4])
        #expect(CodexHistory.appending([], to: samples, cap: 4) == samples)
    }
}
