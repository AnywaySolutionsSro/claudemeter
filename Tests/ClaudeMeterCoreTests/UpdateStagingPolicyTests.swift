@testable import ClaudeMeterCore
import Foundation
import Testing

/// The "download first, ask second" rules of the updater: when a found release is
/// downloaded without asking, what happens to a bundle staged on disk earlier, and
/// how the launch-time check differs from the daily one.
struct UpdateStagingPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = AppVersion(major: 1, minor: 5, patch: 0)

    private func release(_ version: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(version)!, tagName: "v\(version)",
            pageURL: URL(string: "https://x/tag/v\(version)")!,
            archiveURL: URL(string: "https://x/v\(version)/ClaudeMeter.zip")!,
            checksumURL: nil, archiveSize: nil, notes: "notes", publishedAt: nil,
        )
    }

    private func staged(_ version: String) -> StagedUpdate {
        StagedUpdate(release: release(version), bundlePath: "/tmp/Updates/\(version)/ClaudeMeter.app", stagedAt: now)
    }

    // MARK: - Launch check: a login item relaunches rarely, so every launch checks,

    // throttled to once an hour against crash loops.

    @Test func launchCheckIsDueUnlessCheckedWithinTheLastHour() {
        #expect(UpdatePolicy.isLaunchCheckDue(lastCheck: nil, now: now))
        #expect(UpdatePolicy.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-2 * 3600), now: now))
        #expect(!UpdatePolicy.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-10 * 60), now: now))
        #expect(UpdatePolicy.isLaunchCheckDue(lastCheck: now.addingTimeInterval(3600), now: now)) // clock skew
    }

    // MARK: - Auto-download

    @Test func onlyAnAvailableInPlaceUpdateIsStagedWithoutAsking() {
        let inPlace = InstallMode.inPlace(bundleURL: URL(fileURLWithPath: "/Applications/ClaudeMeter.app"))
        let downloadOnly = InstallMode.downloadOnly(reason: "translocated")
        #expect(UpdatePolicy.shouldStage(.available(release("01.06.00")), mode: inPlace))
        #expect(!UpdatePolicy.shouldStage(.available(release("01.06.00")), mode: downloadOnly))
        #expect(!UpdatePolicy.shouldStage(.skipped(release("01.06.00")), mode: inPlace))
        #expect(!UpdatePolicy.shouldStage(.upToDate, mode: inPlace))
    }

    // MARK: - A staged bundle found on disk (launch, or after a later check)

    @Test func stagedNewerThanRunningIsKeptWhenNothingNewerIsKnown() {
        #expect(UpdatePolicy.disposition(of: staged("01.06.00"), current: current, latest: nil) == .keep)
        #expect(UpdatePolicy
            .disposition(of: staged("01.06.00"), current: current, latest: AppVersion("01.06.00")) == .keep)
    }

    @Test func stagedAtOrBelowRunningIsDiscarded() {
        #expect(UpdatePolicy.disposition(of: staged("01.05.00"), current: current, latest: nil) == .discard)
        #expect(UpdatePolicy.disposition(of: staged("01.04.09"), current: current, latest: nil) == .discard)
    }

    @Test func stagedOlderThanLatestIsReplaced() {
        #expect(UpdatePolicy
            .disposition(of: staged("01.06.00"), current: current, latest: AppVersion("01.07.00")) == .replace)
    }

    @Test func stagedIsDiscardedWhenTheRunningVersionIsUnknown() {
        // A dev build must never swap itself for a release.
        #expect(UpdatePolicy.disposition(of: staged("01.06.00"), current: nil, latest: nil) == .discard)
    }

    @Test func stagedUpdateRoundTripsThroughJSON() throws {
        let original = staged("01.06.00")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(StagedUpdate.self, from: data) == original)
    }

    @Test func reminderIsTwoHours() {
        #expect(UpdatePolicy.reminderDate(from: now) == now.addingTimeInterval(2 * 3600))
    }
}
