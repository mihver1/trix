import CryptoKit
import Foundation
import Security

struct TrixRoomNotificationProfileSnapshot: Equatable, Sendable {
    static let empty = TrixRoomNotificationProfileSnapshot(
        profilesByRoomID: [:],
        updatedAt: .distantPast
    )

    let profilesByRoomID: [String: TrixRoomNotificationProfile]
    let updatedAt: Date

    init(
        profilesByRoomID: [String: TrixRoomNotificationProfile],
        updatedAt: Date = Date()
    ) {
        self.profilesByRoomID = profilesByRoomID.reduce(into: [:]) { partialResult, pair in
            let roomID = Self.normalizedRoomID(pair.key)
            guard !roomID.isEmpty, pair.value != .defaultProfile else {
                return
            }

            partialResult[roomID] = pair.value
        }
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool {
        profilesByRoomID.isEmpty
    }

    func profile(for roomID: String) -> TrixRoomNotificationProfile {
        profilesByRoomID[Self.normalizedRoomID(roomID)] ?? .defaultProfile
    }

    func setting(
        _ profile: TrixRoomNotificationProfile,
        for roomID: String,
        updatedAt: Date = Date()
    ) -> TrixRoomNotificationProfileSnapshot {
        let normalizedRoomID = Self.normalizedRoomID(roomID)
        guard !normalizedRoomID.isEmpty else {
            return self
        }

        var profiles = profilesByRoomID
        if profile == .defaultProfile {
            profiles.removeValue(forKey: normalizedRoomID)
        } else {
            profiles[normalizedRoomID] = profile
        }
        return TrixRoomNotificationProfileSnapshot(
            profilesByRoomID: profiles,
            updatedAt: updatedAt
        )
    }

    static func normalizedRoomID(_ roomID: String) -> String {
        roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

final class TrixRoomNotificationProfileStore: @unchecked Sendable {
    private struct StoredProfiles: Codable {
        let version: Int
        let profilesByRoomID: [String: TrixRoomNotificationProfile]
        let updatedAt: Date
    }

    private struct EncryptedProfiles: Codable {
        let version: Int
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private let keychainService: String
    private let keychainAccount: String
    private let directoryName: String
    private let applicationSupportDirectoryURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEncryptionKey: SymmetricKey?

    init(
        keychainService: String = "com.softgrid.trix.xmpp.room-notification-profile-key",
        keychainAccount: String = "room-notification-profile-key:v1",
        directoryName: String = "RoomNotificationProfiles",
        applicationSupportDirectoryURL: URL? = nil
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountID: String) throws -> TrixRoomNotificationProfileSnapshot {
        let fileURL = try encryptedFileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        return try decryptSnapshot(Data(contentsOf: fileURL), accountID: accountID)
    }

    func save(_ snapshot: TrixRoomNotificationProfileSnapshot, accountID: String) throws {
        let encryptedData = try encryptedData(for: snapshot, accountID: accountID)
        try encryptedData.write(to: encryptedFileURL(accountID: accountID), options: .atomic)
    }

    func clear(accountID: String) throws {
        let fileURL = try encryptedFileURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func encryptedFileURL(accountID: String) throws -> URL {
        try profileDirectoryURL().appendingPathComponent(cacheFileName(accountID: accountID))
    }

    private func encryptedData(
        for snapshot: TrixRoomNotificationProfileSnapshot,
        accountID: String
    ) throws -> Data {
        let stored = StoredProfiles(
            version: 1,
            profilesByRoomID: snapshot.profilesByRoomID,
            updatedAt: snapshot.updatedAt
        )
        let data = try encoder.encode(stored)
        let sealedBox = try AES.GCM.seal(
            data,
            using: encryptionKey(),
            authenticating: Data(normalizedCachePart(accountID).utf8)
        )
        let encrypted = EncryptedProfiles(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try encoder.encode(encrypted)
    }

    private func decryptSnapshot(
        _ encryptedData: Data,
        accountID: String
    ) throws -> TrixRoomNotificationProfileSnapshot {
        let encrypted = try decoder.decode(EncryptedProfiles.self, from: encryptedData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encrypted.nonce),
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
        let data = try AES.GCM.open(
            sealedBox,
            using: encryptionKey(),
            authenticating: Data(normalizedCachePart(accountID).utf8)
        )
        let stored = try decoder.decode(StoredProfiles.self, from: data)
        return TrixRoomNotificationProfileSnapshot(
            profilesByRoomID: stored.profilesByRoomID,
            updatedAt: stored.updatedAt
        )
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let cachedEncryptionKey {
            return cachedEncryptionKey
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
            throw TrixClientError.keychainFailure("stored room notification profile key has unexpected format")
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

    private func profileDirectoryURL() throws -> URL {
        let rootURL: URL
        if let applicationSupportDirectoryURL {
            rootURL = applicationSupportDirectoryURL
        } else {
            guard let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            rootURL = applicationSupportURL
        }

        let directoryURL = rootURL
            .appendingPathComponent("Trix", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func cacheFileName(accountID: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedCachePart(accountID).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    private func encryptionKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func normalizedCachePart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
