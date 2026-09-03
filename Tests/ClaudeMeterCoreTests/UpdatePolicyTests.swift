@testable import ClaudeMeterCore
import XCTest

final class UpdatePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = AppVersion(major: 1, minor: 1, patch: 0)

    private func release(_ version: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(version)!,
            tagName: "v\(version)",
            pageURL: URL(string: "https://x/tag/v\(version)")!,
            archiveURL: URL(string: "https://x/v\(version)/ClaudeMeter.zip")!,
            checksumURL: nil,
            archiveSize: nil,
            notes: nil,
            publishedAt: nil,
        )
    }

    // MARK: - Check cadence

    func testCheckIsDueWhenNeverCheckedOrOlderThanInterval() {
        XCTAssertTrue(UpdatePolicy.isCheckDue(lastCheck: nil, now: now))
        XCTAssertTrue(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertFalse(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertFalse(UpdatePolicy.isCheckDue(lastCheck: now, now: now))
    }

    // A last-check stamped while the clock was ahead must not disable checks until
    // that future date arrives — `apply` rewrites the stamp after every check, so a
    // burst cannot happen either way.
    func testClockSkewInTheFutureIsDueAgain() {
        XCTAssertTrue(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
        XCTAssertTrue(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(400 * 86_400), now: now))
    }

    // MARK: - Decision

    func testNewerReleaseIsAvailable() {
        let latest = release("01.02.00")
        XCTAssertEqual(UpdatePolicy.decide(current: current, latest: latest, skipped: nil), .available(latest))
    }

    func testSameOrOlderReleaseIsUpToDate() {
        XCTAssertEqual(UpdatePolicy.decide(current: current, latest: release("01.01.00"), skipped: nil), .upToDate)
        XCTAssertEqual(UpdatePolicy.decide(current: current, latest: release("01.00.09"), skipped: nil), .upToDate)
        XCTAssertEqual(UpdatePolicy.decide(current: current, latest: nil, skipped: nil), .upToDate)
    }

    func testSkippedVersionIsReportedAsSkippedUntilANewerOneAppears() {
        let skipped = release("01.02.00")
        XCTAssertEqual(
            UpdatePolicy.decide(current: current, latest: skipped, skipped: skipped.version),
            .skipped(skipped),
        )
        let newer = release("01.02.01")
        XCTAssertEqual(
            UpdatePolicy.decide(current: current, latest: newer, skipped: skipped.version),
            .available(newer),
        )
    }

    func testUnknownCurrentVersionNeverOffersAnUpdate() {
        // A dev build whose Info.plist still says $(MARKETING_VERSION) must not
        // be "upgraded" to whatever is on GitHub.
        XCTAssertEqual(UpdatePolicy.decide(current: nil, latest: release("09.00.00"), skipped: nil), .upToDate)
    }

    // MARK: - Install mode

    private let home = URL(fileURLWithPath: "/Users/jakub")

    func testInstallsInPlaceFromApplicationsFolders() {
        for path in ["/Applications/ClaudeMeter.app", "/Users/jakub/Applications/ClaudeMeter.app"] {
            let mode = UpdatePolicy.installMode(
                bundleURL: URL(fileURLWithPath: path), homeDirectory: home, canWriteParent: { _ in true },
            )
            XCTAssertEqual(mode, .inPlace(bundleURL: URL(fileURLWithPath: path)), path)
        }
    }

    func testDownloadOnlyOutsideApplications() {
        let mode = UpdatePolicy.installMode(
            bundleURL: URL(fileURLWithPath: "/Users/jakub/code/ClaudeMeter/dist/ClaudeMeter.app"),
            homeDirectory: home, canWriteParent: { _ in true },
        )
        guard case let .downloadOnly(reason) = mode else { return XCTFail("expected downloadOnly, got \(mode)") }
        XCTAssertTrue(reason.contains("Applications"), reason)
    }

    func testDownloadOnlyWhenTranslocatedOrUnwritable() {
        let translocated = UpdatePolicy.installMode(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/ClaudeMeter.app"),
            homeDirectory: home, canWriteParent: { _ in true },
        )
        guard case .downloadOnly = translocated else { return XCTFail("translocated must not install in place") }

        let unwritable = UpdatePolicy.installMode(
            bundleURL: URL(fileURLWithPath: "/Applications/ClaudeMeter.app"),
            homeDirectory: home, canWriteParent: { _ in false },
        )
        guard case let .downloadOnly(reason) = unwritable else { return XCTFail("unwritable must not install") }
        XCTAssertTrue(reason.contains("writable"), reason)
    }
}
