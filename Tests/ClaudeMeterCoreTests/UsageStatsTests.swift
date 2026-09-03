@testable import ClaudeMeterCore
import XCTest

final class UsageStatsTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 2_000_000)

    private func sample(_ minutes: Double, _ util: Double, resetsAt: Date? = nil) -> UsageSample {
        UsageSample(
            timestamp: Date(timeIntervalSince1970: 1_000_000 + minutes * 60),
            sessionUtilization: util,
            sessionResetsAt: resetsAt ?? reset,
            weeklyUtilization: nil,
        )
    }

    func testTypicalPaceIsMedianOfPositiveRates() {
        // Rates: 0→20 in 1h (20), 20→30 in 1h (10), 30→90 in 1h (60) → median of [10,20,60] = 20.
        let samples = [sample(0, 0), sample(60, 20), sample(120, 30), sample(180, 90)]
        XCTAssertEqual(UsageStats.typicalPercentPerHour(samples: samples) ?? 0, 20, accuracy: 0.001)
    }

    func testPaceRatio() {
        XCTAssertEqual(UsageStats.paceRatio(current: 42, typical: 20) ?? 0, 2.1, accuracy: 0.001)
        XCTAssertNil(UsageStats.paceRatio(current: 42, typical: nil))
        XCTAssertNil(UsageStats.paceRatio(current: 0, typical: 20))
    }

    func testCrossedThresholds() {
        XCTAssertEqual(UsageStats.crossedThresholds(previous: 75, current: 92, thresholds: [80, 90, 100]), [80, 90])
        XCTAssertEqual(UsageStats.crossedThresholds(previous: 91, current: 95, thresholds: [80, 90, 100]), [])
        XCTAssertEqual(UsageStats.crossedThresholds(previous: nil, current: 85, thresholds: [80, 90, 100]), [80])
    }

    func testDidRefillOnlyOnSharpDrop() {
        // Real reset: 90% → 5%.
        XCTAssertTrue(UsageStats.didRefill(previousUtilization: 90, currentUtilization: 5))
        // Steady usage (the false-positive case): 62% → 62%.
        XCTAssertFalse(UsageStats.didRefill(previousUtilization: 62, currentUtilization: 62))
        // Normal climb within a window.
        XCTAssertFalse(UsageStats.didRefill(previousUtilization: 38, currentUtilization: 40))
        // No prior reading.
        XCTAssertFalse(UsageStats.didRefill(previousUtilization: nil, currentUtilization: 5))
        // Small dip (jitter) doesn't count.
        XCTAssertFalse(UsageStats.didRefill(previousUtilization: 40, currentUtilization: 30))
    }

    func testMaxedWindows() {
        let r1 = reset, r2 = reset.addingTimeInterval(5 * 3600)
        let samples = [
            sample(0, 96, resetsAt: r1),
            sample(30, 99, resetsAt: r1), // same window, counts once
            sample(400, 97, resetsAt: r2), // second window
            sample(430, 50, resetsAt: r2),
        ]
        XCTAssertEqual(UsageStats.maxedWindows(samples: samples, since: Date(timeIntervalSince1970: 0)), 2)
    }

    // A 5-hour refill is useless while the weekly window is exhausted: typing
    // `continue` just hits the weekly limit again. The gate treats a missing
    // bucket as "not exhausted" so accounts without weekly data keep working.
    func testWeeklyExhaustionGate() {
        XCTAssertTrue(UsageStats.isExhausted(100))
        XCTAssertTrue(UsageStats.isExhausted(120))
        XCTAssertFalse(UsageStats.isExhausted(99.9))
        XCTAssertFalse(UsageStats.isExhausted(nil))
    }
}
