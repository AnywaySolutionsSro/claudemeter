import Foundation

/// Where the vault keeps its tokens (the Keychain item in the app). `read` returns nil
/// when there is no item and throws only when the item can't be read.
public protocol ChatGPTTokenPersistence: Sendable {
    func read() throws -> ChatGPTTokens?
    func write(_ tokens: ChatGPTTokens) throws
    func delete() throws
}

/// The token endpoint's refresh grant. Throws `ChatGPTDeadGrant` when the refresh token
/// is rejected for good; any other error is transient.
public protocol ChatGPTTokenRefreshing: Sendable {
    func refresh(_ tokens: ChatGPTTokens, now: Date) async throws -> ChatGPTTokens
}

public struct ChatGPTDeadGrant: Error, Equatable {
    public init() {}
}

/// ClaudeMeter's ChatGPT tokens: an in-memory copy over a shared persisted item, with the
/// refresh-token rotation rules of `ChatGPTRotation`. Every refresh re-reads the item first;
/// a failed write leaves the new tokens pending (memory authoritative, write retried each
/// poll, never over an item replaced or deleted elsewhere); only a missing item is a sign-out.
public final class ChatGPTTokenVault: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case notSignedIn
        /// The item couldn't be read; nothing was changed. Retry later.
        case unreadable
        /// A newer grant replaced ours mid-refresh; the next poll uses it.
        case superseded
        /// The refresh grant is dead; the login was cleared.
        case sessionExpired
        /// Expired, and the caller may not refresh (diagnostics).
        case tokenExpired
    }

    /// Called when the login ended: a dead grant, or the item vanished (signed out elsewhere).
    public var onSignedOut: (@Sendable () -> Void)?

    private let persistence: ChatGPTTokenPersistence
    private let refresher: ChatGPTTokenRefreshing
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var memory: ChatGPTTokens?
    /// Pending-write marker: the spent refresh token the item still holds (see `ChatGPTRotation`).
    private var staleStored: String?

    public init(persistence: ChatGPTTokenPersistence, refresher: ChatGPTTokenRefreshing,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.persistence = persistence
        self.refresher = refresher
        self.log = log
    }

    /// The tokens to use: memory, else the item.
    public func load(now: Date = Date()) throws -> ChatGPTTokens {
        if let memory = lock.withLock({ memory }) { return memory }
        let state = sync(now: now)
        if let memory = state.memory { return memory }
        throw state.read == .unreadable ? Failure.unreadable : Failure.notSignedIn
    }

    /// A new sign-in. Throws when the write fails (the sign-in fails).
    public func save(_ tokens: ChatGPTTokens) throws {
        try persistence.write(tokens)
        lock.withLock {
            memory = tokens
            staleStored = nil
        }
    }

    public func clear() {
        lock.withLock {
            memory = nil
            staleStored = nil
        }
        do {
            try persistence.delete()
        } catch {
            log("delete failed: \(error.localizedDescription)")
        }
    }

    /// Tokens whose access token is not about to expire, refreshing first when it is.
    /// Retries a pending write first.
    public func validTokens(now: Date = Date()) async throws -> ChatGPTTokens {
        try flushPendingWrite(now: now)
        let tokens = try load(now: now)
        return tokens.isExpired(now: now) ? try await refreshAndSave(now: now, refusedAccess: nil) : tokens
    }

    /// The server refused `refusedAccessToken`: refresh — unless the item already holds
    /// other, unexpired tokens (another process refreshed), which are used as they are.
    public func forceRefresh(refusedAccessToken: String, now: Date = Date()) async throws -> ChatGPTTokens {
        try flushPendingWrite(now: now)
        return try await refreshAndSave(now: now, refusedAccess: refusedAccessToken)
    }

    /// Never refreshes, never touches memory: for one-shot diagnostics, which must not
    /// rotate the refresh token under the running app.
    public func unexpiredTokensWithoutRefresh(now: Date = Date()) throws -> ChatGPTTokens {
        switch readItem() {
        case .missing: throw Failure.notSignedIn
        case .unreadable: throw Failure.unreadable
        case let .found(tokens):
            guard !tokens.isExpired(now: now) else { throw Failure.tokenExpired }
            return tokens
        }
    }

    // MARK: - Reading and reconciling

    private enum Read: Equatable {
        case found(ChatGPTTokens)
        case missing
        case unreadable

        var tokens: ChatGPTTokens? {
            if case let .found(tokens) = self { return tokens }
            return nil
        }

        func stored(now: Date) -> ChatGPTRotation.Stored {
            switch self {
            case let .found(tokens):
                .found(refreshToken: tokens.refreshToken, accessToken: tokens.accessToken,
                       accessValid: !tokens.isExpired(now: now))
            case .missing: .missing
            case .unreadable: .unreadable
            }
        }
    }

    /// One read of the item, reconciled with memory. `staleBefore` is the pending marker
    /// as it was before reconciling (what the decisions compare against).
    private struct Sync {
        let read: Read
        let staleBefore: String?
        let decision: ChatGPTRotation.Reconcile
        let memory: ChatGPTTokens?
    }

    private func readItem() -> Read {
        do {
            return try persistence.read().map(Read.found) ?? .missing
        } catch {
            log("keychain read failed: \(error.localizedDescription)")
            return .unreadable
        }
    }

    private func sync(now: Date) -> Sync {
        let read = readItem()
        return lock.withLock {
            let staleBefore = staleStored
            let decision = ChatGPTRotation.reconcile(stored: read.stored(now: now), staleStored: staleBefore)
            switch decision {
            case .adoptStored:
                memory = read.tokens
                staleStored = nil
            case .signedOut:
                memory = nil
                staleStored = nil
            case .keepMemoryWritable, .keepMemoryUnreadable, .unreadable:
                break
            }
            return Sync(read: read, staleBefore: staleBefore, decision: decision, memory: memory)
        }
    }

    // MARK: - Refreshing

    private func refreshAndSave(now: Date, refusedAccess: String?) async throws -> ChatGPTTokens {
        let state = sync(now: now)
        let start = ChatGPTRotation.beforeRefresh(
            stored: state.read.stored(now: now), staleStored: state.staleBefore,
            hasMemory: state.memory != nil, refusedAccess: refusedAccess,
        )
        switch start {
        case .useStored:
            guard let stored = state.read.tokens else { throw Failure.unreadable }
            return stored
        case .refreshStored:
            guard let stored = state.read.tokens else { throw Failure.unreadable }
            return try await refresh(stored, now: now, canRetry: true)
        case .refreshMemory:
            guard let memory = state.memory else { throw Failure.unreadable }
            return try await refresh(memory, now: now, canRetry: true)
        case .backOff:
            throw Failure.unreadable
        case .signedOut:
            onSignedOut?()
            throw Failure.notSignedIn
        }
    }

    private func refresh(_ used: ChatGPTTokens, now: Date, canRetry: Bool) async throws -> ChatGPTTokens {
        let refreshed: ChatGPTTokens
        do {
            refreshed = try await refresher.refresh(used, now: now)
        } catch is ChatGPTDeadGrant {
            return try await handleDeadGrant(used, now: now, canRetry: canRetry)
        }
        // `used` is spent now: from here on `refreshed` must not be dropped by accident.
        let state = sync(now: now)
        switch ChatGPTRotation.afterRefresh(used: used.refreshToken, stored: state.read.stored(now: now),
                                            staleStored: state.staleBefore) {
        case .save:
            persist(refreshed, used: used, staleBefore: state.staleBefore)
            return refreshed
        case .superseded:
            throw Failure.superseded
        case .signedOut:
            onSignedOut?()
            throw Failure.notSignedIn
        }
    }

    private func handleDeadGrant(_ used: ChatGPTTokens, now: Date, canRetry: Bool) async throws
        -> ChatGPTTokens {
        let state = sync(now: now)
        let decision = ChatGPTRotation.afterDeadGrant(
            used: used.refreshToken, stored: state.read.stored(now: now),
            staleStored: state.staleBefore, canRetry: canRetry,
        )
        switch decision {
        case .adopt:
            guard let stored = state.read.tokens else { throw Failure.unreadable }
            log("refresh token was rotated elsewhere — using the stored one")
            return stored
        case .retry:
            guard let stored = state.read.tokens else { throw Failure.unreadable }
            log("refresh token was rotated elsewhere — retrying with the stored one")
            return try await refresh(stored, now: now, canRetry: false)
        case .superseded:
            throw Failure.superseded
        case .backOff:
            throw Failure.unreadable
        case .signOut:
            log("refresh grant rejected — signing out")
            clear()
            onSignedOut?()
            throw Failure.sessionExpired
        case .signedOut:
            onSignedOut?()
            throw Failure.notSignedIn
        }
    }

    // MARK: - Writing

    /// New tokens go into memory first and are marked pending (the item still holds the
    /// spent token) until the write succeeds.
    private func persist(_ tokens: ChatGPTTokens, used: ChatGPTTokens, staleBefore: String?) {
        lock.withLock {
            memory = tokens
            staleStored = staleBefore ?? used.refreshToken
        }
        write(tokens)
    }

    /// Retry a pending write — only over our own stale item; adopt an item replaced
    /// elsewhere; never recreate one deleted by a sign-out.
    private func flushPendingWrite(now: Date) throws {
        guard lock.withLock({ staleStored != nil }) else { return }
        let state = sync(now: now)
        switch state.decision {
        case .keepMemoryWritable:
            if let memory = state.memory { write(memory) }
        case .signedOut:
            onSignedOut?()
            throw Failure.notSignedIn
        case .adoptStored:
            log("tokens were replaced elsewhere while a write was pending — adopted them")
        case .keepMemoryUnreadable, .unreadable:
            break
        }
    }

    private func write(_ tokens: ChatGPTTokens) {
        do {
            try persistence.write(tokens)
            lock.withLock {
                if memory == tokens { staleStored = nil }
            }
        } catch {
            log("saving refreshed tokens failed (kept in memory, will retry): \(error.localizedDescription)")
        }
    }
}
