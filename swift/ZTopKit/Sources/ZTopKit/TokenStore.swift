// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import Security

/// The Keychain keeps pairing tokens out of plain files: one generic
/// password per host, keyed by `host:port` under the zTop service.
/// The same API covers iOS and macOS (the app targets both).
public enum TokenStore {
    /// The Keychain service name all zTop tokens share.
    static let service = "dev.ztop.token"

    /// Stores (or replaces) the token for a host.
    public static func save(_ token: String, for host: String, port: UInt16) throws {
        let account = account(host, port)
        let query: [String: Any] = base(account)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: Data(token.utf8)]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw TokenStoreError(status: status) }
            return
        }
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // macOS's data-protection keychain can race a fresh Add
            // against its own visibility: fall back to the update.
            let update: [String: Any] = [kSecValueData as String: Data(token.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw TokenStoreError(status: status) }
            return
        }
        guard status == errSecSuccess else { throw TokenStoreError(status: status) }
    }

    /// Reads the token for a host, or nil when none is stored.
    public static func load(for host: String, port: UInt16) -> String? {
        var query = base(account(host, port))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the token for a host; missing entries are not an error.
    public static func delete(for host: String, port: UInt16) {
        let status = SecItemDelete(base(account(host, port)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
    }

    private static func account(_ host: String, _ port: UInt16) -> String {
        "\(host):\(port)"
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A Keychain call returned a status other than success or not-found.
public struct TokenStoreError: Error, Equatable {
    public let status: OSStatus
}
