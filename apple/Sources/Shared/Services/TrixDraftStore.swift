import CryptoKit
import Foundation
import Security

struct TrixComposerDraft: Codable, Equatable, Sendable {
    let text: String
    let replyTargetMessageID: String?
    let threadTargetMessageID: String?
    let updatedAt: Date

    init(
        text: String,
        replyTargetMessageID: String? = nil,
        threadTargetMessageID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.text = text
        self.replyTargetMessageID = Self.trimmedNonEmpty(replyTargetMessageID)
        self.threadTargetMessageID = Self.trimmedNonEmpty(threadTargetMessageID)
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            replyTargetMessageID == nil &&
            threadTargetMessageID == nil
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

final class TrixDraftStore: @unchecked Sendable {
    private struct StoredDrafts: Codable {
        let version: Int
        let draftsByRoomID: [String: TrixComposerDraft]
    }

    private struct EncryptedDrafts: Codable {
        let version: Int
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private let keychainService: String
    private let keychainAccount: String
    private let directoryName: String
    private let keySource: TrixEncryptedCacheKeySource
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEncryptionKey: SymmetricKey?

    init(
        keychainService: String = "com.softgrid.trix.xmpp.composer-draft-key",
        keychainAccount: String = "composer-draft-key:v1",
        directoryName: String = "ComposerDrafts",
        keySource: TrixEncryptedCacheKeySource = .keychain
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        self.keySource = keySource
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    static func makeDefault(localProfile: TrixLocalProfileConfiguration? = nil) -> TrixDraftStore {
        if let smokeStorage = TrixLiveSmokeStorageConfiguration.current() {
            let suffix = localProfile.map { "-\($0.name)" } ?? ""
            return TrixDraftStore(
                directoryName: smokeStorage.directoryName("ComposerDrafts\(suffix)"),
                keySource: smokeStorage.cacheKeySource("composer-drafts\(suffix)")
            )
        }

        if let localProfile {
            return TrixDraftStore(
                keychainService: localProfile.keychainService("com.softgrid.trix.xmpp.composer-draft-key"),
                directoryName: localProfile.directoryName("ComposerDrafts")
            )
        }

        return TrixDraftStore()
    }

    func load(accountJID: String) throws -> [String: TrixComposerDraft] {
        let fileURL = try draftsFileURL(accountJID: accountJID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        return try decrypt(Data(contentsOf: fileURL), accountJID: accountJID)
    }

    func save(_ draftsByRoomID: [String: TrixComposerDraft], accountJID: String) throws {
        let fileURL = try draftsFileURL(accountJID: accountJID)
        let normalizedDrafts = draftsByRoomID.reduce(into: [String: TrixComposerDraft]()) { partialResult, pair in
            let roomID = normalizedCachePart(pair.key)
            guard !roomID.isEmpty, !pair.value.isEmpty else {
                return
            }

            partialResult[roomID] = pair.value
        }
        guard !normalizedDrafts.isEmpty else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        let data = try encoder.encode(StoredDrafts(version: 1, draftsByRoomID: normalizedDrafts))
        // The account id is bound as AAD so a file moved between per-account
        // paths cannot be decrypted under another account's name.
        let sealedBox = try AES.GCM.seal(
            data,
            using: encryptionKey(),
            authenticating: accountAAD(accountJID: accountJID)
        )
        let encrypted = EncryptedDrafts(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        try encoder.encode(encrypted).write(to: fileURL, options: .atomic)
    }

    func draft(accountJID: String, roomID: String) throws -> TrixComposerDraft? {
        try load(accountJID: accountJID)[normalizedCachePart(roomID)]
    }

    func setDraft(_ draft: TrixComposerDraft, accountJID: String, roomID: String) throws {
        var drafts = try load(accountJID: accountJID)
        drafts[normalizedCachePart(roomID)] = draft
        try save(drafts, accountJID: accountJID)
    }

    func clearDraft(accountJID: String, roomID: String) throws {
        var drafts = try load(accountJID: accountJID)
        guard drafts.removeValue(forKey: normalizedCachePart(roomID)) != nil else {
            return
        }

        try save(drafts, accountJID: accountJID)
    }

    func clear(accountJID: String) throws {
        let fileURL = try draftsFileURL(accountJID: accountJID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func decrypt(_ encryptedData: Data, accountJID: String) throws -> [String: TrixComposerDraft] {
        let encrypted = try decoder.decode(EncryptedDrafts.self, from: encryptedData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encrypted.nonce),
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
        let data = try AES.GCM.open(
            sealedBox,
            using: encryptionKey(),
            authenticating: accountAAD(accountJID: accountJID)
        )
        return try decoder.decode(StoredDrafts.self, from: data).draftsByRoomID
    }

    private func accountAAD(accountJID: String) -> Data {
        Data(normalizedCachePart(accountJID).utf8)
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
            throw TrixClientError.keychainFailure("stored composer draft key has unexpected format")
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

    private func draftsFileURL(accountJID: String) throws -> URL {
        try draftsDirectoryURL().appendingPathComponent(draftsFileName(accountJID: accountJID))
    }

    private func draftsDirectoryURL() throws -> URL {
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

    private func draftsFileName(accountJID: String) -> String {
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
