import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case notFound
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code credentials not found. Log in with Claude Code first."
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain access failed: \(message). Allow access when macOS prompts."
        }
    }
}

/// Read/write a generic-password Keychain item by service name.
///
/// Reading the `Claude Code-credentials` item (created by another app) triggers a one-time
/// macOS authorization prompt; choosing "Always Allow" makes it persistent for this signed app.
struct Keychain {
    struct Item {
        let data: Data
        let account: String?
    }

    let service: String

    func read() throws -> Item {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard
            status == errSecSuccess,
            let dict = result as? [String: Any],
            let data = dict[kSecValueData as String] as? Data
        else {
            throw KeychainError.unexpectedStatus(status)
        }

        return Item(data: data, account: dict[kSecAttrAccount as String] as? String)
    }

    /// Does an item exist, without reading its secret?
    ///
    /// Returning the value (`kSecReturnData`) is authorization-gated and makes macOS prompt
    /// for the login password when the ACL doesn't already trust this binary. A
    /// **metadata-only** query is not gated, so existence checks — which views ask for
    /// constantly — must never request the data.
    func exists(account: String?) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Update the existing item in place (matching the same service + account so we never
    /// clobber or duplicate Claude Code's credential).
    func write(_ data: Data, account: String?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }

    func delete(account: String?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
