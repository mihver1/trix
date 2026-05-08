import Foundation
import Security

final class KeychainMatrixSessionStore: MatrixSessionStore {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "com.softgrid.trixmatrix.session",
        account: String = "matrix-session"
    ) {
        self.service = service
        self.account = account
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadSession() throws -> MatrixSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw MatrixClientError.keychainFailure(status.description)
        }

        guard let data = result as? Data else {
            throw MatrixClientError.keychainFailure("stored session has unexpected format")
        }

        return try decoder.decode(MatrixSession.self, from: data)
    }

    func saveSession(_ session: MatrixSession) throws {
        let data = try encoder.encode(session)
        try clearSession()

        var item = baseQuery()
        item[kSecValueData as String] = data
#if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MatrixClientError.keychainFailure(status.description)
        }
    }

    func clearSession() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MatrixClientError.keychainFailure(status.description)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
