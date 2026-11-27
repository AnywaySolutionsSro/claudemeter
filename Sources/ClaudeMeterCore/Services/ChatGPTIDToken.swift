import Foundation

/// Reads claims from an OpenAI JWT's payload. No signature check: the token came to us
/// straight from the token endpoint over TLS, and is only used to learn our own account.
public enum ChatGPTIDToken {
    public struct Claims: Equatable, Sendable {
        /// `https://api.openai.com/auth` → `chatgpt_account_id`.
        public let accountID: String?
        public let email: String?
        public let planType: String?
        /// `exp`.
        public let expiresAt: Date?
    }

    static let authClaim = "https://api.openai.com/auth"
    static let profileClaim = "https://api.openai.com/profile"

    public static func claims(from jwt: String) -> Claims? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let data = base64URLDecode(String(parts[1])),
              let payload = LenientJSON.object(data)
        else { return nil }
        let auth = payload[authClaim] as? [String: Any]
        let profile = payload[profileClaim] as? [String: Any]
        return Claims(
            accountID: LenientJSON.string(auth?["chatgpt_account_id"]),
            email: LenientJSON.string(payload["email"]) ?? LenientJSON.string(profile?["email"]),
            planType: LenientJSON.string(auth?["chatgpt_plan_type"]),
            expiresAt: LenientJSON.double(payload["exp"]).map(Date.init(timeIntervalSince1970:)),
        )
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
