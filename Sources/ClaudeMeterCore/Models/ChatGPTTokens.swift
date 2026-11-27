import Foundation

/// ChatGPT OAuth tokens owned by ClaudeMeter (its own Keychain item, never Codex's
/// `auth.json`). `accountID` comes from the id token and is sent as `chatgpt-account-id`.
public struct ChatGPTTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let expiresAt: Date?
    public let accountID: String
    /// For display only ("Signed in as …").
    public let email: String?

    public init(
        accessToken: String, refreshToken: String, idToken: String, expiresAt: Date?,
        accountID: String, email: String?,
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
    }

    public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }
}
