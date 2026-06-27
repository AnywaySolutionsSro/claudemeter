import Foundation

/// OAuth tokens owned by ClaudeMeter and stored in its own Keychain item.
/// Independent of Claude Code's credential — refreshed on its own lineage.
public struct AuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }
}
