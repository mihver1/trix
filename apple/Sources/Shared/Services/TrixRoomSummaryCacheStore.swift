import CryptoKit
import Foundation
import Security

final class TrixRoomSummaryCacheStore: @unchecked Sendable {
    private struct CachedRoomSummaries: Codable {
        let version: Int
        let rooms: [TrixRoomSummary]
    }

    private struct EncryptedRoomSummaries: Codable {
        let version: Int
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private let keychainService: String
    private let keychainAccount: String
    private let directoryName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEncryptionKey: SymmetricKey?

    init(
        keychainService: String = "com.softgrid.trix.xmpp.room-summary-cache-key",
        keychainAccount: String = "room-summary-cache-key:v1",
        directoryName: String = "RoomSummaryCache"
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountJID: String) throws -> [TrixRoomSummary] {
        let fileURL = try cacheFileURL(accountJID: accountJID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let encryptedData = try Data(contentsOf: fileURL)
        return try decrypt(encryptedData)
    }

    func save(_ rooms: [TrixRoomSummary], accountJID: String) throws {
        try saveEncrypted(rooms, to: cacheFileURL(accountJID: accountJID))
    }

    func clear(accountJID: String) throws {
        let fileURL = try cacheFileURL(accountJID: accountJID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func saveEncrypted(_ rooms: [TrixRoomSummary], to fileURL: URL) throws {
        let data = try encoder.encode(CachedRoomSummaries(version: 1, rooms: rooms))
        let key = try encryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        let encrypted = EncryptedRoomSummaries(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        let encryptedData = try encoder.encode(encrypted)
        try encryptedData.write(to: fileURL, options: .atomic)
    }

    private func decrypt(_ encryptedData: Data) throws -> [TrixRoomSummary] {
        let encrypted = try decoder.decode(EncryptedRoomSummaries.self, from: encryptedData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encrypted.nonce),
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
        let data = try AES.GCM.open(sealedBox, using: encryptionKey())
        return try decoder.decode(CachedRoomSummaries.self, from: data).rooms
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
            throw TrixClientError.keychainFailure("stored room summary cache key has unexpected format")
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

    private func cacheFileURL(accountJID: String) throws -> URL {
        let directoryURL = try cacheDirectoryURL()
        return directoryURL.appendingPathComponent(cacheFileName(accountJID: accountJID))
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

    private func cacheFileName(accountJID: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedCachePart(accountJID).utf8))
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
