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

    private func utcDay2(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
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
        // nil, not 0 — "no data" must never render as "$0.00".
        XCTAssertNil(empty.latestDayUSD)
        XCTAssertNil(empty.latestDay)
        XCTAssertNil(empty.monthToDateUSD(now: utcDay(8, 23)))
        XCTAssertNil(empty.previousMonthUSD(now: utcDay(8, 23)))
        XCTAssertTrue(empty.isEmpty)
    }

    func testByModelAggregatesTheCurrentMonthDescending() {
        let models = snapshot().byModel(now: utcDay(8, 23))
        XCTAssertEqual(models.map(\.model), ["claude-sonnet-5", "claude-opus-5"])
        XCTAssertEqual(models[0].amountUSD, Decimal(string: "2.5877"))
        XCTAssertEqual(models[1].amountUSD, Decimal(string: "0.5000"))
    }

    func testPreviousMonthSumsOnlyThePriorUTCMonth() {
        let twoMonths = ApiSpendSnapshot(
            days: [
                CostDay(start: utcDay(7, 15), amountUSD: 9, byModel: []),
                CostDay(start: utcDay(8, 10), amountUSD: 4, byModel: []),
                CostDay(start: utcDay(8, 11), amountUSD: 1, byModel: []),
            ],
            fetchedAt: utcDay(8, 20),
        )
        XCTAssertEqual(twoMonths.previousMonthUSD(now: utcDay(8, 20)), 9)
        XCTAssertEqual(twoMonths.monthToDateUSD(now: utcDay(8, 20)), 5)
    }

    func testPreviousMonthCrossesAYearBoundary() {
        let acrossYear = ApiSpendSnapshot(
            days: [CostDay(start: utcDay2(2025, 12, 20), amountUSD: 7, byModel: [])],
            fetchedAt: utcDay2(2026, 1, 5),
        )
        XCTAssertEqual(acrossYear.previousMonthUSD(now: utcDay2(2026, 1, 5)), 7)
        XCTAssertEqual(acrossYear.monthToDateUSD(now: utcDay2(2026, 1, 5)), 0)
    }

    func testPreviousMonthIsZeroWhenNothingWasSpent() {
        XCTAssertEqual(snapshot().previousMonthUSD(now: utcDay(8, 23)), 0)
    }

    func testKnowsWhenItIsStaleAndWhenItPredatesTheMonthAsked() {
        let snap = ApiSpendSnapshot(days: [], fetchedAt: utcDay(8, 23))
        XCTAssertFalse(snap.isStale(now: utcDay(8, 23, 12)))
        XCTAssertTrue(snap.isStale(now: utcDay(8, 25)))
        XCTAssertFalse(snap.predatesMonth(of: utcDay(8, 30)))
        XCTAssertTrue(snap.predatesMonth(of: utcDay(9, 2)))
    }

    func testDayLabelOnlySaysYesterdayWhenItReallyIs() {
        XCTAssertEqual(Formatting.utcDayLabel(utcDay(8, 22), now: utcDay(8, 23, 10)), "Yesterday")
        XCTAssertEqual(Formatting.utcDayLabel(utcDay(8, 12), now: utcDay(8, 23, 10)), "12 Aug")
        XCTAssertEqual(Formatting.utcDayLabel(utcDay2(2025, 12, 3), now: utcDay(8, 23)), "3 Dec 2025")
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
