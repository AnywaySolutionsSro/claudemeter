@testable import ClaudeMeterCore
import Foundation
import Testing

/// An in-memory Keychain item shared by "processes" (vaults), with switchable failures.
final class FakeItem: ChatGPTTokenPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: ChatGPTTokens?
    private var failReads = false
    private var failWrites = false

    init(_ tokens: ChatGPTTokens?) { self.tokens = tokens }

    var stored: ChatGPTTokens? {
        get { lock.withLock { tokens } }
        set { lock.withLock { tokens = newValue } }
    }

    var readsFail: Bool {
        get { lock.withLock { failReads } }
        set { lock.withLock { failReads = newValue } }
    }

    var writesFail: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }

    struct Failure: Error {}

    func read() throws -> ChatGPTTokens? {
        try lock.withLock {
            if failReads { throw Failure() }
            return tokens
        }
    }

    func write(_ new: ChatGPTTokens) throws {
        try lock.withLock {
            if failWrites { throw Failure() }
            tokens = new
        }
    }

    func delete() throws { lock.withLock { tokens = nil } }
}

/// A token endpoint that rotates: each refresh token works once, then is dead.
final class FakeEndpoint: ChatGPTTokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var spent: Set<String> = []
    private var counter = 0
    private var calls: [String] = []
    /// Runs inside a refresh, before it returns (to simulate other processes).
    var during: (@Sendable () -> Void)?

    var refreshCalls: [String] { lock.withLock { calls } }

    func spend(_ token: String) { _ = lock.withLock { spent.insert(token) } }

    func refresh(_ tokens: ChatGPTTokens, now: Date) async throws -> ChatGPTTokens {
        let next: Int? = lock.withLock {
            calls.append(tokens.refreshToken)
            guard !spent.contains(tokens.refreshToken) else { return nil }
            spent.insert(tokens.refreshToken)
            counter += 1
            return counter
        }
        during?()
        guard let next else { throw ChatGPTDeadGrant() }
        return VaultFixture.tokens("r\(next)", access: "a\(next)", expires: now.addingTimeInterval(3600))
    }
}

enum VaultFixture {
    static let now = Date(timeIntervalSince1970: 1_796_000_000)

    static func tokens(_ refresh: String, access: String, expires: Date) -> ChatGPTTokens {
        ChatGPTTokens(accessToken: access, refreshToken: refresh, idToken: "id", expiresAt: expires,
                      accountID: "acct", email: nil)
    }

    static func expired(_ refresh: String, access: String = "old") -> ChatGPTTokens {
        tokens(refresh, access: access, expires: now.addingTimeInterval(-10))
    }

    static func valid(_ refresh: String, access: String) -> ChatGPTTokens {
        tokens(refresh, access: access, expires: now.addingTimeInterval(3600))
    }
}

final class SignOutCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var hits: Int { lock.withLock { value } }
    func hit() { lock.withLock { value += 1 } }
}

struct ChatGPTTokenVaultTests {
    private let now = VaultFixture.now

    private func vault(_ item: FakeItem, _ endpoint: FakeEndpoint,
                       signOuts: SignOutCounter = SignOutCounter()) -> ChatGPTTokenVault {
        let vault = ChatGPTTokenVault(persistence: item, refresher: endpoint)
        vault.onSignedOut = { signOuts.hit() }
        return vault
    }

    @Test func expiredTokensAreRefreshedAndSaved() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let tokens = try await vault(item, endpoint).validTokens(now: now)
        #expect(tokens.refreshToken == "r1")
        #expect(item.stored?.refreshToken == "r1")
    }

    /// I-1, through the real sequencing: our memory holds the refused token, another
    /// process already refreshed and stored a valid one. Use it; don't spend it.
    @Test func forcedRefreshUsesAValidTokenRotatedElsewhere() async throws {
        let item = FakeItem(VaultFixture.valid("r0", access: "a0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        let refused = try app.load()
        item.stored = VaultFixture.valid("rX", access: "aX") // the other process
        let tokens = try await app.forceRefresh(refusedAccessToken: refused.accessToken, now: now)
        #expect(tokens.accessToken == "aX")
        #expect(endpoint.refreshCalls.isEmpty)
    }

    @Test func forcedRefreshOfTheStoredTokenRefreshes() async throws {
        let item = FakeItem(VaultFixture.valid("r0", access: "a0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        let tokens = try await app.forceRefresh(refusedAccessToken: "a0", now: now)
        #expect(endpoint.refreshCalls == ["r0"])
        #expect(tokens.refreshToken == "r1")
    }

    /// B: a failed write keeps the new tokens authoritative and retries the write.
    @Test func aFailedWriteIsKeptAndRetried() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        item.writesFail = true
        let first = try await app.validTokens(now: now)
        #expect(first.refreshToken == "r1")
        #expect(item.stored?.refreshToken == "r0")
        // Still pending: the stale item must not replace memory.
        #expect(try await app.validTokens(now: now).refreshToken == "r1")
        item.writesFail = false
        _ = try await app.validTokens(now: now)
        #expect(item.stored?.refreshToken == "r1")
    }

    /// B + refresh while pending: memory (r1) is refreshed, not the spent stale item (r0).
    @Test func aPendingWriteRefreshesMemoryNotTheStaleItem() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        item.writesFail = true
        _ = try await app.validTokens(now: now)
        let later = now.addingTimeInterval(7200)
        let tokens = try await app.validTokens(now: later)
        #expect(endpoint.refreshCalls == ["r0", "r1"])
        #expect(tokens.refreshToken == "r2")
    }

    /// I-2: our write is pending and another process stored a newer token; ours dies.
    /// The newer token is adopted — never deleted.
    @Test func aNewerTokenWrittenElsewhereSurvivesOurDeadGrant() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let signOuts = SignOutCounter()
        let app = vault(item, endpoint, signOuts: signOuts)
        item.writesFail = true
        _ = try await app.validTokens(now: now) // memory r1, item r0 (pending)
        endpoint.spend("r1")
        endpoint.during = { item.writesFail = false; item.stored = VaultFixture.valid("rX", access: "aX") }
        let tokens = try await app.forceRefresh(refusedAccessToken: "a1", now: now)
        #expect(tokens.refreshToken == "rX")
        #expect(item.stored?.refreshToken == "rX")
        #expect(signOuts.hits == 0)
    }

    /// D: our token died, the item holds a newer expired one, and the single retry is spent.
    @Test func aNewerTokenIsKeptWhenTheRetryIsSpent() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        endpoint.spend("r0")
        endpoint.spend("rX")
        item.stored = VaultFixture.expired("r0")
        endpoint.during = { item.stored = VaultFixture.expired(endpoint.refreshCalls.count == 1 ? "rX" : "rY") }
        await #expect(throws: ChatGPTTokenVault.Failure.superseded) {
            try await app.validTokens(now: now)
        }
        #expect(item.stored != nil)
    }

    @Test func aDeadGrantOfTheNewestTokenSignsOut() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        endpoint.spend("r0")
        let signOuts = SignOutCounter()
        let app = vault(item, endpoint, signOuts: signOuts)
        await #expect(throws: ChatGPTTokenVault.Failure.sessionExpired) {
            try await app.validTokens(now: now)
        }
        #expect(item.stored == nil)
        #expect(signOuts.hits == 1)
    }

    /// C: a read error after a successful refresh keeps (and stores) the new tokens.
    @Test func aReadErrorAfterRefreshKeepsTheNewTokens() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        _ = try app.load()
        endpoint.during = { item.readsFail = true }
        let tokens = try await app.validTokens(now: now)
        #expect(tokens.refreshToken == "r1")
        item.readsFail = false
        #expect(item.stored?.refreshToken == "r1")
    }

    @Test func aReadErrorBeforeAnyLoadBacksOff() async {
        let item = FakeItem(VaultFixture.expired("r0"))
        item.readsFail = true
        let app = vault(item, FakeEndpoint())
        await #expect(throws: ChatGPTTokenVault.Failure.unreadable) {
            try await app.validTokens(now: now)
        }
        item.readsFail = false
        #expect(item.stored != nil)
    }

    /// M-1 + sign-out elsewhere: a pending write never recreates a deleted item, and the
    /// app is told it is signed out.
    @Test func aSignOutElsewhereIsNotUndone() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let signOuts = SignOutCounter()
        let app = vault(item, endpoint, signOuts: signOuts)
        item.writesFail = true
        _ = try await app.validTokens(now: now)
        item.writesFail = false
        item.stored = nil // signed out in another process
        await #expect(throws: ChatGPTTokenVault.Failure.notSignedIn) {
            try await app.validTokens(now: now)
        }
        #expect(item.stored == nil)
        #expect(signOuts.hits == 1)
    }

    /// M-1: a pending write never overwrites an item replaced elsewhere.
    @Test func aPendingWriteNeverOverwritesANewerItem() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        item.writesFail = true
        _ = try await app.validTokens(now: now)
        item.writesFail = false
        item.stored = VaultFixture.valid("rX", access: "aX")
        let tokens = try await app.validTokens(now: now)
        #expect(tokens.refreshToken == "rX")
        #expect(item.stored?.refreshToken == "rX")
    }

    @Test func aMissingItemAtRefreshSignsOut() async throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let signOuts = SignOutCounter()
        let app = vault(item, FakeEndpoint(), signOuts: signOuts)
        _ = try app.load()
        item.stored = nil
        await #expect(throws: ChatGPTTokenVault.Failure.notSignedIn) {
            try await app.validTokens(now: now)
        }
        #expect(signOuts.hits == 1)
    }

    @Test func diagnosticsNeverRefresh() throws {
        let item = FakeItem(VaultFixture.expired("r0"))
        let endpoint = FakeEndpoint()
        let app = vault(item, endpoint)
        #expect(throws: ChatGPTTokenVault.Failure.tokenExpired) { try app.unexpiredTokensWithoutRefresh(now: now) }
        item.stored = VaultFixture.valid("r0", access: "a0")
        #expect(try app.unexpiredTokensWithoutRefresh(now: now).accessToken == "a0")
        #expect(endpoint.refreshCalls.isEmpty)
    }

    @Test func saveAndClear() throws {
        let item = FakeItem(nil)
        let app = vault(item, FakeEndpoint())
        #expect(throws: ChatGPTTokenVault.Failure.notSignedIn) { try app.load() }
        try app.save(VaultFixture.valid("r0", access: "a0"))
        #expect(try app.load().accessToken == "a0")
        app.clear()
        #expect(item.stored == nil)
        #expect(throws: ChatGPTTokenVault.Failure.notSignedIn) { try app.load() }
    }
}
