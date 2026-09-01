@testable import ClaudeMeterCore
import XCTest

/// The Cost API only reports **completed** UTC days: it clamps `ending_at` to the start of
/// today, and rejects a range that collapses to zero length with HTTP 400
/// ("ending date must be after starting date"). Verified 2026-09-01: a request for
/// Aug 30 → Sep 02 returns only Aug 30 and Aug 31.
final class CostWindowTests: XCTestCase {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // The window spans the PREVIOUS month too, so the dropdown can show last month's total.
    func testSpansFromTheStartOfThePreviousMonth() {
        let window = CostWindow.trailing(now: utc(2026, 8, 15, 12))
        XCTAssertEqual(window.start, utc(2026, 7, 1))
        XCTAssertEqual(window.end, utc(2026, 8, 15))
    }

    func testSpansAcrossAYearBoundary() {
        let window = CostWindow.trailing(now: utc(2026, 1, 10, 8))
        XCTAssertEqual(window.start, utc(2025, 12, 1))
        XCTAssertEqual(window.end, utc(2026, 1, 10))
    }

    // The bug that produced HTTP 400 in production on 2026-09-01: month-to-date on the
    // first of the month is an empty range, because today is never a completed day.
    func testFirstOfMonthStillRequestsANonEmptyRange() {
        let window = CostWindow.trailing(now: utc(2026, 9, 1, 19))
        XCTAssertEqual(window.end, utc(2026, 9, 1))
        XCTAssertEqual(window.start, utc(2026, 8, 1))
        XCTAssertLessThan(window.start, window.end)
    }

    func testEndIsNeverInTheFuture() {
        let now = utc(2026, 8, 15, 23)
        XCTAssertLessThanOrEqual(CostWindow.trailing(now: now).end, now)
    }

    func testEndIsAlwaysStrictlyAfterStart() {
        for day in 1 ... 28 {
            let window = CostWindow.trailing(now: utc(2026, 2, day, 6))
            XCTAssertLessThan(window.start, window.end, "day \(day)")
        }
    }
}
