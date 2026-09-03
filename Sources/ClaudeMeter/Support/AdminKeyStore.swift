import ClaudeMeterCore
import Foundation
import OSLog

/// Owns the Claude Console **Admin API key** in ClaudeMeter's own Keychain item.
///
/// The key is never returned to a view — callers ask `hasKey` to decide what to render,
/// and only `CostClient` ever reads the value.
/// Failures specific to storing the admin key.
enum AdminKeyStoreError: Error, LocalizedError, Equatable {
    /// Deletion reported success but the key is still readable.
    case stillPresent

    var errorDescription: String? {
        switch self {
        case .stillPresent:
            "The key is still stored in the Keychain."
        }
    }
}

struct AdminKeyStore {
    static let service = "com.jakubzak.claudemeter.adminkey"
    static let account = "default"

    private static let log = Logger(
        subsystem: "com.jakubzak.claudemeter", category: "adminkey",
    )

    /// A Console admin key grants full organization access, so it is stored in the
    /// **data-protection** keychain when possible, rather than the legacy login keychain
    /// whose file is carried by Time Machine and Migration Assistant.
    ///
    /// **The fallback is not optional.** The data-protection keychain requires
    /// `com.apple.application-identifier`, which a dev build gets from its provisioning
    /// profile but a **Developer ID release build does not have** — writes there fail with
    /// `errSecMissingEntitlement`. Storing only in the data-protection keychain therefore
    /// works locally and silently breaks saving the key in every shipped build.
    private let keychain = Keychain(service: service, dataProtection: true)
    private let legacyKeychain = Keychain(service: service)

    /// Existence only — deliberately does NOT read the secret. Reading the value is
    /// authorization-gated and prompts for the login password; this is called from SwiftUI
    /// bodies that re-evaluate every second.
    var hasKey: Bool {
        keychain.exists(account: Self.account) || legacyKeychain.exists(account: Self.account)
    }

    func load() -> AdminKey? {
        if let key = read(from: keychain) { return key }
        // Migrate a key written by a build that used the legacy login keychain.
        guard let legacy = read(from: legacyKeychain) else { return nil }
        do {
            try keychain.write(Data(legacy.raw.utf8), account: Self.account)
            try? legacyKeychain.delete(account: Self.account)
            Self.log.notice("migrated admin key to the data-protection keychain")
        } catch {
            Self.log.notice(
                "data-protection keychain unavailable, staying on the login keychain: \(String(describing: error), privacy: .public)",
            )
        }
        return legacy
    }

    func save(_ key: AdminKey) throws {
        let data = Data(key.raw.utf8)
        do {
            try keychain.write(data, account: Self.account)
            try? legacyKeychain.delete(account: Self.account)
            Self.log.notice("admin key stored in the data-protection keychain")
        } catch {
            // No application-identifier (Developer ID build) — fall back rather than
            // leaving the user unable to save a key at all.
            try legacyKeychain.write(data, account: Self.account)
            Self.log.notice("admin key stored in the legacy keychain (fallback)")
        }
    }

    /// Throws rather than swallowing: reporting "removed" for a key that is still stored
    /// leaves the user believing a full-org-admin credential is gone — exactly the belief
    /// that stops them revoking it in the Console.
    func clear() throws {
        // Both stores: a key may live in either, depending on how the build was signed.
        // The data-protection delete fails with `errSecMissingEntitlement` (-34018) in a
        // Developer ID build even when nothing is stored there — a thrown error here
        // would make "Remove" impossible in every shipped build. The `hasKey` check
        // below is what guarantees honesty, so this delete is best-effort.
        do {
            try keychain.delete(account: Self.account)
        } catch {
            Self.log.notice("data-protection keychain delete skipped: \(String(describing: error), privacy: .public)")
        }
        try legacyKeychain.delete(account: Self.account)
        guard !hasKey else { throw AdminKeyStoreError.stillPresent }
    }

    private func read(from keychain: Keychain) -> AdminKey? {
        guard
            let item = try? keychain.read(account: Self.account),
            let raw = String(data: item.data, encoding: .utf8)
        else {
            return nil
        }
        return AdminKey(raw)
    }
}
