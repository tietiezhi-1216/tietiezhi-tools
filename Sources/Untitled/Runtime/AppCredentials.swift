import Foundation
import Security

/// Injectable Security boundary: tests never read or modify the user's Keychain.
struct CredentialBackend {
    var read: (_ service: String, _ account: String) -> (OSStatus, Data?)
    var update: (_ service: String, _ account: String, _ data: Data) -> OSStatus
    var add: (_ service: String, _ account: String, _ data: Data) -> OSStatus
    var delete: (_ service: String, _ account: String) -> OSStatus

    static var system: Self {
        func query(_ service: String, _ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }
        return Self(read: { service, account in
            var request = query(service, account)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            return (status, value as? Data)
        }, update: { service, account, data in
            SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }, add: { service, account, data in
            var request = query(service, account)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(request as CFDictionary, nil)
        }, delete: { service, account in SecItemDelete(query(service, account) as CFDictionary) })
    }
}

enum AppCredentials {
    static func read(service: String, account: String, backend: CredentialBackend = .system) throws -> Data? {
        let (status, value) = backend.read(service, account)
        if status == errSecSuccess {
            guard let value else { throw failure(status) }
            return value
        }
        guard status == errSecItemNotFound else { throw failure(status) }
        guard let legacy = IdentityMigration.legacyService(for: service) else { return nil }
        let (oldStatus, oldValue) = backend.read(legacy, account)
        if oldStatus == errSecItemNotFound { return nil }
        guard oldStatus == errSecSuccess, let oldValue else { throw failure(oldStatus) }
        // Never fall back to using the legacy identity: publish and verify the new item first.
        let added = backend.add(service, account, oldValue)
        guard added == errSecSuccess || added == errSecDuplicateItem else { throw failure(added) }
        let (verified, result) = backend.read(service, account)
        guard verified == errSecSuccess, let result else { throw failure(verified) }
        // A concurrent new value wins; keep the old item if the values differ.
        if result == oldValue {
            let deleted = backend.delete(legacy, account)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw failure(deleted) }
        }
        return result
    }

    static func save(_ data: Data, service: String, account: String, backend: CredentialBackend = .system) throws {
        let updated = backend.update(service, account, data)
        let status = updated == errSecItemNotFound ? backend.add(service, account, data) : updated
        guard status == errSecSuccess else { throw failure(status) }
        // An explicit replacement must not resurrect an older key after later deletion.
        if let legacy = IdentityMigration.legacyService(for: service) {
            let deleted = backend.delete(legacy, account)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw failure(deleted) }
        }
    }

    static func delete(service: String, account: String, backend: CredentialBackend = .system) throws {
        // Remove the import source first: a denied deletion must not resurrect a revoked new item.
        for name in [IdentityMigration.legacyService(for: service), service].compactMap({ $0 }) {
            let status = backend.delete(name, account)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        }
    }

    private static func failure(_ status: OSStatus) -> PluginError {
        .invalid("无法访问或迁移钥匙串（\(status)）。请在钥匙串访问中允许 Untitled，或重新输入 API 密钥 / 重新配对；原密钥在迁移成功前不会删除。")
    }
}
