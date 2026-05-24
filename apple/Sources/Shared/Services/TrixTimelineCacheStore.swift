import CryptoKit
import Foundation
import Security

enum TrixEncryptedCacheKeySource: Sendable {
    case keychain
    case memory(Data)
}

struct TrixLiveSmokeStorageConfiguration: Sendable {
    static let modeEnvironmentKey = "TRIX_XMPP_LIVE_SMOKE_MODE"
    static let useKeychainEnvironmentKey = "TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN"

    private static let processRunIdentifier = UUID().uuidString.lowercased()

    let runIdentifier: String

    static func usesVolatileStorage(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let mode = environment[modeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mode.isEmpty else {
            return false
        }

        return environment[useKeychainEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runIdentifier: String = processRunIdentifier
    ) -> TrixLiveSmokeStorageConfiguration? {
        guard usesVolatileStorage(environment: environment) else {
            return nil
        }

        return TrixLiveSmokeStorageConfiguration(runIdentifier: sanitizedIdentifier(runIdentifier))
    }

    func cacheKeySource(_ name: String) -> TrixEncryptedCacheKeySource {
        let keyMaterial = "trix-live-smoke-cache:\(runIdentifier):\(name)"
        return .memory(Data(SHA256.hash(data: Data(keyMaterial.utf8))))
    }

    func directoryName(_ base: String) -> String {
        "\(base)-LiveSmoke-\(runIdentifier)"
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        TrixLocalProfileConfiguration(rawName: value)?.name ?? "volatile"
    }
}

final class TrixTimelineCacheStore: @unchecked Sendable {
    private struct CachedTimeline: Codable {
        let version: Int
        let items: [TrixTimelineItem]
    }

    private struct EncryptedTimeline: Codable {
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
        legacyService: String = "com.softgrid.trix.xmpp.timeline",
        keychainService: String = "com.softgrid.trix.xmpp.timeline-cache-key",
        keychainAccount: String = "timeline-cache-key:v1",
        directoryName: String = "TimelineCache",
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
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountJID: String, roomID: String) throws -> [TrixTimelineItem] {
        let fileURL = try cacheFileURL(accountJID: accountJID, roomID: roomID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let encryptedData = try Data(contentsOf: fileURL)
            return try decrypt(encryptedData)
        }

        let legacyItems = try loadLegacyItems(accountJID: accountJID, roomID: roomID)
        guard !legacyItems.isEmpty else {
            return legacyItems
        }

        do {
            try saveEncrypted(legacyItems, to: fileURL)
            try? clearLegacyItems(accountJID: accountJID, roomID: roomID)
        } catch {
            // Keep the legacy Keychain blob until file migration has succeeded.
        }
        return legacyItems
    }

    func save(_ items: [TrixTimelineItem], accountJID: String, roomID: String) throws {
        try saveEncrypted(items, to: cacheFileURL(accountJID: accountJID, roomID: roomID))
    }

    func clear(accountJID: String, roomID: String) throws {
        let fileURL = try cacheFileURL(accountJID: accountJID, roomID: roomID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try clearLegacyItems(accountJID: accountJID, roomID: roomID)
    }

    private func saveEncrypted(_ items: [TrixTimelineItem], to fileURL: URL) throws {
        let data = try encoder.encode(CachedTimeline(version: 1, items: items))
        let key = try encryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        let encrypted = EncryptedTimeline(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        let encryptedData = try encoder.encode(encrypted)
        try encryptedData.write(to: fileURL, options: .atomic)
    }

    private func decrypt(_ encryptedData: Data) throws -> [TrixTimelineItem] {
        let encrypted = try decoder.decode(EncryptedTimeline.self, from: encryptedData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: encrypted.nonce),
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
        let data = try AES.GCM.open(sealedBox, using: encryptionKey())
        return try decoder.decode(CachedTimeline.self, from: data).items
    }

    private func loadLegacyItems(accountJID: String, roomID: String) throws -> [TrixTimelineItem] {
        guard let data = try loadLegacyData(accountJID: accountJID, roomID: roomID) else {
            return []
        }

        return try decoder.decode(CachedTimeline.self, from: data).items
    }

    private func loadLegacyData(accountJID: String, roomID: String) throws -> Data? {
        guard migratesLegacyKeychainItems else {
            return nil
        }

        var query = legacyTimelineQuery(accountJID: accountJID, roomID: roomID)
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
            throw TrixClientError.keychainFailure("stored timeline has unexpected format")
        }

        return data
    }

    private func clearLegacyItems(accountJID: String, roomID: String) throws {
        guard migratesLegacyKeychainItems else {
            return
        }

        let status = SecItemDelete(legacyTimelineQuery(accountJID: accountJID, roomID: roomID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrixClientError.keychainFailure(status.description)
        }
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
            throw TrixClientError.keychainFailure("stored timeline cache key has unexpected format")
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

    private func legacyTimelineQuery(accountJID: String, roomID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyTimelineAccount(accountJID: accountJID, roomID: roomID),
        ]
    }

    private func encryptionKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func legacyTimelineAccount(accountJID: String, roomID: String) -> String {
        let account = normalizedCachePart(accountJID)
        let room = normalizedCachePart(roomID)
        return "timeline:\(account)|\(room)"
    }

    private func normalizedCachePart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
