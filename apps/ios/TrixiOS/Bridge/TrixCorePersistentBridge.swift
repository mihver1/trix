import Foundation

enum ChatHistorySource {
    case server
    case localStore
}

struct LocalChatCursorSnapshot: Identifiable {
    let chatId: String
    let lastServerSeq: UInt64

    var id: String { chatId }
}

struct LocalChatReadStateSnapshot: Identifiable {
    let chatId: String
    let readCursorServerSeq: UInt64
    let unreadCount: UInt64

    var id: String { chatId }
}

struct LocalChatListItemSnapshot: Identifiable {
    let chatId: String
    let chatType: ChatType
    let title: String?
    let displayTitle: String
    let lastServerSeq: UInt64
    let pendingMessageCount: UInt64
    let unreadCount: UInt64
    let previewText: String?
    let previewSenderAccountId: String?
    let previewSenderDisplayName: String?
    let previewIsOutgoing: Bool?
    let previewServerSeq: UInt64?
    let previewCreatedAtUnix: UInt64?
    let participantProfiles: [ChatParticipantProfileSummary]

    var id: String { chatId }

    var previewDate: Date? {
        previewCreatedAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

enum LocalProjectionKindSnapshot {
    case applicationMessage
    case proposalQueued
    case commitMerged
    case welcomeRef
    case system
}

struct LocalTimelineItemSnapshot: Identifiable {
    let serverSeq: UInt64
    let messageId: String
    let senderAccountId: String
    let senderDeviceId: String
    let senderDisplayName: String
    let isOutgoing: Bool
    let epoch: UInt64
    let messageKind: MessageKind
    let contentType: ContentType
    let projectionKind: LocalProjectionKindSnapshot
    let previewText: String
    let bodyPreview: MessageBodyPreview?
    let bodyParseError: String?
    let mergedEpoch: UInt64?
    let createdAtUnix: UInt64

    var id: String { messageId }

    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
    }
}

struct LocalStoreSyncResult {
    let chatsUpserted: UInt64
    let messagesUpserted: UInt64
    let changedChatIds: [String]
}

struct LocalInboxSyncResult {
    let leaseOwner: String
    let leaseExpiresAtUnix: UInt64
    let ackedInboxIds: [UInt64]
    let report: LocalStoreSyncResult

    var leaseExpiresAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(leaseExpiresAtUnix))
    }
}

struct LocalCoreStateSnapshot {
    let mlsStorageRoot: String
    let historyDatabasePath: String
    let syncStatePath: String
    let ciphersuiteLabel: String
    let leaseOwner: String
    let lastAckedInboxId: UInt64?
    let localChats: [ChatSummary]
    let localChatListItems: [LocalChatListItemSnapshot]
    let chatCursors: [LocalChatCursorSnapshot]
    let chatReadStates: [LocalChatReadStateSnapshot]

    func chatListItem(for chatId: String) -> LocalChatListItemSnapshot? {
        localChatListItems.first { $0.chatId == chatId }
    }

    func chatReadState(for chatId: String) -> LocalChatReadStateSnapshot? {
        chatReadStates.first { $0.chatId == chatId }
    }
}

enum TrixCorePersistentBridge {
    static func publishKeyPackages(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        count: Int
    ) throws -> PublishKeyPackagesResponse {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let cipherSuite = try context.mlsFacade.ciphersuiteLabel()
        let keyPackages = try context.mlsFacade.generateKeyPackages(count: UInt32(count))
        let response = try client.publishKeyPackages(
            packages: keyPackages.map {
                FfiPublishKeyPackage(
                    cipherSuite: cipherSuite,
                    keyPackage: $0
                )
            }
        )
        try context.mlsFacade.saveState()
        return response.trix_publishKeyPackagesResponse
    }

    static func syncChatHistoriesIntoStore(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        limitPerChat: Int
    ) throws -> LocalStoreSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let report = try context.syncCoordinator.syncChatHistoriesIntoStore(
            client: client,
            store: context.historyStore,
            limitPerChat: UInt32(limitPerChat)
        )
        return report.trix_localStoreSyncResult
    }

    static func leaseInboxIntoStore(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        limit: Int?,
        leaseTtlSeconds: UInt64?
    ) throws -> LocalInboxSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let outcome = try context.syncCoordinator.leaseInboxIntoStore(
            client: client,
            store: context.historyStore,
            limit: limit.map(UInt32.init),
            leaseTtlSeconds: leaseTtlSeconds
        )
        return outcome.trix_localInboxSyncResult
    }

    static func localStateSnapshot(identity: LocalDeviceIdentity) throws -> LocalCoreStateSnapshot {
        let context = try loadOrCreateContext(identity: identity)
        let syncState = try context.syncCoordinator.stateSnapshot()
        let chats = try context.historyStore.listChats()
            .map(\.trix_chatSummary)
        let localChatListItems = try context.historyStore
            .listLocalChatListItems(selfAccountId: identity.accountId)
            .map(\.trix_localChatListItemSnapshot)
        let chatCursors = syncState.chatCursors
            .map(\.trix_localChatCursorSnapshot)
            .sorted { left, right in
                right.lastServerSeq < left.lastServerSeq
            }
        let chatReadStates = try context.historyStore
            .listChatReadStates(selfAccountId: identity.accountId)
            .map(\.trix_localChatReadStateSnapshot)
            .sorted { left, right in
                if left.unreadCount == right.unreadCount {
                    return left.chatId < right.chatId
                }
                return left.unreadCount > right.unreadCount
            }

        return LocalCoreStateSnapshot(
            mlsStorageRoot: try context.mlsFacade.storageRoot() ?? context.paths.mlsStorageRoot.path,
            historyDatabasePath: try context.historyStore.databasePath() ?? context.paths.historyDatabasePath.path,
            syncStatePath: try context.syncCoordinator.statePath() ?? context.paths.syncStatePath.path,
            ciphersuiteLabel: try context.mlsFacade.ciphersuiteLabel(),
            leaseOwner: syncState.leaseOwner,
            lastAckedInboxId: syncState.lastAckedInboxId,
            localChats: chats,
            localChatListItems: localChatListItems,
            chatCursors: chatCursors,
            chatReadStates: chatReadStates
        )
    }

    static func markChatRead(
        identity: LocalDeviceIdentity,
        chatId: String,
        throughServerSeq: UInt64?
    ) throws -> LocalChatReadStateSnapshot {
        let context = try loadOrCreateContext(identity: identity)
        return try context.historyStore
            .markChatRead(
                chatId: chatId,
                throughServerSeq: throughServerSeq,
                selfAccountId: identity.accountId
            )
            .trix_localChatReadStateSnapshot
    }

    static func loadLocalTimeline(
        identity: LocalDeviceIdentity,
        chatId: String,
        limit: Int = 150
    ) throws -> [LocalTimelineItemSnapshot] {
        let paths = try PersistentCorePaths(identity: identity)
        guard FileManager.default.fileExists(atPath: paths.historyDatabasePath.path) else {
            return []
        }

        let store = try FfiLocalHistoryStore.newPersistent(databasePath: paths.historyDatabasePath.path)
        return try store.getLocalTimelineItems(
            chatId: chatId,
            selfAccountId: identity.accountId,
            afterServerSeq: nil,
            limit: UInt32(min(max(limit, 1), 500))
        )
        .map(\.trix_localTimelineItemSnapshot)
    }

    static func loadLocalChatHistory(
        identity: LocalDeviceIdentity,
        chatId: String,
        limit: Int = 100
    ) throws -> ChatHistoryResponse? {
        let paths = try PersistentCorePaths(identity: identity)
        guard FileManager.default.fileExists(atPath: paths.historyDatabasePath.path) else {
            return nil
        }

        let store = try FfiLocalHistoryStore.newPersistent(databasePath: paths.historyDatabasePath.path)
        let history = try store.getChatHistory(
            chatId: chatId,
            afterServerSeq: nil,
            limit: UInt32(min(max(limit, 1), 500))
        )
        guard !history.messages.isEmpty else {
            return nil
        }

        return history.trix_chatHistoryResponse
    }

    static func deletePersistentState(identity: LocalDeviceIdentity) throws {
        let paths = try PersistentCorePaths(identity: identity)
        guard FileManager.default.fileExists(atPath: paths.rootDirectory.path) else {
            return
        }

        try FileManager.default.removeItem(at: paths.rootDirectory)
    }

    private static func loadOrCreateContext(identity: LocalDeviceIdentity) throws -> PersistentCoreContext {
        let paths = try PersistentCorePaths(identity: identity)
        try paths.prepareRootDirectory()

        let mlsFacade: FfiMlsFacade
        if FileManager.default.fileExists(atPath: paths.mlsStorageRoot.path) {
            mlsFacade = try FfiMlsFacade.loadPersistent(storageRoot: paths.mlsStorageRoot.path)
        } else {
            mlsFacade = try FfiMlsFacade.newPersistent(
                credentialIdentity: identity.credentialIdentity,
                storageRoot: paths.mlsStorageRoot.path
            )
        }

        let persistedCredentialIdentity = try mlsFacade.credentialIdentity()
        guard persistedCredentialIdentity == identity.credentialIdentity else {
            throw TrixCorePersistentBridgeError.credentialIdentityMismatch
        }

        let historyStore = try FfiLocalHistoryStore.newPersistent(
            databasePath: paths.historyDatabasePath.path
        )
        let syncCoordinator = try FfiSyncCoordinator.newPersistent(
            statePath: paths.syncStatePath.path
        )

        return PersistentCoreContext(
            paths: paths,
            mlsFacade: mlsFacade,
            historyStore: historyStore,
            syncCoordinator: syncCoordinator
        )
    }

    private static func makeClient(
        baseURLString: String,
        accessToken: String
    ) throws -> FfiServerApiClient {
        let client = try FfiServerApiClient(
            baseUrl: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try client.setAccessToken(accessToken: accessToken)
        return client
    }
}

private struct PersistentCoreContext {
    let paths: PersistentCorePaths
    let mlsFacade: FfiMlsFacade
    let historyStore: FfiLocalHistoryStore
    let syncCoordinator: FfiSyncCoordinator
}

private struct PersistentCorePaths {
    let rootDirectory: URL
    let mlsStorageRoot: URL
    let historyDatabasePath: URL
    let syncStatePath: URL

    init(identity: LocalDeviceIdentity) throws {
        let appSupportRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootDirectory = appSupportRoot
            .appendingPathComponent("TrixiOS", isDirectory: true)
            .appendingPathComponent("CoreState", isDirectory: true)
            .appendingPathComponent(identity.accountId, isDirectory: true)
            .appendingPathComponent(identity.deviceId, isDirectory: true)

        self.rootDirectory = rootDirectory
        mlsStorageRoot = rootDirectory.appendingPathComponent("mls", isDirectory: true)
        historyDatabasePath = rootDirectory.appendingPathComponent("history-store.json")
        syncStatePath = rootDirectory.appendingPathComponent("sync-state.json")
    }

    func prepareRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
    }
}

private enum TrixCorePersistentBridgeError: LocalizedError {
    case credentialIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .credentialIdentityMismatch:
            return "Persisted trix-core state does not match the current device credential identity."
        }
    }
}

private extension FfiPublishKeyPackagesResponse {
    var trix_publishKeyPackagesResponse: PublishKeyPackagesResponse {
        PublishKeyPackagesResponse(
            deviceId: deviceId,
            packages: packages.map(\.trix_publishedKeyPackage)
        )
    }
}

private extension FfiPublishedKeyPackage {
    var trix_publishedKeyPackage: PublishedKeyPackage {
        PublishedKeyPackage(
            keyPackageId: keyPackageId,
            cipherSuite: cipherSuite
        )
    }
}

private extension FfiLocalStoreApplyReport {
    var trix_localStoreSyncResult: LocalStoreSyncResult {
        LocalStoreSyncResult(
            chatsUpserted: chatsUpserted,
            messagesUpserted: messagesUpserted,
            changedChatIds: changedChatIds
        )
    }
}

private extension FfiInboxApplyOutcome {
    var trix_localInboxSyncResult: LocalInboxSyncResult {
        LocalInboxSyncResult(
            leaseOwner: leaseOwner,
            leaseExpiresAtUnix: leaseExpiresAtUnix,
            ackedInboxIds: ackedInboxIds,
            report: report.trix_localStoreSyncResult
        )
    }
}

private extension FfiSyncChatCursor {
    var trix_localChatCursorSnapshot: LocalChatCursorSnapshot {
        LocalChatCursorSnapshot(
            chatId: chatId,
            lastServerSeq: lastServerSeq
        )
    }
}

private extension FfiLocalChatReadState {
    var trix_localChatReadStateSnapshot: LocalChatReadStateSnapshot {
        LocalChatReadStateSnapshot(
            chatId: chatId,
            readCursorServerSeq: readCursorServerSeq,
            unreadCount: unreadCount
        )
    }
}

private extension FfiLocalChatListItem {
    var trix_localChatListItemSnapshot: LocalChatListItemSnapshot {
        LocalChatListItemSnapshot(
            chatId: chatId,
            chatType: chatType.trix_chatType,
            title: title,
            displayTitle: displayTitle,
            lastServerSeq: lastServerSeq,
            pendingMessageCount: pendingMessageCount,
            unreadCount: unreadCount,
            previewText: previewText,
            previewSenderAccountId: previewSenderAccountId,
            previewSenderDisplayName: previewSenderDisplayName,
            previewIsOutgoing: previewIsOutgoing,
            previewServerSeq: previewServerSeq,
            previewCreatedAtUnix: previewCreatedAtUnix,
            participantProfiles: participantProfiles.map(\.trix_chatParticipantProfileSummary)
        )
    }
}

private extension FfiLocalTimelineItem {
    var trix_localTimelineItemSnapshot: LocalTimelineItemSnapshot {
        LocalTimelineItemSnapshot(
            serverSeq: serverSeq,
            messageId: messageId,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            senderDisplayName: senderDisplayName,
            isOutgoing: isOutgoing,
            epoch: epoch,
            messageKind: messageKind.trix_messageKind,
            contentType: contentType.trix_contentType,
            projectionKind: projectionKind.trix_localProjectionKindSnapshot,
            previewText: previewText,
            bodyPreview: body?.trix_messageBodyPreview,
            bodyParseError: bodyParseError,
            mergedEpoch: mergedEpoch,
            createdAtUnix: createdAtUnix
        )
    }
}

private extension FfiChatHistory {
    var trix_chatHistoryResponse: ChatHistoryResponse {
        ChatHistoryResponse(
            chatId: chatId,
            messages: messages.map(\.trix_messageEnvelope)
        )
    }
}

private extension FfiChatSummary {
    var trix_chatSummary: ChatSummary {
        ChatSummary(
            chatId: chatId,
            chatType: chatType.trix_chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            pendingMessageCount: pendingMessageCount,
            lastMessage: lastMessage?.trix_messageEnvelope,
            participantProfiles: participantProfiles.map(\.trix_chatParticipantProfileSummary)
        )
    }
}

private extension FfiChatParticipantProfile {
    var trix_chatParticipantProfileSummary: ChatParticipantProfileSummary {
        ChatParticipantProfileSummary(
            accountId: accountId,
            handle: handle,
            profileName: profileName,
            profileBio: profileBio
        )
    }
}

private extension FfiMessageEnvelope {
    var trix_messageEnvelope: MessageEnvelope {
        MessageEnvelope(
            messageId: messageId,
            chatId: chatId,
            serverSeq: serverSeq,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            epoch: epoch,
            messageKind: messageKind.trix_messageKind,
            contentType: contentType.trix_contentType,
            ciphertextB64: ciphertext.base64EncodedString(),
            aadJson: aadJson.trix_jsonValue,
            createdAtUnix: createdAtUnix
        )
    }
}

private extension FfiChatType {
    var trix_chatType: ChatType {
        switch self {
        case .dm:
            return .dm
        case .group:
            return .group
        case .accountSync:
            return .accountSync
        }
    }
}

private extension FfiMessageKind {
    var trix_messageKind: MessageKind {
        switch self {
        case .application:
            return .application
        case .commit:
            return .commit
        case .welcomeRef:
            return .welcomeRef
        case .system:
            return .system
        }
    }
}

private extension FfiContentType {
    var trix_contentType: ContentType {
        switch self {
        case .text:
            return .text
        case .reaction:
            return .reaction
        case .receipt:
            return .receipt
        case .attachment:
            return .attachment
        case .chatEvent:
            return .chatEvent
        }
    }
}

private extension FfiLocalProjectionKind {
    var trix_localProjectionKindSnapshot: LocalProjectionKindSnapshot {
        switch self {
        case .applicationMessage:
            return .applicationMessage
        case .proposalQueued:
            return .proposalQueued
        case .commitMerged:
            return .commitMerged
        case .welcomeRef:
            return .welcomeRef
        case .system:
            return .system
        }
    }
}

private extension FfiMessageBody {
    var trix_messageBodyPreview: MessageBodyPreview {
        switch kind {
        case .text:
            return MessageBodyPreview(
                title: text ?? "(empty text)",
                detail: nil
            )
        case .reaction:
            let actionLabel = reactionAction == .remove ? "Removed" : "Reacted"
            return MessageBodyPreview(
                title: "\(actionLabel) \(emoji ?? "")",
                detail: targetMessageId.map { "Target \($0)" }
            )
        case .receipt:
            let receiptLabel = receiptType == .read ? "Read receipt" : "Delivered receipt"
            return MessageBodyPreview(
                title: receiptLabel,
                detail: targetMessageId.map { "Target \($0)" }
            )
        case .attachment:
            let attachmentName = fileName ?? blobId ?? "Attachment"
            let mimeDescription = mimeType ?? "binary/octet-stream"
            return MessageBodyPreview(
                title: attachmentName,
                detail: "\(mimeDescription), \(sizeBytes ?? 0) bytes"
            )
        case .chatEvent:
            return MessageBodyPreview(
                title: eventType ?? "Chat event",
                detail: eventJson
            )
        }
    }
}

private extension String {
    var trix_jsonValue: JSONValue {
        guard let data = data(using: .utf8) else {
            return .string(self)
        }

        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(self)
    }
}
