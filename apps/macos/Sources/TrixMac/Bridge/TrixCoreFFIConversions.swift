import Foundation

extension DeviceStatus {
    init(_ ffiValue: FfiDeviceStatus) {
        switch ffiValue {
        case .pending:
            self = .pending
        case .active:
            self = .active
        case .revoked:
            self = .revoked
        }
    }
}

extension ChatType {
    init(_ ffiValue: FfiChatType) {
        switch ffiValue {
        case .dm:
            self = .dm
        case .group:
            self = .group
        case .accountSync:
            self = .accountSync
        }
    }

    var ffiValue: FfiChatType {
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

extension MessageKind {
    init(_ ffiValue: FfiMessageKind) {
        switch ffiValue {
        case .application:
            self = .application
        case .commit:
            self = .commit
        case .welcomeRef:
            self = .welcomeRef
        case .system:
            self = .system
        }
    }
}

extension ContentType {
    init(_ ffiValue: FfiContentType) {
        switch ffiValue {
        case .text:
            self = .text
        case .reaction:
            self = .reaction
        case .receipt:
            self = .receipt
        case .attachment:
            self = .attachment
        case .chatEvent:
            self = .chatEvent
        }
    }

    var ffiValue: FfiContentType {
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

extension LocalProjectionKind {
    init(_ ffiValue: FfiLocalProjectionKind) {
        switch ffiValue {
        case .applicationMessage:
            self = .applicationMessage
        case .proposalQueued:
            self = .proposalQueued
        case .commitMerged:
            self = .commitMerged
        case .welcomeRef:
            self = .welcomeRef
        case .system:
            self = .system
        }
    }
}

extension TypedMessageBodyKind {
    init(_ ffiValue: FfiMessageBodyKind) {
        switch ffiValue {
        case .text:
            self = .text
        case .reaction:
            self = .reaction
        case .receipt:
            self = .receipt
        case .attachment:
            self = .attachment
        case .chatEvent:
            self = .chatEvent
        }
    }

    var ffiValue: FfiMessageBodyKind {
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

    init(_ ffiValue: FfiMessengerMessageBodyKind) {
        switch ffiValue {
        case .text:
            self = .text
        case .reaction:
            self = .reaction
        case .receipt:
            self = .receipt
        case .attachment:
            self = .attachment
        case .chatEvent:
            self = .chatEvent
        }
    }

    var ffiMessengerValue: FfiMessengerMessageBodyKind {
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

extension ReactionAction {
    init(_ ffiValue: FfiReactionAction) {
        switch ffiValue {
        case .add:
            self = .add
        case .remove:
            self = .remove
        }
    }

    var ffiValue: FfiReactionAction {
        switch self {
        case .add:
            return .add
        case .remove:
            return .remove
        }
    }
}

extension ReceiptType {
    init(_ ffiValue: FfiReceiptType) {
        switch ffiValue {
        case .delivered:
            self = .delivered
        case .read:
            self = .read
        }
    }

    var ffiValue: FfiReceiptType {
        switch self {
        case .delivered:
            return .delivered
        case .read:
            return .read
        }
    }
}

extension BlobUploadStatus {
    init(_ ffiValue: FfiBlobUploadStatus) {
        switch ffiValue {
        case .pendingUpload:
            self = .pending
        case .available:
            self = .uploaded
        }
    }
}

extension HistorySyncJobType {
    init(_ ffiValue: FfiHistorySyncJobType) {
        switch ffiValue {
        case .initialSync:
            self = .initialSync
        case .chatBackfill:
            self = .chatBackfill
        case .deviceRekey:
            self = .deviceRekey
        case .timelineRepair:
            self = .timelineRepair
        }
    }
}

extension HistorySyncJobStatus {
    init(_ ffiValue: FfiHistorySyncJobStatus) {
        switch ffiValue {
        case .pending:
            self = .pending
        case .running:
            self = .running
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .canceled:
            self = .canceled
        }
    }

    var ffiValue: FfiHistorySyncJobStatus {
        switch self {
        case .pending:
            return .pending
        case .running:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .canceled:
            return .canceled
        }
    }
}

extension HistorySyncJobRole {
    var ffiValue: FfiHistorySyncJobRole {
        switch self {
        case .source:
            return .source
        case .target:
            return .target
        }
    }
}

extension CreateAccountRequest {
    func ffiParams() throws -> FfiCreateAccountParams {
        FfiCreateAccountParams(
            handle: handle,
            profileName: profileName,
            profileBio: profileBio,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentity: try TrixCoreCodec.decodeBase64(credentialIdentityB64, label: "credential_identity_b64"),
            accountRootPubkey: try TrixCoreCodec.decodeBase64(accountRootPubkeyB64, label: "account_root_pubkey_b64"),
            accountRootSignature: try TrixCoreCodec.decodeBase64(accountRootSignatureB64, label: "account_root_signature_b64"),
            transportPubkey: try TrixCoreCodec.decodeBase64(transportPubkeyB64, label: "transport_pubkey_b64")
        )
    }
}

extension PublishKeyPackageItem {
    func ffiValue() throws -> FfiPublishKeyPackage {
        FfiPublishKeyPackage(
            cipherSuite: cipherSuite,
            keyPackage: try TrixCoreCodec.decodeBase64(keyPackageB64, label: "key_package_b64")
        )
    }
}

extension CompleteLinkIntentRequest {
    func ffiParams() throws -> FfiCompleteLinkIntentParams {
        FfiCompleteLinkIntentParams(
            linkToken: linkToken,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentity: try TrixCoreCodec.decodeBase64(credentialIdentityB64, label: "credential_identity_b64"),
            transportPubkey: try TrixCoreCodec.decodeBase64(transportPubkeyB64, label: "transport_pubkey_b64"),
            keyPackages: try keyPackages.map { try $0.ffiValue() }
        )
    }
}

extension CompleteHistorySyncJobRequest {
    func ffiCursorJSONString() throws -> String? {
        try TrixCoreCodec.encodeJSONString(cursorJson)
    }
}

extension TypedMessageBody {
    init(ffiValue: FfiMessageBody) throws {
        self.init(
            kind: TypedMessageBodyKind(ffiValue.kind),
            text: ffiValue.text,
            targetMessageId: try ffiValue.targetMessageId.map {
                try TrixCoreCodec.uuid($0, label: "target_message_id")
            },
            emoji: ffiValue.emoji,
            reactionAction: ffiValue.reactionAction.map(ReactionAction.init),
            receiptType: ffiValue.receiptType.map(ReceiptType.init),
            receiptAtUnix: ffiValue.receiptAtUnix,
            attachmentRef: nil,
            blobId: ffiValue.blobId,
            mimeType: ffiValue.mimeType,
            sizeBytes: ffiValue.sizeBytes,
            sha256: ffiValue.sha256,
            fileName: ffiValue.fileName,
            widthPx: ffiValue.widthPx,
            heightPx: ffiValue.heightPx,
            fileKey: ffiValue.fileKey,
            nonce: ffiValue.nonce,
            eventType: ffiValue.eventType,
            eventJson: ffiValue.eventJson
        )
    }

    func ffiValue() -> FfiMessageBody {
        FfiMessageBody(
            kind: kind.ffiValue,
            text: text,
            targetMessageId: targetMessageId?.uuidString,
            emoji: emoji,
            reactionAction: reactionAction?.ffiValue,
            receiptType: receiptType?.ffiValue,
            receiptAtUnix: receiptAtUnix,
            blobId: blobId,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            sha256: sha256,
            fileName: fileName,
            widthPx: widthPx,
            heightPx: heightPx,
            fileKey: fileKey,
            nonce: nonce,
            eventType: eventType,
            eventJson: eventJson
        )
    }

    init(ffiMessengerValue: FfiMessengerMessageBody) throws {
        let attachment = ffiMessengerValue.attachment
        self.init(
            kind: TypedMessageBodyKind(ffiMessengerValue.kind),
            text: ffiMessengerValue.text,
            targetMessageId: try ffiMessengerValue.targetMessageId.map {
                try TrixCoreCodec.uuid($0, label: "target_message_id")
            },
            emoji: ffiMessengerValue.emoji,
            reactionAction: ffiMessengerValue.reactionAction.map(ReactionAction.init),
            receiptType: ffiMessengerValue.receiptType.map(ReceiptType.init),
            receiptAtUnix: ffiMessengerValue.receiptAtUnix,
            attachmentRef: attachment?.attachmentRef,
            blobId: nil,
            mimeType: attachment?.mimeType,
            sizeBytes: attachment?.sizeBytes,
            sha256: nil,
            fileName: attachment?.fileName,
            widthPx: attachment?.widthPx,
            heightPx: attachment?.heightPx,
            fileKey: nil,
            nonce: nil,
            eventType: ffiMessengerValue.eventType,
            eventJson: ffiMessengerValue.eventJson
        )
    }

    func ffiMessengerSendRequest(
        conversationId: UUID,
        messageId: UUID? = nil,
        attachmentTokens: [String] = []
    ) -> FfiMessengerSendMessageRequest {
        FfiMessengerSendMessageRequest(
            conversationId: conversationId.uuidString,
            messageId: messageId?.uuidString,
            kind: kind.ffiMessengerValue,
            text: text,
            targetMessageId: targetMessageId?.uuidString,
            emoji: emoji,
            reactionAction: reactionAction?.ffiValue,
            receiptType: receiptType?.ffiValue,
            receiptAtUnix: receiptAtUnix,
            eventType: eventType,
            eventJson: eventJson,
            attachmentTokens: attachmentTokens
        )
    }
}

extension MessageReactionSummary {
    init(ffiValue: FfiMessageReactionSummary) throws {
        self.init(
            emoji: ffiValue.emoji,
            reactorAccountIds: try ffiValue.reactorAccountIds.map {
                try TrixCoreCodec.uuid($0, label: "reactor_account_id")
            },
            count: ffiValue.count,
            includesSelf: ffiValue.includesSelf
        )
    }
}

extension HealthResponse {
    init(ffiValue: FfiHealthResponse) {
        let status: ServiceStatus
        switch ffiValue.status {
        case .ok:
            status = .ok
        case .degraded:
            status = .degraded
        }

        self.init(
            service: ffiValue.service,
            status: status,
            version: ffiValue.version,
            uptimeMs: ffiValue.uptimeMs
        )
    }
}

extension VersionResponse {
    init(ffiValue: FfiVersionResponse) {
        self.init(
            service: ffiValue.service,
            version: ffiValue.version,
            gitSha: ffiValue.gitSha
        )
    }
}

extension CreateAccountResponse {
    init(ffiValue: FfiCreateAccountResponse) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            accountSyncChatId: try TrixCoreCodec.uuid(ffiValue.accountSyncChatId, label: "account_sync_chat_id")
        )
    }
}

extension AuthChallengeResponse {
    init(ffiValue: FfiAuthChallenge) {
        self.init(
            challengeId: ffiValue.challengeId,
            challengeB64: ffiValue.challenge.base64EncodedString(),
            expiresAtUnix: ffiValue.expiresAtUnix
        )
    }
}

extension AuthSessionResponse {
    init(ffiValue: FfiAuthSession) throws {
        self.init(
            accessToken: ffiValue.accessToken,
            expiresAtUnix: ffiValue.expiresAtUnix,
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            deviceStatus: DeviceStatus(ffiValue.deviceStatus)
        )
    }
}

extension AccountProfileResponse {
    init(ffiValue: FfiAccountProfile) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            handle: ffiValue.handle,
            profileName: ffiValue.profileName,
            profileBio: ffiValue.profileBio,
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            deviceStatus: DeviceStatus(ffiValue.deviceStatus)
        )
    }
}

extension DirectoryAccountSummary {
    init(ffiValue: FfiDirectoryAccount) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            handle: ffiValue.handle,
            profileName: ffiValue.profileName,
            profileBio: ffiValue.profileBio
        )
    }
}

extension AccountDirectoryResponse {
    init(ffiValue: FfiAccountDirectory) throws {
        self.init(accounts: try ffiValue.accounts.map { try DirectoryAccountSummary(ffiValue: $0) })
    }
}

extension UpdateAccountProfileRequest {
    func ffiParams() -> FfiUpdateAccountProfileParams {
        FfiUpdateAccountProfileParams(
            handle: handle,
            profileName: profileName,
            profileBio: profileBio
        )
    }
}

extension DeviceSummary {
    init(ffiValue: FfiDeviceSummary) throws {
        self.init(
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            displayName: ffiValue.displayName,
            platform: ffiValue.platform,
            deviceStatus: DeviceStatus(ffiValue.deviceStatus),
            availableKeyPackageCount: ffiValue.availableKeyPackageCount
        )
    }
}

extension DeviceListResponse {
    init(ffiValue: FfiDeviceList) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            devices: try ffiValue.devices.map { try DeviceSummary(ffiValue: $0) }
        )
    }
}

extension CreateLinkIntentResponse {
    init(ffiValue: FfiCreateLinkIntentResponse) throws {
        self.init(
            linkIntentId: try TrixCoreCodec.uuid(ffiValue.linkIntentId, label: "link_intent_id"),
            qrPayload: ffiValue.qrPayload,
            expiresAtUnix: ffiValue.expiresAtUnix
        )
    }
}

extension CompleteLinkIntentResponse {
    init(ffiValue: FfiCompletedLinkIntent) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            pendingDeviceId: try TrixCoreCodec.uuid(ffiValue.pendingDeviceId, label: "pending_device_id"),
            deviceStatus: DeviceStatus(ffiValue.deviceStatus),
            bootstrapPayloadB64: ffiValue.bootstrapPayload.base64EncodedString()
        )
    }
}

extension DeviceApprovePayloadResponse {
    init(ffiValue: FfiDeviceApprovePayload) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            deviceDisplayName: ffiValue.deviceDisplayName,
            platform: ffiValue.platform,
            deviceStatus: DeviceStatus(ffiValue.deviceStatus),
            credentialIdentityB64: ffiValue.credentialIdentity.base64EncodedString(),
            transportPubkeyB64: ffiValue.transportPubkey.base64EncodedString(),
            bootstrapPayloadB64: ffiValue.bootstrapPayload.base64EncodedString()
        )
    }
}

extension ApproveDeviceResponse {
    init(ffiValue: FfiApproveDeviceResponse) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            deviceStatus: DeviceStatus(ffiValue.deviceStatus)
        )
    }
}

extension RevokeDeviceResponse {
    init(ffiValue: FfiRevokeDeviceResponse) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            deviceStatus: DeviceStatus(ffiValue.deviceStatus)
        )
    }
}

extension PublishedKeyPackage {
    init(ffiValue: FfiPublishedKeyPackage) {
        self.init(
            keyPackageId: ffiValue.keyPackageId,
            cipherSuite: ffiValue.cipherSuite
        )
    }
}

extension PublishKeyPackagesResponse {
    init(ffiValue: FfiPublishKeyPackagesResponse) throws {
        self.init(
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            packages: ffiValue.packages.map(PublishedKeyPackage.init(ffiValue:))
        )
    }
}

extension ReservedKeyPackage {
    init(ffiValue: FfiReservedKeyPackage) throws {
        self.init(
            keyPackageId: ffiValue.keyPackageId,
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            cipherSuite: ffiValue.cipherSuite,
            keyPackageB64: ffiValue.keyPackage.base64EncodedString()
        )
    }
}

extension AccountKeyPackagesResponse {
    init(accountId: String, packages: [FfiReservedKeyPackage]) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(accountId, label: "account_id"),
            packages: try packages.map { try ReservedKeyPackage(ffiValue: $0) }
        )
    }
}

extension ChatParticipantProfileSummary {
    init(ffiValue: FfiChatParticipantProfile) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            handle: ffiValue.handle,
            profileName: ffiValue.profileName,
            profileBio: ffiValue.profileBio
        )
    }
}

extension LocalChatListItem {
    init(ffiValue: FfiLocalChatListItem) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            chatType: ChatType(ffiValue.chatType),
            title: ffiValue.title,
            displayTitle: ffiValue.displayTitle,
            lastServerSeq: ffiValue.lastServerSeq,
            epoch: ffiValue.epoch,
            pendingMessageCount: ffiValue.pendingMessageCount,
            unreadCount: ffiValue.unreadCount,
            previewText: ffiValue.previewText,
            previewSenderAccountId: try ffiValue.previewSenderAccountId.map {
                try TrixCoreCodec.uuid($0, label: "preview_sender_account_id")
            },
            previewSenderDisplayName: ffiValue.previewSenderDisplayName,
            previewIsOutgoing: ffiValue.previewIsOutgoing,
            previewServerSeq: ffiValue.previewServerSeq,
            previewCreatedAtUnix: ffiValue.previewCreatedAtUnix,
            participantProfiles: try ffiValue.participantProfiles.map {
                try ChatParticipantProfileSummary(ffiValue: $0)
            }
        )
    }
}

extension LocalChatReadState {
    init(ffiValue: FfiLocalChatReadState) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            readCursorServerSeq: ffiValue.readCursorServerSeq,
            unreadCount: ffiValue.unreadCount
        )
    }
}

extension ChatDeviceSummary {
    init(ffiValue: FfiChatDeviceMember) throws {
        self.init(
            deviceId: try TrixCoreCodec.uuid(ffiValue.deviceId, label: "device_id"),
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            displayName: ffiValue.displayName,
            platform: ffiValue.platform,
            leafIndex: ffiValue.leafIndex,
            credentialIdentityB64: ffiValue.credentialIdentity.base64EncodedString()
        )
    }
}

extension ChatSummary {
    init(ffiValue: FfiChatSummary) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            chatType: ChatType(ffiValue.chatType),
            title: ffiValue.title,
            lastServerSeq: ffiValue.lastServerSeq,
            epoch: ffiValue.epoch,
            pendingMessageCount: ffiValue.pendingMessageCount,
            lastMessage: try ffiValue.lastMessage.map { try MessageEnvelope(ffiValue: $0) },
            participantProfiles: try ffiValue.participantProfiles.map { try ChatParticipantProfileSummary(ffiValue: $0) }
        )
    }
}

extension ControlMessageInput {
    func ffiValue() throws -> FfiControlMessage {
        FfiControlMessage(
            messageId: messageId.uuidString,
            ciphertext: try TrixCoreCodec.decodeBase64(ciphertextB64, label: "ciphertext_b64"),
            aadJson: try TrixCoreCodec.encodeJSONString(aadJson)
        )
    }
}

extension CreateChatRequest {
    func ffiValue() throws -> FfiCreateChatParams {
        FfiCreateChatParams(
            chatType: chatType.ffiValue,
            title: title,
            participantAccountIds: participantAccountIds.map(\.uuidString),
            reservedKeyPackageIds: reservedKeyPackageIds,
            initialCommit: try initialCommit?.ffiValue(),
            welcomeMessage: try welcomeMessage?.ffiValue()
        )
    }
}

extension CreateChatResponse {
    init(ffiValue: FfiCreateChatResponse) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            chatType: ChatType(ffiValue.chatType),
            epoch: ffiValue.epoch
        )
    }
}

extension CreateChatControlOutcome {
    init(ffiValue: FfiCreateChatControlOutcome) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            chatType: ChatType(ffiValue.chatType),
            epoch: ffiValue.epoch,
            mlsGroupId: ffiValue.mlsGroupId,
            report: try LocalStoreApplyReport(ffiValue: ffiValue.report),
            projectedMessages: try ffiValue.projectedMessages.map { try LocalProjectedMessage(ffiValue: $0) }
        )
    }
}

extension ChatListResponse {
    init(ffiValues: [FfiChatSummary]) throws {
        self.init(chats: try ffiValues.map { try ChatSummary(ffiValue: $0) })
    }
}

extension ChatMemberSummary {
    init(ffiValue: FfiChatMember) throws {
        self.init(
            accountId: try TrixCoreCodec.uuid(ffiValue.accountId, label: "account_id"),
            role: ffiValue.role,
            membershipStatus: ffiValue.membershipStatus
        )
    }
}

extension ChatDetailResponse {
    init(ffiValue: FfiChatDetail) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            chatType: ChatType(ffiValue.chatType),
            title: ffiValue.title,
            lastServerSeq: ffiValue.lastServerSeq,
            pendingMessageCount: ffiValue.pendingMessageCount,
            epoch: ffiValue.epoch,
            lastCommitMessageId: try ffiValue.lastCommitMessageId.map {
                try TrixCoreCodec.uuid($0, label: "last_commit_message_id")
            },
            lastMessage: try ffiValue.lastMessage.map { try MessageEnvelope(ffiValue: $0) },
            participantProfiles: try ffiValue.participantProfiles.map { try ChatParticipantProfileSummary(ffiValue: $0) },
            members: try ffiValue.members.map { try ChatMemberSummary(ffiValue: $0) },
            deviceMembers: try ffiValue.deviceMembers.map { try ChatDeviceSummary(ffiValue: $0) }
        )
    }
}

extension MessageEnvelope {
    init(ffiValue: FfiMessageEnvelope) throws {
        self.init(
            messageId: try TrixCoreCodec.uuid(ffiValue.messageId, label: "message_id"),
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            serverSeq: ffiValue.serverSeq,
            senderAccountId: try TrixCoreCodec.uuid(ffiValue.senderAccountId, label: "sender_account_id"),
            senderDeviceId: try TrixCoreCodec.uuid(ffiValue.senderDeviceId, label: "sender_device_id"),
            epoch: ffiValue.epoch,
            messageKind: MessageKind(ffiValue.messageKind),
            contentType: ContentType(ffiValue.contentType),
            ciphertextB64: ffiValue.ciphertext.base64EncodedString(),
            aadJson: try TrixCoreCodec.decodeJSONObjectAllowingNull(ffiValue.aadJson, label: "aad_json"),
            createdAtUnix: ffiValue.createdAtUnix
        )
    }
}

extension ChatHistoryResponse {
    init(ffiValue: FfiChatHistory) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            messages: try ffiValue.messages.map { try MessageEnvelope(ffiValue: $0) }
        )
    }
}

extension HistorySyncJobSummary {
    init(ffiValue: FfiHistorySyncJob, role: HistorySyncJobRole) throws {
        self.init(
            jobId: try TrixCoreCodec.uuid(ffiValue.jobId, label: "job_id"),
            role: role,
            jobType: HistorySyncJobType(ffiValue.jobType),
            jobStatus: HistorySyncJobStatus(ffiValue.jobStatus),
            sourceDeviceId: try TrixCoreCodec.uuid(ffiValue.sourceDeviceId, label: "source_device_id"),
            targetDeviceId: try TrixCoreCodec.uuid(ffiValue.targetDeviceId, label: "target_device_id"),
            chatId: try ffiValue.chatId.map { try TrixCoreCodec.uuid($0, label: "chat_id") },
            cursorJson: try TrixCoreCodec.decodeOptionalJSONValue(ffiValue.cursorJson, label: "cursor_json"),
            createdAtUnix: ffiValue.createdAtUnix,
            updatedAtUnix: ffiValue.updatedAtUnix
        )
    }
}

extension HistorySyncJobListResponse {
    init(ffiValues: [FfiHistorySyncJob], role: HistorySyncJobRole) throws {
        self.init(jobs: try ffiValues.map { try HistorySyncJobSummary(ffiValue: $0, role: role) })
    }
}

extension LocalProjectedMessage {
    init(ffiValue: FfiLocalProjectedMessage) throws {
        self.init(
            serverSeq: ffiValue.serverSeq,
            messageId: try TrixCoreCodec.uuid(ffiValue.messageId, label: "message_id"),
            senderAccountId: try TrixCoreCodec.uuid(ffiValue.senderAccountId, label: "sender_account_id"),
            senderDeviceId: try TrixCoreCodec.uuid(ffiValue.senderDeviceId, label: "sender_device_id"),
            epoch: ffiValue.epoch,
            messageKind: MessageKind(ffiValue.messageKind),
            contentType: ContentType(ffiValue.contentType),
            projectionKind: LocalProjectionKind(ffiValue.projectionKind),
            payloadB64: ffiValue.payload?.base64EncodedString(),
            body: try ffiValue.body.map { try TypedMessageBody(ffiValue: $0) },
            bodyParseError: ffiValue.bodyParseError,
            mergedEpoch: ffiValue.mergedEpoch,
            createdAtUnix: ffiValue.createdAtUnix
        )
    }
}

extension LocalTimelineItem {
    init(ffiValue: FfiLocalTimelineItem) throws {
        self.init(
            serverSeq: ffiValue.serverSeq,
            messageId: try TrixCoreCodec.uuid(ffiValue.messageId, label: "message_id"),
            senderAccountId: try TrixCoreCodec.uuid(ffiValue.senderAccountId, label: "sender_account_id"),
            senderDeviceId: try TrixCoreCodec.uuid(ffiValue.senderDeviceId, label: "sender_device_id"),
            senderDisplayName: ffiValue.senderDisplayName,
            isOutgoing: ffiValue.isOutgoing,
            epoch: ffiValue.epoch,
            messageKind: MessageKind(ffiValue.messageKind),
            contentType: ContentType(ffiValue.contentType),
            projectionKind: LocalProjectionKind(ffiValue.projectionKind),
            body: try ffiValue.body.map { try TypedMessageBody(ffiValue: $0) },
            bodyParseError: ffiValue.bodyParseError,
            previewText: ffiValue.previewText,
            receiptStatus: ffiValue.receiptStatus.map(ReceiptType.init),
            reactions: try ffiValue.reactions.map(MessageReactionSummary.init),
            isVisibleInTimeline: ffiValue.isVisibleInTimeline,
            mergedEpoch: ffiValue.mergedEpoch,
            createdAtUnix: ffiValue.createdAtUnix
        )
    }

    init(ffiMessengerValue: FfiMessengerMessageRecord) throws {
        let resolvedBody = try ffiMessengerValue.body.map { try TypedMessageBody(ffiMessengerValue: $0) }
        let resolvedContentType = ContentType(ffiMessengerValue.contentType)
        let resolvedMessageKind: MessageKind = resolvedContentType == .chatEvent ? .system : .application
        let resolvedProjectionKind: LocalProjectionKind =
            resolvedContentType == .chatEvent ? .system : .applicationMessage

        let resolvedSenderDisplayName: String = {
            if let senderDisplayName = ffiMessengerValue.senderDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !senderDisplayName.isEmpty {
                return senderDisplayName
            }
            return String(ffiMessengerValue.senderAccountId.prefix(8)).lowercased()
        }()

        self.init(
            serverSeq: ffiMessengerValue.serverSeq,
            messageId: try TrixCoreCodec.uuid(ffiMessengerValue.messageId, label: "message_id"),
            senderAccountId: try TrixCoreCodec.uuid(
                ffiMessengerValue.senderAccountId,
                label: "sender_account_id"
            ),
            senderDeviceId: try TrixCoreCodec.uuid(
                ffiMessengerValue.senderDeviceId,
                label: "sender_device_id"
            ),
            senderDisplayName: resolvedSenderDisplayName,
            isOutgoing: ffiMessengerValue.isOutgoing,
            epoch: ffiMessengerValue.epoch,
            messageKind: resolvedMessageKind,
            contentType: resolvedContentType,
            projectionKind: resolvedProjectionKind,
            body: resolvedBody,
            bodyParseError: nil,
            previewText: ffiMessengerValue.previewText,
            receiptStatus: ffiMessengerValue.receiptStatus.map(ReceiptType.init),
            reactions: try ffiMessengerValue.reactions.map(MessageReactionSummary.init),
            isVisibleInTimeline: ffiMessengerValue.isVisibleInTimeline,
            mergedEpoch: nil,
            createdAtUnix: ffiMessengerValue.createdAtUnix
        )
    }
}

extension LocalChatListItem {
    init(ffiMessengerValue: FfiMessengerConversationSummary) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiMessengerValue.conversationId, label: "conversation_id"),
            chatType: ChatType(ffiMessengerValue.conversationType),
            title: ffiMessengerValue.title,
            displayTitle: ffiMessengerValue.displayTitle,
            lastServerSeq: ffiMessengerValue.lastServerSeq,
            epoch: ffiMessengerValue.epoch,
            pendingMessageCount: ffiMessengerValue.pendingMessageCount,
            unreadCount: ffiMessengerValue.unreadCount,
            previewText: ffiMessengerValue.previewText,
            previewSenderAccountId: try ffiMessengerValue.previewSenderAccountId.map {
                try TrixCoreCodec.uuid($0, label: "preview_sender_account_id")
            },
            previewSenderDisplayName: ffiMessengerValue.previewSenderDisplayName,
            previewIsOutgoing: ffiMessengerValue.previewIsOutgoing,
            previewServerSeq: ffiMessengerValue.previewServerSeq,
            previewCreatedAtUnix: ffiMessengerValue.previewCreatedAtUnix,
            participantProfiles: try ffiMessengerValue.participantProfiles.map {
                try ChatParticipantProfileSummary(
                    accountId: TrixCoreCodec.uuid($0.accountId, label: "participant_account_id"),
                    handle: $0.handle,
                    profileName: $0.profileName,
                    profileBio: $0.profileBio
                )
            }
        )
    }
}

extension DeviceSummary {
    init(ffiMessengerValue: FfiMessengerDeviceRecord) throws {
        self.init(
            deviceId: try TrixCoreCodec.uuid(ffiMessengerValue.deviceId, label: "device_id"),
            displayName: ffiMessengerValue.displayName,
            platform: ffiMessengerValue.platform,
            deviceStatus: DeviceStatus(ffiMessengerValue.deviceStatus),
            availableKeyPackageCount: ffiMessengerValue.availableKeyPackageCount
        )
    }
}

extension LocalChatReadState {
    init(ffiMessengerValue: FfiMessengerReadStateResult) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiMessengerValue.conversationId, label: "conversation_id"),
            readCursorServerSeq: ffiMessengerValue.readCursorServerSeq,
            unreadCount: ffiMessengerValue.unreadCount
        )
    }
}

extension UploadedAttachment {
    init(ffiValue: FfiUploadedAttachment) throws {
        self.init(
            body: try TypedMessageBody(ffiValue: ffiValue.body),
            blobId: ffiValue.blobId,
            uploadStatus: BlobUploadStatus(ffiValue.uploadStatus),
            plaintextSizeBytes: ffiValue.plaintextSizeBytes,
            encryptedSizeBytes: ffiValue.encryptedSizeBytes,
            encryptedSha256: ffiValue.encryptedSha256
        )
    }
}

extension DownloadedAttachment {
    init(ffiValue: FfiDownloadedAttachment) throws {
        self.init(
            body: try TypedMessageBody(ffiValue: ffiValue.body),
            plaintext: ffiValue.plaintext
        )
    }
}

extension SendMessageOutcome {
    init(ffiValue: FfiSendMessageOutcome) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            messageId: try TrixCoreCodec.uuid(ffiValue.messageId, label: "message_id"),
            serverSeq: ffiValue.serverSeq,
            report: try LocalStoreApplyReport(ffiValue: ffiValue.report),
            projectedMessage: try LocalProjectedMessage(ffiValue: ffiValue.projectedMessage)
        )
    }
}

extension ModifyChatMembersControlOutcome {
    init(ffiValue: FfiModifyChatMembersControlOutcome) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            epoch: ffiValue.epoch,
            changedParticipantAccountIDs: try ffiValue.changedAccountIds.map {
                try TrixCoreCodec.uuid($0, label: "changed_participant_account_id")
            },
            report: try LocalStoreApplyReport(ffiValue: ffiValue.report),
            projectedMessages: try ffiValue.projectedMessages.map { try LocalProjectedMessage(ffiValue: $0) }
        )
    }
}

extension ModifyChatDevicesControlOutcome {
    init(ffiValue: FfiModifyChatDevicesControlOutcome) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            epoch: ffiValue.epoch,
            changedDeviceIDs: try ffiValue.changedDeviceIds.map {
                try TrixCoreCodec.uuid($0, label: "changed_device_id")
            },
            report: try LocalStoreApplyReport(ffiValue: ffiValue.report),
            projectedMessages: try ffiValue.projectedMessages.map { try LocalProjectedMessage(ffiValue: $0) }
        )
    }
}

extension LocalStoreApplyReport {
    init(ffiValue: FfiLocalStoreApplyReport) throws {
        self.init(
            chatsUpserted: try TrixCoreCodec.int(ffiValue.chatsUpserted, label: "chats_upserted"),
            messagesUpserted: try TrixCoreCodec.int(ffiValue.messagesUpserted, label: "messages_upserted"),
            changedChatIDs: try ffiValue.changedChatIds.map {
                try TrixCoreCodec.uuid($0, label: "changed_chat_id")
            }
        )
    }
}

extension SyncChatCursor {
    init(ffiValue: FfiSyncChatCursor) throws {
        self.init(
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            lastServerSeq: ffiValue.lastServerSeq
        )
    }
}

extension SyncStateSnapshot {
    init(ffiValue: FfiSyncStateSnapshot) throws {
        self.init(
            leaseOwner: ffiValue.leaseOwner,
            lastAckedInboxId: ffiValue.lastAckedInboxId,
            chatCursors: try ffiValue.chatCursors.map { try SyncChatCursor(ffiValue: $0) }
        )
    }
}

extension CompleteHistorySyncJobResponse {
    init(ffiValue: FfiCompleteHistorySyncJobResponse) throws {
        self.init(
            jobId: try TrixCoreCodec.uuid(ffiValue.jobId, label: "job_id"),
            jobStatus: HistorySyncJobStatus(ffiValue.jobStatus)
        )
    }
}

extension AppendHistorySyncChunkResponse {
    init(ffiValue: FfiAppendHistorySyncChunkResponse) throws {
        self.init(
            jobId: try TrixCoreCodec.uuid(ffiValue.jobId, label: "job_id"),
            chunkId: ffiValue.chunkId,
            jobStatus: HistorySyncJobStatus(ffiValue.jobStatus)
        )
    }
}

extension HistorySyncChunkSummary {
    init(ffiValue: FfiHistorySyncChunk) {
        self.init(
            chunkId: ffiValue.chunkId,
            sequenceNo: ffiValue.sequenceNo,
            payloadB64: ffiValue.payload.base64EncodedString(),
            cursorJson: try? TrixCoreCodec.decodeOptionalJSONValue(ffiValue.cursorJson ?? "null", label: "cursor_json"),
            isFinal: ffiValue.isFinal,
            uploadedAtUnix: ffiValue.uploadedAtUnix
        )
    }
}

extension OutboxStatus {
    init(_ ffiValue: FfiLocalOutboxStatus) {
        switch ffiValue {
        case .pending:
            self = .pending
        case .failed:
            self = .failed
        }
    }
}

extension LocalOutboxItem {
    init(ffiValue: FfiLocalOutboxItem) throws {
        self.init(
            messageId: try TrixCoreCodec.uuid(ffiValue.messageId, label: "message_id"),
            chatId: try TrixCoreCodec.uuid(ffiValue.chatId, label: "chat_id"),
            senderAccountId: try TrixCoreCodec.uuid(ffiValue.senderAccountId, label: "sender_account_id"),
            senderDeviceId: try TrixCoreCodec.uuid(ffiValue.senderDeviceId, label: "sender_device_id"),
            body: try ffiValue.body.map { try TypedMessageBody(ffiValue: $0) },
            queuedAtUnix: ffiValue.queuedAtUnix,
            status: OutboxStatus(ffiValue.status),
            failureMessage: ffiValue.failureMessage
        )
    }
}

enum TrixCoreCodec {
    static func uuid(_ rawValue: String, label: String) throws -> UUID {
        guard let value = UUID(uuidString: rawValue) else {
            throw TrixAPIError.invalidPayload("FFI returned invalid \(label).")
        }

        return value
    }

    static func decodeBase64(_ rawValue: String, label: String) throws -> Data {
        guard let value = Data(base64Encoded: rawValue) else {
            throw TrixAPIError.invalidPayload("Не удалось декодировать \(label).")
        }

        return value
    }

    static func uint32(_ value: Int, label: String) throws -> UInt32 {
        guard let converted = UInt32(exactly: value) else {
            throw TrixAPIError.invalidPayload("\(label) exceeds supported range.")
        }

        return converted
    }

    static func int(_ value: UInt64, label: String) throws -> Int {
        guard let converted = Int(exactly: value) else {
            throw TrixAPIError.invalidPayload("FFI returned invalid \(label).")
        }

        return converted
    }

    static func decodeJSONObject(_ rawValue: String, label: String) throws -> [String: JSONValue] {
        let value = try decodeJSONValue(rawValue, label: label)
        guard case let .object(object) = value else {
            throw TrixAPIError.invalidPayload("FFI returned invalid \(label).")
        }

        return object
    }

    static func decodeJSONObjectAllowingNull(
        _ rawValue: String,
        label: String
    ) throws -> [String: JSONValue] {
        let value = try decodeJSONValue(rawValue, label: label)
        switch value {
        case let .object(object):
            return object
        case .null:
            return [:]
        default:
            throw TrixAPIError.invalidPayload("FFI returned invalid \(label).")
        }
    }

    static func decodeOptionalJSONValue(_ rawValue: String, label: String) throws -> JSONValue? {
        let value = try decodeJSONValue(rawValue, label: label)
        if case .null = value {
            return nil
        }

        return value
    }

    static func encodeJSONString(_ value: JSONValue?) throws -> String? {
        guard let value else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TrixAPIError.invalidPayload("Не удалось сериализовать cursor JSON.")
        }

        return string
    }

    private static func decodeJSONValue(_ rawValue: String, label: String) throws -> JSONValue {
        guard let data = rawValue.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("FFI returned non-UTF8 \(label).")
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw TrixAPIError.invalidPayload("FFI returned invalid \(label).")
        }
    }
}
