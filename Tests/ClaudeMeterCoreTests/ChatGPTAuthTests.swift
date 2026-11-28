@testable import ClaudeMeterCore
import Foundation
import Testing

struct ChatGPTAuthTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func authorizeURLCarriesTheSpecParameters() {
        let url = ChatGPTAuth.authorizeURL(challenge: "CHAL", state: "STATE")
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize?"))
        let params = query(url)
        #expect(params == [
            "response_type": "code",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "redirect_uri": "http://localhost:1455/auth/callback",
            "scope": "openid profile email offline_access",
            "code_challenge": "CHAL",
            "code_challenge_method": "S256",
            "state": "STATE",
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true",
        ])
    }

    @Test func redirectMatchesPortAndPath() {
        #expect(ChatGPTAuth.callbackPort == 1455)
        #expect(ChatGPTAuth.callbackPath == "/auth/callback")
        #expect(ChatGPTAuth.redirectURI == "http://localhost:\(ChatGPTAuth.callbackPort)\(ChatGPTAuth.callbackPath)")
    }

    @Test func codeExchangeIsFormEncoded() throws {
        let body = ChatGPTAuth.codeExchangeBody(code: "a b&c=d", verifier: "v~-._")
        let text = try #require(String(data: body, encoding: .utf8))
        let pairs = Set(text.split(separator: "&").map(String.init))
        #expect(pairs == [
            "grant_type=authorization_code",
            "code=a%20b%26c%3Dd",
            "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
            "client_id=app_EMoamEEZ73f0CkXaXp7hrann",
            "code_verifier=v~-._",
        ])
    }

    @Test func refreshIsJSON() throws {
        let body = ChatGPTAuth.refreshBody(refreshToken: "rt")
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": "rt",
            "scope": "openid profile email",
        ])
    }

    @Test func deadGrantNeedsAnAuthStatus() {
        #expect(ChatGPTAuth.isDeadGrant(status: 401, errorCode: nil))
        #expect(ChatGPTAuth.isDeadGrant(status: 400, errorCode: "invalid_grant"))
        #expect(ChatGPTAuth.isDeadGrant(status: 400, errorCode: "refresh_token_expired"))
        #expect(ChatGPTAuth.isDeadGrant(status: 403, errorCode: "refresh_token_reused"))
        #expect(!ChatGPTAuth.isDeadGrant(status: 400, errorCode: "invalid_request"))
        #expect(!ChatGPTAuth.isDeadGrant(status: 400, errorCode: nil))
        #expect(!ChatGPTAuth.isDeadGrant(status: 500, errorCode: "invalid_grant"))
        #expect(!ChatGPTAuth.isDeadGrant(status: 429, errorCode: nil))
    }
}
