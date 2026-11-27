import ClaudeMeterCore
import Foundation
import OSLog

/// Owns ClaudeMeter's ChatGPT tokens in its **own** Keychain item
/// (`com.jakubzak.claudemeter.chatgpt`). Never reads or writes Codex's `~/.codex/auth.json`.
///
/// The UI asks only `exists` (metadata, never the secret — a secret read can prompt for
/// the login password); the poller loads the tokens once and keeps them in memory.
///
/// Rotation (`ChatGPTRotation`): every refresh re-reads the item, because another
/// ClaudeMeter process may have rotated the refresh token; a failed write keeps the new
/// tokens in memory and is retried every poll; only a *missing* item means signed out.
final class ChatGPTAccountStore: @unchecked Sendable {
    static let service = "com.jakubzak.claudemeter.chatgpt"
    static let account = "default"
    static let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "chatgpt")

    private let keychain = Keychain(service: service)
    private let client: ChatGPTTokenClient
    private let lock = NSLock()
    private var cached: ChatGPTTokens?
    /// The in-memory tokens were rotated but the Keychain write failed. Until a write
    /// succeeds, memory is authoritative: the item holds a token we already spent.
    private var pendingWrite = false
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
        switch readStored() {
        case let .found(tokens): return tokens
        case .missing: throw ChatGPTError.notSignedIn
        case .unreadable: throw ChatGPTError.keychainUnreadable
        }
    }

    private enum Read {
        case found(ChatGPTTokens)
        case missing
        case unreadable

        func rotation(now: Date) -> ChatGPTRotation.Stored {
            switch self {
            case let .found(tokens): .found(refreshToken: tokens.refreshToken, accessValid: !tokens.isExpired(now: now))
            case .missing: .missing
            case .unreadable: .unreadable
            }
        }

        var tokens: ChatGPTTokens? {
            if case let .found(tokens) = self { return tokens }
            return nil
        }
    }

    /// The Keychain item itself. Replaces the in-memory copy only when no write is
    /// pending; never clears it on a read error.
    private func readStored() -> Read {
        let read: Read
        do {
            let item = try keychain.read(account: Self.account)
            read = try .found(Self.decoder.decode(ChatGPTTokens.self, from: item.data))
        } catch KeychainError.notFound {
            read = .missing
        } catch {
            Self.log.notice("chatgpt: keychain read failed: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
        lock.withLock {
            guard ChatGPTRotation.mayReplaceMemory(pendingWrite: pendingWrite) else { return }
            cached = read.tokens
        }
        return read
    }

    /// Persist a new sign-in. Throws when the Keychain write fails (the sign-in fails).
    func save(_ tokens: ChatGPTTokens) throws {
        try keychain.write(Self.encoder.encode(tokens), account: Self.account)
        lock.withLock {
            cached = tokens
            pendingWrite = false
        }
    }

    func clear() {
        lock.withLock {
            cached = nil
            pendingWrite = false
        }
        do {
            try keychain.delete(account: Self.account)
        } catch {
            Self.log.notice("chatgpt: keychain delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tokens whose access token is not about to expire, refreshing (and saving) first
    /// when it is. Retries a pending Keychain write first.
    func validTokens(now: Date = Date()) async throws -> ChatGPTTokens {
        flushPendingWrite()
        let tokens = try load()
        return tokens.isExpired(now: now) ? try await refreshAndSave(now: now, force: false) : tokens
    }

    /// Refresh regardless of expiry (the server rejected a token we thought valid).
    func forceRefresh(now: Date = Date()) async throws -> ChatGPTTokens {
        flushPendingWrite()
        return try await refreshAndSave(now: now, force: true)
    }

    /// Never refreshes: the stored access token, or `tokenExpired`. For one-shot
    /// diagnostics, which must not rotate the refresh token under the running app.
    func unexpiredTokensWithoutRefresh(now: Date = Date()) throws -> ChatGPTTokens {
        switch readStored() {
        case .missing: throw ChatGPTError.notSignedIn
        case .unreadable: throw ChatGPTError.keychainUnreadable
        case let .found(tokens):
            guard !tokens.isExpired(now: now) else { throw ChatGPTError.tokenExpired }
            return tokens
        }
    }

    private func refreshAndSave(now: Date, force: Bool) async throws -> ChatGPTTokens {
        let read = readStored()
        let (memory, pending) = lock.withLock { (cached, pendingWrite) }
        let start = ChatGPTRotation.beforeRefresh(
            memory: memory?.refreshToken, stored: read.rotation(now: now), pendingWrite: pending, force: force,
        )
        switch start {
        case .useStored:
            guard let stored = read.tokens else { throw ChatGPTError.keychainUnreadable }
            return stored
        case .refreshStored:
            guard let stored = read.tokens else { throw ChatGPTError.keychainUnreadable }
            return try await refresh(stored, now: now, canRetry: true)
        case .refreshMemory:
            guard let memory else { throw ChatGPTError.keychainUnreadable }
            return try await refresh(memory, now: now, canRetry: true)
        case .backOff:
            throw ChatGPTError.keychainUnreadable
        case .signedOut:
            throw ChatGPTError.notSignedIn
        }
    }

    private func refresh(_ used: ChatGPTTokens, now: Date, canRetry: Bool) async throws -> ChatGPTTokens {
        let refreshed: ChatGPTTokens
        do {
            refreshed = try await client.refresh(used, now: now)
        } catch ChatGPTError.sessionExpired {
            return try await handleDeadGrant(used, now: now, canRetry: canRetry)
        } catch {
            Self.log.notice("chatgpt: refresh failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // `used` is spent now: from here on `refreshed` must not be dropped by accident.
        let read = readStored()
        let pending = lock.withLock { pendingWrite }
        switch ChatGPTRotation.afterRefresh(used: used.refreshToken, stored: read.rotation(now: now),
                                            pendingWrite: pending) {
        case .save:
            persist(refreshed)
            return refreshed
        case .superseded:
            throw ChatGPTError.superseded
        case .signedOut:
            throw ChatGPTError.notSignedIn
        }
    }

    /// A rejected refresh token. A newer token in the item (rotated elsewhere) is adopted
    /// or retried once and never deleted; a read error backs off; only a dead token that
    /// is the newest there is signs out.
    private func handleDeadGrant(_ used: ChatGPTTokens, now: Date, canRetry: Bool) async throws
        -> ChatGPTTokens {
        let read = readStored()
        let pending = lock.withLock { pendingWrite }
        let decision = ChatGPTRotation.afterDeadGrant(
            used: used.refreshToken, stored: read.rotation(now: now), pendingWrite: pending, canRetry: canRetry,
        )
        switch decision {
        case .adopt:
            guard let stored = read.tokens else { throw ChatGPTError.keychainUnreadable }
            Self.log.notice("chatgpt: refresh token was rotated elsewhere — using the stored one")
            return stored
        case .retry:
            guard let stored = read.tokens else { throw ChatGPTError.keychainUnreadable }
            Self.log.notice("chatgpt: refresh token was rotated elsewhere — retrying with the stored one")
            return try await refresh(stored, now: now, canRetry: false)
        case .superseded:
            throw ChatGPTError.superseded
        case .backOff:
            throw ChatGPTError.keychainUnreadable
        case .signOut:
            Self.log.notice("chatgpt: refresh grant rejected — signing out")
            clear()
            onSignedOut?()
            throw ChatGPTError.sessionExpired
        case .signedOut:
            throw ChatGPTError.notSignedIn
        }
    }

    /// Refreshed tokens are live the moment the server issued them (the old refresh token
    /// is spent), so they go into memory first. A failed write leaves them pending —
    /// authoritative over the stale item — and is retried every poll.
    private func persist(_ tokens: ChatGPTTokens) {
        lock.withLock {
            cached = tokens
            pendingWrite = true
        }
        writePending()
    }

    private func flushPendingWrite() {
        guard lock.withLock({ pendingWrite }) else { return }
        writePending()
    }

    private func writePending() {
        guard let tokens = lock.withLock({ pendingWrite ? cached : nil }) else { return }
        do {
            try keychain.write(Self.encoder.encode(tokens), account: Self.account)
            lock.withLock {
                // Only clear the flag for the tokens we wrote; a newer rotation stays pending.
                if cached == tokens { pendingWrite = false }
            }
        } catch {
            Self.log.notice(
                "chatgpt: saving refreshed tokens failed (kept in memory, will retry): \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}
