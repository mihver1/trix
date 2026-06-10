import CryptoKit
import Foundation
import Martin
import Security

struct TrixOutboxMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let roomID: String
    let body: String
    let metadata: TrixTextMessageSendMetadata
    let createdAt: Date
    let attemptCount: Int
    let isFailed: Bool

    init(
        id: String = "trix-outbox-\(UUID().uuidString)",
        roomID: String,
        body: String,
        metadata: TrixTextMessageSendMetadata = .empty,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        isFailed: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.body = body
        self.metadata = metadata
        self.createdAt = createdAt
        self.attemptCount = max(attemptCount, 0)
        self.isFailed = isFailed
    }

    var sendRequest: TrixTextMessageSendRequest {
        // Reuse the queued message id as the stanza/origin id so retries are
        // idempotent for the receiving side: if the first attempt actually
        // reached the server, the resend carries the same XEP-0359 origin-id.
        TrixTextMessageSendRequest(
            text: body,
            roomID: roomID,
            metadata: metadata,
            preferredMessageID: id
        )
    }

    func echoItem(sender: String) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: roomID,
            sender: sender,
            timestamp: createdAt,
            body: body,
            isLocalEcho: true,
            attachment: nil,
            deliveryState: isFailed ? .failed : .pending,
            mentions: metadata.mentions,
            replyTo: metadata.replyTo,
            thread: metadata.thread
        )
    }

    func registeringFailedAttempt(maxAttempts: Int = TrixSendRetryPolicy.maxSendAttempts) -> TrixOutboxMessage {
        let nextAttemptCount = attemptCount + 1
        return TrixOutboxMessage(
            id: id,
            roomID: roomID,
            body: body,
            metadata: metadata,
            createdAt: createdAt,
            attemptCount: nextAttemptCount,
            isFailed: nextAttemptCount >= maxAttempts
        )
    }

    func markingFailed() -> TrixOutboxMessage {
        TrixOutboxMessage(
            id: id,
            roomID: roomID,
            body: body,
            metadata: metadata,
            createdAt: createdAt,
            attemptCount: attemptCount + 1,
            isFailed: true
        )
    }

    func resetForRetry() -> TrixOutboxMessage {
        TrixOutboxMessage(
            id: id,
            roomID: roomID,
            body: body,
            metadata: metadata,
            createdAt: createdAt,
            attemptCount: 0,
            isFailed: false
        )
    }
}

/// Classifies send failures into retryable connection-level problems (queued in
/// the outbox) and fatal ones (validation/OMEMO trust) that keep the existing
/// inline error behavior. Never queue fatal errors: retrying them cannot succeed
/// without user action.
enum TrixSendRetryPolicy {
    static let maxSendAttempts = 5

    static func isRetryableSendError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let clientError = error as? TrixClientError {
            switch clientError {
            case .xmppConnectionFailed:
                return true
            default:
                return false
            }
        }

        if let xmppError = error as? XMPPError {
            // Subset of XMPPMartinService.shouldReconnect(after:): only the
            // failures that unambiguously mean a dead or timed-out link.
            // `undefined_condition` is deliberately excluded — it is a server
            // catch-all that can also wrap permanent rejections, so it fails
            // fast (visible inline, manual Retry) instead of silently burning
            // the whole automatic attempt budget.
            switch xmppError {
            case .remote_server_timeout, .remote_server_not_found:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
    }
}

final class TrixOutboxStore: @unchecked Sendable {
    private struct StoredOutbox: Codable {
        let version: Int
        let messages: [TrixOutboxMessage]
    }

    private struct EncryptedOutbox: Codable {
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
        keychainService: String = "com.softgrid.trix.xmpp.outbox-key",
        keychainAccount: String = "outbox-key:v1",
        directoryName: String = "Outbox",
        keySource: TrixEncryptedCacheKeySource = .keychain
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryName = directoryName
        self.keySource = keySource
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    static func makeDefault(localProfile: TrixLocalProfileConfiguration? = nil) -> TrixOutboxStore {
        if let smokeStorage = TrixLiveSmokeStorageConfiguration.current() {
            let suffix = localProfile.map { "-\($0.name)" } ?? ""
            return TrixOutboxStore(
                directoryName: smokeStorage.directoryName("Outbox\(suffix)"),
                keySource: smokeStorage.cacheKeySource("outbox\(suffix)")
            )
        }

        if let localProfile {
            return TrixOutboxStore(
                keychainService: localProfile.keychainService("com.softgrid.trix.xmpp.outbox-key"),
                directoryName: localProfile.directoryName("Outbox")
            )
        }

        return TrixOutboxStore()
    }

    func load(accountJID: String) throws -> [TrixOutboxMessage] {
        let fileURL = try outboxFileURL(accountJID: accountJID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        return try decrypt(Data(contentsOf: fileURL), accountJID: accountJID)
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }

                return lhs.id < rhs.id
            }
    }

    func save(_ messages: [TrixOutboxMessage], accountJID: String) throws {
        let fileURL = try outboxFileURL(accountJID: accountJID)
        guard !messages.isEmpty else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        let data = try encoder.encode(StoredOutbox(version: 1, messages: messages))
        // The account id is bound as AAD so a file moved between per-account
        // paths cannot be decrypted under another account's name.
        let sealedBox = try AES.GCM.seal(
            data,
            using: encryptionKey(),
            authenticating: accountAAD(accountJID: accountJID)
        )
        let encrypted = EncryptedOutbox(
            version: 1,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        try encoder.encode(encrypted).write(to: fileURL, options: .atomic)
    }

    func append(_ message: TrixOutboxMessage, accountJID: String) throws {
        var messages = try load(accountJID: accountJID)
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        try save(messages, accountJID: accountJID)
    }

    func update(_ message: TrixOutboxMessage, accountJID: String) throws {
        var messages = try load(accountJID: accountJID)
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else {
            return
        }

        messages[index] = message
        try save(messages, accountJID: accountJID)
    }

    func remove(id: String, accountJID: String) throws {
        var messages = try load(accountJID: accountJID)
        let originalCount = messages.count
        messages.removeAll { $0.id == id }
        guard messages.count != originalCount else {
            return
        }

        try save(messages, accountJID: accountJID)
    }

    func clear(accountJID: String) throws {
        let fileURL = try outboxFileURL(accountJID: accountJID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func decrypt(_ encryptedData: Data, accountJID: String) throws -> [TrixOutboxMessage] {
        let encrypted = try decoder.decode(EncryptedOutbox.self, from: encryptedData)
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
        return try decoder.decode(StoredOutbox.self, from: data).messages
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
            throw TrixClientError.keychainFailure("stored outbox key has unexpected format")
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

    private func outboxFileURL(accountJID: String) throws -> URL {
        try outboxDirectoryURL().appendingPathComponent(outboxFileName(accountJID: accountJID))
    }

    private func outboxDirectoryURL() throws -> URL {
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

    private func outboxFileName(accountJID: String) -> String {
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
