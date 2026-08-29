import Foundation

/// A published GitHub release of ClaudeMeter, as far as the updater needs it.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    /// The git tag, e.g. `v01.02.00`.
    public let tagName: String
    /// The human-facing release page (fallback when in-place install isn't possible).
    public let pageURL: URL
    /// `ClaudeMeter.zip` — the notarized, stapled app bundle.
    public let archiveURL: URL
    /// `ClaudeMeter.zip.sha256` — optional; when absent the download is verified by
    /// code signature alone.
    public let checksumURL: URL?
    /// Byte size of the archive when GitHub reports it (download progress).
    public let archiveSize: Int?
    /// Release notes (GitHub-generated markdown).
    public let notes: String?
    public let publishedAt: Date?

    public init(
        version: AppVersion,
        tagName: String,
        pageURL: URL,
        archiveURL: URL,
        checksumURL: URL?,
        archiveSize: Int?,
        notes: String?,
        publishedAt: Date?,
    ) {
        self.version = version
        self.tagName = tagName
        self.pageURL = pageURL
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
        self.archiveSize = archiveSize
        self.notes = notes
        self.publishedAt = publishedAt
    }
}
