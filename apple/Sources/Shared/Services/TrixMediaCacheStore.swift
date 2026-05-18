import CryptoKit
import Foundation
import Security

struct TrixMediaCachePolicy: Codable, Equatable, Sendable {
    static let defaultPolicy = TrixMediaCachePolicy(
        maxSizeBytes: 512 * 1024 * 1024,
        maxAgeDays: 30,
        maxMediaItemsPerRoom: 500
    )

    static let unlimited = TrixMediaCachePolicy(
        maxSizeBytes: nil,
        maxAgeDays: nil,
        maxMediaItemsPerRoom: nil
    )

    let maxSizeBytes: Int64?
    let maxAgeDays: Int?
    let maxMediaItemsPerRoom: Int?

    var sanitized: TrixMediaCachePolicy {
        TrixMediaCachePolicy(
            maxSizeBytes: maxSizeBytes.map { max(1, $0) },
            maxAgeDays: maxAgeDays.map { max(1, $0) },
            maxMediaItemsPerRoom: maxMediaItemsPerRoom.map { max(1, $0) }
        )
    }

    var isUnlimited: Bool {
        maxSizeBytes == nil && maxAgeDays == nil && maxMediaItemsPerRoom == nil
    }
}

struct TrixMediaCacheSnapshot: Equatable, Sendable {
    let entryCount: Int
    let totalBytes: Int64
    let oldestEntryAt: Date?
    let newestEntryAt: Date?
    let updatedAt: Date

    static let empty = TrixMediaCacheSnapshot(
        entryCount: 0,
        totalBytes: 0,
        oldestEntryAt: nil,
        newestEntryAt: nil,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

protocol TrixMediaCacheSettingsStore {
    func loadPolicy() -> TrixMediaCachePolicy
    func savePolicy(_ policy: TrixMediaCachePolicy) throws
}

final class UserDefaultsTrixMediaCacheSettingsStore: TrixMediaCacheSettingsStore {
    private let userDefaults: UserDefaults
    private let policyKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        policyKey: String = "com.softgrid.trix.media-cache.policy.v1"
    ) {
        self.userDefaults = userDefaults
        self.policyKey = policyKey
    }

    func loadPolicy() -> TrixMediaCachePolicy {
        guard let data = userDefaults.data(forKey: policyKey),
              let policy = try? decoder.decode(TrixMediaCachePolicy.self, from: data) else {
            return .defaultPolicy
        }

        return policy.sanitized
    }

    func savePolicy(_ policy: TrixMediaCachePolicy) throws {
        let data = try encoder.encode(policy.sanitized)
        userDefaults.set(data, forKey: policyKey)
    }
}

final class TrixMediaCacheStore: @unchecked Sendable {
    private struct StoredIndex: Codable {
        let version: Int
        var entries: [TrixMediaCacheEntry]
    }

    private struct TrixMediaCacheEntry: Codable, Equatable {
        let id: String
        let roomID: String
        let messageID: String
        let kind: TrixTimelineAttachmentKind
        let filename: String
        let mimeType: String?
        var byteCount: Int64
        let createdAt: Date
        var lastAccessedAt: Date
        let messageTimestamp: Date
    }

    private struct EncryptedPayload: Codable {
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
        keychainService: String = "com.softgrid.trix.xmpp.media-cache-key",
        keychainAccount: String = "media-cache-key:v1",
        directoryName: String = "MediaCache"
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadAttachment(
        for item: TrixTimelineItem,
        accountID: String,
        now: Date = Date()
    ) throws -> TrixAttachmentDownload? {
        guard let attachment = item.attachment else {
            return nil
        }

        let id = cacheEntryID(accountID: accountID, roomID: item.roomID, messageID: item.id, attachment: attachment)
        var index = try loadIndex(accountID: accountID)
        guard let entryIndex = index.entries.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let fileURL = try dataFileURL(accountID: accountID, entryID: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            index.entries.remove(at: entryIndex)
            try saveIndex(index, accountID: accountID)
            return nil
        }

        let data = try decrypt(Data(contentsOf: fileURL))
        index.entries[entryIndex].lastAccessedAt = now
        index.entries[entryIndex].byteCount = Int64(data.count)
        try saveIndex(index, accountID: accountID)

        let entry = index.entries[entryIndex]
        return TrixAttachmentDownload(
            filename: entry.filename,
            mimeType: entry.mimeType,
            data: data
        )
    }

    @discardableResult
    func saveAttachment(
        _ download: TrixAttachmentDownload,
        for item: TrixTimelineItem,
        accountID: String,
        policy: TrixMediaCachePolicy,
        now: Date = Date()
    ) throws -> TrixMediaCacheSnapshot {
        guard let attachment = item.attachment else {
            return try snapshot(accountID: accountID, now: now)
        }

        let id = cacheEntryID(accountID: accountID, roomID: item.roomID, messageID: item.id, attachment: attachment)
        let fileURL = try dataFileURL(accountID: accountID, entryID: id)
        try encrypt(download.data).write(to: fileURL, options: .atomic)

        var index = try loadIndex(accountID: accountID)
        let entry = TrixMediaCacheEntry(
            id: id,
            roomID: normalizedCachePart(item.roomID),
            messageID: item.id,
            kind: attachment.kind,
            filename: download.filename,
            mimeType: download.mimeType,
            byteCount: Int64(download.data.count),
            createdAt: existingEntry(id: id, in: index)?.createdAt ?? now,
            lastAccessedAt: now,
            messageTimestamp: item.timestamp
        )

        if let existingIndex = index.entries.firstIndex(where: { $0.id == id }) {
            index.entries[existingIndex] = entry
        } else {
            index.entries.append(entry)
        }

        return try saveIndexApplyingRetention(index, accountID: accountID, policy: policy.sanitized, now: now)
    }

    @discardableResult
    func applyRetention(
        accountID: String,
        policy: TrixMediaCachePolicy,
        now: Date = Date()
    ) throws -> TrixMediaCacheSnapshot {
        let index = try loadIndex(accountID: accountID)
        return try saveIndexApplyingRetention(index, accountID: accountID, policy: policy.sanitized, now: now)
    }

    func snapshot(accountID: String, now: Date = Date()) throws -> TrixMediaCacheSnapshot {
        let index = try loadIndex(accountID: accountID)
        return snapshot(for: index.entries, now: now)
    }

    @discardableResult
    func clearAll(accountID: String, now: Date = Date()) throws -> TrixMediaCacheSnapshot {
        let indexURL = try indexFileURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try FileManager.default.removeItem(at: indexURL)
        }

        let dataDirectoryURL = try dataDirectoryURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: dataDirectoryURL.path) {
            try FileManager.default.removeItem(at: dataDirectoryURL)
        }

        return snapshot(for: [], now: now)
    }

    @discardableResult
    func clearRoom(
        accountID: String,
        roomID: String,
        now: Date = Date()
    ) throws -> TrixMediaCacheSnapshot {
        var index = try loadIndex(accountID: accountID)
        let normalizedRoomID = normalizedCachePart(roomID)
        let removedEntries = index.entries.filter { $0.roomID == normalizedRoomID }
        index.entries.removeAll { $0.roomID == normalizedRoomID }
        try removeDataFiles(removedEntries, accountID: accountID)
        try saveIndex(index, accountID: accountID)
        return snapshot(for: index.entries, now: now)
    }

    @discardableResult
    func clearOlderThan(
        accountID: String,
        cutoff: Date,
        now: Date = Date()
    ) throws -> TrixMediaCacheSnapshot {
        var index = try loadIndex(accountID: accountID)
        let removedEntries = index.entries.filter { $0.messageTimestamp < cutoff }
        index.entries.removeAll { $0.messageTimestamp < cutoff }
        try removeDataFiles(removedEntries, accountID: accountID)
        try saveIndex(index, accountID: accountID)
        return snapshot(for: index.entries, now: now)
    }

    private func saveIndexApplyingRetention(
        _ index: StoredIndex,
        accountID: String,
        policy: TrixMediaCachePolicy,
        now: Date
    ) throws -> TrixMediaCacheSnapshot {
        let retainedEntries = retainedEntries(from: index.entries, policy: policy, now: now)
        let removedIDs = Set(index.entries.map(\.id)).subtracting(retainedEntries.map(\.id))
        let removedEntries = index.entries.filter { removedIDs.contains($0.id) }
        try removeDataFiles(removedEntries, accountID: accountID)
        try saveIndex(StoredIndex(version: 1, entries: retainedEntries), accountID: accountID)
        return snapshot(for: retainedEntries, now: now)
    }

    private func retainedEntries(
        from entries: [TrixMediaCacheEntry],
        policy: TrixMediaCachePolicy,
        now: Date
    ) -> [TrixMediaCacheEntry] {
        var retained = entries

        if let maxAgeDays = policy.maxAgeDays {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 24 * 60 * 60)
            retained.removeAll { $0.messageTimestamp < cutoff }
        }

        if let maxMediaItemsPerRoom = policy.maxMediaItemsPerRoom {
            retained = Dictionary(grouping: retained, by: \.roomID)
                .values
                .flatMap { roomEntries in
                    roomEntries
                        .sorted { lhs, rhs in
                            if lhs.messageTimestamp != rhs.messageTimestamp {
                                return lhs.messageTimestamp > rhs.messageTimestamp
                            }
                            return lhs.lastAccessedAt > rhs.lastAccessedAt
                        }
                        .prefix(maxMediaItemsPerRoom)
                }
        }

        if let maxSizeBytes = policy.maxSizeBytes {
            var size = retained.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
            guard size > maxSizeBytes else {
                return retained
            }

            var entriesToRemove = Set<String>()
            let evictionOrder = retained.sorted { lhs, rhs in
                if lhs.lastAccessedAt != rhs.lastAccessedAt {
                    return lhs.lastAccessedAt < rhs.lastAccessedAt
                }
                return lhs.messageTimestamp < rhs.messageTimestamp
            }

            for entry in evictionOrder where size > maxSizeBytes {
                entriesToRemove.insert(entry.id)
                size -= max(0, entry.byteCount)
            }

            retained.removeAll { entriesToRemove.contains($0.id) }
        }

        return retained.sorted { lhs, rhs in
            if lhs.messageTimestamp != rhs.messageTimestamp {
                return lhs.messageTimestamp < rhs.messageTimestamp
            }
            return lhs.id < rhs.id
        }
    }

    private func snapshot(for entries: [TrixMediaCacheEntry], now: Date) -> TrixMediaCacheSnapshot {
        TrixMediaCacheSnapshot(
            entryCount: entries.count,
            totalBytes: entries.reduce(Int64(0)) { $0 + max(0, $1.byteCount) },
            oldestEntryAt: entries.map(\.messageTimestamp).min(),
            newestEntryAt: entries.map(\.messageTimestamp).max(),
            updatedAt: now
        )
    }

    private func loadIndex(accountID: String) throws -> StoredIndex {
        let fileURL = try indexFileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return StoredIndex(version: 1, entries: [])
        }

        let encryptedData = try Data(contentsOf: fileURL)
        return try decoder.decode(StoredIndex.self, from: decrypt(encryptedData))
    }

    private func saveIndex(_ index: StoredIndex, accountID: String) throws {
        try encrypt(encoder.encode(index)).write(to: indexFileURL(accountID: accountID), options: .atomic)
    }

    private func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey())
        let encrypted = EncryptedPayload(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try encoder.encode(encrypted)
    }

    private func decrypt(_ encryptedData: Data) throws -> Data {
        let encrypted = try decoder.decode(EncryptedPayload.self, from: encryptedData)
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
            throw TrixClientError.keychainFailure("stored media cache key has unexpected format")
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

    private func indexFileURL(accountID: String) throws -> URL {
        try rootDirectoryURL().appendingPathComponent("\(accountHash(accountID)).json")
    }

    private func dataFileURL(accountID: String, entryID: String) throws -> URL {
        try dataDirectoryURL(accountID: accountID).appendingPathComponent("\(entryID).bin")
    }

    private func dataDirectoryURL(accountID: String) throws -> URL {
        let directoryURL = try rootDirectoryURL()
            .appendingPathComponent(accountHash(accountID), isDirectory: true)
            .appendingPathComponent("Blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func rootDirectoryURL() throws -> URL {
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

    private func removeDataFiles(_ entries: [TrixMediaCacheEntry], accountID: String) throws {
        for entry in entries {
            let fileURL = try dataFileURL(accountID: accountID, entryID: entry.id)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func existingEntry(id: String, in index: StoredIndex) -> TrixMediaCacheEntry? {
        index.entries.first { $0.id == id }
    }

    private func cacheEntryID(
        accountID: String,
        roomID: String,
        messageID: String,
        attachment: TrixTimelineAttachment
    ) -> String {
        let rawKey = [
            normalizedCachePart(accountID),
            normalizedCachePart(roomID),
            messageID,
            attachment.kind.rawValue,
            attachment.sourceJSON ?? "",
            attachment.filename,
            attachment.mimeType ?? "",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func accountHash(_ accountID: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedCachePart(accountID).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedCachePart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func encryptionKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }
}
