import Foundation
import Security

struct MessengerSnapshot: Sendable {
    let accountId: UUID?
    let deviceId: UUID?
    let accountSyncChatId: UUID?
    let conversations: [LocalChatListItem]
    let devices: [DeviceSummary]
    let checkpoint: String?
}

struct MessengerMessagePage: Sendable {
    let conversationId: UUID
    let messages: [LocalTimelineItem]
    let nextCursor: String?
}

struct MessengerEventBatchSummary: Sendable {
    let checkpoint: String?
    let changedConversationIDs: Set<UUID>
    let hasDeviceChanges: Bool
}

struct MessengerAttachmentFile: Sendable {
    let attachmentRef: String
    let localURL: URL
    let mimeType: String
    let sizeBytes: UInt64
    let fileName: String?
    let widthPx: UInt32?
    let heightPx: UInt32?
}

struct MessengerSendMessageResult: Sendable {
    let conversationId: UUID
    let message: LocalTimelineItem
    let checkpoint: String?
}

struct MessengerConversationMutationResult: Sendable {
    let conversationId: UUID
    let conversation: LocalChatListItem?
    let messages: [LocalTimelineItem]
    let changedParticipantAccountIDs: [UUID]
    let changedDeviceIDs: [UUID]
}

struct MessengerPendingDeviceResult: Sendable {
    let accountId: UUID
    let deviceId: UUID
    let deviceStatus: DeviceStatus
}

struct MessengerDeviceLinkIntent: Sendable {
    let linkIntentId: UUID
    let payload: String
    let expiresAt: Date
}

struct MessengerDeviceMutationResult: Sendable {
    let accountId: UUID?
    let deviceId: UUID
    let deviceStatus: DeviceStatus
    let devices: [DeviceSummary]
}

struct TrixMessengerClient {
    struct Configuration: Sendable {
        let rootPath: String
        let databaseKey: Data
        let baseURL: String
        let accessToken: String?
        let accountId: UUID?
        let deviceId: UUID?
        let accountSyncChatId: UUID?
        let deviceDisplayName: String?
        let platform: String?
        let credentialIdentity: Data?
        let accountRootPrivateKey: Data?
        let transportPrivateKey: Data?
    }

    let configuration: Configuration

    init(
        workspaceRoot: URL,
        baseURL: String,
        accessToken: String?,
        accountId: UUID?,
        deviceId: UUID?,
        accountSyncChatId: UUID?,
        deviceDisplayName: String?,
        platform: String?,
        credentialIdentity: Data?,
        accountRootPrivateKey: Data?,
        transportPrivateKey: Data?
    ) throws {
        self.configuration = Configuration(
            rootPath: workspaceRoot.path,
            databaseKey: try MessengerWorkspaceDatabaseKeyStore().getOrCreate(workspaceRoot: workspaceRoot),
            baseURL: baseURL,
            accessToken: accessToken,
            accountId: accountId,
            deviceId: deviceId,
            accountSyncChatId: accountSyncChatId,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentity: credentialIdentity,
            accountRootPrivateKey: accountRootPrivateKey,
            transportPrivateKey: transportPrivateKey
        )
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func loadSnapshot() async throws -> MessengerSnapshot {
        try await callFFI { client in
            let snapshot = try client.loadSnapshot()
            return try MessengerSnapshot(
                accountId: snapshot.accountId.map {
                    try TrixCoreCodec.uuid($0, label: "account_id")
                },
                deviceId: snapshot.deviceId.map {
                    try TrixCoreCodec.uuid($0, label: "device_id")
                },
                accountSyncChatId: snapshot.accountSyncChatId.map {
                    try TrixCoreCodec.uuid($0, label: "account_sync_chat_id")
                },
                conversations: snapshot.conversations.map {
                    try LocalChatListItem(ffiMessengerValue: $0)
                },
                devices: snapshot.devices.map {
                    try DeviceSummary(ffiMessengerValue: $0)
                },
                checkpoint: snapshot.checkpoint
            )
        }
    }

    func listConversations() async throws -> [LocalChatListItem] {
        try await callFFI { client in
            try client.listConversations().map { try LocalChatListItem(ffiMessengerValue: $0) }
        }
    }

    func listDevices() async throws -> [DeviceSummary] {
        try await callFFI { client in
            try client.listDevices().map { try DeviceSummary(ffiMessengerValue: $0) }
        }
    }

    func getMessages(
        conversationId: UUID,
        pageCursor: String? = nil,
        limit: Int = 200
    ) async throws -> MessengerMessagePage {
        try await callFFI { client in
            let page = try client.getMessages(
                conversationId: conversationId.uuidString,
                pageCursor: pageCursor,
                limit: try TrixCoreCodec.uint32(limit, label: "message page limit")
            )
            return try MessengerMessagePage(
                conversationId: TrixCoreCodec.uuid(page.conversationId, label: "conversation_id"),
                messages: page.messages.map { try LocalTimelineItem(ffiMessengerValue: $0) },
                nextCursor: page.nextCursor
            )
        }
    }

    func getAllMessages(
        conversationId: UUID,
        pageLimit: Int = 200
    ) async throws -> [LocalTimelineItem] {
        let clampedPageLimit = max(1, min(pageLimit, 500))
        var pageCursor: String?
        var messagesByID: [UUID: LocalTimelineItem] = [:]

        while true {
            let page = try await getMessages(
                conversationId: conversationId,
                pageCursor: pageCursor,
                limit: clampedPageLimit
            )
            for message in page.messages {
                messagesByID[message.messageId] = message
            }
            guard let nextCursor = page.nextCursor else {
                break
            }
            pageCursor = nextCursor
        }

        return messagesByID.values.sorted { lhs, rhs in
            if lhs.serverSeq == rhs.serverSeq {
                return lhs.createdAtUnix < rhs.createdAtUnix
            }
            return lhs.serverSeq < rhs.serverSeq
        }
    }

    func getNewEvents(checkpoint: String?) async throws -> MessengerEventBatchSummary {
        try await callFFI { client in
            let batch = try client.getNewEvents(checkpoint: checkpoint)
            var changedConversationIDs = Set<UUID>()

            for event in batch.events {
                if let conversation = event.conversation {
                    changedConversationIDs.insert(
                        try TrixCoreCodec.uuid(
                            conversation.conversationId,
                            label: "conversation_id"
                        )
                    )
                    continue
                }
                if let message = event.message {
                    changedConversationIDs.insert(
                        try TrixCoreCodec.uuid(
                            message.conversationId,
                            label: "conversation_id"
                        )
                    )
                    continue
                }
                if let readState = event.readState {
                    changedConversationIDs.insert(
                        try TrixCoreCodec.uuid(
                            readState.conversationId,
                            label: "conversation_id"
                        )
                    )
                    continue
                }
                if let conversationId = event.conversationId {
                    changedConversationIDs.insert(
                        try TrixCoreCodec.uuid(conversationId, label: "conversation_id")
                    )
                }
            }

            return MessengerEventBatchSummary(
                checkpoint: batch.checkpoint,
                changedConversationIDs: changedConversationIDs,
                hasDeviceChanges: batch.events.contains { event in
                    switch event.kind {
                    case .devicePending, .deviceApproved, .deviceRevoked:
                        return true
                    default:
                        return false
                    }
                }
            )
        }
    }

    func sendAttachment(
        conversationId: UUID,
        payload: Data,
        mimeType: String,
        fileName: String?,
        widthPx: UInt32?,
        heightPx: UInt32?
    ) async throws -> String {
        try await callFFI { client in
            try client.sendAttachment(
                conversationId: conversationId.uuidString,
                payload: payload,
                metadata: FfiMessengerAttachmentMetadata(
                    mimeType: mimeType,
                    fileName: fileName,
                    widthPx: widthPx,
                    heightPx: heightPx
                )
            ).token
        }
    }

    func sendMessage(
        conversationId: UUID,
        body: TypedMessageBody,
        messageId: UUID? = nil,
        attachmentTokens: [String] = []
    ) async throws -> MessengerSendMessageResult {
        try await callFFI { client in
            let result = try client.sendMessage(
                request: body.ffiMessengerSendRequest(
                    conversationId: conversationId,
                    messageId: messageId,
                    attachmentTokens: attachmentTokens
                )
            )
            return try MessengerSendMessageResult(
                conversationId: TrixCoreCodec.uuid(result.conversationId, label: "conversation_id"),
                message: LocalTimelineItem(ffiMessengerValue: result.message),
                checkpoint: result.checkpoint
            )
        }
    }

    func createConversation(
        chatType: ChatType,
        title: String?,
        participantAccountIds: [UUID]
    ) async throws -> MessengerConversationMutationResult {
        try await callFFI { client in
            let result = try client.createConversation(
                request: FfiMessengerCreateConversationRequest(
                    conversationType: chatType.ffiValue,
                    title: title,
                    participantAccountIds: participantAccountIds.map(\.uuidString)
                )
            )
            return try convertConversationMutationResult(result)
        }
    }

    func updateConversationMembers(
        conversationId: UUID,
        participantAccountIds: [UUID]
    ) async throws -> MessengerConversationMutationResult {
        try await callFFI { client in
            let result = try client.updateConversationMembers(
                request: FfiMessengerUpdateConversationMembersRequest(
                    conversationId: conversationId.uuidString,
                    participantAccountIds: participantAccountIds.map(\.uuidString)
                )
            )
            return try convertConversationMutationResult(result)
        }
    }

    func removeConversationMembers(
        conversationId: UUID,
        participantAccountIds: [UUID]
    ) async throws -> MessengerConversationMutationResult {
        try await callFFI { client in
            let result = try client.removeConversationMembers(
                request: FfiMessengerUpdateConversationMembersRequest(
                    conversationId: conversationId.uuidString,
                    participantAccountIds: participantAccountIds.map(\.uuidString)
                )
            )
            return try convertConversationMutationResult(result)
        }
    }

    func updateConversationDevices(
        conversationId: UUID,
        deviceIds: [UUID]
    ) async throws -> MessengerConversationMutationResult {
        try await callFFI { client in
            let result = try client.updateConversationDevices(
                request: FfiMessengerUpdateConversationDevicesRequest(
                    conversationId: conversationId.uuidString,
                    deviceIds: deviceIds.map(\.uuidString)
                )
            )
            return try convertConversationMutationResult(result)
        }
    }

    func removeConversationDevices(
        conversationId: UUID,
        deviceIds: [UUID]
    ) async throws -> MessengerConversationMutationResult {
        try await callFFI { client in
            let result = try client.removeConversationDevices(
                request: FfiMessengerUpdateConversationDevicesRequest(
                    conversationId: conversationId.uuidString,
                    deviceIds: deviceIds.map(\.uuidString)
                )
            )
            return try convertConversationMutationResult(result)
        }
    }

    func markRead(
        conversationId: UUID,
        throughMessageId: UUID?
    ) async throws -> LocalChatReadState {
        try await callFFI { client in
            try LocalChatReadState(
                ffiMessengerValue: client.markRead(
                    conversationId: conversationId.uuidString,
                    throughMessageId: throughMessageId?.uuidString
                )
            )
        }
    }

    func getAttachment(attachmentRef: String) async throws -> MessengerAttachmentFile {
        try await callFFI { client in
            let file = try client.getAttachment(attachmentRef: attachmentRef)
            return MessengerAttachmentFile(
                attachmentRef: file.attachmentRef,
                localURL: URL(fileURLWithPath: file.localPath),
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes,
                fileName: file.fileName,
                widthPx: file.widthPx,
                heightPx: file.heightPx
            )
        }
    }

    func setTyping(conversationId: UUID, isTyping: Bool) async throws {
        try await callFFI { client in
            try client.setTyping(
                conversationId: conversationId.uuidString,
                isTyping: isTyping
            )
        }
    }

    func createLinkDeviceIntent() async throws -> MessengerDeviceLinkIntent {
        try await callFFI { client in
            let intent = try client.createLinkDeviceIntent()
            return try MessengerDeviceLinkIntent(
                linkIntentId: TrixCoreCodec.uuid(intent.linkIntentId, label: "link_intent_id"),
                payload: intent.payload,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(intent.expiresAtUnix))
            )
        }
    }

    func completeLinkDevice(
        linkPayload: String,
        deviceDisplayName: String
    ) async throws -> MessengerPendingDeviceResult {
        try await callFFI { client in
            let result = try client.completeLinkDevice(
                linkPayload: linkPayload,
                deviceDisplayName: deviceDisplayName
            )
            return try MessengerPendingDeviceResult(
                accountId: TrixCoreCodec.uuid(result.accountId, label: "account_id"),
                deviceId: TrixCoreCodec.uuid(result.deviceId, label: "device_id"),
                deviceStatus: DeviceStatus(result.deviceStatus)
            )
        }
    }

    func approveLinkedDevice(deviceId: UUID) async throws -> MessengerDeviceMutationResult {
        try await callFFI { client in
            try convertDeviceMutationResult(
                client.approveLinkedDevice(deviceId: deviceId.uuidString)
            )
        }
    }

    func revokeDevice(
        deviceId: UUID,
        reason: String? = nil
    ) async throws -> MessengerDeviceMutationResult {
        try await callFFI { client in
            try convertDeviceMutationResult(
                client.revokeDevice(
                    request: FfiMessengerRevokeDeviceRequest(
                        deviceId: deviceId.uuidString,
                        reason: reason
                    )
                )
            )
        }
    }

    private func callFFI<Response: Sendable>(
        _ operation: @escaping @Sendable (FfiMessengerClient) throws -> Response
    ) async throws -> Response {
        let configuration = self.configuration

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try operation(try Self.makeFFIClient(configuration: configuration))
                    )
                } catch let error as TrixAPIError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: Self.mapFFIError(error))
                }
            }
        }
    }

    private func convertConversationMutationResult(
        _ result: FfiMessengerConversationMutationResult
    ) throws -> MessengerConversationMutationResult {
        try MessengerConversationMutationResult(
            conversationId: TrixCoreCodec.uuid(result.conversationId, label: "conversation_id"),
            conversation: result.conversation.map { try LocalChatListItem(ffiMessengerValue: $0) },
            messages: result.messages.map { try LocalTimelineItem(ffiMessengerValue: $0) },
            changedParticipantAccountIDs: try result.changedAccountIds.map {
                try TrixCoreCodec.uuid($0, label: "participant_account_id")
            },
            changedDeviceIDs: try result.changedDeviceIds.map {
                try TrixCoreCodec.uuid($0, label: "device_id")
            }
        )
    }

    private func convertDeviceMutationResult(
        _ result: FfiMessengerDeviceMutationResult
    ) throws -> MessengerDeviceMutationResult {
        try MessengerDeviceMutationResult(
            accountId: try result.accountId.map {
                try TrixCoreCodec.uuid($0, label: "account_id")
            },
            deviceId: TrixCoreCodec.uuid(result.deviceId, label: "device_id"),
            deviceStatus: DeviceStatus(result.deviceStatus),
            devices: result.devices.map { try DeviceSummary(ffiMessengerValue: $0) }
        )
    }

    private static func makeFFIClient(configuration: Configuration) throws -> FfiMessengerClient {
        let rootURL = URL(fileURLWithPath: configuration.rootPath, isDirectory: true)
        try prepareWorkspaceMigrationIfNeeded(workspaceRoot: rootURL)
        return try FfiMessengerClient.open(
            config: FfiMessengerOpenConfig(
                rootPath: configuration.rootPath,
                databaseKey: configuration.databaseKey,
                baseUrl: configuration.baseURL,
                accessToken: configuration.accessToken,
                accountId: configuration.accountId?.uuidString,
                deviceId: configuration.deviceId?.uuidString,
                accountSyncChatId: configuration.accountSyncChatId?.uuidString,
                deviceDisplayName: configuration.deviceDisplayName,
                platform: configuration.platform,
                credentialIdentity: configuration.credentialIdentity,
                accountRootPrivateKey: configuration.accountRootPrivateKey,
                transportPrivateKey: configuration.transportPrivateKey
            )
        )
    }

    private static func prepareWorkspaceMigrationIfNeeded(workspaceRoot: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        let safeDatabasePath = workspaceRoot.appendingPathComponent("client-store.sqlite")
        if !fileManager.fileExists(atPath: safeDatabasePath.path) {
            let candidateSources = [
                workspaceRoot.appendingPathComponent("state-v1.db"),
                workspaceRoot.appendingPathComponent("trix-client.db"),
            ]
            for source in candidateSources where fileManager.fileExists(atPath: source.path) {
                try copyItemIfNeeded(from: source, to: safeDatabasePath)
                try copySQLiteSidecarIfNeeded(from: source, to: safeDatabasePath, suffix: "-shm")
                try copySQLiteSidecarIfNeeded(from: source, to: safeDatabasePath, suffix: "-wal")
                break
            }
        }

        let safeMlsRoot = workspaceRoot.appendingPathComponent("mls", isDirectory: true)
        let legacyMlsRoot = workspaceRoot.appendingPathComponent("mls-state", isDirectory: true)
        if !fileManager.fileExists(atPath: safeMlsRoot.path),
           fileManager.fileExists(atPath: legacyMlsRoot.path) {
            try copyItemIfNeeded(from: legacyMlsRoot, to: safeMlsRoot)
        }
    }

    private static func copyItemIfNeeded(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: destination.path)
        else {
            return
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func copySQLiteSidecarIfNeeded(
        from source: URL,
        to destination: URL,
        suffix: String
    ) throws {
        try copyItemIfNeeded(
            from: URL(fileURLWithPath: source.path + suffix),
            to: URL(fileURLWithPath: destination.path + suffix)
        )
    }

    private static func mapFFIError(_ error: Error) -> TrixAPIError {
        if let error = error as? TrixAPIError {
            return error
        }
        if let ffiError = error as? FfiMessengerError {
            let message: String = switch ffiError {
            case let .Message(message):
                message
            case let .RequiresResync(message):
                message
            case let .AttachmentExpired(message):
                message
            case let .AttachmentInvalid(message):
                message
            case let .DeviceNotApprovable(message):
                message
            case let .NotConfigured(message):
                message
            }
            if let serverError = parseServerError(message) {
                return serverError
            }
            return .invalidPayload(message)
        }
        return .transport(error)
    }

    private static func parseServerError(_ message: String) -> TrixAPIError? {
        let prefix = "api error "
        guard message.hasPrefix(prefix) else {
            return nil
        }

        let remainder = message.dropFirst(prefix.count)
        guard let firstColon = remainder.firstIndex(of: ":") else {
            return nil
        }
        let statusPart = remainder[..<firstColon].trimmingCharacters(in: .whitespaces)
        guard let statusCode = Int(statusPart) else {
            return nil
        }

        let afterStatus = remainder[remainder.index(after: firstColon)...]
            .trimmingCharacters(in: .whitespaces)
        guard let secondColon = afterStatus.firstIndex(of: ":") else {
            return nil
        }

        let code = afterStatus[..<secondColon].trimmingCharacters(in: .whitespaces)
        let serverMessage = afterStatus[afterStatus.index(after: secondColon)...]
            .trimmingCharacters(in: .whitespaces)

        return .server(
            code: String(code),
            message: String(serverMessage),
            statusCode: statusCode
        )
    }
}

private struct MessengerWorkspaceDatabaseKeyStore {
    private let keychainStore = KeychainStore()

    func getOrCreate(workspaceRoot: URL) throws -> Data {
        let account = "workspace-core-store-key-v1:\(workspaceRoot.lastPathComponent.lowercased())"
        if let existing = try keychainStore.loadData(account: account) {
            return existing
        }

        let generated = try randomDatabaseKey()
        try keychainStore.save(generated, account: account)
        return generated
    }

    private func randomDatabaseKey(count: Int = 32) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
        return bytes
    }
}
