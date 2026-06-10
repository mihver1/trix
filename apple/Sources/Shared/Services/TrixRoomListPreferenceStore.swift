import CryptoKit
import Foundation
import Security

struct TrixRoomListPreferenceSnapshot: Equatable, Sendable {
    static let empty = TrixRoomListPreferenceSnapshot(
        pinnedRoomIDs: [],
        markedUnreadRoomIDs: [],
        updatedAt: .distantPast
    )

    let pinnedRoomIDs: Set<String>
    let markedUnreadRoomIDs: Set<String>
    let updatedAt: Date

    init(
        pinnedRoomIDs: Set<String>,
        markedUnreadRoomIDs: Set<String>,
        updatedAt: Date = Date()
    ) {
        self.pinnedRoomIDs = Self.normalizedRoomIDs(pinnedRoomIDs)
        self.markedUnreadRoomIDs = Self.normalizedRoomIDs(markedUnreadRoomIDs)
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool {
        pinnedRoomIDs.isEmpty && markedUnreadRoomIDs.isEmpty
    }

    func isPinned(_ roomID: String) -> Bool {
        pinnedRoomIDs.contains(Self.normalizedRoomID(roomID))
    }

    func isMarkedUnread(_ roomID: String) -> Bool {
        markedUnreadRoomIDs.contains(Self.normalizedRoomID(roomID))
    }

    func togglingPin(
        for roomID: String,
        updatedAt: Date = Date()
    ) -> TrixRoomListPreferenceSnapshot {
        let normalizedRoomID = Self.normalizedRoomID(roomID)
        guard !normalizedRoomID.isEmpty else {
            return self
        }

        var pinned = pinnedRoomIDs
        if !pinned.insert(normalizedRoomID).inserted {
            pinned.remove(normalizedRoomID)
        }
        return TrixRoomListPreferenceSnapshot(
            pinnedRoomIDs: pinned,
            markedUnreadRoomIDs: markedUnreadRoomIDs,
            updatedAt: updatedAt
        )
    }

    func settingMarkedUnread(
        _ isMarkedUnread: Bool,
        for roomID: String,
        updatedAt: Date = Date()
    ) -> TrixRoomListPreferenceSnapshot {
        let normalizedRoomID = Self.normalizedRoomID(roomID)
        guard !normalizedRoomID.isEmpty else {
            return self
        }

        var markedUnread = markedUnreadRoomIDs
        if isMarkedUnread {
            guard markedUnread.insert(normalizedRoomID).inserted else {
                return self
            }
        } else {
            guard markedUnread.remove(normalizedRoomID) != nil else {
                return self
            }
        }
        return TrixRoomListPreferenceSnapshot(
            pinnedRoomIDs: pinnedRoomIDs,
            markedUnreadRoomIDs: markedUnread,
            updatedAt: updatedAt
        )
    }

    static func normalizedRoomID(_ roomID: String) -> String {
        roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedRoomIDs(_ roomIDs: Set<String>) -> Set<String> {
        Set(
            roomIDs
                .map(normalizedRoomID)
                .filter { !$0.isEmpty }
        )
    }
}

final class TrixRoomListPreferenceStore: @unchecked Sendable {
    private struct StoredPreferences: Codable {
        let version: Int
        let pinnedRoomIDs: [String]
        let markedUnreadRoomIDs: [String]
        let updatedAt: Date
    }

    private struct EncryptedPreferences: Codable {
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
        keychainService: String = "com.softgrid.trix.xmpp.room-list-preference-key",
        keychainAccount: String = "room-list-preference-key:v1",
        directoryName: String = "RoomListPreferences",
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

    func load(accountID: String) throws -> TrixRoomListPreferenceSnapshot {
        let fileURL = try encryptedFileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        return try decryptSnapshot(Data(contentsOf: fileURL), accountID: accountID)
    }

    func save(_ snapshot: TrixRoomListPreferenceSnapshot, accountID: String) throws {
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
        try preferenceDirectoryURL().appendingPathComponent(cacheFileName(accountID: accountID))
    }

    private func encryptedData(
        for snapshot: TrixRoomListPreferenceSnapshot,
        accountID: String
    ) throws -> Data {
        let stored = StoredPreferences(
            version: 1,
            pinnedRoomIDs: snapshot.pinnedRoomIDs.sorted(),
            markedUnreadRoomIDs: snapshot.markedUnreadRoomIDs.sorted(),
            updatedAt: snapshot.updatedAt
        )
        let data = try encoder.encode(stored)
        let sealedBox = try AES.GCM.seal(
            data,
            using: encryptionKey(),
            authenticating: Data(normalizedCachePart(accountID).utf8)
        )
        let encrypted = EncryptedPreferences(
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
    ) throws -> TrixRoomListPreferenceSnapshot {
        let encrypted = try decoder.decode(EncryptedPreferences.self, from: encryptedData)
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
        let stored = try decoder.decode(StoredPreferences.self, from: data)
        return TrixRoomListPreferenceSnapshot(
            pinnedRoomIDs: Set(stored.pinnedRoomIDs),
            markedUnreadRoomIDs: Set(stored.markedUnreadRoomIDs),
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
            throw TrixClientError.keychainFailure("stored room list preference key has unexpected format")
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

    private func preferenceDirectoryURL() throws -> URL {
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
