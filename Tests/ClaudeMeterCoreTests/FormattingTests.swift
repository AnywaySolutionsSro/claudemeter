@testable import ClaudeMeterCore
import XCTest

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

    func testBucketRemainingAndReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let bucket = UsageBucket(
            utilization: 63,
            resetsAt: now.addingTimeInterval(8000),
        )
        XCTAssertEqual(bucket.percentRemaining, 37)
        XCTAssertEqual(bucket.timeUntilReset(now: now), 8000)
        XCTAssertEqual(try Formatting.countdown(XCTUnwrap(bucket.timeUntilReset(now: now))), "2h13m")
    }

    func testUtilizationClamped() {
        XCTAssertEqual(UsageBucket(utilization: 140, resetsAt: nil).utilization, 100)
        XCTAssertEqual(UsageBucket(utilization: -5, resetsAt: nil).percentRemaining, 100)
    }

    func testTokenCount() {
        XCTAssertEqual(Formatting.tokenCount(999), "999")
        XCTAssertEqual(Formatting.tokenCount(1_500), "1.5K")
        XCTAssertEqual(Formatting.tokenCount(28_046), "28K")
        XCTAssertEqual(Formatting.tokenCount(1_250_000), "1.2M") // %.1f rounds half-to-even
        XCTAssertEqual(Formatting.tokenCount(1_300_000), "1.3M")
    }
}

extension FormattingTests {
    func testUSDRoundsHalfUpToMatchTheInvoice() throws {
        // NumberFormatter defaults to half-even, which would give $0.02 / $0.12.
        XCTAssertEqual(try Formatting.usd(XCTUnwrap(Decimal(string: "0.025"))), "$0.03")
        XCTAssertEqual(try Formatting.usd(XCTUnwrap(Decimal(string: "0.125"))), "$0.13")
    }

    func testUSDNeverShowsRealSpendAsZero() throws {
        // Sub-cent days are normal — the API reports cents to 4 decimal places.
        XCTAssertEqual(try Formatting.usd(XCTUnwrap(Decimal(string: "0.004"))), "<$0.01")
        XCTAssertEqual(try Formatting.usd(XCTUnwrap(Decimal(string: "-0.001"))), "-<$0.01")
        XCTAssertEqual(Formatting.usd(0), "$0.00")
    }

    func testUSDDistinguishesAbsentDataFromZero() {
        XCTAssertEqual(Formatting.usd(nil), "—")
        XCTAssertEqual(Formatting.usd(Decimal(0)), "$0.00")
    }
}
