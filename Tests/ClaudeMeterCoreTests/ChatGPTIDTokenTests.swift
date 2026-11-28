@testable import ClaudeMeterCore
import Foundation
import Testing

/// Builds an unsigned JWT around `payload` (the signature is never checked).
func makeJWT(_ payload: [String: Any]) -> String {
    let header = PKCE.base64URLEncode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return "\(header).\(PKCE.base64URLEncode(body)).c2ln"
}

struct ChatGPTIDTokenTests {
    @Test func readsAccountEmailPlanAndExpiry() throws {
        let jwt = makeJWT([
            "email": "j@example.com",
            "exp": 1_800_000_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "pro"],
        ])
        let claims = try #require(ChatGPTIDToken.claims(from: jwt))
        #expect(claims.accountID == "acct-1")
        #expect(claims.email == "j@example.com")
        #expect(claims.planType == "pro")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func emailFallsBackToTheProfileClaim() throws {
        let jwt = makeJWT(["https://api.openai.com/profile": ["email": "p@example.com"]])
        #expect(try #require(ChatGPTIDToken.claims(from: jwt)).email == "p@example.com")
    }

    @Test func missingClaimsAreNil() throws {
        let claims = try #require(ChatGPTIDToken.claims(from: makeJWT(["sub": "x"])))
        #expect(claims.accountID == nil)
        #expect(claims.email == nil)
        #expect(claims.expiresAt == nil)
    }

    @Test func paddingIsRestoredForEveryLength() {
        for length in 1 ... 4 {
            let jwt = makeJWT(["email": String(repeating: "a", count: length) + "@x"])
            #expect(ChatGPTIDToken.claims(from: jwt)?.email != nil)
        }
    }

    @Test func garbageIsNil() {
        #expect(ChatGPTIDToken.claims(from: "") == nil)
        #expect(ChatGPTIDToken.claims(from: "onlyone") == nil)
        #expect(ChatGPTIDToken.claims(from: "a.!!!.c") == nil)
        #expect(ChatGPTIDToken.claims(from: "a.\(PKCE.base64URLEncode(Data("[1]".utf8))).c") == nil)
    }
}
