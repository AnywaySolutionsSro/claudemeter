@testable import ClaudeMeterCore
import XCTest

final class AdminKeyTests: XCTestCase {
    func testAcceptsAWellFormedKey() {
        let key = AdminKey("sk-ant-admin01-abc123")
        XCTAssertEqual(key?.raw, "sk-ant-admin01-abc123")
    }

    func testTrimsSurroundingWhitespaceFromAPaste() {
        XCTAssertEqual(AdminKey("  sk-ant-admin01-abc123\n")?.raw, "sk-ant-admin01-abc123")
    }

    func testRejectsTheWrongPrefix() {
        // A regular API key, not an admin key — the endpoint would 401 confusingly.
        XCTAssertNil(AdminKey("sk-ant-api01-abc123"))
    }

    func testRejectsThePrefixAlone() {
        XCTAssertNil(AdminKey("sk-ant-admin01-"))
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(AdminKey(""))
        XCTAssertNil(AdminKey("   "))
    }
}
