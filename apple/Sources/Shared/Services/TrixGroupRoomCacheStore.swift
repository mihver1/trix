import CryptoKit
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

    private struct EncryptedGroupRoom: Codable {
        let version: Int
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private let legacyService: String
    private let keychainService: String
    private let keychainAccount: String
    private let directoryName: String
    private let keySource: TrixEncryptedCacheKeySource
    private let migratesLegacyKeychainItems: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEncryptionKey: SymmetricKey?

    init(
        legacyService: String = "com.softgrid.trix.xmpp.group-members",
        keychainService: String = "com.softgrid.trix.xmpp.group-members-cache-key",
        keychainAccount: String = "group-members-cache-key:v1",
        directoryName: String = "GroupMemberCache",
        keySource: TrixEncryptedCacheKeySource = .keychain,
        migratesLegacyKeychainItems: Bool = true
    ) {
        self.legacyService = legacyService
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        self.keySource = keySource
        self.migratesLegacyKeychainItems = migratesLegacyKeychainItems
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountJID: String, roomID: String) throws -> TrixCachedGroupRoom? {
        let fileURL = try cacheFileURL(accountJID: accountJID, roomID: roomID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let encryptedData = try Data(contentsOf: fileURL)
            return try decodeGroupRoom(from: try decrypt(encryptedData))
        }

        guard let legacyData = try loadLegacyData(accountJID: accountJID, roomID: roomID) else {
            return nil
        }

        let cached = try decodeGroupRoom(from: legacyData)
        do {
            try save(cached, accountJID: accountJID)
            try? clearLegacy(accountJID: accountJID, roomID: roomID)
        } catch {
            // Keep the legacy Keychain blob until file migration has succeeded.
        }
        return cached
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
        try saveEncrypted(data, to: cacheFileURL(accountJID: accountJID, roomID: group.roomID))
    }

    func clear(accountJID: String, roomID: String) throws {
        let fileURL = try cacheFileURL(accountJID: accountJID, roomID: roomID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try clearLegacy(accountJID: accountJID, roomID: roomID)
    }

    private func decodeGroupRoom(from data: Data) throws -> TrixCachedGroupRoom {
        let stored = try decoder.decode(StoredGroupRoom.self, from: data)
        return TrixCachedGroupRoom(
            roomID: stored.roomID,
            name: stored.name,
            memberUserIDs: Set(stored.memberUserIDs.map { $0.lowercased() }),
            lastActivityAt: stored.lastActivityAt
        )
    }

    private func saveEncrypted(_ data: Data, to fileURL: URL) throws {
        let key = try encryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        let encrypted = EncryptedGroupRoom(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        let encryptedData = try encoder.encode(encrypted)
        try encryptedData.write(to: fileURL, options: .atomic)
    }

    private func decrypt(_ encryptedData: Data) throws -> Data {
        let encrypted = try decoder.decode(EncryptedGroupRoom.self, from: encryptedData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encrypted.nonce),
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
        return try AES.GCM.open(sealedBox, using: encryptionKey())
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let cachedEncryptionKey {
            return cachedEncryptionKey
        }

        if case .memory(let data) = keySource {
            let key = SymmetricKey(data: data)
            cachedEncryptionKey = key
            return key
        }

        if let data = try loadEncryptionKeyData() {
            let key = SymmetricKey(data: data)
            cachedEncryptionKey = key
            return key
        }

        let data = try makeEncryptionKeyData()
        try saveEncryptionKeyData(data)
        let key = SymmetricKey(data: data)
        cachedEncryptionKey = key
        return key
    }

    private func loadEncryptionKeyData() throws -> Data? {
        var query = encryptionKeyQuery()
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
            throw TrixClientError.keychainFailure("stored group member cache key has unexpected format")
        }

        return data
    }

    private func makeEncryptionKeyData() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecAllocate
            }

            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw TrixClientError.keychainFailure(status.description)
        }

        return data
    }

    private func saveEncryptionKeyData(_ data: Data) throws {
        var item = encryptionKeyQuery()
        item[kSecValueData as String] = data
#if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TrixClientError.keychainFailure(addStatus.description)
        }
    }

    private func loadLegacyData(accountJID: String, roomID: String) throws -> Data? {
        guard migratesLegacyKeychainItems else {
            return nil
        }

        var query = legacyGroupQuery(accountJID: accountJID, roomID: roomID)
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

        return data
    }

    private func clearLegacy(accountJID: String, roomID: String) throws {
        guard migratesLegacyKeychainItems else {
            return
        }

        let status = SecItemDelete(legacyGroupQuery(accountJID: accountJID, roomID: roomID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrixClientError.keychainFailure(status.description)
        }
    }

    private func cacheFileURL(accountJID: String, roomID: String) throws -> URL {
        let directoryURL = try cacheDirectoryURL()
        return directoryURL.appendingPathComponent(cacheFileName(accountJID: accountJID, roomID: roomID))
    }

    private func cacheDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directoryURL = applicationSupportURL
            .appendingPathComponent("Trix", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func cacheFileName(accountJID: String, roomID: String) -> String {
        let rawKey = "\(normalizedCachePart(accountJID))|\(normalizedCachePart(roomID))"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    private func legacyGroupQuery(accountJID: String, roomID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyKeychainAccount(accountJID: accountJID, roomID: roomID),
        ]
    }

    private func encryptionKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func legacyKeychainAccount(accountJID: String, roomID: String) -> String {
        let account = normalizedCachePart(accountJID)
        let room = normalizedCachePart(roomID)
        return "group-members:\(account)|\(room)"
    }

    private func normalizedCachePart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
