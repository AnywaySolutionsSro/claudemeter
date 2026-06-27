import Foundation
import CryptoKit
import Security

/// A PKCE (RFC 7636) verifier/challenge pair for the OAuth authorization-code flow.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// Derives the S256 challenge from a given verifier.
    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Self.base64URLEncode(Data(digest))
    }

    /// Generates a fresh verifier (32 random bytes) and its S256 challenge.
    public static func generate() -> PKCE {
        PKCE(verifier: base64URLEncode(randomBytes(32)))
    }

    public static func randomState() -> String {
        base64URLEncode(randomBytes(24))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    /// Base64URL without padding (RFC 4648 §5).
    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
