@testable import ClaudeMeterCore
import XCTest

final class CostReportDecoderTests: XCTestCase {
    private let decoder = CostReportDecoder()

    /// The verified shape of `GET /v1/organizations/cost_report`, synthetic values.
    /// One day, split into the separate input/output rows the API really returns.
    private let realShape = Data("""
    {"data":[
      {"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
        {"currency":"USD","amount":"103.1554","workspace_id":null,
         "description":"Claude Sonnet 5 - Input Tokens","cost_type":"tokens",
         "context_window":"0-200k","model":"claude-sonnet-5","service_tier":"standard",
         "token_type":"uncached_input_tokens","inference_geo":"global"},
        {"currency":"USD","amount":"33.755","workspace_id":null,
         "description":"Claude Sonnet 5 - Output Tokens","cost_type":"tokens",
         "context_window":"0-200k","model":"claude-sonnet-5","service_tier":"standard",
         "token_type":"output_tokens","inference_geo":"global"}
      ]},
      {"starting_at":"2026-08-22T00:00:00Z","ending_at":"2026-08-23T00:00:00Z","results":[]}
    ],"has_more":false,"next_page":null}
    """.utf8)

    // THE bug this decoder exists to prevent: `amount` is a decimal string in CENTS.
    // "103.1554" + "33.755" = 136.9104 cents = $1.3691, NOT $136.91.
    func testConvertsCentsToDollars() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days[0].amountUSD, Decimal(string: "1.369104"))
    }

    func testSumsTheSeparateInputAndOutputRowsOfOneDay() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days[0].byModel.count, 1)
        XCTAssertEqual(page.days[0].byModel[0].model, "claude-sonnet-5")
        XCTAssertEqual(page.days[0].byModel[0].amountUSD, Decimal(string: "1.369104"))
    }

    func testParsesTheBucketStartAsUTC() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days[0].start, Date(timeIntervalSince1970: 1_787_270_400))
    }

    func testKeepsDaysWithEmptyResultsAsZero() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days.count, 2)
        XCTAssertEqual(page.days[1].amountUSD, 0)
        XCTAssertTrue(page.days[1].byModel.isEmpty)
    }

    func testReportsNoNextPageWhenHasMoreIsFalse() throws {
        XCTAssertNil(try decoder.decode(realShape).nextPage)
    }

    func testReportsTheNextPageCursorWhenHasMoreIsTrue() throws {
        let paged = Data("""
        {"data":[],"has_more":true,"next_page":"page_abc123"}
        """.utf8)
        XCTAssertEqual(try decoder.decode(paged).nextPage, "page_abc123")
    }

    func testIgnoresACursorWhenHasMoreIsFalse() throws {
        let stale = Data("""
        {"data":[],"has_more":false,"next_page":"page_abc123"}
        """.utf8)
        XCTAssertNil(try decoder.decode(stale).nextPage)
    }

    func testGroupsRowsByModelWithinADay() throws {
        let mixed = Data("""
        {"data":[{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
          {"currency":"USD","amount":"100","model":"claude-sonnet-5","token_type":"output_tokens"},
          {"currency":"USD","amount":"300","model":"claude-opus-5","token_type":"output_tokens"}
        ]}],"has_more":false,"next_page":null}
        """.utf8)
        let day = try decoder.decode(mixed).days[0]
        XCTAssertEqual(day.amountUSD, 4)
        XCTAssertEqual(day.byModel.map(\.model), ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(day.byModel[0].amountUSD, 3)
    }

    // Lenient parsing: the endpoint will grow fields, and rows without a model
    // (e.g. Code Execution Usage) still count toward the day's total.
    func testFallsBackToDescriptionWhenModelIsAbsent() throws {
        let noModel = Data("""
        {"data":[{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
          {"currency":"USD","amount":"250","description":"Code Execution Usage","brand_new_key":1}
        ]}],"has_more":false,"next_page":null}
        """.utf8)
        let day = try decoder.decode(noModel).days[0]
        XCTAssertEqual(day.amountUSD, Decimal(string: "2.5"))
        XCTAssertEqual(day.byModel.map(\.model), ["Code Execution Usage"])
    }

    func testSkipsRowsWithAnUnparseableAmount() throws {
        let junk = Data("""
        {"data":[{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
          {"currency":"USD","amount":"not-a-number","model":"claude-sonnet-5"},
          {"currency":"USD","amount":"100","model":"claude-sonnet-5"}
        ]}],"has_more":false,"next_page":null}
        """.utf8)
        XCTAssertEqual(try decoder.decode(junk).days[0].amountUSD, 1)
    }

    func testSkipsBucketsWithAnUnparseableStart() throws {
        let junk = Data("""
        {"data":[{"starting_at":"tomorrow","results":[]}],"has_more":false,"next_page":null}
        """.utf8)
        XCTAssertTrue(try decoder.decode(junk).days.isEmpty)
    }

    func testThrowsOnNonObjectRoot() {
        XCTAssertThrowsError(try decoder.decode(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? CostReportDecoder.DecodingError, .malformed)
        }
    }

    func testTreatsAMissingDataArrayAsNoDays() throws {
        XCTAssertTrue(try decoder.decode(Data("{}".utf8)).days.isEmpty)
    }
}
