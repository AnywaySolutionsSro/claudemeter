import XCTest
@testable import ClaudeMeterCore

final class BurnRateTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 2_000_000)

    private func sample(_ minutes: Double, _ util: Double, resetsAt: Date? = nil) -> UsageSample {
        UsageSample(
            timestamp: Date(timeIntervalSince1970: 1_000_000 + minutes * 60),
            sessionUtilization: util,
            sessionResetsAt: resetsAt ?? reset,
            weeklyUtilization: nil
        )
    }

    func testSteadyBurnRateAndEta() {
        // 20% over 30 minutes == 40%/hour. From 40% used, 60 left → 1.5h to limit.
        let samples = [sample(0, 20), sample(30, 40)]
        let now = Date(timeIntervalSince1970: 1_000_000 + 30 * 60)
        let estimate = BurnRate.estimate(samples: samples, now: now)

        XCTAssertEqual(estimate?.percentPerHour ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(estimate?.etaToLimit ?? 0, 1.5 * 3600, accuracy: 1)
        XCTAssertTrue(estimate?.isBurning ?? false)
    }

    func testIdleIsNotBurning() {
        let samples = [sample(0, 50), sample(30, 50)]
        let now = Date(timeIntervalSince1970: 1_000_000 + 30 * 60)
        let estimate = BurnRate.estimate(samples: samples, now: now)
        XCTAssertEqual(estimate?.percentPerHour, 0)
        XCTAssertNil(estimate?.etaToLimit)
        XCTAssertFalse(estimate?.isBurning ?? true)
    }

    func testResetDoesNotProduceNegativeBurn() {
        // Old window high, new window (later reset) low — only the new window counts.
        let newReset = reset.addingTimeInterval(5 * 3600)
        let samples = [
            sample(0, 90),
            sample(30, 5, resetsAt: newReset),
            sample(60, 15, resetsAt: newReset),
        ]
        let now = Date(timeIntervalSince1970: 1_000_000 + 60 * 60)
        let estimate = BurnRate.estimate(samples: samples, now: now)
        // 10% over 30 min in the new window == 20%/h, never negative.
        XCTAssertEqual(estimate?.percentPerHour ?? 0, 20, accuracy: 0.001)
    }

    func testNeedsTwoSpacedSamples() {
        XCTAssertNil(BurnRate.estimate(samples: [sample(0, 10)], now: Date()))
    }

    func testRejectsTooShortASpan() {
        // Two samples only 2 minutes apart — below the minimum span, too noisy to trust.
        let samples = [sample(0, 10), sample(2, 14)]
        let now = Date(timeIntervalSince1970: 1_000_000 + 2 * 60)
        XCTAssertNil(BurnRate.estimate(samples: samples, now: now))
    }

    func testSmoothsNoisyTrend() {
        // A ~40%/h trend with per-sample noise should still regress near 40, not swing wildly.
        let samples = [sample(0, 0), sample(15, 12), sample(30, 18), sample(45, 33), sample(60, 40)]
        let now = Date(timeIntervalSince1970: 1_000_000 + 60 * 60)
        let rate = BurnRate.estimate(samples: samples, now: now)?.percentPerHour ?? 0
        XCTAssertGreaterThan(rate, 30)
        XCTAssertLessThan(rate, 50)
    }
}
