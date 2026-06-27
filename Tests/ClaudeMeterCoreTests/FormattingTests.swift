import XCTest
@testable import ClaudeMeterCore

final class FormattingTests: XCTestCase {
    func testPercentRounds() {
        XCTAssertEqual(Formatting.percent(0), "0%")
        XCTAssertEqual(Formatting.percent(37.4), "37%")
        XCTAssertEqual(Formatting.percent(37.6), "38%")
        XCTAssertEqual(Formatting.percent(100), "100%")
    }

    func testCountdownFormats() {
        XCTAssertEqual(Formatting.countdown(0), "now")
        XCTAssertEqual(Formatting.countdown(-5), "now")
        XCTAssertEqual(Formatting.countdown(8), "8s")
        XCTAssertEqual(Formatting.countdown(47 * 60), "47m")
        XCTAssertEqual(Formatting.countdown(8000), "2h13m")
        XCTAssertEqual(Formatting.countdown(2 * 3600), "2h0m")
    }

    func testBucketRemainingAndReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let bucket = UsageBucket(
            utilization: 63,
            resetsAt: now.addingTimeInterval(8000)
        )
        XCTAssertEqual(bucket.percentRemaining, 37)
        XCTAssertEqual(bucket.timeUntilReset(now: now), 8000)
        XCTAssertEqual(Formatting.countdown(bucket.timeUntilReset(now: now)!), "2h13m")
    }

    func testUtilizationClamped() {
        XCTAssertEqual(UsageBucket(utilization: 140, resetsAt: nil).utilization, 100)
        XCTAssertEqual(UsageBucket(utilization: -5, resetsAt: nil).percentRemaining, 100)
    }
}
