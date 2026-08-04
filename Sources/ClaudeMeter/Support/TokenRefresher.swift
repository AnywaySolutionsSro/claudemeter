import Foundation

struct RefreshedToken {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

/// Exchanges a refresh token for a fresh access token at Anthropic's OAuth token endpoint,
/// using Claude Code's public client id so the grant matches the stored credential.
struct TokenRefresher {
    /// Claude Code's public OAuth client id (extracted from the CLI; not a secret).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let betaHeader = "oauth-2025-04-20"

    let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    var session: URLSession = .shared

    func refresh(refreshToken: String, now: Date = Date()) async throws -> RefreshedToken {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UsageError.refreshFailed }
        guard (200..<300).contains(http.statusCode) else {
            // 400/401/403 mean the grant itself was rejected (revoked / expired refresh token) —
            // that never recovers without a new sign-in. Anything else (5xx, odd shapes) is
            // treated as transient so a flaky token endpoint doesn't sign the user out.
            if [400, 401, 403].contains(http.statusCode) { throw UsageError.sessionExpired }
            throw UsageError.refreshFailed
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else {
            throw UsageError.refreshFailed
        }

        let newRefresh = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let expiresAt = expiresIn.map { now.addingTimeInterval($0) }

        return RefreshedToken(accessToken: access, refreshToken: newRefresh, expiresAt: expiresAt)
    }
}
