import Foundation

/// Lenient decoding of `https://auth.openai.com/oauth/token` responses.
public enum ChatGPTTokenResponseDecoder {
    /// The tokens a response grants. A refresh may omit the refresh token, id token or
    /// claims; those carry over from `previous`. `nil` when the result would be unusable:
    /// no access token, nothing to refresh with, or no ChatGPT account to call usage for.
    public static func tokens(from data: Data, previous: ChatGPTTokens?, now: Date) -> ChatGPTTokens? {
        guard let json = LenientJSON.object(data),
              let access = LenientJSON.string(json["access_token"]),
              let refresh = LenientJSON.string(json["refresh_token"]) ?? previous?.refreshToken,
              let idToken = LenientJSON.string(json["id_token"]) ?? previous?.idToken
        else { return nil }
        let claims = ChatGPTIDToken.claims(from: idToken)
        guard let accountID = claims?.accountID ?? previous?.accountID else { return nil }
        let expiresAt = LenientJSON.double(json["expires_in"]).map { now.addingTimeInterval($0) }
            ?? ChatGPTIDToken.claims(from: access)?.expiresAt
        return ChatGPTTokens(
            accessToken: access, refreshToken: refresh, idToken: idToken, expiresAt: expiresAt,
            accountID: accountID, email: claims?.email ?? previous?.email,
        )
    }

    /// The error code of a failed token request: `error` as a string, or its
    /// `code`/`type` when it is an object, or a top-level `code`.
    public static func errorCode(from data: Data) -> String? {
        guard let json = LenientJSON.object(data) else { return nil }
        if let error = LenientJSON.string(json["error"]) { return error }
        if let error = json["error"] as? [String: Any] {
            return LenientJSON.string(error["code"]) ?? LenientJSON.string(error["type"])
        }
        return LenientJSON.string(json["code"])
    }
}
