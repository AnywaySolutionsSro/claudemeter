import ClaudeMeterCore
import Foundation
import OSLog

/// Owns ClaudeMeter's ChatGPT tokens in its **own** Keychain item
/// (`com.jakubzak.claudemeter.chatgpt`). Never reads or writes Codex's `~/.codex/auth.json`.
///
/// The UI asks only `exists` (metadata, never the secret — a secret read can prompt for
/// the login password); the poller loads the tokens once and keeps them in memory.
final class ChatGPTAccountStore: @unchecked Sendable {
    static let service = "com.jakubzak.claudemeter.chatgpt"
    static let account = "default"
    static let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "chatgpt")

    private let keychain = Keychain(service: service)
    private let client: ChatGPTTokenClient
    private let lock = NSLock()
    private var cached: ChatGPTTokens?
    /// Called (on any thread) when a dead grant made the store drop the tokens.
    var onSignedOut: (@Sendable () -> Void)?

    init(client: ChatGPTTokenClient = ChatGPTTokenClient()) {
        self.client = client
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Whether a login is stored — metadata only, safe to ask from UI code.
    var exists: Bool { keychain.exists(account: Self.account) }

    /// The stored tokens; `ChatGPTError.notSignedIn` without an item.
    func load() throws -> ChatGPTTokens {
        if let cached = lock.withLock({ cached }) { return cached }
        let item: Keychain.Item
        do {
            item = try keychain.read(account: Self.account)
        } catch KeychainError.notFound {
            throw ChatGPTError.notSignedIn
        }
        let tokens = try Self.decoder.decode(ChatGPTTokens.self, from: item.data)
        lock.withLock { cached = tokens }
        return tokens
    }

    func save(_ tokens: ChatGPTTokens) throws {
        try keychain.write(Self.encoder.encode(tokens), account: Self.account)
        lock.withLock { cached = tokens }
    }

    func clear() {
        lock.withLock { cached = nil }
        do {
            try keychain.delete(account: Self.account)
        } catch {
            Self.log.notice("chatgpt: keychain delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tokens whose access token is not about to expire, refreshing (and saving) first
    /// when it is.
    func validTokens(now: Date = Date()) async throws -> ChatGPTTokens {
        let tokens = try load()
        return tokens.isExpired(now: now) ? try await refreshAndSave(tokens, now: now) : tokens
    }

    /// Refresh regardless of expiry (the server rejected a token we thought valid).
    func forceRefresh(now: Date = Date()) async throws -> ChatGPTTokens {
        try await refreshAndSave(load(), now: now)
    }

    private func refreshAndSave(_ tokens: ChatGPTTokens, now: Date) async throws -> ChatGPTTokens {
        let refreshed: ChatGPTTokens
        do {
            refreshed = try await client.refresh(tokens, now: now)
        } catch ChatGPTError.sessionExpired {
            Self.log.notice("chatgpt: refresh grant rejected — signing out")
            clear()
            onSignedOut?()
            throw ChatGPTError.sessionExpired
        } catch {
            Self.log.notice("chatgpt: refresh failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // Signed out (or in again) while the request was in flight: writing now would
        // resurrect a deleted login or clobber a newer grant.
        guard let current = try? load(), current.refreshToken == tokens.refreshToken else {
            throw ChatGPTError.notSignedIn
        }
        try save(refreshed)
        return refreshed
    }
}
