@testable import ClaudeMeterCore
import XCTest

final class AppVersionTests: XCTestCase {
    func testParsesPaddedAndTaggedForms() {
        XCTAssertEqual(AppVersion("01.02.03"), AppVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(AppVersion("v01.02.03"), AppVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(AppVersion("1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(AppVersion(" v01.10.00\n"), AppVersion(major: 1, minor: 10, patch: 0))
    }

    func testRejectsMalformedStrings() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("01.02"))
        XCTAssertNil(AppVersion("01.02.03.04"))
        XCTAssertNil(AppVersion("v01.02.03-rc1"))
        XCTAssertNil(AppVersion("a.b.c"))
        XCTAssertNil(AppVersion("$(MARKETING_VERSION)"))
    }

    func testOrdersNumericallyNotLexically() throws {
        let v0109 = try XCTUnwrap(AppVersion("01.09.00"))
        let v0110 = try XCTUnwrap(AppVersion("01.10.00"))
        let v0200 = try XCTUnwrap(AppVersion("02.00.00"))
        let v010901 = try XCTUnwrap(AppVersion("01.09.01"))
        XCTAssertLessThan(v0109, v0110)
        XCTAssertLessThan(v0110, v0200)
        XCTAssertLessThan(v0109, v010901)
        XCTAssertLessThan(v010901, v0110)
        XCTAssertEqual([v0200, v010901, v0110, v0109].sorted(), [v0109, v010901, v0110, v0200])
    }

    func testDescriptionIsZeroPaddedAndTagNameHasPrefix() {
        let version = AppVersion(major: 1, minor: 2, patch: 3)
        XCTAssertEqual(version.description, "01.02.03")
        XCTAssertEqual(version.tagName, "v01.02.03")
        XCTAssertEqual(AppVersion(major: 100, minor: 0, patch: 0).description, "100.00.00")
    }
}
