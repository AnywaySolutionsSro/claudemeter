import Foundation

/// OpenAI OAuth for ChatGPT accounts, as the Codex CLI uses it (values recovered from
/// its binary; the client id is public, not a secret). ClaudeMeter runs its **own**
/// login against these and never touches Codex's `auth.json`.
public enum ChatGPTAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// The only redirect registered for this client: no other port works.
    public static let callbackPort: UInt16 = 1455
    public static let callbackPath = "/auth/callback"
    public static let redirectURI = "http://localhost:\(callbackPort)\(callbackPath)"
    public static let scope = "openid profile email offline_access"
    /// What the Codex CLI asks for on refresh.
    static let refreshScope = "openid profile email"

    /// Token-endpoint error codes that mean the grant can never be refreshed again.
    static let deadGrantCodes: Set<String> = [
        "invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
    ]

    public static func authorizeURL(challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        ]
        return components.url!
    }

    /// `application/x-www-form-urlencoded` body for the authorization-code exchange.
    public static func codeExchangeBody(code: String, verifier: String) -> Data {
        let fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ]
        return Data(fields.map { "\($0)=\(formEncode($1))" }.joined(separator: "&").utf8)
    }

    /// JSON body for the refresh grant (the Codex CLI sends JSON here).
    public static func refreshBody(refreshToken: String) -> Data {
        let body = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": refreshScope,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Whether a failed refresh means the login is dead (sign in again) rather than a
    /// transient failure: an auth status, and for 400/403 a known dead-grant code, so a
    /// malformed request or a flaky server never signs the user out.
    public static func isDeadGrant(status: Int, errorCode: String?) -> Bool {
        switch status {
        case 401: true
        case 400, 403: errorCode.map(deadGrantCodes.contains) ?? false
        default: false
        }
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~",
    )

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }
}
