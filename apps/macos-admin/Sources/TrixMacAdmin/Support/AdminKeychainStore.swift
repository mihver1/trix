import Foundation
import Security

struct AdminKeychainStore: Sendable {
    private let service: String

    init(service: String = AppIdentity.keychainService) {
        self.service = service
    }

    func accessTokenAccount(for clusterID: UUID) -> String {
        "cluster.\(clusterID.uuidString.lowercased()).access-token"
    }

    func saveAccessToken(_ token: String, for clusterID: UUID) throws {
        let data = Data(token.utf8)
        let account = accessTokenAccount(for: clusterID)
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
                    throw AdminKeychainStoreError.unhandledStatus(retryStatus)
                }
            default:
                throw AdminKeychainStoreError.unhandledStatus(addStatus)
            }
        default:
            throw AdminKeychainStoreError.unhandledStatus(updateStatus)
        }
    }

    func loadAccessToken(for clusterID: UUID) throws -> String? {
        let account = accessTokenAccount(for: clusterID)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AdminKeychainStoreError.unhandledStatus(status)
        }
    }

    func removeAccessToken(for clusterID: UUID) throws {
        let account = accessTokenAccount(for: clusterID)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AdminKeychainStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum AdminKeychainStoreError: LocalizedError {
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
