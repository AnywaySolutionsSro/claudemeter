import AppKit
import ClaudeMeterCore
import Foundation

/// ClaudeMeter's own ChatGPT OAuth login (PKCE S256) against the redirect the Codex
/// client registers: `http://localhost:1455/auth/callback`. The listener binds
/// 127.0.0.1:1455 only, accepts only the path and `state` this login sent, and gives
/// up after 10 minutes. There is no fallback port: if 1455 is busy (a `codex login`
/// in progress) the sign-in fails with `ChatGPTError.portBusy`.
@MainActor
final class ChatGPTLoginService {
    private let tokens: ChatGPTTokenClient
    private var server: LoopbackCallbackServer?

    init(tokens: ChatGPTTokenClient = ChatGPTTokenClient()) {
        self.tokens = tokens
    }

    /// Opens the browser and resolves with the granted tokens. Throws
    /// `CancellationError` after `cancel()`.
    func signIn(open: (URL) -> Void = { NSWorkspace.shared.open($0) }) async throws -> ChatGPTTokens {
        let server = LoopbackCallbackServer()
        self.server = server
        defer {
            server.stop()
            if self.server === server { self.server = nil }
        }

        do {
            _ = try await server.start(port: ChatGPTAuth.callbackPort)
        } catch {
            throw ChatGPTError.isAddressInUse(error) ? ChatGPTError.portBusy : error
        }
        let pkce = PKCE.generate()
        let state = PKCE.randomState()
        server.expectedState = state
        server.expectedPath = ChatGPTAuth.callbackPath
        open(ChatGPTAuth.authorizeURL(challenge: pkce.challenge, state: state))

        let query: [String: String]
        do {
            query = try await server.waitForCallback()
        } catch AuthError.timedOut {
            throw ChatGPTError.timedOut
        }
        // The server already refused anything else; re-check so this never depends on it.
        guard let code = query["code"], query["state"] == state else { throw ChatGPTError.invalidResponse }
        return try await tokens.exchange(code: code, verifier: pkce.verifier)
    }

    func cancel() {
        server?.stop()
        server = nil
    }
}
