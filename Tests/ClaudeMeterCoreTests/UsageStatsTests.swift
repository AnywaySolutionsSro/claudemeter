import XCTest
@testable import ClaudeMeterCore

final class UsageStatsTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 2_000_000)

    private func sample(_ minutes: Double, _ util: Double, resetsAt: Date? = nil) -> UsageSample {
        UsageSample(
            timestamp: Date(timeIntervalSince1970: 1_000_000 + minutes * 60),
            sessionUtilization: util,
            sessionResetsAt: resetsAt ?? reset,
            weeklyUtilization: nil
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

    func testDidReset() {
        let later = reset.addingTimeInterval(3600)
        XCTAssertTrue(UsageStats.didReset(previousResetsAt: reset, currentResetsAt: later))
        XCTAssertFalse(UsageStats.didReset(previousResetsAt: reset, currentResetsAt: reset))
        XCTAssertFalse(UsageStats.didReset(previousResetsAt: nil, currentResetsAt: later))
    }

    func testMaxedWindows() {
        let r1 = reset, r2 = reset.addingTimeInterval(5 * 3600)
        let samples = [
            sample(0, 96, resetsAt: r1),
            sample(30, 99, resetsAt: r1),   // same window, counts once
            sample(400, 97, resetsAt: r2),  // second window
            sample(430, 50, resetsAt: r2),
        ]
        XCTAssertEqual(UsageStats.maxedWindows(samples: samples, since: Date(timeIntervalSince1970: 0)), 2)
    }
}
