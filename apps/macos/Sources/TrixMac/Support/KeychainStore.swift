import Foundation
import Security

enum VaultKey: String, CaseIterable {
    case accountRootSeed = "current.account-root-seed"
    case transportSeed = "current.transport-seed"
    case credentialIdentity = "current.credential-identity"
    case accessToken = "current.access-token"
}

struct KeychainStore {
    private let service = AppIdentity.keychainService

    func save(_ data: Data, for key: VaultKey) throws {
        try save(data, account: key.rawValue)
    }

    func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainStoreError.unhandledStatus(retryStatus)
                }
            default:
                throw KeychainStoreError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unhandledStatus(updateStatus)
        }
    }

    func loadData(for key: VaultKey) throws -> Data? {
        try loadData(account: key.rawValue)
    }

    func loadData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    func removeValue(for key: VaultKey) throws {
        try removeValue(account: key.rawValue)
    }

    func removeValue(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    /// Deletes generic-password items for this service whose `kSecAttrAccount` begins with one of the prefixes (e.g. per-workspace SQLite keys).
    func removeGenericPasswords(withAccountPrefixes prefixes: [String]) throws {
        guard !prefixes.isEmpty else { return }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: kCFBooleanTrue,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecItemNotFound:
            return
        case errSecSuccess:
            break
        default:
            throw KeychainStoreError.unhandledStatus(status)
        }

        let itemDictionaries: [[String: Any]]
        if let array = result as? [[String: Any]] {
            itemDictionaries = array
        } else if let single = result as? [String: Any] {
            itemDictionaries = [single]
        } else {
            return
        }

        for attributes in itemDictionaries {
            guard let account = attributes[kSecAttrAccount as String] as? String else { continue }
            guard prefixes.contains(where: { account.hasPrefix($0) }) else { continue }
            try removeValue(account: account)
        }
    }

    private func baseQuery(for key: VaultKey) -> [String: Any] {
        baseQuery(account: key.rawValue)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainStoreError: LocalizedError {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandledStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain operation failed with status \(status)."
        }
    }
}
