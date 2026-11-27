import Foundation

/// Refresh-token rotation rules for ClaudeMeter's ChatGPT login. The Keychain item is
/// shared by every ClaudeMeter process (the app, `--codex-usage-dump`), and OpenAI
/// rotates the refresh token on each refresh, so a token in memory can be spent by
/// another process. The stored item is always re-read around a refresh and decides.
public enum ChatGPTRotation {
    public enum DeadGrant: Equatable, Sendable {
        /// The stored token differs from the one that failed: someone rotated it — retry once with it.
        case retry
        /// The token that failed is still the stored one: the login is really dead.
        case signOut
        /// Nothing is stored any more: already signed out.
        case signedOut
    }

    public enum Refreshed: Equatable, Sendable {
        /// The stored grant is still the one we renewed: save the result.
        case save
        /// A newer grant replaced it while the request ran (a new sign-in, another process).
        case superseded
        /// Signed out while the request ran: writing would resurrect the login.
        case signedOut
    }

    public static func afterDeadGrant(used: String, stored: String?) -> DeadGrant {
        guard let stored else { return .signedOut }
        return stored == used ? .signOut : .retry
    }

    public static func afterRefresh(used: String, stored: String?) -> Refreshed {
        guard let stored else { return .signedOut }
        return stored == used ? .save : .superseded
    }
}
