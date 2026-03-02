import Foundation
import Security

nonisolated enum KeyStoreError: Error {
    case unexpectedStatus(OSStatus)
    case invalidItemData
}

nonisolated final class KeyStore: Sendable {
    static let shared = KeyStore()

    private let service = "com.pigeon.messenger.keystore"

    private enum Account {
        static let identityPrivateKey = "identity.private-key"
        static let peerPrefix = "peer."
        static let groupPrefix = "group."
    }

    private init() {}

    func saveIdentityPrivateKey(_ privateKeyData: Data) throws {
        try save(data: privateKeyData, account: Account.identityPrivateKey)
    }

    func loadIdentityPrivateKey() throws -> Data? {
        try loadData(account: Account.identityPrivateKey)
    }

    func deleteIdentityPrivateKey() throws {
        try deleteData(account: Account.identityPrivateKey)
    }

    func saveKnownPeerPublicKey(_ publicKeyData: Data, pigeonID: String) throws {
        try save(data: publicKeyData, account: Account.peerPrefix + pigeonID)
    }

    func loadKnownPeerPublicKey(pigeonID: String) throws -> Data? {
        try loadData(account: Account.peerPrefix + pigeonID)
    }

    func loadKnownPeerPublicKeys() throws -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return [:]
        }

        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }

        guard let rawItems = result as? [[String: Any]] else {
            throw KeyStoreError.invalidItemData
        }

        var peers: [String: Data] = [:]

        for item in rawItems {
            guard
                let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(Account.peerPrefix),
                let data = item[kSecValueData as String] as? Data
            else {
                continue
            }

            let pigeonID = String(account.dropFirst(Account.peerPrefix.count))
            peers[pigeonID] = data
        }

        return peers
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    func saveGroupSymmetricKey(_ keyData: Data, groupID: UUID, epoch: Int) throws {
        try save(data: keyData, account: groupKeyAccount(groupID: groupID, epoch: epoch))
    }

    func loadGroupSymmetricKey(groupID: UUID, epoch: Int) throws -> Data? {
        try loadData(account: groupKeyAccount(groupID: groupID, epoch: epoch))
    }

    func deleteAllGroupSymmetricKeys() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return
        }

        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }

        guard let rawItems = result as? [[String: Any]] else {
            throw KeyStoreError.invalidItemData
        }

        for item in rawItems {
            guard
                let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(Account.groupPrefix)
            else {
                continue
            }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw KeyStoreError.unexpectedStatus(deleteStatus)
            }
        }
    }

    private func save(data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private func loadData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeyStoreError.invalidItemData
        }

        return data
    }

    private func deleteData(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private func groupKeyAccount(groupID: UUID, epoch: Int) -> String {
        "\(Account.groupPrefix)\(groupID.uuidString.lowercased()).epoch.\(epoch)"
    }
}
