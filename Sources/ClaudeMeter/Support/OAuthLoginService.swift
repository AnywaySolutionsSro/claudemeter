import ClaudeMeterCore
import Foundation

/// Drives the OAuth authorization-code + PKCE login: builds the authorize URL the user opens
/// in a browser, then exchanges the pasted code for tokens.
struct OAuthLoginService {
    struct Request {
        let url: URL
        let pkce: PKCE
        let state: String
        let redirectURI: String
    }

    var session: URLSession = .shared

    /// Builds an authorize request. `redirectURI` is the loopback URL for the automatic flow,
    /// or `AuthEndpoints.redirectURI` for the manual copy/paste fallback.
    func makeRequest(redirectURI: String) -> Request {
        let pkce = PKCE.generate()
        let state = PKCE.randomState()

        var components = URLComponents(string: AuthEndpoints.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: AuthEndpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: AuthEndpoints.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return Request(url: components.url!, pkce: pkce, state: state, redirectURI: redirectURI)
    }

    /// Exchange the authorization code for tokens. Manual paste may include `CODE#STATE`;
    /// the bare code from the loopback redirect works too.
    func exchange(code rawCode: String, request: Request, now: Date = Date()) async throws -> AuthTokens {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? trimmed
        let returnedState = parts.count > 1 ? parts[1] : request.state

        var httpRequest = URLRequest(url: AuthEndpoints.tokenURL)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue(AuthEndpoints.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": returnedState,
            "client_id": AuthEndpoints.clientID,
            "redirect_uri": request.redirectURI,
            "code_verifier": request.pkce.verifier,
        ]
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: httpRequest)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw AuthError.exchangeFailed(http.statusCode) }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else {
            throw AuthError.invalidResponse
        }

        let refresh = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        return AuthTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
        )
    }
}
