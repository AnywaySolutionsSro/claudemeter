@testable import ClaudeMeterCore
import XCTest

final class PKCETests: XCTestCase {
    func testS256ChallengeMatchesRFC7636Vector() {
        // RFC 7636 Appendix B reference vector.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testBase64URLHasNoPaddingOrUnsafeChars() {
        let encoded = PKCE.base64URLEncode(Data([0xFB, 0xFF, 0xFE, 0xF0, 0x0F]))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func testGeneratedVerifierIsUniqueAndValid() {
        let a = PKCE.generate()
        let b = PKCE.generate()
        XCTAssertNotEqual(a.verifier, b.verifier)
        // A regenerated PKCE from the same verifier yields the same challenge.
        XCTAssertEqual(PKCE(verifier: a.verifier).challenge, a.challenge)
    }

    func testAuthTokensExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_000_000)
        let tokens = AuthTokens(accessToken: "a", refreshToken: "r", expiresAt: expiry)
        XCTAssertFalse(tokens.isExpired(now: expiry.addingTimeInterval(-120)))
        XCTAssertTrue(tokens.isExpired(now: expiry))
        XCTAssertFalse(AuthTokens(accessToken: "a", refreshToken: nil, expiresAt: nil).isExpired(now: Date()))
    }
}
