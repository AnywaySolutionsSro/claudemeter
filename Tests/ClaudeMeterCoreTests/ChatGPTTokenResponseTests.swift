@testable import ClaudeMeterCore
import Foundation
import Testing

struct ChatGPTTokenResponseTests {
    private let now = Date(timeIntervalSince1970: 1_796_000_000)

    private func idToken(account: String? = "acct-1", email: String? = "j@example.com") -> String {
        var auth: [String: Any] = [:]
        if let account { auth["chatgpt_account_id"] = account }
        var payload: [String: Any] = ["https://api.openai.com/auth": auth]
        if let email { payload["email"] = email }
        return makeJWT(payload)
    }

    private func body(_ json: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    @Test func freshLoginBuildsTokens() throws {
        let data = body([
            "access_token": "at", "refresh_token": "rt", "id_token": idToken(), "expires_in": 3600,
        ])
        let tokens = try #require(ChatGPTTokenResponseDecoder.tokens(from: data, previous: nil, now: now))
        #expect(tokens == ChatGPTTokens(
            accessToken: "at", refreshToken: "rt", idToken: idToken(),
            expiresAt: now.addingTimeInterval(3600), accountID: "acct-1", email: "j@example.com",
        ))
    }

    @Test func expiryFallsBackToTheAccessTokensExp() throws {
        let access = makeJWT(["exp": 1_796_007_200])
        let data = body(["access_token": access, "refresh_token": "rt", "id_token": idToken()])
        let tokens = try #require(ChatGPTTokenResponseDecoder.tokens(from: data, previous: nil, now: now))
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1_796_007_200))
    }

    @Test func opaqueAccessTokenWithoutExpiryHasNoExpiry() throws {
        let data = body(["access_token": "opaque", "refresh_token": "rt", "id_token": idToken()])
        let tokens = try #require(ChatGPTTokenResponseDecoder.tokens(from: data, previous: nil, now: now))
        #expect(tokens.expiresAt == nil)
    }

    @Test func refreshKeepsWhatTheResponseOmits() throws {
        let previous = ChatGPTTokens(
            accessToken: "old", refreshToken: "rt0", idToken: idToken(), expiresAt: now,
            accountID: "acct-1", email: "j@example.com",
        )
        let data = body(["access_token": "new", "expires_in": 60])
        let tokens = try #require(ChatGPTTokenResponseDecoder.tokens(from: data, previous: previous, now: now))
        #expect(tokens.accessToken == "new")
        #expect(tokens.refreshToken == "rt0")
        #expect(tokens.idToken == previous.idToken)
        #expect(tokens.accountID == "acct-1")
        #expect(tokens.expiresAt == now.addingTimeInterval(60))
    }

    @Test func refreshWithNewIDTokenUpdatesTheAccount() throws {
        let previous = ChatGPTTokens(
            accessToken: "old", refreshToken: "rt0", idToken: idToken(), expiresAt: nil,
            accountID: "acct-1", email: "j@example.com",
        )
        let data = body([
            "access_token": "new",
            "refresh_token": "rt1",
            "id_token": idToken(account: "acct-2", email: nil),
        ])
        let tokens = try #require(ChatGPTTokenResponseDecoder.tokens(from: data, previous: previous, now: now))
        #expect(tokens.refreshToken == "rt1")
        #expect(tokens.accountID == "acct-2")
        #expect(tokens.email == "j@example.com")
    }

    @Test func unusableResponsesAreNil() {
        #expect(ChatGPTTokenResponseDecoder.tokens(from: Data("nope".utf8), previous: nil, now: now) == nil)
        #expect(ChatGPTTokenResponseDecoder.tokens(from: body(["refresh_token": "rt"]), previous: nil, now: now) == nil)
        #expect(ChatGPTTokenResponseDecoder.tokens(
            from: body(["access_token": "", "refresh_token": "rt", "id_token": idToken()]), previous: nil, now: now,
        ) == nil)
        // No refresh token: the login could never be renewed.
        #expect(ChatGPTTokenResponseDecoder.tokens(
            from: body(["access_token": "at", "id_token": idToken()]), previous: nil, now: now,
        ) == nil)
        // No ChatGPT account: the usage endpoint can't be called.
        #expect(ChatGPTTokenResponseDecoder.tokens(
            from: body(["access_token": "at", "refresh_token": "rt", "id_token": idToken(account: nil)]),
            previous: nil, now: now,
        ) == nil)
    }

    @Test func errorCodeReadsStringAndObjectForms() {
        #expect(ChatGPTTokenResponseDecoder.errorCode(from: body(["error": "invalid_grant"])) == "invalid_grant")
        #expect(ChatGPTTokenResponseDecoder.errorCode(
            from: body(["error": ["code": "refresh_token_expired", "message": "x"]]),
        ) == "refresh_token_expired")
        #expect(ChatGPTTokenResponseDecoder.errorCode(from: body(["error": ["type": "t"]])) == "t")
        #expect(ChatGPTTokenResponseDecoder.errorCode(from: body(["code": "c"])) == "c")
        #expect(ChatGPTTokenResponseDecoder.errorCode(from: Data("<html>".utf8)) == nil)
    }

    @Test func tokensExpireWithLeeway() {
        let tokens = ChatGPTTokens(
            accessToken: "a", refreshToken: "r", idToken: "i", expiresAt: now, accountID: "x", email: nil,
        )
        #expect(!tokens.isExpired(now: now.addingTimeInterval(-120)))
        #expect(tokens.isExpired(now: now.addingTimeInterval(-30)))
        let forever = ChatGPTTokens(
            accessToken: "a", refreshToken: "r", idToken: "i", expiresAt: nil, accountID: "x", email: nil,
        )
        #expect(!forever.isExpired(now: now))
    }

    @Test func tokensRoundTripThroughCodable() throws {
        let tokens = ChatGPTTokens(
            accessToken: "a", refreshToken: "r", idToken: "i", expiresAt: now, accountID: "x", email: "e",
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(ChatGPTTokens.self, from: encoder.encode(tokens)) == tokens)
    }
}
