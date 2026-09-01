@testable import ClaudeMeterCore
import XCTest

final class ApiSpendSnapshotTests: XCTestCase {
    private func utcDay(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = month; components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func snapshot() -> ApiSpendSnapshot {
        ApiSpendSnapshot(
            days: [
                CostDay(start: utcDay(8, 21), amountUSD: Decimal(string: "1.3691")!,
                        byModel: [ModelSpend(model: "claude-sonnet-5",
                                             amountUSD: Decimal(string: "1.3691")!)]),
                CostDay(start: utcDay(8, 22), amountUSD: Decimal(string: "1.2186")!,
                        byModel: [ModelSpend(model: "claude-sonnet-5",
                                             amountUSD: Decimal(string: "1.2186")!),
                                  ModelSpend(model: "claude-opus-5",
                                             amountUSD: Decimal(string: "0.5000")!)]),
            ],
            fetchedAt: utcDay(8, 23),
        )
    }

    func testMonthToDateSumsDaysInTheCurrentUTCMonth() {
        XCTAssertEqual(snapshot().monthToDateUSD(now: utcDay(8, 23)), Decimal(string: "2.5877"))
    }

    // On the 1st the fetched window reaches back into the previous month for the latest
    // completed day (see `CostWindow`). That day is last month's spend, so month-to-date
    // is legitimately zero — and the API cannot return a bucket for today itself.
    func testMonthToDateIsZeroOnTheFirstOfTheMonth() {
        let firstOfMonth = ApiSpendSnapshot(
            days: [CostDay(start: utcDay(8, 31), amountUSD: 5, byModel: [])],
            fetchedAt: utcDay(9, 1, 19),
        )
        XCTAssertEqual(firstOfMonth.monthToDateUSD(now: utcDay(9, 1, 19)), 0)
        // ...but the previous month's last day is still the freshest completed figure.
        XCTAssertEqual(firstOfMonth.latestDayUSD, 5)
    }

    func testMonthToDateCountsOnlyTheCurrentMonthOnceItHasCompletedDays() {
        let acrossMonths = ApiSpendSnapshot(
            days: [
                CostDay(start: utcDay(8, 31), amountUSD: 5, byModel: []),
                CostDay(start: utcDay(9, 1), amountUSD: 2, byModel: []),
            ],
            fetchedAt: utcDay(9, 2),
        )
        XCTAssertEqual(acrossMonths.monthToDateUSD(now: utcDay(9, 2)), 2)
    }

    // The Cost API never reports the current day, so the headline "recent" figure is the
    // most recent COMPLETED day, not today.
    func testLatestDayIsTheMostRecentCompletedBucket() {
        XCTAssertEqual(snapshot().latestDayUSD, Decimal(string: "1.2186"))
        XCTAssertEqual(snapshot().latestDay?.start, utcDay(8, 22))
    }

    func testLatestDayIsZeroWhenThereAreNoDays() {
        let empty = ApiSpendSnapshot(days: [], fetchedAt: utcDay(8, 23))
        XCTAssertEqual(empty.latestDayUSD, 0)
        XCTAssertNil(empty.latestDay)
        XCTAssertTrue(empty.isEmpty)
    }

    func testByModelAggregatesTheCurrentMonthDescending() {
        let models = snapshot().byModel(now: utcDay(8, 23))
        XCTAssertEqual(models.map(\.model), ["claude-sonnet-5", "claude-opus-5"])
        XCTAssertEqual(models[0].amountUSD, Decimal(string: "2.5877"))
        XCTAssertEqual(models[1].amountUSD, Decimal(string: "0.5000"))
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
