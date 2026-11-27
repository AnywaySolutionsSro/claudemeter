import ClaudeMeterCore
import Foundation
import OSLog

/// Owns ClaudeMeter's ChatGPT tokens in its **own** Keychain item
/// (`com.jakubzak.claudemeter.chatgpt`). Never reads or writes Codex's `~/.codex/auth.json`.
///
/// The UI asks only `exists` (metadata, never the secret — a secret read can prompt for
/// the login password). Everything else — the in-memory copy, refresh-token rotation,
/// pending writes — is `ChatGPTTokenVault` in core (tested); this adapts it to the
/// Keychain, the token endpoint and `ChatGPTError`.
final class ChatGPTAccountStore: @unchecked Sendable {
    static let service = "com.jakubzak.claudemeter.chatgpt"
    static let account = "default"
    static let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "chatgpt")

    private let keychain = Keychain(service: service)
    private let vault: ChatGPTTokenVault

    /// Called (on any thread) when the login ended: a dead grant, or the item vanished.
    var onSignedOut: (@Sendable () -> Void)? {
        get { vault.onSignedOut }
        set { vault.onSignedOut = newValue }
    }

    init(client: ChatGPTTokenClient = ChatGPTTokenClient()) {
        vault = ChatGPTTokenVault(
            persistence: KeychainTokenItem(keychain: keychain),
            refresher: EndpointRefresher(client: client),
            log: { Self.log.notice("chatgpt: \($0, privacy: .public)") },
        )
    }

    /// Whether a login is stored — metadata only, safe to ask from UI code.
    var exists: Bool { keychain.exists(account: Self.account) }

    func load() throws -> ChatGPTTokens {
        try mapped { try vault.load() }
    }

    func save(_ tokens: ChatGPTTokens) throws {
        try vault.save(tokens)
    }

    func clear() {
        vault.clear()
    }

    func validTokens(now: Date = Date()) async throws -> ChatGPTTokens {
        do {
            return try await vault.validTokens(now: now)
        } catch let failure as ChatGPTTokenVault.Failure {
            throw ChatGPTError(failure)
        }
    }

    /// The server refused `refused`: refresh, or use newer stored tokens if another
    /// process already refreshed.
    func forceRefresh(refused: ChatGPTTokens, now: Date = Date()) async throws -> ChatGPTTokens {
        do {
            return try await vault.forceRefresh(refusedAccessToken: refused.accessToken, now: now)
        } catch let failure as ChatGPTTokenVault.Failure {
            throw ChatGPTError(failure)
        }
    }

    /// Never refreshes (diagnostics must not rotate the token under the running app).
    func unexpiredTokensWithoutRefresh(now: Date = Date()) throws -> ChatGPTTokens {
        try mapped { try vault.unexpiredTokensWithoutRefresh(now: now) }
    }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as ChatGPTTokenVault.Failure {
            throw ChatGPTError(failure)
        }
    }
}

/// The Keychain item as the vault's persistence: nil when missing, a throw only when unreadable.
private struct KeychainTokenItem: ChatGPTTokenPersistence {
    let keychain: Keychain

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

    func read() throws -> ChatGPTTokens? {
        let item: Keychain.Item
        do {
            item = try keychain.read(account: ChatGPTAccountStore.account)
        } catch KeychainError.notFound {
            return nil
        }
        return try Self.decoder.decode(ChatGPTTokens.self, from: item.data)
    }

    func write(_ tokens: ChatGPTTokens) throws {
        try keychain.write(Self.encoder.encode(tokens), account: ChatGPTAccountStore.account)
    }

    func delete() throws {
        try keychain.delete(account: ChatGPTAccountStore.account)
    }
}

/// The token endpoint as the vault's refresher: a dead grant is `ChatGPTDeadGrant`.
private struct EndpointRefresher: ChatGPTTokenRefreshing {
    let client: ChatGPTTokenClient

    func refresh(_ tokens: ChatGPTTokens, now: Date) async throws -> ChatGPTTokens {
        do {
            return try await client.refresh(tokens, now: now)
        } catch ChatGPTError.sessionExpired {
            throw ChatGPTDeadGrant()
        } catch {
            ChatGPTAccountStore.log.notice("chatgpt: refresh failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

extension ChatGPTError {
    init(_ failure: ChatGPTTokenVault.Failure) {
        self = switch failure {
        case .notSignedIn: .notSignedIn
        case .unreadable: .keychainUnreadable
        case .superseded: .superseded
        case .sessionExpired: .sessionExpired
        case .tokenExpired: .tokenExpired
        }
    }
}
