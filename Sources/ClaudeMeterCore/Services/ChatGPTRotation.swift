import Foundation

/// Refresh-token rotation rules for ClaudeMeter's ChatGPT login.
///
/// The Keychain item is shared by every ClaudeMeter process (the app, `--codex-usage-dump`),
/// and OpenAI rotates the refresh token on each refresh, so the old one is spent the moment a
/// new one is issued. A rotated token must never be lost: not to another process (re-read the
/// item and adopt its newer token), not to a failed Keychain write (memory stays authoritative
/// while a write is pending), and not to a read error (only a *missing* item is a sign-out).
public enum ChatGPTRotation {
    /// What a read of the Keychain item found.
    public enum Stored: Equatable, Sendable {
        /// `accessValid`: its access token has not expired.
        case found(refreshToken: String, accessValid: Bool)
        /// No item: signed out.
        case missing
        /// The read failed (not "not found"): says nothing about the login.
        case unreadable
    }

    public enum Start: Equatable, Sendable {
        /// Use the stored tokens as they are; no refresh.
        case useStored
        /// Refresh the stored tokens.
        case refreshStored
        /// Refresh the in-memory tokens (a write is pending, or the item is unreadable).
        case refreshMemory
        /// Nothing usable right now; try again later without touching the login.
        case backOff
        case signedOut
    }

    public enum Refreshed: Equatable, Sendable {
        /// Keep and persist the result (a failed write leaves it pending, in memory).
        case save
        /// A newer grant replaced the one we renewed (a new sign-in, another process).
        case superseded
        /// Signed out while the request ran: writing would resurrect the login.
        case signedOut
    }

    public enum DeadGrant: Equatable, Sendable {
        /// The item holds a newer token with a valid access token: use it as is.
        case adopt
        /// The item holds a newer, expired token: refresh with it, once.
        case retry
        /// The item holds a newer token but the retry is spent: keep it, try next poll.
        case superseded
        /// The token that failed is the newest there is: the login is dead.
        case signOut
        /// Nothing stored any more: already signed out.
        case signedOut
        /// The item can't be read: keep everything and try again later.
        case backOff
    }

    /// Whether a Keychain read may replace the in-memory tokens. Not while a write is
    /// pending: the item then holds the token we already spent.
    public static func mayReplaceMemory(pendingWrite: Bool) -> Bool {
        !pendingWrite
    }

    /// What to do when a refresh is due. `memory` is the in-memory refresh token.
    public static func beforeRefresh(memory: String?, stored: Stored, pendingWrite: Bool, force: Bool) -> Start {
        if pendingWrite { return memory == nil ? .backOff : .refreshMemory }
        switch stored {
        case .missing:
            return .signedOut
        case .unreadable:
            return memory == nil ? .backOff : .refreshMemory
        case let .found(token, accessValid):
            // Valid and not the token the server just refused: someone already refreshed.
            if accessValid, !force || token != memory { return .useStored }
            return .refreshStored
        }
    }

    public static func afterRefresh(used: String, stored: Stored, pendingWrite: Bool) -> Refreshed {
        switch stored {
        case .missing: .signedOut
        case .unreadable: .save
        case let .found(token, _): token == used || pendingWrite ? .save : .superseded
        }
    }

    public static func afterDeadGrant(used: String, stored: Stored, pendingWrite: Bool, canRetry: Bool) -> DeadGrant {
        switch stored {
        case .missing:
            return .signedOut
        case .unreadable:
            return .backOff
        case let .found(token, accessValid):
            // With a write pending the item holds a token we spent before `used`.
            if token == used || pendingWrite { return .signOut }
            if accessValid { return .adopt }
            return canRetry ? .retry : .superseded
        }
    }
}
