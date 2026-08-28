import Foundation

/// Errors surfaced from the networking / auth layer to the UI.
enum UsageError: Error, LocalizedError, Equatable {
    case notAuthenticated
    case refreshFailed
    /// The OAuth grant itself is dead (refresh token rejected, or the API keeps returning 401
    /// on a freshly refreshed token). Unlike the transient errors, this never heals on its own —
    /// the only recovery is a new sign-in, so the UI must fall back to the signed-out state.
    case sessionExpired
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not logged in. Run `claude` and sign in, then retry."
        case .refreshFailed:
            "Couldn't refresh the access token. Re-login in Claude Code."
        case .sessionExpired:
            "Your login session expired. Please sign in again."
        case .rateLimited:
            "Anthropic rate limit reached — showing last reading."
        case let .http(code):
            "Usage API returned HTTP \(code)."
        case let .network(message):
            "Network error: \(message)"
        }
    }
}
