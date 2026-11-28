import Foundation

/// Refresh-token rotation rules for ClaudeMeter's ChatGPT login (used by `ChatGPTTokenVault`).
///
/// The Keychain item is shared by every ClaudeMeter process (the app, `--codex-usage-dump`),
/// and OpenAI rotates the refresh token on each refresh, so the old one is spent the moment a
/// new one is issued. A rotated token must never be lost: not to another process, not to a
/// failed Keychain write, not to a read error.
///
/// `staleStored` is the pending-write marker: the spent refresh token the item still holds
/// because writing our newer tokens failed (nil = nothing pending). It is what tells *our*
/// stale item apart from a newer token another process wrote.
public enum ChatGPTRotation {
    /// What a read of the Keychain item found.
    public enum Stored: Equatable, Sendable {
        /// `accessValid`: its access token has not expired.
        case found(refreshToken: String, accessToken: String, accessValid: Bool)
        /// No item: signed out.
        case missing
        /// The read failed (not "not found"): says nothing about the login.
        case unreadable
    }

    /// How the in-memory tokens relate to the item.
    public enum Reconcile: Equatable, Sendable {
        /// The item is the truth (nothing pending, or it was replaced elsewhere): adopt it.
        case adoptStored
        /// A write is pending and the item still holds our stale token: memory wins,
        /// and the item may be overwritten.
        case keepMemoryWritable
        /// A write is pending and the item can't be read: memory wins, don't write.
        case keepMemoryUnreadable
        /// No item — never signed in, or signed out (perhaps elsewhere). Never recreate it.
        case signedOut
        /// Nothing pending and the item can't be read: keep memory, change nothing.
        case unreadable
    }

    public enum Start: Equatable, Sendable {
        /// Use the stored tokens as they are; no refresh.
        case useStored
        case refreshStored
        /// Refresh the in-memory tokens (a write is pending, or the item is unreadable).
        case refreshMemory
        /// Nothing usable right now; try again later without touching the login.
        case backOff
        case signedOut
    }

    public enum Refreshed: Equatable, Sendable {
        /// Keep and persist the result (a failed write leaves it pending).
        case save
        /// The item now holds a token neither renewed by us nor ours: someone else's newer grant.
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
        /// The token that died is ours and the newest there is: the login is dead.
        case signOut
        case signedOut
        /// The item can't be read: keep everything and try again later.
        case backOff
    }

    public static func reconcile(stored: Stored, staleStored: String?) -> Reconcile {
        switch stored {
        case .missing:
            return .signedOut
        case .unreadable:
            return staleStored == nil ? .unreadable : .keepMemoryUnreadable
        case let .found(token, _, _):
            guard let staleStored else { return .adoptStored }
            return token == staleStored ? .keepMemoryWritable : .adoptStored
        }
    }

    /// What to do when a refresh is due. `refusedAccess` is the access token the server
    /// just rejected (a forced refresh), never the in-memory copy: a read may already have
    /// replaced memory with the stored tokens.
    public static func beforeRefresh(stored: Stored, staleStored: String?, hasMemory: Bool,
                                     refusedAccess: String?) -> Start {
        switch reconcile(stored: stored, staleStored: staleStored) {
        case .signedOut:
            return .signedOut
        case .keepMemoryWritable, .keepMemoryUnreadable, .unreadable:
            return hasMemory ? .refreshMemory : .backOff
        case .adoptStored:
            guard case let .found(_, access, valid) = stored else { return .backOff }
            return valid && access != refusedAccess ? .useStored : .refreshStored
        }
    }

    public static func afterRefresh(used: String, stored: Stored, staleStored: String?) -> Refreshed {
        switch stored {
        case .missing: .signedOut
        case .unreadable: .save
        case let .found(token, _, _): token == used || token == staleStored ? .save : .superseded
        }
    }

    public static func afterDeadGrant(used: String, stored: Stored, staleStored: String?,
                                      canRetry: Bool) -> DeadGrant {
        switch stored {
        case .missing:
            return .signedOut
        case .unreadable:
            return .backOff
        case let .found(token, _, accessValid):
            if token == used || token == staleStored { return .signOut }
            if accessValid { return .adopt }
            return canRetry ? .retry : .superseded
        }
    }
}
