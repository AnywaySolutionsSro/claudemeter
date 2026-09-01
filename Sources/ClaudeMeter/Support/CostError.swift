import ClaudeMeterCore
import Foundation

/// Errors specific to the **Admin API key** and the Cost API.
///
/// Deliberately separate from `UsageError`: that type's copy is about the OAuth
/// subscription login ("Run `claude` and sign in"), which is a different credential
/// entirely. Reusing it here told users to re-authenticate something that was never
/// broken, while the admin key sat rejected in the field above the message.
enum CostError: Error, LocalizedError, Equatable {
    /// No key stored, or the Keychain refused to return it.
    case keyUnreadable
    /// The key was rejected (revoked, rotated, or mistyped).
    case invalidAdminKey
    /// The Admin API is unavailable to individual accounts.
    case notAnOrganization
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    /// Part of the report couldn't be read, so any total would be understated.
    case unreadableReport

    var errorDescription: String? {
        switch self {
        case .keyUnreadable:
            "Couldn't read the admin key from the Keychain. Re-paste it in Settings."
        case .invalidAdminKey:
            "Admin key rejected — check or replace it in Settings."
        case .notAnOrganization:
            "The Admin API needs an organization; individual accounts can't use it."
        case .rateLimited:
            "Anthropic rate limit reached — showing the last reading."
        case let .http(code):
            "Cost API returned HTTP \(code)."
        case let .network(message):
            "Network error: \(message)"
        case .unreadableReport:
            "Couldn't read the whole cost report — showing the last complete reading."
        }
    }
}
