import Foundation
import Security

struct TrixCachedGroupRoom: Equatable, Sendable {
    let roomID: String
    var name: String
    var memberUserIDs: Set<String>
    var lastActivityAt: Date
}

final class TrixGroupRoomCacheStore: @unchecked Sendable {
    private struct StoredGroupRoom: Codable {
        let version: Int
        let roomID: String
        let name: String
        let memberUserIDs: [String]
        let lastActivityAt: Date
    }

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = "com.softgrid.trix.xmpp.group-members") {
        self.service = service
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountJID: String, roomID: String) throws -> TrixCachedGroupRoom? {
        var query = baseQuery(accountJID: accountJID, roomID: roomID)
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
            throw TrixClientError.keychainFailure("stored group members have unexpected format")
        }

        let stored = try decoder.decode(StoredGroupRoom.self, from: data)
        return TrixCachedGroupRoom(
            roomID: stored.roomID,
            name: stored.name,
            memberUserIDs: Set(stored.memberUserIDs.map { $0.lowercased() }),
            lastActivityAt: stored.lastActivityAt
        )
    }

    func save(_ group: TrixCachedGroupRoom, accountJID: String) throws {
        let stored = StoredGroupRoom(
            version: 1,
            roomID: group.roomID,
            name: group.name,
            memberUserIDs: group.memberUserIDs.map { $0.lowercased() }.sorted(),
            lastActivityAt: group.lastActivityAt
        )
        let data = try encoder.encode(stored)
        let query = baseQuery(accountJID: accountJID, roomID: group.roomID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw TrixClientError.keychainFailure(updateStatus.description)
        }

        var item = query
        item[kSecValueData as String] = data
#if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TrixClientError.keychainFailure(addStatus.description)
        }
    }

    func clear(accountJID: String, roomID: String) throws {
        let status = SecItemDelete(baseQuery(accountJID: accountJID, roomID: roomID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrixClientError.keychainFailure(status.description)
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
        return "group-members:\(account)|\(room)"
    }
}
