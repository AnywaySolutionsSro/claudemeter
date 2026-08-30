import ClaudeMeterCore
import Foundation

/// Owns the Claude Console **Admin API key** in ClaudeMeter's own Keychain item.
///
/// Mirrors `AccountStore`: because the app creates the item, it reads it back without
/// prompting. The key is never returned to a view — callers ask `hasKey` to decide what to
/// render, and only `CostClient` ever reads the value.
struct AdminKeyStore {
    static let service = "com.jakubzak.claudemeter.adminkey"
    static let account = "default"

    private let keychain = Keychain(service: service)

    var hasKey: Bool { load() != nil }

    func load() -> AdminKey? {
        guard
            let item = try? keychain.read(),
            let raw = String(data: item.data, encoding: .utf8)
        else {
            return nil
        }
        return AdminKey(raw)
    }

    func save(_ key: AdminKey) throws {
        try keychain.write(Data(key.raw.utf8), account: Self.account)
    }

    func clear() {
        try? keychain.delete(account: Self.account)
    }
}
