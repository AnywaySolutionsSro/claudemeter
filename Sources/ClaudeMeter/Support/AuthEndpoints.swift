import Foundation

/// OAuth endpoints and parameters for Anthropic's Claude (subscription) accounts, recovered
/// from the Claude Code CLI. The client id and beta header are public values, not secrets.
enum AuthEndpoints {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scope = "org:create_api_key user:profile user:inference"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let betaHeader = "oauth-2025-04-20"
}

enum AuthError: Error, LocalizedError, Equatable {
    case invalidResponse
    case exchangeFailed(Int)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Sign-in failed: unexpected response. Please try again."
        case let .exchangeFailed(code):
            "Sign-in failed (HTTP \(code)). Check the code and try again."
        case .notAuthenticated:
            "Not connected. Click Connect to sign in."
        }
    }
}
