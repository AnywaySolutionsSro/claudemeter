import Foundation

/// A release that has been downloaded and verified, waiting for the user's say-so
/// (or the next restart) to be swapped in. Persisted next to the bundle so it
/// survives a relaunch or a reboot.
public struct StagedUpdate: Equatable, Sendable, Codable {
    public let release: ReleaseInfo
    /// The verified `ClaudeMeter.app` on disk.
    public let bundlePath: String
    public let stagedAt: Date

    public init(release: ReleaseInfo, bundlePath: String, stagedAt: Date) {
        self.release = release
        self.bundlePath = bundlePath
        self.stagedAt = stagedAt
    }

    public var version: AppVersion { release.version }
}

/// What to do with a staged bundle found on disk.
public enum StagedDisposition: Equatable, Sendable {
    /// Still the right thing to install.
    case keep
    /// Already running this version (or newer), or the running build has no version.
    case discard
    /// A newer release exists; download that one instead.
    case replace
}
