@testable import ClaudeMeterCore
import XCTest

final class ResetMomentTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .gmt
    private let h24 = Locale(identifier: "en_GB")
    private let h12 = Locale(identifier: "en_US")

    /// 2026-11-23 19:41 UTC, a Monday.
    private let now = Date(timeIntervalSince1970: 1_795_462_860)

    private func at(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testLaterTodaySaysToday() throws {
        let reset = try at("2026-11-23T23:05:00Z")
        XCTAssertEqual(Formatting.resetMoment(reset, now: now, timeZone: utc, locale: h24), "today 23:05")
    }

    func testTomorrowSaysTomorrow() throws {
        let reset = try at("2026-11-24T04:00:00Z")
        XCTAssertEqual(Formatting.resetMoment(reset, now: now, timeZone: utc, locale: h24), "tomorrow 04:00")
    }

    func testLaterThisWeekNamesTheWeekdayAndDate() throws {
        let reset = try at("2026-11-28T06:00:00Z")
        XCTAssertEqual(Formatting.resetMoment(reset, now: now, timeZone: utc, locale: h24), "Sat 28 Nov 06:00")
    }

    func testTwelveHourLocaleUsesAmPm() throws {
        let reset = try at("2026-11-28T18:30:00Z")
        XCTAssertEqual(Formatting.resetMoment(reset, now: now, timeZone: utc, locale: h12), "Sat 28 Nov 6:30 PM")
    }

    /// The day boundary is the viewer's, not UTC's: 01:00 UTC on the 24th is still
    /// the evening of the 23rd in New York.
    func testDayIsJudgedInTheViewersTimeZone() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let reset = try at("2026-11-24T01:00:00Z")
        XCTAssertEqual(Formatting.resetMoment(reset, now: now, timeZone: newYork, locale: h12), "today 8:00 PM")
    }

    func testPastResetStillReadsAsAMoment() throws {
        let reset = try at("2026-11-23T19:00:00Z")
        XCTAssertEqual(Formatting.resetMoment(reset, now: now, timeZone: utc, locale: h24), "today 19:00")
    }
}
