import Foundation
import Security

final class KeychainTrixSessionStore: TrixSessionStore {
    private static let defaultService = "com.softgrid.trix.session"
    private static let defaultAccount = "trix-session"
    private static let legacyService = "com.softgrid.trixmatrix.session"
    private static let legacyAccount = "matrix-session"

    private let service: String
    private let account: String
    private let legacyService: String?
    private let legacyAccount: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = KeychainTrixSessionStore.defaultService,
        account: String = KeychainTrixSessionStore.defaultAccount,
        legacyService: String? = nil,
        legacyAccount: String? = nil
    ) {
        self.service = service
        self.account = account
        let shouldUseDefaultLegacyFallback = service == Self.defaultService && account == Self.defaultAccount
        self.legacyService = legacyService ?? (shouldUseDefaultLegacyFallback ? Self.legacyService : nil)
        self.legacyAccount = legacyAccount ?? (shouldUseDefaultLegacyFallback ? Self.legacyAccount : nil)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadSession() throws -> TrixSession? {
        if let data = try loadData(service: service, account: account) {
            return try decoder.decode(TrixSession.self, from: data)
        }

        if let legacyService,
           let legacyAccount,
           let data = try loadData(service: legacyService, account: legacyAccount) {
            let session = try decoder.decode(TrixSession.self, from: data)
            try? saveSession(session)
            return session
        }

        return nil
    }

    func saveSession(_ session: TrixSession) throws {
        let data = try encoder.encode(session)
        try clearSession()

        var item = baseQuery()
        item[kSecValueData as String] = data
#if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TrixClientError.keychainFailure(status.description)
        }
    }

    func clearSession() throws {
        try deleteSession(service: service, account: account)
        if let legacyService, let legacyAccount {
            try deleteSession(service: legacyService, account: legacyAccount)
        }
    }

    private func loadData(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw TrixClientError.keychainFailure(status.description)
        }

        guard let data = result as? Data else {
            throw TrixClientError.keychainFailure("stored session has unexpected format")
        }

        return data
    }

    private func deleteSession(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrixClientError.keychainFailure(status.description)
        }
    }

    private func baseQuery(service: String = "", account: String = "") -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.isEmpty ? self.service : service,
            kSecAttrAccount as String: account.isEmpty ? self.account : account,
        ]
    }
}
