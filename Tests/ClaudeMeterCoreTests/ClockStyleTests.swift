@testable import ClaudeMeterCore
import XCTest

final class ClockStyleTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let enGB = Locale(identifier: "en_GB")
    private let enUS = Locale(identifier: "en_US")
    // 2026-11-27 14:05:00 UTC
    private let moment = Date(timeIntervalSince1970: 1_795_788_300)

    func testTwelveForcesAMPM() {
        XCTAssertEqual(Formatting.clockTime(moment, style: .twelve, timeZone: utc, locale: enGB), "2:05 PM")
    }

    func testTwentyFourForcesHH() {
        XCTAssertEqual(Formatting.clockTime(moment, style: .twentyFour, timeZone: utc, locale: enUS), "14:05")
    }

    func testSystemFollowsLocale() {
        XCTAssertEqual(Formatting.clockTime(moment, style: .system, timeZone: utc, locale: enUS), "2:05 PM")
        XCTAssertEqual(Formatting.clockTime(moment, style: .system, timeZone: utc, locale: enGB), "14:05")
    }

    func testResetMomentHonoursStyle() {
        let now = moment.addingTimeInterval(-86400)
        XCTAssertEqual(
            Formatting.resetMoment(moment, now: now, timeZone: utc, locale: enGB, style: .twelve),
            "tomorrow 2:05 PM",
        )
    }

    func testDateTime() {
        XCTAssertEqual(
            Formatting.dateTime(moment, style: .twentyFour, timeZone: utc, locale: enUS), "27 Nov 14:05",
        )
        XCTAssertEqual(
            Formatting.dateTime(moment, style: .twelve, timeZone: utc, locale: enGB), "27 Nov 2:05 PM",
        )
    }

    func testLabelsAndCodable() throws {
        XCTAssertEqual(ClockStyle.allCases.map(\.label), ["System", "24-hour", "12-hour"])
        let data = try JSONEncoder().encode(ClockStyle.twelve)
        XCTAssertEqual(try JSONDecoder().decode(ClockStyle.self, from: data), .twelve)
    }
}
