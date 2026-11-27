import ClaudeMeterCore
import Foundation

/// Talks to `https://auth.openai.com/oauth/token`: the authorization-code exchange
/// (form-encoded) and the refresh grant (JSON, as the Codex CLI sends it). Never logs
/// a token or a response body.
struct ChatGPTTokenClient {
    /// Ephemeral: token responses never touch the on-disk URL cache.
    var session: URLSession = ChatGPTUsageClient.ephemeral

    func exchange(code: String, verifier: String, now: Date = Date()) async throws -> ChatGPTTokens {
        let body = ChatGPTAuth.codeExchangeBody(code: code, verifier: verifier)
        let (data, status) = try await post(body, contentType: "application/x-www-form-urlencoded")
        guard (200 ..< 300).contains(status) else { throw ChatGPTError.exchangeFailed(status) }
        guard LenientJSONProbe.hasAccessToken(data) else { throw ChatGPTError.invalidResponse }
        guard let tokens = ChatGPTTokenResponseDecoder.tokens(from: data, previous: nil, now: now) else {
            throw ChatGPTError.noAccount
        }
        return tokens
    }

    /// Fresh tokens for `tokens`. Throws `sessionExpired` only when the grant is dead
    /// for good (`ChatGPTAuth.isDeadGrant`); anything else is `refreshFailed`.
    func refresh(_ tokens: ChatGPTTokens, now: Date = Date()) async throws -> ChatGPTTokens {
        let body = ChatGPTAuth.refreshBody(refreshToken: tokens.refreshToken)
        let (data, status) = try await post(body, contentType: "application/json")
        guard (200 ..< 300).contains(status) else {
            let code = ChatGPTTokenResponseDecoder.errorCode(from: data)
            throw ChatGPTAuth.isDeadGrant(status: status, errorCode: code)
                ? ChatGPTError.sessionExpired : ChatGPTError.refreshFailed
        }
        guard let refreshed = ChatGPTTokenResponseDecoder.tokens(from: data, previous: tokens, now: now) else {
            throw ChatGPTError.refreshFailed
        }
        return refreshed
    }

    private func post(_ body: Data, contentType: String) async throws -> (Data, Int) {
        var request = URLRequest(url: ChatGPTAuth.tokenURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatGPTError.invalidResponse }
            return (data, http.statusCode)
        } catch let error as ChatGPTError {
            throw error
        } catch {
            throw ChatGPTError.network(error.localizedDescription)
        }
    }
}

/// Tells "no access token at all" apart from "tokens but no ChatGPT account", so the
/// sign-in error says which.
private enum LenientJSONProbe {
    static func hasAccessToken(_ data: Data) -> Bool {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["access_token"] as? String).map { !$0.isEmpty } ?? false
    }
}
