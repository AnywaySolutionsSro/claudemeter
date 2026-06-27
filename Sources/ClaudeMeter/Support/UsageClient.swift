import Foundation
import ClaudeMeterCore

/// Fetches live usage from `GET /api/oauth/usage`, refreshing the token once on a 401.
struct UsageClient {
    let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    let betaHeader = "oauth-2025-04-20"

    let account: AccessTokenProvider
    var session: URLSession = .shared
    private let decoder = UsageResponseDecoder()

    init(account: AccessTokenProvider, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func fetch(now: Date = Date()) async throws -> UsageSnapshot {
        let token = try await account.validAccessToken(now: now)
        do {
            return try await request(token: token, now: now)
        } catch UsageError.http(401) {
            // Token rejected despite passing the local expiry check — refresh once and retry.
            let fresh = try await account.forceRefresh(now: now)
            return try await request(token: fresh, now: now)
        }
    }

    private func request(token: String, now: Date) async throws -> UsageSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMeter/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Malformed response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            throw UsageError.http(http.statusCode)
        }

        ResponseCache.write(data)
        return try decoder.decode(data, fetchedAt: now)
    }
}
