@testable import ClaudeMeterCore
import Foundation
import Testing

/// The Codex resume gate: a window refills when its reset passes (whatever its
/// used%), or when a fresh reading drops ≥ 25 points; an exhausted window blocks.
struct CodexRefillTests {
    private let observed = Date(timeIntervalSince1970: 1_796_000_000)
    private var resets: Date { observed.addingTimeInterval(3600) }

    private func snapshot(_ used: Double, resetsAt: Date?, now: Date, observedAt: Date? = nil) -> UsageSnapshot {
        let reading = CodexLimitReading(
            limitID: "codex", observedAt: observedAt ?? observed,
            windows: [CodexWindowReading(usedPercent: used, windowMinutes: 10080, resetsAt: resetsAt)],
            reachedType: nil,
        )
        return CodexLimits.snapshot(from: reading, now: now)
    }

    @Test func resetPassingRefillsEvenBelowTheDropThreshold() {
        // A cutoff via rate_limit_reached_type at 10% used: the drop rule alone misses it.
        let before = snapshot(10, resetsAt: resets, now: resets.addingTimeInterval(-10))
        let after = snapshot(10, resetsAt: resets, now: resets.addingTimeInterval(5))
        let refilled = CodexLimits.refilledWindows(
            previous: before.limitWindows, previousAt: resets.addingTimeInterval(-10),
            current: after, now: resets.addingTimeInterval(5),
        )
        #expect(refilled.map(\.id) == ["Weekly"])
    }

    @Test func alreadyPastResetLastScanIsNotARefillAgain() {
        let first = resets.addingTimeInterval(5)
        let second = resets.addingTimeInterval(15)
        let refilled = CodexLimits.refilledWindows(
            previous: snapshot(100, resetsAt: resets, now: first).limitWindows, previousAt: first,
            current: snapshot(100, resetsAt: resets, now: second), now: second,
        )
        #expect(refilled.isEmpty)
    }

    @Test func noPreviousReadingRefillsNothing() {
        let now = resets.addingTimeInterval(5)
        #expect(CodexLimits.refilledWindows(
            previous: [], previousAt: nil, current: snapshot(100, resetsAt: resets, now: now), now: now,
        ).isEmpty)
    }

    @Test func freshReadingDropOfTwentyFivePointsRefills() {
        let later = observed.addingTimeInterval(60)
        let refilled = CodexLimits.refilledWindows(
            previous: snapshot(90, resetsAt: resets, now: observed).limitWindows, previousAt: observed,
            current: snapshot(10, resetsAt: resets.addingTimeInterval(86400), now: later, observedAt: later),
            now: later,
        )
        #expect(refilled.map(\.id) == ["Weekly"])
    }

    @Test func smallDropBeforeResetIsNoRefill() {
        let later = observed.addingTimeInterval(60)
        #expect(CodexLimits.refilledWindows(
            previous: snapshot(50, resetsAt: resets, now: observed).limitWindows, previousAt: observed,
            current: snapshot(40, resetsAt: resets, now: later), now: later,
        ).isEmpty)
    }

    @Test func bothRulesFiringReportTheWindowOnce() {
        let now = resets.addingTimeInterval(1)
        let refilled = CodexLimits.refilledWindows(
            previous: snapshot(100, resetsAt: resets, now: observed).limitWindows, previousAt: observed,
            current: snapshot(100, resetsAt: resets, now: now), now: now,
        )
        #expect(refilled.map(\.id) == ["Weekly"])
    }

    @Test func gateBlocksWhileAWindowIsExhausted() {
        let now = observed.addingTimeInterval(60)
        let gate = CodexLimits.gate(
            previous: [], previousAt: nil, current: snapshot(100, resetsAt: resets, now: now), now: now,
        )
        guard case let .blocked(window) = gate else { Issue.record("expected blocked"); return }
        #expect(window.id == "Weekly")
    }

    @Test func gateClearsWithTheRefilledWindowsOnceTheResetPasses() {
        let before = resets.addingTimeInterval(-10)
        let now = resets.addingTimeInterval(10)
        let gate = CodexLimits.gate(
            previous: snapshot(100, resetsAt: resets, now: before).limitWindows, previousAt: before,
            current: snapshot(100, resetsAt: resets, now: now), now: now,
        )
        #expect(gate == .clear(refilled: snapshot(100, resetsAt: resets, now: now).limitWindows))
    }

    @Test func windowWithoutResetTimeNeverRefillsByTime() {
        let now = observed.addingTimeInterval(60)
        #expect(CodexLimits.refilledWindows(
            previous: snapshot(10, resetsAt: nil, now: observed).limitWindows, previousAt: observed,
            current: snapshot(10, resetsAt: nil, now: now), now: now,
        ).isEmpty)
    }
}
