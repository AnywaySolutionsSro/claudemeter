@testable import ClaudeMeterCore
import XCTest

/// `Decimal(string:)` TRUNCATES at the first invalid character instead of failing:
/// `Decimal(string: "1,234.5678")` is `1`, not nil. Parsing money that way understates
/// spend ~1000x silently, so amounts must be parsed strictly.
final class CostAmountTests: XCTestCase {
    func testParsesAPlainDecimalString() {
        XCTAssertEqual(CostAmount.parse("103.1554"), Decimal(string: "103.1554"))
        XCTAssertEqual(CostAmount.parse("0"), 0)
        XCTAssertEqual(CostAmount.parse("-500.25"), Decimal(string: "-500.25"))
    }

    func testRejectsThousandsSeparatorsRatherThanTruncating() {
        // Decimal(string:) would return 1 here — a 1000x understatement.
        XCTAssertNil(CostAmount.parse("1,234.5678"))
    }

    func testRejectsTrailingGarbage() {
        XCTAssertNil(CostAmount.parse("1.5abc"))
        XCTAssertNil(CostAmount.parse("1.2.3"))
        XCTAssertNil(CostAmount.parse("0x10"))
        XCTAssertNil(CostAmount.parse("1 234"))
        XCTAssertNil(CostAmount.parse(""))
        XCTAssertNil(CostAmount.parse("not-a-number"))
        XCTAssertNil(CostAmount.parse("."))
        XCTAssertNil(CostAmount.parse("-"))
    }

    // If the API ever emits `"amount": 103.1554` as a JSON number instead of a string,
    // `as? String` returns nil and every row would be dropped, yielding a confident $0.00.
    func testAcceptsAJSONNumberAsWellAsAString() throws {
        let json = Data(#"{"amount": 103.1554, "other": 7}"#.utf8)
        let root = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(CostAmount.parse(root?["amount"]), Decimal(string: "103.1554"))
        XCTAssertEqual(CostAmount.parse(root?["other"]), 7)
    }

    func testRejectsUnrelatedTypes() {
        XCTAssertNil(CostAmount.parse(nil))
        XCTAssertNil(CostAmount.parse(["1.0"]))
    }
}
