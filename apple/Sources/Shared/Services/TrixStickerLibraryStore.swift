import CryptoKit
import Foundation
import Security

struct TrixStickerLibraryState: Equatable, Sendable {
    let packs: [TrixStickerPack]
    let dataByStickerID: [String: Data]
}

struct TrixStickerLibraryStats: Equatable, Sendable {
    let packCount: Int
    let stickerCount: Int
    let totalBytes: Int64

    static let empty = TrixStickerLibraryStats(packCount: 0, stickerCount: 0, totalBytes: 0)

    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

final class TrixStickerLibraryStore: @unchecked Sendable {
    private struct StoredLibrary: Codable {
        let version: Int
        var packs: [TrixStickerPack]
        var dataByStickerID: [String: Data]
    }

    private struct EncryptedLibrary: Codable {
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
        keychainService: String = "com.softgrid.trix.xmpp.sticker-library-key",
        keychainAccount: String = "sticker-library-key:v1",
        directoryName: String = "StickerLibrary"
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountID: String) throws -> TrixStickerLibraryState {
        let stored = try loadStoredLibrary(accountID: accountID)
        return TrixStickerLibraryState(
            packs: sortedPacks(stored.packs),
            dataByStickerID: stored.dataByStickerID
        )
    }

    func save(
        pack: TrixStickerPack,
        dataByStickerID newDataByStickerID: [String: Data],
        accountID: String
    ) throws -> TrixStickerLibraryState {
        var stored = try loadStoredLibrary(accountID: accountID)
        stored.packs.removeAll { $0.id == pack.id }
        stored.packs.append(pack)
        for (stickerID, data) in newDataByStickerID {
            stored.dataByStickerID[stickerID] = data
        }
        stored.packs = sortedPacks(stored.packs)
        try saveStoredLibrary(stored, accountID: accountID)
        return TrixStickerLibraryState(
            packs: stored.packs,
            dataByStickerID: stored.dataByStickerID
        )
    }

    func deletePack(id packID: String, accountID: String) throws -> TrixStickerLibraryState {
        var stored = try loadStoredLibrary(accountID: accountID)
        let removedStickerIDs = Set(
            stored.packs
                .filter { $0.id == packID }
                .flatMap(\.stickers)
                .map(\.id)
        )

        stored.packs.removeAll { $0.id == packID }
        let retainedStickerIDs = Set(stored.packs.flatMap(\.stickers).map(\.id))
        for stickerID in removedStickerIDs {
            if !retainedStickerIDs.contains(stickerID) {
                stored.dataByStickerID[stickerID] = nil
            }
        }
        stored.packs = sortedPacks(stored.packs)
        try saveStoredLibrary(stored, accountID: accountID)
        return TrixStickerLibraryState(
            packs: stored.packs,
            dataByStickerID: stored.dataByStickerID
        )
    }

    func clear(accountID: String) throws {
        let fileURL = try libraryFileURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func stats(accountID: String) throws -> TrixStickerLibraryStats {
        let stored = try loadStoredLibrary(accountID: accountID)
        return TrixStickerLibraryStats(
            packCount: stored.packs.count,
            stickerCount: stored.packs.reduce(0) { $0 + $1.stickers.count },
            totalBytes: stored.dataByStickerID.values.reduce(Int64(0)) { $0 + Int64($1.count) }
        )
    }

    private func loadStoredLibrary(accountID: String) throws -> StoredLibrary {
        let fileURL = try libraryFileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return StoredLibrary(version: 1, packs: [], dataByStickerID: [:])
        }

        let encryptedData = try Data(contentsOf: fileURL)
        let encrypted = try decoder.decode(EncryptedLibrary.self, from: encryptedData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encrypted.nonce),
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
        let data = try AES.GCM.open(sealedBox, using: encryptionKey())
        return try decoder.decode(StoredLibrary.self, from: data)
    }

    private func saveStoredLibrary(_ stored: StoredLibrary, accountID: String) throws {
        let data = try encoder.encode(stored)
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey())
        let encrypted = EncryptedLibrary(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        let encryptedData = try encoder.encode(encrypted)
        try encryptedData.write(to: libraryFileURL(accountID: accountID), options: .atomic)
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
            throw TrixClientError.keychainFailure("stored sticker library key has unexpected format")
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

    private func libraryFileURL(accountID: String) throws -> URL {
        let directoryURL = try libraryDirectoryURL()
        return directoryURL.appendingPathComponent("\(accountHash(accountID)).json")
    }

    private func libraryDirectoryURL() throws -> URL {
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

    private func encryptionKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func accountHash(_ accountID: String) -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sortedPacks(_ packs: [TrixStickerPack]) -> [TrixStickerPack] {
        packs.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
