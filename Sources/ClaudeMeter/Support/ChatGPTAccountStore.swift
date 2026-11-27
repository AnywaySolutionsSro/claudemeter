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

    /// The tokens to use: the in-memory copy, else the Keychain item.
    /// `ChatGPTError.notSignedIn` without an item.
    func load() throws -> ChatGPTTokens {
        if let cached = lock.withLock({ cached }) { return cached }
        guard let stored = try loadStored() else { throw ChatGPTError.notSignedIn }
        return stored
    }

    /// The Keychain item itself, bypassing (and refreshing) the in-memory copy; `nil`
    /// when there is none. Another ClaudeMeter process may have rotated the refresh
    /// token since we last looked, so every refresh starts here.
    private func loadStored() throws -> ChatGPTTokens? {
        let item: Keychain.Item
        do {
            item = try keychain.read(account: Self.account)
        } catch KeychainError.notFound {
            lock.withLock { cached = nil }
            return nil
        }
        let tokens = try Self.decoder.decode(ChatGPTTokens.self, from: item.data)
        lock.withLock { cached = tokens }
        return tokens
    }

    /// Persist a new sign-in. Throws when the Keychain write fails (the sign-in fails).
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
        return tokens.isExpired(now: now) ? try await refreshAndSave(now: now, force: false) : tokens
    }

    /// Refresh regardless of expiry (the server rejected a token we thought valid).
    func forceRefresh(now: Date = Date()) async throws -> ChatGPTTokens {
        try await refreshAndSave(now: now, force: true)
    }

    /// Never refreshes: the stored access token, or `tokenExpired`. For one-shot
    /// diagnostics, which must not rotate the refresh token under the running app.
    func unexpiredTokensWithoutRefresh(now: Date = Date()) throws -> ChatGPTTokens {
        guard let stored = try loadStored() else { throw ChatGPTError.notSignedIn }
        guard !stored.isExpired(now: now) else { throw ChatGPTError.tokenExpired }
        return stored
    }

    private func refreshAndSave(now: Date, force: Bool) async throws -> ChatGPTTokens {
        guard let stored = try loadStored() else { throw ChatGPTError.notSignedIn }
        // Another process may already have refreshed: use its tokens instead of spending ours.
        if !force, !stored.isExpired(now: now) { return stored }
        return try await refresh(stored, now: now, retryOnRotation: true)
    }

    private func refresh(_ used: ChatGPTTokens, now: Date, retryOnRotation: Bool) async throws -> ChatGPTTokens {
        let refreshed: ChatGPTTokens
        do {
            refreshed = try await client.refresh(used, now: now)
        } catch ChatGPTError.sessionExpired {
            return try await handleDeadGrant(used, now: now, retryOnRotation: retryOnRotation)
        } catch {
            Self.log.notice("chatgpt: refresh failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let stored = try? loadStored()
        switch ChatGPTRotation.afterRefresh(used: used.refreshToken, stored: stored?.refreshToken) {
        case .save:
            persist(refreshed)
            return refreshed
        case .superseded:
            throw ChatGPTError.superseded
        case .signedOut:
            throw ChatGPTError.notSignedIn
        }
    }

    /// A rejected refresh token. If the stored one has changed since (rotated by another
    /// process, or a new sign-in), retry once with it instead of deleting good tokens.
    private func handleDeadGrant(_ used: ChatGPTTokens, now: Date, retryOnRotation: Bool) async throws
        -> ChatGPTTokens {
        let stored = try? loadStored()
        switch ChatGPTRotation.afterDeadGrant(used: used.refreshToken, stored: stored?.refreshToken) {
        case .retry where retryOnRotation:
            Self.log.notice("chatgpt: refresh token was rotated elsewhere — retrying with the stored one")
            guard let stored else { throw ChatGPTError.notSignedIn }
            return try await refresh(stored, now: now, retryOnRotation: false)
        case .retry, .signOut:
            Self.log.notice("chatgpt: refresh grant rejected — signing out")
            clear()
            onSignedOut?()
            throw ChatGPTError.sessionExpired
        case .signedOut:
            throw ChatGPTError.notSignedIn
        }
    }

    /// The refreshed tokens are live the moment the server issued them (the old refresh
    /// token is spent), so they go into memory first; a failed Keychain write is logged
    /// and never discards them.
    private func persist(_ tokens: ChatGPTTokens) {
        lock.withLock { cached = tokens }
        do {
            try keychain.write(Self.encoder.encode(tokens), account: Self.account)
        } catch {
            Self.log.notice(
                "chatgpt: saving refreshed tokens failed (kept in memory): \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}
