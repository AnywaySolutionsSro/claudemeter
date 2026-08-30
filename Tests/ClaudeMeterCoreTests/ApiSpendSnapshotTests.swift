@testable import ClaudeMeterCore
import XCTest

final class ApiSpendSnapshotTests: XCTestCase {
    /// 2026-08-21T00:00:00Z and the days after it.
    private func utcDay(_ day: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = day
        components.hour = 0; components.minute = 0; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func snapshot() -> ApiSpendSnapshot {
        ApiSpendSnapshot(
            days: [
                CostDay(start: utcDay(21), amountUSD: Decimal(string: "1.3691")!,
                        byModel: [ModelSpend(model: "claude-sonnet-5", amountUSD: Decimal(string: "1.3691")!)]),
                CostDay(start: utcDay(22), amountUSD: Decimal(string: "1.2186")!,
                        byModel: [ModelSpend(model: "claude-sonnet-5", amountUSD: Decimal(string: "1.2186")!),
                                  ModelSpend(model: "claude-opus-5", amountUSD: Decimal(string: "0.5000")!)]),
            ],
            fetchedAt: utcDay(23),
        )
    }

    func testTotalSumsEveryDay() {
        XCTAssertEqual(snapshot().totalUSD, Decimal(string: "2.5877"))
    }

    func testTodayMatchesTheUTCDayContainingNow() {
        // 23:30 UTC on the 22nd still belongs to the 22nd's bucket.
        let late = utcDay(22).addingTimeInterval(23 * 3600 + 1800)
        XCTAssertEqual(snapshot().todayUSD(now: late), Decimal(string: "1.2186"))
    }

    func testTodayIsZeroWhenNoBucketExistsYet() {
        XCTAssertEqual(snapshot().todayUSD(now: utcDay(25)), 0)
    }

    func testByModelAggregatesAcrossDaysDescending() {
        let models = snapshot().byModel
        XCTAssertEqual(models.map(\.model), ["claude-sonnet-5", "claude-opus-5"])
        XCTAssertEqual(models[0].amountUSD, Decimal(string: "2.5877"))
        XCTAssertEqual(models[1].amountUSD, Decimal(string: "0.5000"))
    }

    func testIsEmptyWhenNoDaysCarrySpend() {
        let empty = ApiSpendSnapshot(days: [], fetchedAt: utcDay(23))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(snapshot().isEmpty)
    }

    func testRoundTripsThroughCodableForTheWidget() throws {
        let data = try JSONEncoder().encode(snapshot())
        XCTAssertEqual(try JSONDecoder().decode(ApiSpendSnapshot.self, from: data), snapshot())
    }

    func testFormatsSmallAmountsToCents() throws {
        XCTAssertEqual(try Formatting.usd(XCTUnwrap(Decimal(string: "2.5877"))), "$2.59")
        XCTAssertEqual(Formatting.usd(0), "$0.00")
    }
}
