import Foundation

/// What the updater should do with the latest release, and how.
public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo)
    /// The user chose "Skip this version" for exactly this release.
    case skipped(ReleaseInfo)
}

/// Whether the app can replace itself, or must hand the user the release page.
public enum InstallMode: Equatable, Sendable {
    case inPlace(bundleURL: URL)
    case downloadOnly(reason: String)
}

/// The pure "should we bother the user, and can we install" rules of the updater.
/// Everything time- and filesystem-dependent is passed in, so it's fully testable.
public enum UpdatePolicy {
    /// Once a day is plenty: releases are rare and the GitHub API is unauthenticated.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// True when no check has ever run, the last one is older than `interval`, or the
    /// last one is stamped in the future (the clock was ahead when it ran — treating
    /// that as "recent" would silence the updater until that date comes around).
    public static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age >= interval || age < 0
    }

    /// `current == nil` means the running build has no parsable version (a dev build
    /// whose Info.plist still holds `$(MARKETING_VERSION)`): never offer an update.
    public static func decide(current: AppVersion?, latest: ReleaseInfo?, skipped: AppVersion?) -> UpdateDecision {
        guard let current, let latest, latest.version > current else { return .upToDate }
        if let skipped, skipped == latest.version { return .skipped(latest) }
        return .available(latest)
    }

    /// In-place replacement is only attempted for a bundle living directly in
    /// `/Applications` or `~/Applications`, not app-translocated, whose parent folder
    /// the current user can write. Anything else gets the release page instead.
    public static func installMode(
        bundleURL: URL,
        homeDirectory: URL,
        canWriteParent: (URL) -> Bool,
    ) -> InstallMode {
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        if bundle.path.contains("/AppTranslocation/") {
            return .downloadOnly(reason: "The app is running from a quarantined location.")
        }
        let allowedParents = [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
        ].map(\.standardizedFileURL.path)
        guard allowedParents.contains(parent.path) else {
            return .downloadOnly(reason: "The app isn't installed in the Applications folder.")
        }
        guard canWriteParent(parent) else {
            return .downloadOnly(reason: "\(parent.path) isn't writable by this user.")
        }
        return .inPlace(bundleURL: bundle)
    }
}
