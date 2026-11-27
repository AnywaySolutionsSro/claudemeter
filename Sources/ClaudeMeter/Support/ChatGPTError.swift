import Foundation
import Network

/// Failures of the ChatGPT sign-in and live Codex usage path. Never `UsageError` or
/// `AuthError`: their copy is about the Claude login, a different credential.
enum ChatGPTError: Error, LocalizedError, Equatable {
    /// Port 1455 is held by someone else — typically a `codex login` in progress.
    case portBusy
    case timedOut
    case invalidResponse
    case exchangeFailed(Int)
    /// The id token names no ChatGPT account, so usage can't be asked for.
    case noAccount
    case notSignedIn
    /// The grant was rejected for good; the tokens have been dropped.
    case sessionExpired
    /// A refresh failed for a reason that may pass (5xx, network, odd body).
    case refreshFailed
    case network(String)
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    /// The usage body had no shape we recognise; the previous reading stands.
    case unreadableUsage

    var errorDescription: String? {
        switch self {
        case .portBusy:
            "Port 1455 is in use — is `codex login` running? Finish or cancel it, then try again."
        case .timedOut:
            "ChatGPT sign-in timed out waiting for the browser. Please try again."
        case .invalidResponse:
            "ChatGPT sign-in failed: unexpected response. Please try again."
        case let .exchangeFailed(code):
            "ChatGPT sign-in failed (HTTP \(code)). Please try again."
        case .noAccount:
            "This login has no ChatGPT workspace with Codex. Sign in with the account Codex uses."
        case .notSignedIn:
            "Not signed in to ChatGPT."
        case .sessionExpired:
            "Your ChatGPT login expired. Sign in again for live Codex limits."
        case .refreshFailed:
            "Couldn't renew the ChatGPT login — will retry."
        case let .network(message):
            "Couldn't reach ChatGPT: \(message)"
        case let .http(code):
            "ChatGPT usage request failed (HTTP \(code))."
        case let .rateLimited(retryAfter):
            retryAfter.map { "ChatGPT is rate limiting — retrying in \(Int($0.rounded())) s." }
                ?? "ChatGPT is rate limiting — retrying shortly."
        case .unreadableUsage:
            "ChatGPT returned usage in an unexpected shape — showing the last reading."
        }
    }

    /// Whether `error` is "address already in use" from the listener.
    static func isAddressInUse(_ error: Error) -> Bool {
        if case let .posix(code)? = error as? NWError { return code == .EADDRINUSE }
        return (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(EADDRINUSE)
    }
}
