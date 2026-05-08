import Foundation
import Security

final class TrixTimelineCacheStore: @unchecked Sendable {
    private struct CachedTimeline: Codable {
        let version: Int
        let items: [MatrixTimelineItem]
    }

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = "com.softgrid.trix.xmpp.timeline") {
        self.service = service
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountJID: String, roomID: String) throws -> [MatrixTimelineItem] {
        var query = baseQuery(accountJID: accountJID, roomID: roomID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw MatrixClientError.keychainFailure(status.description)
        }
        guard let data = result as? Data else {
            throw MatrixClientError.keychainFailure("stored timeline has unexpected format")
        }

        return try decoder.decode(CachedTimeline.self, from: data).items
    }

    func save(_ items: [MatrixTimelineItem], accountJID: String, roomID: String) throws {
        let data = try encoder.encode(CachedTimeline(version: 1, items: items))
        let query = baseQuery(accountJID: accountJID, roomID: roomID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw MatrixClientError.keychainFailure(updateStatus.description)
        }

        var item = query
        item[kSecValueData as String] = data
#if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MatrixClientError.keychainFailure(addStatus.description)
        }
    }

    func clear(accountJID: String, roomID: String) throws {
        let status = SecItemDelete(baseQuery(accountJID: accountJID, roomID: roomID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MatrixClientError.keychainFailure(status.description)
        }
    }

    private func baseQuery(accountJID: String, roomID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(accountJID: accountJID, roomID: roomID),
        ]
    }

    private func keychainAccount(accountJID: String, roomID: String) -> String {
        let account = accountJID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let room = roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "timeline:\(account)|\(room)"
    }
}
