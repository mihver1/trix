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
    let epoch: UInt64
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
    let messageBody: FfiMessageBody?
    let previewText: String
    let bodyPreview: MessageBodyPreview?
    let bodyParseError: String?
    let receiptStatus: SafeMessengerReceiptType?
    let reactions: [SafeMessengerReactionSummary]
    let isVisibleInTimeline: Bool
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

struct LocalInboxAckResult {
    let ackedInboxIds: [UInt64]
}

struct PersistentRealtimeBindings {
    let websocket: FfiServerWebSocketClient
    let realtimeDriver: FfiRealtimeDriver
    let historyStore: FfiLocalHistoryStore
    let syncCoordinator: FfiSyncCoordinator
}

struct PreparedLinkedDeviceState {
    let provisionalIdentity: LocalDeviceIdentity
    let keyPackages: [FfiPublishKeyPackage]
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

private struct DeviceDatabaseKeyStore {
    private let keychain = KeychainStore()

    func getOrCreate(account: String) throws -> Data {
        if let existing = try keychain.load(account: account) {
            return existing
        }

        let generated = try Data.trix_random(count: 32)
        try keychain.save(generated, account: account)
        return generated
    }

    func clear(account: String) throws {
        try keychain.delete(account: account)
    }

    func relocate(from sourceAccount: String, to destinationAccount: String) throws {
        guard sourceAccount != destinationAccount else {
            return
        }
        guard let existing = try keychain.load(account: sourceAccount) else {
            return
        }

        try keychain.save(existing, account: destinationAccount)
        try keychain.delete(account: sourceAccount)
    }
}

enum TrixCorePersistentBridge {
    private static let realtimeConfig = FfiRealtimeConfig(
        inboxLimit: 100,
        inboxLeaseTtlSeconds: 30,
        pollIntervalMs: 750,
        websocketRetryDelayMs: 3_000
    )
    // FfiMessengerClient opens independent runtimes/coordinators over the same persisted state.
    // Serialize access so snapshot refresh, realtime polling, and device mutations cannot race
    // each other while draining history sync jobs.
    private static let messengerClientLock = NSLock()

    static func loadMessengerSnapshot(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) throws -> SafeMessengerSnapshot {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            try client.loadSnapshot().trix_safeMessengerSnapshot
        }
    }

    static func syncPendingHistoryRepairs(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatIds: [String]?
    ) async throws -> [String] {
        let uniqueChatIds = chatIds
            .map { Array(Set($0)).sorted() }
            .flatMap { $0.isEmpty ? nil : $0 }

        return try await Task.detached(priority: .utility) {
            let client = try openMessengerClient(
                baseURLString: baseURLString,
                accessToken: accessToken,
                identity: identity
            )
            return try client.syncPendingHistoryRepairs(conversationIds: uniqueChatIds)
        }.value
    }

    static func loadConversationSnapshot(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        messageLimit: Int = 150
    ) throws -> SafeConversationSnapshot {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let snapshot = try client.loadSnapshot()
            let conversation = snapshot.conversations.first { $0.conversationId == chatId }
            let detail = conversation?.trix_chatDetailResponse
                ?? ChatDetailResponse(
                    chatId: chatId,
                    chatType: .dm,
                    title: nil,
                    lastServerSeq: 0,
                    pendingMessageCount: 0,
                    epoch: 0,
                    lastCommitMessageId: nil,
                    lastMessage: nil,
                    participantProfiles: [],
                    members: [],
                    deviceMembers: []
                )
            let totalLimit = max(messageLimit, 1)
            var pageCursor: String?
            var allMessages: [FfiMessengerMessageRecord] = []
            var seenMessageIDs = Set<String>()

            while allMessages.count < totalLimit {
                let pageLimit = UInt32(min(max(totalLimit - allMessages.count, 1), 500))
                let messagesCountBeforePage = allMessages.count
                let page = try client.getMessages(
                    conversationId: chatId,
                    pageCursor: pageCursor,
                    limit: pageLimit
                )
                guard !page.messages.isEmpty else {
                    break
                }
                for message in page.messages where seenMessageIDs.insert(message.messageId).inserted {
                    allMessages.append(message)
                    if allMessages.count >= totalLimit {
                        break
                    }
                }
                guard allMessages.count > messagesCountBeforePage else {
                    break
                }
                guard let nextCursor = page.nextCursor,
                      allMessages.count < totalLimit
                else {
                    break
                }
                pageCursor = nextCursor
            }

            allMessages.sort { lhs, rhs in
                if lhs.serverSeq == rhs.serverSeq {
                    return lhs.createdAtUnix < rhs.createdAtUnix
                }
                return lhs.serverSeq < rhs.serverSeq
            }
            return SafeConversationSnapshot(
                detail: detail,
                messages: allMessages.map(\.trix_safeMessengerMessage),
                nextCursor: nil
            )
        }
    }

    static func getNewMessengerEvents(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        checkpoint: String?
    ) throws -> SafeMessengerEventBatch {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            try client.getNewEvents(checkpoint: checkpoint).trix_safeMessengerEventBatch
        }
    }

    static func sendMessage(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        draft: DebugMessageDraft
    ) async throws -> CreateMessageResponse {
        try await withMessengerClientAsync(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let response = try client.sendMessage(
                request: try draft.trix_safeSendMessageRequest(chatId: chatId)
            )
            return response.trix_createMessageResponse
        }
    }

    static func sendMessage(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        draft: DebugMessageDraft
    ) throws -> CreateMessageResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let response = try client.sendMessage(
                request: try draft.trix_safeSendMessageRequest(chatId: chatId)
            )
            return response.trix_createMessageResponse
        }
    }

    static func sendAttachment(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        fileURL: URL
    ) async throws -> DebugAttachmentSendOutcome {
        try await withMessengerClientAsync(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let attachmentUpload = try TrixCoreMessageBridge.readAttachmentUploadMaterial(fileURL: fileURL)
            let token = try client.sendAttachment(
                conversationId: chatId,
                payload: attachmentUpload.payload,
                metadata: FfiMessengerAttachmentMetadata(
                    mimeType: attachmentUpload.params.mimeType,
                    fileName: attachmentUpload.params.fileName,
                    widthPx: attachmentUpload.params.widthPx,
                    heightPx: attachmentUpload.params.heightPx
                )
            )
            let messageId = UUID().uuidString.lowercased()
            let response = try client.sendMessage(
                request: FfiMessengerSendMessageRequest(
                    conversationId: chatId,
                    messageId: messageId,
                    kind: .attachment,
                    text: nil,
                    targetMessageId: nil,
                    emoji: nil,
                    reactionAction: nil,
                    receiptType: nil,
                    receiptAtUnix: nil,
                    eventType: nil,
                    eventJson: nil,
                    attachmentTokens: [token.token]
                )
            )

            return DebugAttachmentSendOutcome(
                createMessage: response.trix_createMessageResponse,
                attachmentRef: response.message.body?.attachment?.attachmentRef,
                fileName: response.message.body?.attachment?.fileName ?? attachmentUpload.params.fileName
            )
        }
    }

    static func sendAttachment(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        fileURL: URL
    ) throws -> DebugAttachmentSendOutcome {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let attachmentUpload = try TrixCoreMessageBridge.readAttachmentUploadMaterial(fileURL: fileURL)
            let token = try client.sendAttachment(
                conversationId: chatId,
                payload: attachmentUpload.payload,
                metadata: FfiMessengerAttachmentMetadata(
                    mimeType: attachmentUpload.params.mimeType,
                    fileName: attachmentUpload.params.fileName,
                    widthPx: attachmentUpload.params.widthPx,
                    heightPx: attachmentUpload.params.heightPx
                )
            )
            let messageId = UUID().uuidString.lowercased()
            let response = try client.sendMessage(
                request: FfiMessengerSendMessageRequest(
                    conversationId: chatId,
                    messageId: messageId,
                    kind: .attachment,
                    text: nil,
                    targetMessageId: nil,
                    emoji: nil,
                    reactionAction: nil,
                    receiptType: nil,
                    receiptAtUnix: nil,
                    eventType: nil,
                    eventJson: nil,
                    attachmentTokens: [token.token]
                )
            )

            return DebugAttachmentSendOutcome(
                createMessage: response.trix_createMessageResponse,
                attachmentRef: response.message.body?.attachment?.attachmentRef,
                fileName: response.message.body?.attachment?.fileName ?? attachmentUpload.params.fileName
            )
        }
    }

    static func getAttachment(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        attachment: SafeMessengerAttachment
    ) async throws -> DownloadedAttachmentFile {
        try await withMessengerClientAsync(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let file = try client.getAttachment(attachmentRef: attachment.attachmentRef)
            let fileURL = URL(fileURLWithPath: file.localPath)
            return DownloadedAttachmentFile(
                fileURL: fileURL,
                fileName: file.fileName ?? fileURL.lastPathComponent,
                mimeType: file.mimeType
            )
        }
    }

    static func getAttachment(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        attachment: SafeMessengerAttachment
    ) throws -> DownloadedAttachmentFile {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let file = try client.getAttachment(attachmentRef: attachment.attachmentRef)
            let fileURL = URL(fileURLWithPath: file.localPath)
            return DownloadedAttachmentFile(
                fileURL: fileURL,
                fileName: file.fileName ?? fileURL.lastPathComponent,
                mimeType: file.mimeType
            )
        }
    }

    static func createConversation(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatType: ChatType,
        title: String?,
        participantAccountIds: [String]
    ) throws -> CreateChatResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let result = try client.createConversation(
                request: FfiMessengerCreateConversationRequest(
                    conversationType: chatType.trix_ffiChatType,
                    title: title?.trix_trimmedOrNil(),
                    participantAccountIds: participantAccountIds
                )
            )
            let conversation = result.conversation
            return CreateChatResponse(
                chatId: result.conversationId,
                chatType: conversation?.conversationType.trix_chatType ?? chatType,
                epoch: conversation?.epoch ?? 0
            )
        }
    }

    static func addConversationMembers(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        participantAccountIds: [String]
    ) throws -> ModifyChatMembersResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let result = try client.updateConversationMembers(
                request: FfiMessengerUpdateConversationMembersRequest(
                    conversationId: chatId,
                    participantAccountIds: participantAccountIds
                )
            )
            return ModifyChatMembersResponse(
                chatId: result.conversationId,
                epoch: result.conversation?.epoch ?? 0,
                changedAccountIds: result.changedAccountIds
            )
        }
    }

    static func removeConversationMembers(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        participantAccountIds: [String]
    ) throws -> ModifyChatMembersResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let result = try client.removeConversationMembers(
                request: FfiMessengerUpdateConversationMembersRequest(
                    conversationId: chatId,
                    participantAccountIds: participantAccountIds
                )
            )
            return ModifyChatMembersResponse(
                chatId: result.conversationId,
                epoch: result.conversation?.epoch ?? 0,
                changedAccountIds: result.changedAccountIds
            )
        }
    }

    static func addConversationDevices(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        deviceIds: [String]
    ) throws -> ModifyChatDevicesResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let result = try client.updateConversationDevices(
                request: FfiMessengerUpdateConversationDevicesRequest(
                    conversationId: chatId,
                    deviceIds: deviceIds
                )
            )
            return ModifyChatDevicesResponse(
                chatId: result.conversationId,
                epoch: result.conversation?.epoch ?? 0,
                changedDeviceIds: result.changedDeviceIds
            )
        }
    }

    static func removeConversationDevices(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        deviceIds: [String]
    ) throws -> ModifyChatDevicesResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let result = try client.removeConversationDevices(
                request: FfiMessengerUpdateConversationDevicesRequest(
                    conversationId: chatId,
                    deviceIds: deviceIds
                )
            )
            return ModifyChatDevicesResponse(
                chatId: result.conversationId,
                epoch: result.conversation?.epoch ?? 0,
                changedDeviceIds: result.changedDeviceIds
            )
        }
    }

    static func markConversationRead(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        throughMessageId: String?
    ) throws -> LocalChatReadStateSnapshot {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            try client
                .markRead(conversationId: chatId, throughMessageId: throughMessageId?.trix_trimmedOrNil())
                .trix_localChatReadStateSnapshot
        }
    }

    static func setTyping(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        isTyping: Bool
    ) throws {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            try client.setTyping(conversationId: chatId, isTyping: isTyping)
        }
    }

    static func createLinkDeviceIntent(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) throws -> CreateLinkIntentResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let response = try client.createLinkDeviceIntent()
            return CreateLinkIntentResponse(
                linkIntentId: response.linkIntentId,
                qrPayload: response.payload,
                expiresAtUnix: response.expiresAtUnix
            )
        }
    }

    static func completeLinkDevice(
        payload: LinkIntentPayload,
        form: LinkExistingAccountForm,
        bootstrapMaterial: DeviceBootstrapMaterial
    ) throws -> LocalDeviceIdentity {
        let provisionalIdentity = bootstrapMaterial.makeLinkedLocalIdentity(
            accountId: payload.accountId,
            deviceId: UUID().uuidString,
            deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
            platform: form.platform
        )
        return try withMessengerClient(
            baseURLString: payload.baseURL,
            accessToken: nil,
            identity: provisionalIdentity
        ) { client in
            let response = try client.completeLinkDevice(
                linkPayload: payload.trix_rawPayload,
                deviceDisplayName: form.deviceDisplayName.trix_trimmed()
            )
            let finalizedIdentity = LocalDeviceIdentity(
                accountId: response.accountId,
                deviceId: response.deviceId,
                accountSyncChatId: provisionalIdentity.accountSyncChatId,
                deviceDisplayName: provisionalIdentity.deviceDisplayName,
                platform: provisionalIdentity.platform,
                credentialIdentity: provisionalIdentity.credentialIdentity,
                accountRootPrivateKeyRaw: provisionalIdentity.accountRootPrivateKeyRaw,
                transportPrivateKeyRaw: provisionalIdentity.transportPrivateKeyRaw,
                trustState: provisionalIdentity.trustState,
                capabilityState: provisionalIdentity.capabilityState
            )
            try relocatePersistentState(
                from: provisionalIdentity,
                to: finalizedIdentity,
                requireSource: true
            )
            return finalizedIdentity
        }
    }

    static func approveLinkedDevice(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        deviceId: String
    ) throws -> ApproveDeviceResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let response = try client.approveLinkedDevice(deviceId: deviceId)
            return ApproveDeviceResponse(
                accountId: response.accountId ?? identity.accountId,
                deviceId: response.deviceId,
                deviceStatus: response.deviceStatus.trix_deviceStatus
            )
        }
    }

    static func revokeDevice(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        deviceId: String,
        reason: String
    ) throws -> RevokeDeviceResponse {
        try withMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        ) { client in
            let response = try client.revokeDevice(
                request: FfiMessengerRevokeDeviceRequest(
                    deviceId: deviceId,
                    reason: reason.trix_trimmedOrNil()
                )
            )
            return RevokeDeviceResponse(
                accountId: response.accountId ?? identity.accountId,
                deviceId: response.deviceId,
                deviceStatus: response.deviceStatus.trix_deviceStatus
            )
        }
    }

    static func publishKeyPackages(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        count: Int
    ) throws -> PublishKeyPackagesResponse {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let keyPackages = try context.mlsFacade.generatePublishKeyPackages(count: UInt32(count))
        let response = try client.publishKeyPackages(packages: keyPackages)
        try context.mlsFacade.saveState()
        return response.trix_publishKeyPackagesResponse
    }

    static func ensureOwnDeviceKeyPackages(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        minimumAvailable: Int = 8,
        targetAvailable: Int = 32
    ) throws -> PublishKeyPackagesResponse? {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client
            .ensureDeviceKeyPackages(
                facade: context.mlsFacade,
                deviceId: identity.deviceId,
                minimumAvailable: UInt32(max(minimumAvailable, 0)),
                targetAvailable: UInt32(max(targetAvailable, 0))
            )?
            .trix_publishKeyPackagesResponse
    }

    static func dryRunCreateGroupCommit(
        identity: LocalDeviceIdentity,
        reservedPackages: [ReservedKeyPackage]
    ) throws -> UInt64 {
        let context = try loadOrCreateContext(identity: identity)
        let keyPackages = try reservedPackages.map {
            try $0.keyPackageB64.trix_decodedBase64(fieldName: "key_package_b64")
        }
        let groupId = try Data.trix_random(count: 16)
        let conversation = try context.mlsFacade.createGroup(groupId: groupId)
        return try context.mlsFacade.addMembers(
            conversation: conversation,
            keyPackages: keyPackages
        ).epoch
    }

    static func prepareLinkedDeviceState(
        payload: LinkIntentPayload,
        form: LinkExistingAccountForm,
        bootstrapMaterial: DeviceBootstrapMaterial,
        count: Int = 32
    ) throws -> PreparedLinkedDeviceState {
        let provisionalIdentity = bootstrapMaterial.makeLinkedLocalIdentity(
            accountId: payload.accountId,
            deviceId: UUID().uuidString,
            deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
            platform: form.platform
        )
        return PreparedLinkedDeviceState(
            provisionalIdentity: provisionalIdentity,
            keyPackages: []
        )
    }

    static func finalizeLinkedDeviceState(
        preparedState: PreparedLinkedDeviceState,
        pendingDeviceId: String
    ) throws -> LocalDeviceIdentity {
        let finalizedIdentity = LocalDeviceIdentity(
            accountId: preparedState.provisionalIdentity.accountId,
            deviceId: pendingDeviceId,
            accountSyncChatId: preparedState.provisionalIdentity.accountSyncChatId,
            deviceDisplayName: preparedState.provisionalIdentity.deviceDisplayName,
            platform: preparedState.provisionalIdentity.platform,
            credentialIdentity: preparedState.provisionalIdentity.credentialIdentity,
            accountRootPrivateKeyRaw: preparedState.provisionalIdentity.accountRootPrivateKeyRaw,
            transportPrivateKeyRaw: preparedState.provisionalIdentity.transportPrivateKeyRaw,
            trustState: preparedState.provisionalIdentity.trustState,
            capabilityState: preparedState.provisionalIdentity.capabilityState
        )
        try relocatePersistentState(
            from: preparedState.provisionalIdentity,
            to: finalizedIdentity,
            requireSource: true
        )
        return finalizedIdentity
    }

    @discardableResult
    static func repairLinkedDevicePersistentStateIfNeeded(
        identity: LocalDeviceIdentity
    ) throws -> Bool {
        let fileManager = FileManager.default
        let targetPaths = try PersistentCorePaths(identity: identity)
        if fileManager.fileExists(atPath: targetPaths.mlsStorageRoot.path) {
            return false
        }
        guard fileManager.fileExists(atPath: targetPaths.accountDirectory.path) else {
            return false
        }

        let candidateDirectories = try fileManager.contentsOfDirectory(
            at: targetPaths.accountDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for candidateRoot in candidateDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard candidateRoot.lastPathComponent != identity.deviceId else {
                continue
            }
            guard (try candidateRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let candidateMlsRoot = candidateRoot.appendingPathComponent("mls", isDirectory: true)
            guard fileManager.fileExists(atPath: candidateMlsRoot.path) else {
                continue
            }
            guard let facade = try? FfiMlsFacade.loadPersistent(storageRoot: candidateMlsRoot.path),
                  (try? facade.credentialIdentity()) == identity.credentialIdentity
            else {
                continue
            }

            let provisionalIdentity = LocalDeviceIdentity(
                accountId: identity.accountId,
                deviceId: candidateRoot.lastPathComponent,
                accountSyncChatId: identity.accountSyncChatId,
                deviceDisplayName: identity.deviceDisplayName,
                platform: identity.platform,
                credentialIdentity: identity.credentialIdentity,
                accountRootPrivateKeyRaw: identity.accountRootPrivateKeyRaw,
                transportPrivateKeyRaw: identity.transportPrivateKeyRaw,
                trustState: identity.trustState,
                capabilityState: identity.capabilityState
            )
            try relocatePersistentState(from: provisionalIdentity, to: identity)
            return true
        }

        return false
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
        _ = try projectChatsIfPossible(
            context: context,
            chatIds: report.changedChatIds,
            limit: limitPerChat
        )
        try saveContextState(context)
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
        _ = try projectChatsIfPossible(
            context: context,
            chatIds: outcome.report.changedChatIds,
            limit: 500
        )
        try saveContextState(context)
        return outcome.trix_localInboxSyncResult
    }

    static func pollRealtimeOnce(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) throws -> LocalInboxSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let driver: FfiRealtimeDriver
        do {
            driver = try FfiRealtimeDriver.withConfig(config: realtimeConfig)
        } catch {
            driver = try FfiRealtimeDriver()
        }
        let outcome = try driver.pollOnce(
            client: client,
            coordinator: context.syncCoordinator,
            store: context.historyStore
        )
        _ = try projectChatsIfPossible(
            context: context,
            chatIds: outcome.report.changedChatIds,
            limit: 500
        )
        try saveContextState(context)
        return outcome.trix_localInboxSyncResult
    }

    static func ackInboxIntoSyncState(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        inboxIds: [UInt64]
    ) throws -> LocalInboxAckResult {
        let dedupedInboxIds = Array(Set(inboxIds)).sorted()
        guard !dedupedInboxIds.isEmpty else {
            return LocalInboxAckResult(ackedInboxIds: [])
        }

        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try context.syncCoordinator.ackInbox(client: client, inboxIds: dedupedInboxIds)
        try saveContextState(context)
        return LocalInboxAckResult(ackedInboxIds: response.ackedInboxIds.sorted())
    }

    static func makeRealtimeBindings(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) throws -> PersistentRealtimeBindings {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let realtimeDriver: FfiRealtimeDriver
        do {
            realtimeDriver = try FfiRealtimeDriver.withConfig(config: realtimeConfig)
        } catch {
            realtimeDriver = try FfiRealtimeDriver()
        }

        return PersistentRealtimeBindings(
            websocket: try client.connectWebsocket(),
            realtimeDriver: realtimeDriver,
            historyStore: context.historyStore,
            syncCoordinator: context.syncCoordinator
        )
    }

    static func localStateSnapshot(identity: LocalDeviceIdentity) throws -> LocalCoreStateSnapshot {
        let context = try loadOrCreateContext(identity: identity)
        let syncState = try context.syncCoordinator.stateSnapshot()
        let storedChats = try context.historyStore.listChats()
        let chatIdsNeedingProjection = try storedChats.compactMap { chat in
            let projectedCursor = try context.historyStore.projectedCursor(chatId: chat.chatId) ?? 0
            return chat.lastServerSeq > projectedCursor ? chat.chatId : nil
        }
        if !chatIdsNeedingProjection.isEmpty {
            _ = try projectChatsIfPossible(
                context: context,
                chatIds: chatIdsNeedingProjection,
                limit: 500
            )
        }

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
        let mlsStorageRoot = if let clientStore = context.clientStore {
            clientStore.mlsStorageRoot()
        } else {
            try context.mlsFacade.storageRoot() ?? context.paths.mlsStorageRoot.path
        }
        let historyDatabasePath = if let clientStore = context.clientStore {
            clientStore.databasePath()
        } else {
            try context.historyStore.databasePath() ?? context.paths.legacyHistoryDatabasePath.path
        }
        let syncStatePath = try context.syncCoordinator.statePath()
            ?? context.clientStore?.databasePath()
            ?? context.paths.legacySyncStatePath.path

        return LocalCoreStateSnapshot(
            mlsStorageRoot: mlsStorageRoot,
            historyDatabasePath: historyDatabasePath,
            syncStatePath: syncStatePath,
            ciphersuiteLabel: try context.mlsFacade.ciphersuiteLabel(),
            leaseOwner: syncState.leaseOwner,
            lastAckedInboxId: syncState.lastAckedInboxId,
            localChats: chats,
            localChatListItems: localChatListItems,
            chatCursors: chatCursors,
            chatReadStates: chatReadStates
        )
    }

    static func applyChatList(
        identity: LocalDeviceIdentity,
        chats: [ChatSummary]
    ) throws -> LocalStoreSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let report = try context.historyStore.applyChatList(
            chats: try chats.map { try $0.trix_ffiChatSummary() }
        )
        try saveContextState(context)
        return report.trix_localStoreSyncResult
    }

    static func applyChatDetail(
        identity: LocalDeviceIdentity,
        detail: ChatDetailResponse
    ) throws -> LocalStoreSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let report = try context.historyStore.applyChatDetail(detail: try detail.trix_ffiChatDetail())
        _ = try projectChatsIfPossible(
            context: context,
            chatIds: report.changedChatIds,
            limit: 500
        )
        try saveContextState(context)
        return report.trix_localStoreSyncResult
    }

    static func applyChatHistory(
        identity: LocalDeviceIdentity,
        chatId: String,
        messages: [MessageEnvelope]
    ) throws -> LocalStoreSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let report = try context.historyStore.applyChatHistory(
            history: FfiChatHistory(
                chatId: chatId,
                messages: try messages.map { try $0.trix_ffiMessageEnvelope() }
            )
        )

        if let lastServerSeq = messages.map(\.serverSeq).max() {
            _ = try context.syncCoordinator.recordChatServerSeq(
                chatId: chatId,
                serverSeq: lastServerSeq
            )
        }

        _ = try projectChatsIfPossible(
            context: context,
            chatIds: report.changedChatIds,
            limit: 500
        )
        try saveContextState(context)
        return report.trix_localStoreSyncResult
    }

    static func applyInboxItems(
        identity: LocalDeviceIdentity,
        items: [InboxItem],
        leaseOwner: String? = nil,
        leaseExpiresAtUnix: UInt64 = 0
    ) throws -> LocalStoreSyncResult {
        let context = try loadOrCreateContext(identity: identity)
        let effectiveLeaseOwner = if let leaseOwner {
            leaseOwner
        } else {
            try context.syncCoordinator.leaseOwner()
        }
        let report = try context.historyStore.applyLeasedInbox(
            lease: FfiLeaseInboxResponse(
                leaseOwner: effectiveLeaseOwner,
                leaseExpiresAtUnix: leaseExpiresAtUnix,
                items: try items.map { try $0.trix_ffiInboxItem() }
            )
        )

        for item in items {
            _ = try context.syncCoordinator.recordChatServerSeq(
                chatId: item.message.chatId,
                serverSeq: item.message.serverSeq
            )
        }

        _ = try projectChatsIfPossible(
            context: context,
            chatIds: report.changedChatIds,
            limit: 500
        )
        try saveContextState(context)
        return report.trix_localStoreSyncResult
    }

    static func createChatControl(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatType: ChatType,
        title: String?,
        participantAccountIds: [String]
    ) throws -> CreateChatResponse {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let outcome = try context.syncCoordinator.createChatControl(
            client: client,
            store: context.historyStore,
            facade: context.mlsFacade,
            input: FfiCreateChatControlInput(
                creatorAccountId: identity.accountId,
                creatorDeviceId: identity.deviceId,
                chatType: chatType.trix_ffiChatType,
                title: title?.trix_trimmedOrNil(),
                participantAccountIds: participantAccountIds,
                groupId: nil,
                commitAadJson: nil,
                welcomeAadJson: nil
            )
        )

        try saveContextState(context)
        return CreateChatResponse(
            chatId: outcome.chatId,
            chatType: outcome.chatType.trix_chatType,
            epoch: outcome.epoch
        )
    }

    static func addChatMembersControl(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        participantAccountIds: [String]
    ) throws -> ModifyChatMembersResponse {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        _ = try prepareConversationIfNeeded(
            context: context,
            chatId: chatId
        )
        let outcome = try context.syncCoordinator.addChatMembersControl(
            client: client,
            store: context.historyStore,
            facade: context.mlsFacade,
            input: FfiModifyChatMembersControlInput(
                actorAccountId: identity.accountId,
                actorDeviceId: identity.deviceId,
                chatId: chatId,
                participantAccountIds: participantAccountIds,
                commitAadJson: nil,
                welcomeAadJson: nil
            )
        )

        try saveContextState(context)
        return ModifyChatMembersResponse(
            chatId: outcome.chatId,
            epoch: outcome.epoch,
            changedAccountIds: outcome.changedAccountIds
        )
    }

    static func addChatDevicesControl(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        deviceIds: [String]
    ) throws -> ModifyChatDevicesResponse {
        let context = try loadOrCreateContext(identity: identity)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        _ = try prepareConversationIfNeeded(
            context: context,
            chatId: chatId
        )
        let outcome = try context.syncCoordinator.addChatDevicesControl(
            client: client,
            store: context.historyStore,
            facade: context.mlsFacade,
            input: FfiModifyChatDevicesControlInput(
                actorAccountId: identity.accountId,
                actorDeviceId: identity.deviceId,
                chatId: chatId,
                deviceIds: deviceIds,
                commitAadJson: nil,
                welcomeAadJson: nil
            )
        )

        try saveContextState(context)
        return ModifyChatDevicesResponse(
            chatId: outcome.chatId,
            epoch: outcome.epoch,
            changedDeviceIds: outcome.changedDeviceIds
        )
    }

    static func sendMessageBody(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        body: FfiMessageBody,
        messageId: String? = nil,
        aadJSON: String? = nil
    ) throws -> CreateMessageResponse {
        let conversationContext = try loadConversationContext(identity: identity, chatId: chatId)
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let outcome = try conversationContext.context.syncCoordinator.sendMessageBody(
            client: client,
            store: conversationContext.context.historyStore,
            facade: conversationContext.context.mlsFacade,
            conversation: conversationContext.conversation,
            input: FfiSendMessageInput(
                senderAccountId: identity.accountId,
                senderDeviceId: identity.deviceId,
                chatId: chatId,
                messageId: messageId,
                body: body,
                aadJson: aadJSON
            )
        )

        try saveContextState(conversationContext.context)
        return CreateMessageResponse(
            messageId: outcome.messageId,
            serverSeq: outcome.serverSeq
        )
    }

    @discardableResult
    static func projectChatMessagesIfPossible(
        identity: LocalDeviceIdentity,
        chatId: String,
        limit: Int = 200
    ) throws -> Bool {
        let context = try loadOrCreateContext(identity: identity)
        let projectedChatIds = try projectChatsIfPossible(
            context: context,
            chatIds: [chatId],
            limit: limit
        )
        guard projectedChatIds.contains(chatId) else {
            return false
        }

        try saveContextState(context)
        return true
    }

    @discardableResult
    static func recoverConversationProjectionIfNeeded(
        identity: LocalDeviceIdentity,
        chatId: String,
        historyMessages: [MessageEnvelope],
        limit: Int = 200
    ) throws -> Bool {
        let context = try loadOrCreateContext(identity: identity)

        let projectedChatIds = try projectChatsIfPossible(
            context: context,
            chatIds: [chatId],
            limit: limit
        )
        if projectedChatIds.contains(chatId) {
            try saveContextState(context)
            return true
        }

        return try rebuildConversationProjectionFromHistory(
            context: context,
            chatId: chatId,
            historyMessages: historyMessages
        )
    }

    static func markChatRead(
        identity: LocalDeviceIdentity,
        chatId: String,
        throughServerSeq: UInt64?
    ) throws -> LocalChatReadStateSnapshot {
        let context = try loadOrCreateContext(identity: identity)
        do {
            return try context.historyStore
                .markChatRead(
                    chatId: chatId,
                    throughServerSeq: throughServerSeq,
                    selfAccountId: identity.accountId
                )
                .trix_localChatReadStateSnapshot
        } catch {
            guard throughServerSeq != nil else {
                throw error
            }
            return try context.historyStore
                .setChatReadCursor(
                    chatId: chatId,
                    readCursorServerSeq: throughServerSeq,
                    selfAccountId: identity.accountId
                )
                .trix_localChatReadStateSnapshot
        }
    }

    static func loadLocalTimeline(
        identity: LocalDeviceIdentity,
        chatId: String,
        limit: Int = 150
    ) throws -> [LocalTimelineItemSnapshot] {
        let paths = try PersistentCorePaths(identity: identity)
        guard FileManager.default.fileExists(atPath: paths.stateDatabasePath.path)
                || FileManager.default.fileExists(atPath: paths.legacyHistoryDatabasePath.path)
        else {
            return []
        }

        let context = try loadOrCreateContext(identity: identity)
        return try context.historyStore.getLocalTimelineItems(
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
        guard FileManager.default.fileExists(atPath: paths.stateDatabasePath.path)
                || FileManager.default.fileExists(atPath: paths.legacyHistoryDatabasePath.path)
        else {
            return nil
        }

        let context = try loadOrCreateContext(identity: identity)
        let history = try context.historyStore.getChatHistory(
            chatId: chatId,
            afterServerSeq: nil,
            limit: UInt32(min(max(limit, 1), 500))
        )
        guard !history.messages.isEmpty else {
            return nil
        }

        return history.trix_chatHistoryResponse
    }

    static func projectedCursor(
        identity: LocalDeviceIdentity,
        chatId: String
    ) throws -> UInt64? {
        let paths = try PersistentCorePaths(identity: identity)
        guard FileManager.default.fileExists(atPath: paths.stateDatabasePath.path)
                || FileManager.default.fileExists(atPath: paths.legacyHistoryDatabasePath.path)
        else {
            return nil
        }

        let context = try loadOrCreateContext(identity: identity)
        return try context.historyStore.projectedCursor(chatId: chatId)
    }

    static func getChatReadState(
        identity: LocalDeviceIdentity,
        chatId: String
    ) throws -> LocalChatReadStateSnapshot? {
        let context = try loadOrCreateContext(identity: identity)
        if let state = try context.historyStore
            .getChatReadState(chatId: chatId, selfAccountId: identity.accountId)
        {
            return state.trix_localChatReadStateSnapshot
        }

        let readCursor = try context.historyStore.chatReadCursor(chatId: chatId) ?? 0
        let unreadCount = try context.historyStore.chatUnreadCount(
            chatId: chatId,
            selfAccountId: identity.accountId
        ) ?? 0
        guard readCursor > 0 || unreadCount > 0 else {
            return nil
        }

        return LocalChatReadStateSnapshot(
            chatId: chatId,
            readCursorServerSeq: readCursor,
            unreadCount: unreadCount
        )
    }

    static func signaturePublicKey(
        identity: LocalDeviceIdentity
    ) throws -> Data {
        let context = try loadOrCreateContext(identity: identity)
        return try context.mlsFacade.signaturePublicKey()
    }

    static func localConversationDiagnostics(
        identity: LocalDeviceIdentity,
        chatId: String
    ) throws -> LocalConversationDiagnostics? {
        let conversationContext = try? loadConversationContext(identity: identity, chatId: chatId)
        guard let conversationContext else {
            return nil
        }

        let members = try conversationContext.context.mlsFacade.members(
            conversation: conversationContext.conversation
        )
        let ratchetTree = try conversationContext.conversation.exportRatchetTree()
        return LocalConversationDiagnostics(
            chatCursor: try conversationContext.context.syncCoordinator.chatCursor(chatId: chatId),
            memberCount: members.count,
            ratchetTreeBytes: ratchetTree.count
        )
    }

    static func getLocalChatListItem(
        identity: LocalDeviceIdentity,
        chatId: String
    ) throws -> LocalChatListItemSnapshot? {
        let context = try loadOrCreateContext(identity: identity)
        return try context.historyStore
            .getLocalChatListItem(chatId: chatId, selfAccountId: identity.accountId)
            .map(\.trix_localChatListItemSnapshot)
    }

    static func getProjectedMessages(
        identity: LocalDeviceIdentity,
        chatId: String,
        afterServerSeq: UInt64? = nil,
        limit: Int = 100
    ) throws -> [FfiLocalProjectedMessage] {
        let context = try loadOrCreateContext(identity: identity)
        return try context.historyStore.getProjectedMessages(
            chatId: chatId,
            afterServerSeq: afterServerSeq,
            limit: UInt32(min(max(limit, 1), 500))
        )
    }

    // MARK: - Outbox

    static func enqueueOutboxMessage(
        identity: LocalDeviceIdentity,
        chatId: String,
        messageId: String,
        body: FfiMessageBody,
        queuedAtUnix: UInt64
    ) throws -> FfiLocalOutboxItem {
        let context = try loadOrCreateContext(identity: identity)
        let item = try context.historyStore.enqueueOutboxMessage(
            chatId: chatId,
            senderAccountId: identity.accountId,
            senderDeviceId: identity.deviceId,
            messageId: messageId,
            body: body,
            queuedAtUnix: queuedAtUnix
        )
        try saveContextState(context)
        return item
    }

    static func enqueueOutboxAttachment(
        identity: LocalDeviceIdentity,
        chatId: String,
        messageId: String,
        attachment: FfiLocalOutboxAttachmentDraft,
        queuedAtUnix: UInt64
    ) throws -> FfiLocalOutboxItem {
        let context = try loadOrCreateContext(identity: identity)
        let item = try context.historyStore.enqueueOutboxAttachment(
            chatId: chatId,
            senderAccountId: identity.accountId,
            senderDeviceId: identity.deviceId,
            messageId: messageId,
            attachment: attachment,
            queuedAtUnix: queuedAtUnix
        )
        try saveContextState(context)
        return item
    }

    static func listOutboxMessages(
        identity: LocalDeviceIdentity,
        chatId: String? = nil
    ) throws -> [FfiLocalOutboxItem] {
        let context = try loadOrCreateContext(identity: identity)
        return try context.historyStore.listOutboxMessages(chatId: chatId)
    }

    static func markOutboxFailure(
        identity: LocalDeviceIdentity,
        messageId: String,
        failureMessage: String
    ) throws {
        let context = try loadOrCreateContext(identity: identity)
        try context.historyStore.markOutboxFailure(messageId: messageId, failureMessage: failureMessage)
        try saveContextState(context)
    }

    static func clearOutboxFailure(
        identity: LocalDeviceIdentity,
        messageId: String
    ) throws {
        let context = try loadOrCreateContext(identity: identity)
        try context.historyStore.clearOutboxFailure(messageId: messageId)
        try saveContextState(context)
    }

    static func removeOutboxMessage(
        identity: LocalDeviceIdentity,
        messageId: String
    ) throws {
        let context = try loadOrCreateContext(identity: identity)
        try context.historyStore.removeOutboxMessage(messageId: messageId)
        try saveContextState(context)
    }

    static func deletePersistentState(identity: LocalDeviceIdentity) throws {
        let paths = try PersistentCorePaths(identity: identity)
        if FileManager.default.fileExists(atPath: paths.rootDirectory.path) {
            try FileManager.default.removeItem(at: paths.rootDirectory)
        }

        try DeviceDatabaseKeyStore().clear(account: paths.databaseKeyAccount)
    }

    private static func loadOrCreateContext(identity: LocalDeviceIdentity) throws -> PersistentCoreContext {
        let paths = try PersistentCorePaths(identity: identity)
        try paths.prepareRootDirectory()
        do {
            let databaseKey = try DeviceDatabaseKeyStore().getOrCreate(account: paths.databaseKeyAccount)
            let clientStore = try FfiClientStore.open(
                config: FfiClientStoreConfig(
                    databasePath: paths.stateDatabasePath.path,
                    databaseKey: databaseKey,
                    attachmentCacheRoot: paths.attachmentCacheRoot.path
                )
            )
            let historyStore = clientStore.historyStore()
            let syncCoordinator = clientStore.syncCoordinator()
            let mlsFacade = try clientStore.openMlsFacade(credentialIdentity: identity.credentialIdentity)

            let persistedCredentialIdentity = try mlsFacade.credentialIdentity()
            guard persistedCredentialIdentity == identity.credentialIdentity else {
                throw TrixCorePersistentBridgeError.credentialIdentityMismatch
            }

            return PersistentCoreContext(
                paths: paths,
                clientStore: clientStore,
                mlsFacade: mlsFacade,
                historyStore: historyStore,
                syncCoordinator: syncCoordinator
            )
        } catch {
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
                databasePath: paths.legacyHistoryDatabasePath.path
            )
            let syncCoordinator = try FfiSyncCoordinator.newPersistent(
                statePath: paths.legacySyncStatePath.path
            )

            return PersistentCoreContext(
                paths: paths,
                clientStore: nil,
                mlsFacade: mlsFacade,
                historyStore: historyStore,
                syncCoordinator: syncCoordinator
            )
        }
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

    private static func withMessengerClient<T>(
        baseURLString: String,
        accessToken: String?,
        identity: LocalDeviceIdentity,
        _ operation: (FfiMessengerClient) throws -> T
    ) throws -> T {
        messengerClientLock.lock()
        defer { messengerClientLock.unlock() }

        let client = try openMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        return try operation(client)
    }

    private static func withMessengerClientAsync<Response: Sendable>(
        baseURLString: String,
        accessToken: String?,
        identity: LocalDeviceIdentity,
        _ operation: @escaping @Sendable (FfiMessengerClient) throws -> Response
    ) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try withMessengerClient(
                            baseURLString: baseURLString,
                            accessToken: accessToken,
                            identity: identity,
                            operation
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func openMessengerClient(
        baseURLString: String,
        accessToken: String?,
        identity: LocalDeviceIdentity
    ) throws -> FfiMessengerClient {
        let paths = try PersistentCorePaths(identity: identity)
        try paths.prepareRootDirectory()
        let databaseKey = try DeviceDatabaseKeyStore().getOrCreate(account: paths.databaseKeyAccount)
        return try FfiMessengerClient.open(
            config: FfiMessengerOpenConfig(
                rootPath: paths.rootDirectory.path,
                databaseKey: databaseKey,
                baseUrl: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines),
                accessToken: accessToken,
                accountId: identity.accountId,
                deviceId: identity.deviceId,
                accountSyncChatId: identity.accountSyncChatId,
                deviceDisplayName: identity.deviceDisplayName,
                platform: identity.platform,
                credentialIdentity: identity.credentialIdentity,
                accountRootPrivateKey: identity.accountRootPrivateKeyRaw,
                transportPrivateKey: identity.transportPrivateKeyRaw
            )
        )
    }
}

private struct PersistentCoreContext {
    let paths: PersistentCorePaths
    let clientStore: FfiClientStore?
    let mlsFacade: FfiMlsFacade
    let historyStore: FfiLocalHistoryStore
    let syncCoordinator: FfiSyncCoordinator
}

private struct PersistentConversationContext {
    let context: PersistentCoreContext
    let conversation: FfiMlsConversation
}

struct PersistentCorePaths {
    let accountDirectory: URL
    let rootDirectory: URL
    let mlsStorageRoot: URL
    let stateDatabasePath: URL
    let legacyHistoryDatabasePath: URL
    let legacySyncStatePath: URL
    let attachmentCacheRoot: URL
    let databaseKeyAccount: String

    init(identity: LocalDeviceIdentity) throws {
        let appSupportRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let accountDirectory = appSupportRoot
            .appendingPathComponent("TrixiOS", isDirectory: true)
            .appendingPathComponent("CoreState", isDirectory: true)
            .appendingPathComponent(identity.accountId, isDirectory: true)
        let rootDirectory = accountDirectory
            .appendingPathComponent(identity.deviceId, isDirectory: true)

        self.accountDirectory = accountDirectory
        self.rootDirectory = rootDirectory
        mlsStorageRoot = rootDirectory.appendingPathComponent("mls", isDirectory: true)
        stateDatabasePath = rootDirectory.appendingPathComponent("state-v1.db")
        legacyHistoryDatabasePath = rootDirectory.appendingPathComponent("history-store.sqlite")
        legacySyncStatePath = rootDirectory.appendingPathComponent("sync-state.sqlite")
        attachmentCacheRoot = rootDirectory.appendingPathComponent("attachments", isDirectory: true)
        databaseKeyAccount = "device-core-store-key-v1:\(identity.accountId):\(identity.deviceId)"
    }

    func prepareRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attachmentCacheRoot,
            withIntermediateDirectories: true
        )
    }
}

private enum TrixCorePersistentBridgeError: LocalizedError {
    case credentialIdentityMismatch
    case missingPersistentState(deviceId: String)
    case missingMlsGroupID(chatId: String)
    case missingConversationState(chatId: String)
    case invalidBase64Field(String)

    var errorDescription: String? {
        switch self {
        case .credentialIdentityMismatch:
            return "Persisted trix-core state does not match the current device credential identity."
        case let .missingPersistentState(deviceId):
            return "Persisted trix-core state is missing for device \(deviceId)."
        case let .missingMlsGroupID(chatId):
            return "This chat is not ready for MLS messaging on this device yet (\(chatId))."
        case let .missingConversationState(chatId):
            return "Local MLS conversation state is missing for chat \(chatId)."
        case let .invalidBase64Field(fieldName):
            return "Invalid base64 data in \(fieldName)."
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

private extension TrixCorePersistentBridge {
    static func relocatePersistentState(
        from sourceIdentity: LocalDeviceIdentity,
        to destinationIdentity: LocalDeviceIdentity,
        requireSource: Bool = false
    ) throws {
        let fileManager = FileManager.default
        let sourcePaths = try PersistentCorePaths(identity: sourceIdentity)
        let destinationPaths = try PersistentCorePaths(identity: destinationIdentity)

        guard sourcePaths.rootDirectory.path != destinationPaths.rootDirectory.path else {
            return
        }
        guard fileManager.fileExists(atPath: sourcePaths.rootDirectory.path) else {
            if requireSource {
                throw TrixCorePersistentBridgeError.missingPersistentState(deviceId: sourceIdentity.deviceId)
            }
            return
        }

        if fileManager.fileExists(atPath: destinationPaths.rootDirectory.path) {
            try fileManager.removeItem(at: destinationPaths.rootDirectory)
        }
        try fileManager.createDirectory(
            at: destinationPaths.accountDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: sourcePaths.rootDirectory, to: destinationPaths.rootDirectory)
        try DeviceDatabaseKeyStore().relocate(
            from: sourcePaths.databaseKeyAccount,
            to: destinationPaths.databaseKeyAccount
        )
    }

    static func loadConversationContext(
        identity: LocalDeviceIdentity,
        chatId: String
    ) throws -> PersistentConversationContext {
        let context = try loadOrCreateContext(identity: identity)
        let conversation = try prepareConversationIfNeeded(
            context: context,
            chatId: chatId
        )

        return PersistentConversationContext(
            context: context,
            conversation: conversation
        )
    }

    static func prepareConversationIfNeeded(
        context: PersistentCoreContext,
        chatId: String,
        projectionLimit: Int = 500
    ) throws -> FfiMlsConversation {
        if let groupId = try context.historyStore.chatMlsGroupId(chatId: chatId),
           let conversation = try context.mlsFacade.loadGroup(groupId: groupId) {
            return conversation
        }

        guard let conversation = try context.historyStore.loadOrBootstrapChatConversation(
            chatId: chatId,
            facade: context.mlsFacade
        ) else {
            throw TrixCorePersistentBridgeError.missingMlsGroupID(chatId: chatId)
        }

        _ = try context.historyStore.projectChatMessages(
            chatId: chatId,
            facade: context.mlsFacade,
            conversation: conversation,
            limit: UInt32(min(max(projectionLimit, 1), 500))
        )
        return conversation
    }

    static func saveContextState(_ context: PersistentCoreContext) throws {
        try context.historyStore.saveState()
        try context.mlsFacade.saveState()
        try context.syncCoordinator.saveState()
    }

    static func projectChatsIfPossible(
        context: PersistentCoreContext,
        chatIds: [String],
        limit: Int = 500
    ) throws -> Set<String> {
        let clampedLimit = UInt32(min(max(limit, 1), 500))
        var projectedChatIds = Set<String>()

        for chatId in Set(chatIds) {
            do {
                _ = try context.historyStore.projectChatWithFacade(
                    chatId: chatId,
                    facade: context.mlsFacade,
                    limit: clampedLimit
                )
                projectedChatIds.insert(chatId)
            } catch {
                continue
            }
        }

        return projectedChatIds
    }

    static func rebuildConversationProjectionFromHistory(
        context: PersistentCoreContext,
        chatId: String,
        historyMessages: [MessageEnvelope]
    ) throws -> Bool {
        let sortedMessages = historyMessages.sorted {
            if $0.serverSeq == $1.serverSeq {
                return $0.createdAtUnix < $1.createdAtUnix
            }
            return $0.serverSeq < $1.serverSeq
        }
        let welcomeCandidates = sortedMessages
            .filter { $0.messageKind == .welcomeRef }
            .sorted { $0.serverSeq > $1.serverSeq }

        guard !welcomeCandidates.isEmpty else {
            return false
        }

        for welcomeMessage in welcomeCandidates {
            do {
                let conversation = try context.mlsFacade.joinGroupFromWelcome(
                    welcomeMessage: try welcomeMessage.ciphertextB64.trix_decodedBase64(fieldName: "ciphertext_b64"),
                    ratchetTree: controlMessageRatchetTree(from: welcomeMessage.aadJson)
                )
                let groupId = try conversation.groupId()
                _ = try context.historyStore.setChatMlsGroupId(chatId: chatId, groupId: groupId)

                let projectedMessages = try buildProjectedMessagesFromWelcome(
                    welcomeMessage: welcomeMessage,
                    allMessages: sortedMessages,
                    facade: context.mlsFacade,
                    conversation: conversation
                )

                guard !projectedMessages.isEmpty else {
                    continue
                }
                _ = try context.historyStore.applyProjectedMessages(
                    chatId: chatId,
                    projectedMessages: projectedMessages
                )
                try saveContextState(context)
                return true
            } catch {
                continue
            }
        }

        return false
    }

    static func buildProjectedMessagesFromWelcome(
        welcomeMessage: MessageEnvelope,
        allMessages: [MessageEnvelope],
        facade: FfiMlsFacade,
        conversation: FfiMlsConversation
    ) throws -> [FfiLocalProjectedMessage] {
        var projectedMessages: [FfiLocalProjectedMessage] = []

        for message in allMessages where message.serverSeq <= welcomeMessage.serverSeq {
            switch message.messageKind {
            case .commit:
                projectedMessages.append(
                    try makeProjectedMessage(
                        from: message,
                        projectionKind: .commitMerged,
                        payload: nil,
                        mergedEpoch: message.epoch
                    )
                )
            case .welcomeRef:
                projectedMessages.append(
                    try makeProjectedMessage(
                        from: message,
                        projectionKind: .welcomeRef,
                        payload: try message.ciphertextB64.trix_decodedBase64(fieldName: "ciphertext_b64"),
                        mergedEpoch: nil
                    )
                )
            case .application, .system:
                continue
            }
        }

        for message in allMessages where message.serverSeq > welcomeMessage.serverSeq {
            let ciphertext = try message.ciphertextB64.trix_decodedBase64(fieldName: "ciphertext_b64")

            switch message.messageKind {
            case .application, .commit:
                let result = try facade.processMessage(
                    conversation: conversation,
                    messageBytes: ciphertext
                )
                switch result.kind {
                case .applicationMessage:
                    projectedMessages.append(
                        try makeProjectedMessage(
                            from: message,
                            projectionKind: .applicationMessage,
                            payload: result.applicationMessage,
                            mergedEpoch: nil
                        )
                    )
                case .proposalQueued:
                    projectedMessages.append(
                        try makeProjectedMessage(
                            from: message,
                            projectionKind: .proposalQueued,
                            payload: nil,
                            mergedEpoch: nil
                        )
                    )
                case .commitMerged:
                    projectedMessages.append(
                        try makeProjectedMessage(
                            from: message,
                            projectionKind: .commitMerged,
                            payload: nil,
                            mergedEpoch: result.epoch
                        )
                    )
                }
            case .welcomeRef:
                projectedMessages.append(
                    try makeProjectedMessage(
                        from: message,
                        projectionKind: .welcomeRef,
                        payload: ciphertext,
                        mergedEpoch: nil
                    )
                )
            case .system:
                projectedMessages.append(
                    try makeProjectedMessage(
                        from: message,
                        projectionKind: .system,
                        payload: ciphertext,
                        mergedEpoch: nil
                    )
                )
            }
        }

        return projectedMessages
    }

    static func controlMessageRatchetTree(from aadJson: JSONValue) -> Data? {
        guard case let .object(root) = aadJson,
              case let .object(meta)? = root["_trix"],
              case let .string(ratchetTreeB64)? = meta["ratchet_tree_b64"]
        else {
            return nil
        }

        return try? ratchetTreeB64.trix_decodedBase64(fieldName: "aadJson._trix.ratchet_tree_b64")
    }

    static func makeProjectedMessage(
        from message: MessageEnvelope,
        projectionKind: FfiLocalProjectionKind,
        payload: Data?,
        mergedEpoch: UInt64?
    ) throws -> FfiLocalProjectedMessage {
        FfiLocalProjectedMessage(
            serverSeq: message.serverSeq,
            messageId: message.messageId,
            senderAccountId: message.senderAccountId,
            senderDeviceId: message.senderDeviceId,
            epoch: message.epoch,
            messageKind: message.messageKind.trix_ffiMessageKind,
            contentType: message.contentType.trix_ffiContentType,
            projectionKind: projectionKind,
            payload: payload,
            body: nil,
            bodyParseError: nil,
            mergedEpoch: mergedEpoch,
            createdAtUnix: message.createdAtUnix
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
            epoch: epoch,
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
            messageBody: body,
            previewText: previewText,
            bodyPreview: body?.trix_messageBodyPreview,
            bodyParseError: bodyParseError,
            receiptStatus: receiptStatus?.trix_safeReceiptType,
            reactions: reactions.map(\.trix_safeMessengerReactionSummary),
            isVisibleInTimeline: isVisibleInTimeline,
            mergedEpoch: mergedEpoch,
            createdAtUnix: createdAtUnix
        )
    }
}

extension FfiChatHistory {
    var trix_chatHistoryResponse: ChatHistoryResponse {
        ChatHistoryResponse(
            chatId: chatId,
            messages: messages.map(\.trix_messageEnvelope)
        )
    }
}

extension FfiChatSummary {
    var trix_chatSummary: ChatSummary {
        ChatSummary(
            chatId: chatId,
            chatType: chatType.trix_chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: lastMessage?.trix_messageEnvelope,
            participantProfiles: participantProfiles.map(\.trix_chatParticipantProfileSummary)
        )
    }
}

extension FfiChatParticipantProfile {
    var trix_chatParticipantProfileSummary: ChatParticipantProfileSummary {
        ChatParticipantProfileSummary(
            accountId: accountId,
            handle: handle,
            profileName: profileName,
            profileBio: profileBio
        )
    }
}

extension FfiMessageEnvelope {
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

extension FfiChatType {
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

private extension ChatType {
    var trix_ffiChatType: FfiChatType {
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

extension FfiMessageKind {
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

extension FfiContentType {
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

private extension ContentType {
    var trix_ffiContentType: FfiContentType {
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

private extension FfiDeviceStatus {
    var trix_deviceStatus: DeviceStatus {
        switch self {
        case .pending:
            return .pending
        case .active:
            return .active
        case .revoked:
            return .revoked
        }
    }
}

private extension FfiMessengerSnapshot {
    var trix_safeMessengerSnapshot: SafeMessengerSnapshot {
        let chatListItems = conversations.map(\.trix_localChatListItemSnapshot)
        return SafeMessengerSnapshot(
            accountId: accountId,
            deviceId: deviceId,
            accountSyncChatId: accountSyncChatId,
            chats: conversations.map(\.trix_chatSummary),
            chatListItems: chatListItems,
            devices: devices.map(\.trix_deviceSummary),
            checkpoint: checkpoint
        )
    }
}

private extension FfiMessengerConversationSummary {
    var trix_chatSummary: ChatSummary {
        ChatSummary(
            chatId: conversationId,
            chatType: conversationType.trix_chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: nil,
            participantProfiles: participantProfiles.map(\.trix_chatParticipantProfileSummary)
        )
    }

    var trix_localChatListItemSnapshot: LocalChatListItemSnapshot {
        LocalChatListItemSnapshot(
            chatId: conversationId,
            chatType: conversationType.trix_chatType,
            title: title,
            displayTitle: displayTitle,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
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

    var trix_chatDetailResponse: ChatDetailResponse {
        let profiles = participantProfiles.map(\.trix_chatParticipantProfileSummary)
        return ChatDetailResponse(
            chatId: conversationId,
            chatType: conversationType.trix_chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            pendingMessageCount: pendingMessageCount,
            epoch: epoch,
            lastCommitMessageId: nil,
            lastMessage: nil,
            participantProfiles: profiles,
            members: profiles.map {
                ChatMemberSummary(
                    accountId: $0.accountId,
                    role: "member",
                    membershipStatus: "active"
                )
            },
            deviceMembers: []
        )
    }
}

private extension FfiMessengerParticipantProfile {
    var trix_chatParticipantProfileSummary: ChatParticipantProfileSummary {
        ChatParticipantProfileSummary(
            accountId: accountId,
            handle: handle,
            profileName: profileName,
            profileBio: profileBio
        )
    }
}

private extension FfiMessengerDeviceRecord {
    var trix_deviceSummary: DeviceSummary {
        DeviceSummary(
            deviceId: deviceId,
            displayName: displayName,
            platform: platform,
            deviceStatus: deviceStatus.trix_deviceStatus,
            availableKeyPackageCount: availableKeyPackageCount
        )
    }
}

private extension FfiMessengerMessageBodyKind {
    var trix_safeMessageBodyKind: SafeMessengerMessageBodyKind {
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

private extension FfiReactionAction {
    var trix_safeReactionAction: SafeMessengerReactionAction {
        switch self {
        case .add:
            return .add
        case .remove:
            return .remove
        }
    }
}

private extension FfiReceiptType {
    var trix_safeReceiptType: SafeMessengerReceiptType {
        switch self {
        case .delivered:
            return .delivered
        case .read:
            return .read
        }
    }
}

private extension FfiMessengerAttachmentDescriptor {
    var trix_safeMessengerAttachment: SafeMessengerAttachment {
        SafeMessengerAttachment(
            attachmentRef: attachmentRef,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            fileName: fileName,
            widthPx: widthPx,
            heightPx: heightPx
        )
    }
}

private extension FfiMessageReactionSummary {
    var trix_safeMessengerReactionSummary: SafeMessengerReactionSummary {
        SafeMessengerReactionSummary(
            emoji: emoji,
            reactorAccountIds: reactorAccountIds,
            count: count,
            includesSelf: includesSelf
        )
    }
}

private extension FfiMessengerMessageBody {
    var trix_safeMessengerMessageBody: SafeMessengerMessageBody {
        SafeMessengerMessageBody(
            kind: kind.trix_safeMessageBodyKind,
            text: text,
            targetMessageId: targetMessageId,
            emoji: emoji,
            reactionAction: reactionAction?.trix_safeReactionAction,
            receiptType: receiptType?.trix_safeReceiptType,
            receiptAtUnix: receiptAtUnix,
            attachment: attachment?.trix_safeMessengerAttachment,
            eventType: eventType,
            eventJSON: eventJson
        )
    }
}

private extension FfiMessengerMessageRecord {
    var trix_safeMessengerMessage: SafeMessengerMessage {
        SafeMessengerMessage(
            conversationId: conversationId,
            serverSeq: serverSeq,
            messageId: messageId,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            senderDisplayName: senderDisplayName,
            isOutgoing: isOutgoing,
            contentType: contentType.trix_contentType,
            body: body?.trix_safeMessengerMessageBody,
            previewText: previewText,
            receiptStatus: receiptStatus?.trix_safeReceiptType,
            reactions: reactions.map(\.trix_safeMessengerReactionSummary),
            isVisibleInTimeline: isVisibleInTimeline,
            createdAtUnix: createdAtUnix
        )
    }
}

private extension FfiMessengerReadStateResult {
    var trix_localChatReadStateSnapshot: LocalChatReadStateSnapshot {
        LocalChatReadStateSnapshot(
            chatId: conversationId,
            readCursorServerSeq: readCursorServerSeq,
            unreadCount: unreadCount
        )
    }
}

private extension FfiMessengerEventKind {
    var trix_safeEventKind: SafeMessengerEventKind {
        switch self {
        case .messageCreated:
            return .messageCreated
        case .messageUpdated:
            return .messageUpdated
        case .conversationUpdated:
            return .conversationUpdated
        case .devicePending:
            return .devicePending
        case .deviceApproved:
            return .deviceApproved
        case .deviceRevoked:
            return .deviceRevoked
        case .attachmentReady:
            return .attachmentReady
        case .readStateUpdated:
            return .readStateUpdated
        case .typingUpdated:
            return .typingUpdated
        }
    }
}

private extension FfiMessengerEvent {
    var trix_safeMessengerEvent: SafeMessengerEvent {
        SafeMessengerEvent(
            eventId: eventId,
            kind: kind.trix_safeEventKind,
            conversationId: conversationId,
            message: message?.trix_safeMessengerMessage,
            chat: conversation?.trix_chatSummary,
            device: device?.trix_deviceSummary,
            readState: readState?.trix_localChatReadStateSnapshot,
            attachmentRef: attachmentRef
        )
    }
}

private extension FfiMessengerEventBatch {
    var trix_safeMessengerEventBatch: SafeMessengerEventBatch {
        SafeMessengerEventBatch(
            checkpoint: checkpoint,
            events: events.map(\.trix_safeMessengerEvent)
        )
    }
}

private extension FfiMessengerSendMessageResult {
    var trix_createMessageResponse: CreateMessageResponse {
        CreateMessageResponse(
            messageId: message.messageId,
            serverSeq: message.serverSeq
        )
    }
}

private extension DebugMessageDraft {
    func trix_safeSendMessageRequest(chatId: String) throws -> FfiMessengerSendMessageRequest {
        let messageId = UUID().uuidString.lowercased()
        switch kind {
        case .text:
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidTextBody
            }
            return FfiMessengerSendMessageRequest(
                conversationId: chatId,
                messageId: messageId,
                kind: .text,
                text: text,
                targetMessageId: nil,
                emoji: nil,
                reactionAction: nil,
                receiptType: nil,
                receiptAtUnix: nil,
                eventType: nil,
                eventJson: nil,
                attachmentTokens: []
            )
        case .attachment:
            throw TrixCoreMessageBridgeError.attachmentRequiresUploadFlow
        case .reaction:
            let targetMessageId = targetMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetMessageId.isEmpty, !emoji.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidReactionBody
            }
            return FfiMessengerSendMessageRequest(
                conversationId: chatId,
                messageId: messageId,
                kind: .reaction,
                text: nil,
                targetMessageId: targetMessageId,
                emoji: emoji,
                reactionAction: reactionAction.trix_ffiReactionAction,
                receiptType: nil,
                receiptAtUnix: nil,
                eventType: nil,
                eventJson: nil,
                attachmentTokens: []
            )
        case .receipt:
            let targetMessageId = targetMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetMessageId.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidReceiptBody
            }
            let trimmedReceiptAtUnix = receiptAtUnix.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedReceiptAtUnix: UInt64?
            if trimmedReceiptAtUnix.isEmpty {
                parsedReceiptAtUnix = nil
            } else if let parsed = UInt64(trimmedReceiptAtUnix) {
                parsedReceiptAtUnix = parsed
            } else {
                throw TrixCoreMessageBridgeError.invalidReceiptTimestamp
            }
            return FfiMessengerSendMessageRequest(
                conversationId: chatId,
                messageId: messageId,
                kind: .receipt,
                text: nil,
                targetMessageId: targetMessageId,
                emoji: nil,
                reactionAction: nil,
                receiptType: receiptKind.trix_ffiReceiptType,
                receiptAtUnix: parsedReceiptAtUnix,
                eventType: nil,
                eventJson: nil,
                attachmentTokens: []
            )
        case .chatEvent:
            let eventType = eventType.trimmingCharacters(in: .whitespacesAndNewlines)
            let eventJSON = eventJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !eventType.isEmpty, !eventJSON.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidChatEventBody
            }
            _ = try JSONSerialization.jsonObject(with: Data(eventJSON.utf8))
            return FfiMessengerSendMessageRequest(
                conversationId: chatId,
                messageId: messageId,
                kind: .chatEvent,
                text: nil,
                targetMessageId: nil,
                emoji: nil,
                reactionAction: nil,
                receiptType: nil,
                receiptAtUnix: nil,
                eventType: eventType,
                eventJson: eventJSON,
                attachmentTokens: []
            )
        }
    }
}

private extension LinkIntentPayload {
    var trix_rawPayload: String {
        let payload: [String: Any] = [
            "version": version,
            "base_url": baseURL,
            "account_id": accountId,
            "link_intent_id": linkIntentId,
            "link_token": linkToken,
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
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

private extension ChatSummary {
    func trix_ffiChatSummary() throws -> FfiChatSummary {
        FfiChatSummary(
            chatId: chatId,
            chatType: chatType.trix_ffiChatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: try lastMessage?.trix_ffiMessageEnvelope(),
            participantProfiles: participantProfiles.map(\.trix_ffiChatParticipantProfile)
        )
    }
}

private extension ChatDetailResponse {
    func trix_ffiChatDetail() throws -> FfiChatDetail {
        FfiChatDetail(
            chatId: chatId,
            chatType: chatType.trix_ffiChatType,
            title: title,
            lastServerSeq: lastServerSeq,
            pendingMessageCount: pendingMessageCount,
            epoch: epoch,
            lastCommitMessageId: lastCommitMessageId,
            lastMessage: try lastMessage?.trix_ffiMessageEnvelope(),
            participantProfiles: participantProfiles.map(\.trix_ffiChatParticipantProfile),
            members: members.map(\.trix_ffiChatMember),
            deviceMembers: try deviceMembers.map { try $0.trix_ffiChatDeviceMember() }
        )
    }
}

private extension ChatParticipantProfileSummary {
    var trix_ffiChatParticipantProfile: FfiChatParticipantProfile {
        FfiChatParticipantProfile(
            accountId: accountId,
            handle: handle,
            profileName: profileName,
            profileBio: profileBio
        )
    }
}

private extension ChatMemberSummary {
    var trix_ffiChatMember: FfiChatMember {
        FfiChatMember(
            accountId: accountId,
            role: role,
            membershipStatus: membershipStatus
        )
    }
}

private extension ChatDeviceSummary {
    func trix_ffiChatDeviceMember() throws -> FfiChatDeviceMember {
        FfiChatDeviceMember(
            deviceId: deviceId,
            accountId: accountId,
            displayName: displayName,
            platform: platform,
            leafIndex: leafIndex,
            credentialIdentity: try credentialIdentityB64.trix_decodedBase64(fieldName: "credential_identity_b64")
        )
    }
}

private extension MessageEnvelope {
    func trix_ffiMessageEnvelope() throws -> FfiMessageEnvelope {
        FfiMessageEnvelope(
            messageId: messageId,
            chatId: chatId,
            serverSeq: serverSeq,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            epoch: epoch,
            messageKind: messageKind.trix_ffiMessageKind,
            contentType: contentType.trix_ffiContentType,
            ciphertext: try ciphertextB64.trix_decodedBase64(fieldName: "ciphertext_b64"),
            aadJson: try aadJson.trix_jsonString(),
            createdAtUnix: createdAtUnix
        )
    }
}

private extension InboxItem {
    func trix_ffiInboxItem() throws -> FfiInboxItem {
        FfiInboxItem(
            inboxId: inboxId,
            message: try message.trix_ffiMessageEnvelope()
        )
    }
}

private extension MessageKind {
    var trix_ffiMessageKind: FfiMessageKind {
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

private extension JSONValue {
    func trix_jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    func trix_decodedBase64(fieldName: String) throws -> Data {
        guard let data = Data(base64Encoded: self) else {
            throw TrixCorePersistentBridgeError.invalidBase64Field(fieldName)
        }
        return data
    }
}
