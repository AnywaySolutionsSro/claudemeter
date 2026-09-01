import Foundation

/// A Claude Console **Admin API key** (`sk-ant-admin01-…`).
///
/// Validating the prefix at entry turns a mis-paste into an immediate, clear rejection in
/// Settings instead of a confusing HTTP 401 later.
public struct AdminKey: Equatable, Sendable {
    public static let prefix = "sk-ant-admin01-"

    public let raw: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), trimmed.count > Self.prefix.count else { return nil }
        self.raw = trimmed
    }
}
