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
            return "Not logged in. Run `claude` and sign in, then retry."
        case .refreshFailed:
            return "Couldn't refresh the access token. Re-login in Claude Code."
        case .sessionExpired:
            return "Your login session expired. Please sign in again."
        case .rateLimited:
            return "Anthropic rate limit reached — showing last reading."
        case .http(let code):
            return "Usage API returned HTTP \(code)."
        case .network(let message):
            return "Network error: \(message)"
        }
    }
}
