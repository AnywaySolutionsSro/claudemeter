@testable import ClaudeMeterCore
import XCTest

final class UsageResponseDecoderTests: XCTestCase {
    private let decoder = UsageResponseDecoder()
    private let fetchedAt = Date(timeIntervalSince1970: 1_782_000_000)

    func testDecodesAllBuckets() throws {
        let json = """
        {
          "five_hour":       { "utilization": 63, "resets_at": 1782001800 },
          "seven_day":       { "utilization": 21.5, "resets_at": 1782400000 },
          "seven_day_opus":  { "utilization": 80, "resets_at": 1782400000 },
          "seven_day_sonnet":{ "utilization": 5, "resets_at": 1782400000 }
        }
        """.data(using: .utf8)!

        let snap = try decoder.decode(json, fetchedAt: fetchedAt)

        XCTAssertEqual(snap.fiveHour?.utilization, 63)
        XCTAssertEqual(snap.fiveHour?.percentRemaining, 37)
        XCTAssertEqual(snap.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_782_001_800))
        XCTAssertEqual(snap.sevenDay?.utilization, 21.5)
        XCTAssertEqual(snap.sevenDayOpus?.percentRemaining, 20)
        XCTAssertEqual(snap.sevenDaySonnet?.utilization, 5)
        XCTAssertEqual(snap.fetchedAt, fetchedAt)
    }

    func testMissingBucketsBecomeNil() throws {
        let json = #"{ "five_hour": { "utilization": 10, "resets_at": 1782001800 } }"#.data(using: .utf8)!
        let snap = try decoder.decode(json, fetchedAt: fetchedAt)

        XCTAssertNotNil(snap.fiveHour)
        XCTAssertNil(snap.sevenDay)
        XCTAssertNil(snap.sevenDayOpus)
        XCTAssertEqual(snap.primary?.utilization, 10)
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {
          "five_hour": { "utilization": 50, "resets_at": 1782001800, "status": "allowed_warning", "extra": 1 },
          "brand_new_bucket": { "utilization": 99 }
        }
        """.data(using: .utf8)!
        let snap = try decoder.decode(json, fetchedAt: fetchedAt)

        XCTAssertEqual(snap.fiveHour?.status, "allowed_warning")
        XCTAssertEqual(snap.fiveHour?.utilization, 50)
    }

    func testMalformedBodyThrows() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(json, fetchedAt: fetchedAt))
    }

    func testParsesRealApiShapeWithISO8601Resets() throws {
        // Mirrors the live response: ISO-8601 reset strings with microsecond precision,
        // null buckets, and extra dollar fields.
        let json = """
        {
          "five_hour": {
            "utilization": 55.0,
            "resets_at": "2026-06-27T16:19:59.398499+00:00",
            "limit_dollars": null, "used_dollars": null
          },
          "seven_day": {
            "utilization": 11.0,
            "resets_at": "2026-07-04T04:59:59.398532+00:00"
          },
          "seven_day_opus": null,
          "seven_day_sonnet": { "utilization": 0.0, "resets_at": "2026-07-04T04:59:59.398543+00:00" }
        }
        """.data(using: .utf8)!

        let snap = try decoder.decode(json, fetchedAt: fetchedAt)

        XCTAssertEqual(snap.fiveHour?.utilization, 55)
        XCTAssertEqual(snap.fiveHour?.percentRemaining, 45)
        // 2026-06-27T16:19:59Z after stripping fractional seconds.
        XCTAssertEqual(snap.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_782_577_199))
        XCTAssertNotNil(snap.sevenDay?.resetsAt)
        XCTAssertNil(snap.sevenDayOpus)
        XCTAssertEqual(snap.sevenDaySonnet?.utilization, 0)
    }

    func testISODateParsesMicrosecondsAndTimezone() {
        XCTAssertEqual(
            ISODate.parse("2026-06-27T16:19:59.398499+00:00"),
            Date(timeIntervalSince1970: 1_782_577_199),
        )
        XCTAssertEqual(
            ISODate.parse("2026-06-27T16:19:59Z"),
            Date(timeIntervalSince1970: 1_782_577_199),
        )
        XCTAssertNil(ISODate.parse("not a date"))
    }

    func testMostConstrainedPicksHighestUtilization() throws {
        let json = """
        {
          "five_hour":      { "utilization": 30 },
          "seven_day":      { "utilization": 72 },
          "seven_day_opus": { "utilization": 55 }
        }
        """.data(using: .utf8)!
        let snap = try decoder.decode(json, fetchedAt: fetchedAt)
        XCTAssertEqual(snap.mostConstrained?.utilization, 72)
    }
}
