import Foundation

/// Errors surfaced from the networking / auth layer to the UI.
enum UsageError: Error, LocalizedError, Equatable {
    case notAuthenticated
    case refreshFailed
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not logged in. Run `claude` and sign in, then retry."
        case .refreshFailed:
            return "Couldn't refresh the access token. Re-login in Claude Code."
        case .rateLimited:
            return "Anthropic rate limit reached — showing last reading."
        case .http(let code):
            return "Usage API returned HTTP \(code)."
        case .network(let message):
            return "Network error: \(message)"
        }
    }
}
