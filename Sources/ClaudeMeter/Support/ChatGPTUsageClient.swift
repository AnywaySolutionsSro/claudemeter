import ClaudeMeterCore
import Foundation

/// Fetches live Codex limits from `GET https://chatgpt.com/backend-api/wham/usage`
/// (undocumented) with the stored ChatGPT login, refreshing once on a 401.
struct ChatGPTUsageClient {
    let account: ChatGPTAccountStore
    var session: URLSession = .shared

    /// The decoded reading. An unrecognised body is `unreadableUsage`, never a zero reading.
    func fetch(now: Date = Date()) async throws -> CodexLimitReading {
        let data = try await fetchRaw(now: now)
        guard let reading = WhamUsageDecoder.decode(data, observedAt: now) else {
            throw ChatGPTError.unreadableUsage
        }
        return reading
    }

    /// The raw body (for `--codex-usage-dump`, which prints only its structure).
    func fetchRaw(now: Date = Date()) async throws -> Data {
        let tokens = try await account.validTokens(now: now)
        do {
            return try await request(tokens, now: now)
        } catch ChatGPTError.http(401) {
            let fresh = try await account.forceRefresh(now: now)
            do {
                return try await request(fresh, now: now)
            } catch ChatGPTError.http(401) {
                throw ChatGPTError.sessionExpired
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
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { RetryAfter.seconds($0, now: now) }
                throw ChatGPTError.rateLimited(retryAfter: retryAfter)
            }
            throw ChatGPTError.http(http.statusCode)
        }
        return data
    }
}
