import ClaudeMeterCore
import Foundation

/// Fetches live Codex limits from `GET https://chatgpt.com/backend-api/wham/usage`
/// (undocumented) with the stored ChatGPT login, refreshing once on a 401.
struct ChatGPTUsageClient {
    let account: ChatGPTAccountStore
    /// Ephemeral: the usage body (account data) is never written to the on-disk URL cache.
    var session: URLSession = Self.ephemeral

    static let ephemeral = URLSession(configuration: .ephemeral)

    /// The decoded reading. An unrecognised body is `unreadableUsage`, never a zero reading.
    func fetch(now: Date = Date()) async throws -> CodexLimitReading {
        let data = try await fetchRaw(now: now)
        guard let reading = WhamUsageDecoder.decode(data, observedAt: now) else {
            throw ChatGPTError.unreadableUsage
        }
        return reading
    }

    /// The raw body. On a 401 the token is refreshed once and the request retried; a
    /// second 401 is `tokenRefused` (the login is kept — only a dead refresh grant signs
    /// out). With `allowRefresh: false` (`--codex-usage-dump`) nothing is ever refreshed,
    /// so a one-shot diagnostic can't rotate the refresh token under the running app.
    func fetchRaw(now: Date = Date(), allowRefresh: Bool = true) async throws -> Data {
        guard allowRefresh else {
            let tokens = try account.unexpiredTokensWithoutRefresh(now: now)
            do {
                return try await request(tokens, now: now)
            } catch ChatGPTError.http(401) {
                throw ChatGPTError.tokenRefused
            }
        }
        let tokens = try await account.validTokens(now: now)
        do {
            return try await request(tokens, now: now)
        } catch ChatGPTError.http(401) {
            let fresh = try await account.forceRefresh(now: now)
            do {
                return try await request(fresh, now: now)
            } catch ChatGPTError.http(401) {
                throw ChatGPTError.tokenRefused
            }
        }
    }

    private func request(_ tokens: ChatGPTTokens, now: Date) async throws -> Data {
        var request = URLRequest(url: ChatGPTAuth.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatGPTError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.network("Malformed response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                let parsed = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { RetryAfter.seconds($0, now: now) }
                // Clamped here so no caller ever sees an absurd or non-finite delay.
                throw ChatGPTError.rateLimited(retryAfter: RetryAfter.clamped(parsed))
            }
            throw ChatGPTError.http(http.statusCode)
        }
        return data
    }
}
