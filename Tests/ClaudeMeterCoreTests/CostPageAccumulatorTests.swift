@testable import ClaudeMeterCore
import XCTest

final class CostPageAccumulatorTests: XCTestCase {
    private func day(_ d: Int, _ amount: Decimal) -> CostDay {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = d
        c.timeZone = TimeZone(identifier: "UTC")
        return CostDay(
            start: Calendar(identifier: .gregorian).date(from: c)!,
            amountUSD: amount,
            byModel: [],
        )
    }

    private func page(_ days: [CostDay], next: String? = nil,
                      skippedRows: Int = 0, skippedBuckets: Int = 0) -> CostReportDecoder.Page {
        CostReportDecoder.Page(days: days, nextPage: next,
                               skippedRows: skippedRows, skippedBuckets: skippedBuckets)
    }

    func testAccumulatesPagesInOrderAndReportsTheNextCursor() throws {
        var accumulator = CostPageAccumulator()
        XCTAssertEqual(try accumulator.accept(page([day(1, 1)], next: "p2")), "p2")
        XCTAssertNil(try accumulator.accept(page([day(2, 2)])))
        XCTAssertEqual(accumulator.days.map(\.amountUSD), [1, 2])
    }

    // A server that re-serves a bucket across pages would otherwise be summed twice:
    // 12 repeats turn a real $1.37 day into $16.43.
    func testDeduplicatesDaysByStart() throws {
        var accumulator = CostPageAccumulator()
        _ = try accumulator.accept(page([day(1, 1), day(2, 2)], next: "p2"))
        _ = try accumulator.accept(page([day(2, 2), day(3, 3)]))
        XCTAssertEqual(accumulator.days.count, 3)
        XCTAssertEqual(accumulator.days.reduce(0) { $0 + $1.amountUSD }, 6)
    }

    func testThrowsWhenTheServerRepeatsACursor() throws {
        var accumulator = CostPageAccumulator()
        _ = try accumulator.accept(page([day(1, 1)], next: "same"))
        XCTAssertThrowsError(try accumulator.accept(page([day(2, 2)], next: "same"))) { error in
            XCTAssertEqual(error as? CostPageAccumulator.Failure, .repeatedCursor)
        }
    }

    // Exhausting the page budget must fail loudly: returning what we have would present
    // an understated total as if it were complete.
    func testThrowsWhenThePageBudgetIsExhausted() throws {
        var accumulator = CostPageAccumulator()
        XCTAssertThrowsError(
            try (0 ..< (CostPageAccumulator.maxPages + 1)).forEach { i in
                _ = try accumulator.accept(page([day(i + 1, 1)], next: "p\(i)"))
            },
        ) { error in
            XCTAssertEqual(error as? CostPageAccumulator.Failure, .tooManyPages)
        }
    }

    func testTracksSkipsAcrossPages() throws {
        var accumulator = CostPageAccumulator()
        _ = try accumulator.accept(page([day(1, 1)], next: "p2", skippedRows: 2))
        _ = try accumulator.accept(page([day(2, 2)], skippedBuckets: 3))
        XCTAssertEqual(accumulator.skippedRows, 2)
        XCTAssertEqual(accumulator.skippedBuckets, 3)
        XCTAssertTrue(accumulator.isDegraded)
    }

    func testACleanRunIsNotDegraded() throws {
        var accumulator = CostPageAccumulator()
        _ = try accumulator.accept(page([day(1, 1)]))
        XCTAssertFalse(accumulator.isDegraded)
    }
}
