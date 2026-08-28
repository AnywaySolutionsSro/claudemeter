import ClaudeMeterCore
import Foundation

/// Supplies a valid access token to the usage client.
protocol AccessTokenProvider {
    func validAccessToken(now: Date) async throws -> String
    func forceRefresh(now: Date) async throws -> String
}

/// Owns ClaudeMeter's OAuth tokens in its **own** Keychain item (`com.jakubzak.claudemeter.oauth`).
/// Because the app created the item, it reads it back without prompting; refreshes are written
/// straight back to it. No interaction with Claude Code's credential.
final class AccountStore: AccessTokenProvider {
    static let service = "com.jakubzak.claudemeter.oauth"
    static let account = "default"

    private let keychain = Keychain(service: service)
    private let refresher = TokenRefresher()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    var isAuthenticated: Bool { (try? load()) != nil }

    func load() throws -> AuthTokens {
        let item = try keychain.read()
        return try decoder.decode(AuthTokens.self, from: item.data)
    }

    func save(_ tokens: AuthTokens) throws {
        try keychain.write(encoder.encode(tokens), account: Self.account)
    }

    func clear() {
        try? keychain.delete(account: Self.account)
    }

    func validAccessToken(now: Date = Date()) async throws -> String {
        let tokens = try load()
        if !tokens.isExpired(now: now) { return tokens.accessToken }
        return try await refreshAndSave(tokens, now: now)
    }

    func forceRefresh(now: Date = Date()) async throws -> String {
        try await refreshAndSave(load(), now: now)
    }

    private func refreshAndSave(_ tokens: AuthTokens, now: Date) async throws -> String {
        guard let refreshToken = tokens.refreshToken else { throw AuthError.notAuthenticated }
        let refreshed = try await refresher.refresh(refreshToken: refreshToken, now: now)
        let updated = AuthTokens(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? tokens.refreshToken,
            expiresAt: refreshed.expiresAt,
        )
        try save(updated)
        return updated.accessToken
    }
}
