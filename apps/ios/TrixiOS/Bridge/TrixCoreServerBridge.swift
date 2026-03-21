import Foundation

struct TrixCoreServerBridge {
    static func fetchSystemSnapshot(
        baseURLString: String
    ) async throws -> ServerSnapshot {
        let client = try makeClient(baseURLString: baseURLString)
        let health = try client.getHealth()
        let version = try client.getVersion()

        return ServerSnapshot(
            health: health.trix_serverHealthResponse,
            version: version.trix_serverVersionResponse
        )
    }

    static func createAccount(
        baseURLString: String,
        form: CreateAccountForm,
        bootstrapMaterial: DeviceBootstrapMaterial
    ) throws -> CreateAccountResponse {
        let client = try makeClient(baseURLString: baseURLString)
        let accountRoot = try bootstrapMaterial.accountRootMaterial()
        let deviceKeys = try bootstrapMaterial.deviceKeyMaterial()
        let transportPubkey = deviceKeys.publicKeyBytes()
        let accountBootstrapPayload = accountRoot.accountBootstrapPayload(
            transportPubkey: transportPubkey,
            credentialIdentity: bootstrapMaterial.credentialIdentity
        )
        let response: FfiCreateAccountResponse
        do {
            response = try client.createAccount(
                params: FfiCreateAccountParams(
                    handle: form.handle.trix_trimmedOrNil(),
                    profileName: form.profileName.trix_trimmed(),
                    profileBio: form.profileBio.trix_trimmedOrNil(),
                    deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
                    platform: form.platform,
                    credentialIdentity: bootstrapMaterial.credentialIdentity,
                    accountRootPubkey: accountRoot.publicKeyBytes(),
                    accountRootSignature: accountRoot.sign(payload: accountBootstrapPayload),
                    transportPubkey: transportPubkey
                )
            )
        } catch {
            response = try client.createAccountWithMaterials(
                params: FfiCreateAccountWithMaterialsParams(
                    handle: form.handle.trix_trimmedOrNil(),
                    profileName: form.profileName.trix_trimmed(),
                    profileBio: form.profileBio.trix_trimmedOrNil(),
                    deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
                    platform: form.platform,
                    credentialIdentity: bootstrapMaterial.credentialIdentity
                ),
                accountRoot: accountRoot,
                deviceKeys: deviceKeys
            )
        }

        return CreateAccountResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            accountSyncChatId: response.accountSyncChatId
        )
    }

    static func createLinkIntent(
        baseURLString: String,
        accessToken: String
    ) throws -> CreateLinkIntentResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.createLinkIntent()
        return CreateLinkIntentResponse(
            linkIntentId: response.linkIntentId,
            qrPayload: response.qrPayload,
            expiresAtUnix: response.expiresAtUnix
        )
    }

    static func clearAccessToken(
        baseURLString: String,
        accessToken: String
    ) throws {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        try client.clearAccessToken()
    }

    static func searchAccountDirectory(
        baseURLString: String,
        accessToken: String,
        query: String?,
        limit: Int = 20,
        excludeSelf: Bool = true
    ) throws -> [DirectoryAccountSummary] {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.searchAccountDirectory(
            query: query?.trix_trimmedOrNil(),
            limit: limit > 0 ? UInt32(limit) : nil,
            excludeSelf: excludeSelf
        )

        return response.accounts.map { account in
            DirectoryAccountSummary(
                accountId: account.accountId,
                handle: account.handle,
                profileName: account.profileName,
                profileBio: account.profileBio
            )
        }
    }

    static func getAccount(
        baseURLString: String,
        accessToken: String,
        accountId: String
    ) throws -> DirectoryAccountSummary {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let account = try client.getAccount(accountId: accountId)
        return DirectoryAccountSummary(
            accountId: account.accountId,
            handle: account.handle,
            profileName: account.profileName,
            profileBio: account.profileBio
        )
    }

    static func updateAccountProfile(
        baseURLString: String,
        accessToken: String,
        form: EditProfileForm
    ) throws -> AccountProfileResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let profile = try client.updateAccountProfile(
            params: FfiUpdateAccountProfileParams(
                handle: form.handle.trix_trimmedOrNil(),
                profileName: form.profileName.trix_trimmed(),
                profileBio: form.profileBio.trix_trimmedOrNil()
            )
        )

        return AccountProfileResponse(
            accountId: profile.accountId,
            handle: profile.handle,
            profileName: profile.profileName,
            profileBio: profile.profileBio,
            deviceId: profile.deviceId,
            deviceStatus: profile.deviceStatus.trix_serverDeviceStatus
        )
    }

    static func completeLinkIntent(
        baseURLString: String,
        payload: LinkIntentPayload,
        form: LinkExistingAccountForm,
        preparedState: PreparedLinkedDeviceState
    ) throws -> CompleteLinkIntentResponse {
        let client = try makeClient(baseURLString: baseURLString)
        let response = try client.completeLinkIntentWithDeviceKey(
            linkIntentId: payload.linkIntentId,
            params: FfiCompleteLinkIntentWithDeviceKeyParams(
                linkToken: payload.linkToken,
                deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
                platform: form.platform,
                credentialIdentity: preparedState.provisionalIdentity.credentialIdentity,
                keyPackages: preparedState.keyPackages
            ),
            deviceKeys: try preparedState.provisionalIdentity.deviceKeyMaterial()
        )

        return CompleteLinkIntentResponse(
            accountId: response.accountId,
            pendingDeviceId: response.pendingDeviceId,
            deviceStatus: response.deviceStatus.trix_serverDeviceStatus,
            bootstrapPayloadB64: response.bootstrapPayload.base64EncodedString()
        )
    }

    static func authenticate(
        baseURLString: String,
        identity: LocalDeviceIdentity
    ) throws -> AuthSessionResponse {
        let client = try makeClient(baseURLString: baseURLString)
        let deviceKeys = try identity.deviceKeyMaterial()
        _ = deviceKeys.publicKeyBytes()

        do {
            let challenge = try client.createAuthChallenge(deviceId: identity.deviceId)
            let session = try client.createAuthSession(
                deviceId: identity.deviceId,
                challengeId: challenge.challengeId,
                signature: deviceKeys.sign(payload: challenge.challenge)
            )
            return session.trix_authSessionResponse
        } catch {
            return try client.authenticateWithDeviceKey(
                deviceId: identity.deviceId,
                deviceKeys: deviceKeys,
                setAccessToken: false
            ).trix_authSessionResponse
        }
    }

    static func getAccountProfile(
        baseURLString: String,
        accessToken: String
    ) async throws -> AccountProfileResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.getMe().trix_serverAccountProfileResponse
    }

    static func listDevices(
        baseURLString: String,
        accessToken: String
    ) async throws -> DeviceListResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.listDevices().trix_serverDeviceListResponse
    }

    static func reserveKeyPackages(
        baseURLString: String,
        accessToken: String,
        accountId: String,
        deviceIds: [String]
    ) throws -> AccountKeyPackagesResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.reserveKeyPackages(
            accountId: accountId,
            deviceIds: deviceIds
        ).trix_serverAccountKeyPackagesResponse(accountId: accountId)
    }

    static func getAccountKeyPackages(
        baseURLString: String,
        accessToken: String,
        accountId: String
    ) throws -> AccountKeyPackagesResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.getAccountKeyPackages(accountId: accountId)
            .trix_serverAccountKeyPackagesResponse(accountId: accountId)
    }

    static func listHistorySyncJobs(
        baseURLString: String,
        accessToken: String,
        role: HistorySyncJobRole? = nil,
        limit: Int = 50
    ) async throws -> HistorySyncJobListResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let clampedLimit = limit > 0 ? UInt32(limit) : nil
        return try client.listHistorySyncJobs(
            role: role?.trix_ffiHistorySyncJobRole,
            status: nil,
            limit: clampedLimit
        ).trix_serverHistorySyncJobListResponse(role: role)
    }

    static func getHistorySyncChunks(
        baseURLString: String,
        accessToken: String,
        jobId: String
    ) async throws -> [HistorySyncChunkSummary] {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.getHistorySyncChunks(jobId: jobId).map(\.trix_serverHistorySyncChunkSummary)
    }

    static func appendHistorySyncChunk(
        baseURLString: String,
        accessToken: String,
        jobId: String,
        sequenceNo: UInt64,
        payload: Data,
        cursorJson: String?,
        isFinal: Bool
    ) async throws -> AppendHistorySyncChunkResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.appendHistorySyncChunk(
            jobId: jobId,
            sequenceNo: sequenceNo,
            payload: payload,
            cursorJson: cursorJson,
            isFinal: isFinal
        ).trix_serverAppendHistorySyncChunkResponse
    }

    static func listChats(
        baseURLString: String,
        accessToken: String
    ) async throws -> ChatListResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return ChatListResponse(chats: try client.listChats().map(\.trix_serverChatSummary))
    }

    static func getChat(
        baseURLString: String,
        accessToken: String,
        chatId: String
    ) async throws -> ChatDetailResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.getChat(chatId: chatId).trix_serverChatDetailResponse
    }

    static func getChatHistory(
        baseURLString: String,
        accessToken: String,
        chatId: String,
        afterServerSeq: UInt64? = nil,
        limit: Int = 500
    ) async throws -> ChatHistoryResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let clampedLimit = limit > 0 ? UInt32(limit) : nil
        return try client.getChatHistory(
            chatId: chatId,
            afterServerSeq: afterServerSeq,
            limit: clampedLimit
        ).trix_serverChatHistoryResponse
    }

    static func getInbox(
        baseURLString: String,
        accessToken: String,
        afterInboxId: UInt64? = nil,
        limit: Int = 50
    ) async throws -> InboxResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let clampedLimit = limit > 0 ? UInt32(limit) : nil
        return try client.getInbox(afterInboxId: afterInboxId, limit: clampedLimit).trix_serverInboxResponse
    }

    static func leaseInbox(
        baseURLString: String,
        accessToken: String,
        leaseOwner: String? = nil,
        limit: Int = 25,
        afterInboxId: UInt64? = nil,
        leaseTtlSeconds: UInt64? = nil
    ) async throws -> LeaseInboxResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.leaseInbox(
            params: FfiLeaseInboxParams(
                leaseOwner: leaseOwner.flatMap { $0.trix_trimmedOrNil() },
                limit: limit > 0 ? UInt32(limit) : nil,
                afterInboxId: afterInboxId,
                leaseTtlSeconds: leaseTtlSeconds
            )
        )
        return response.trix_serverLeaseInboxResponse
    }

    static func ackInbox(
        baseURLString: String,
        accessToken: String,
        inboxIds: [UInt64]
    ) async throws -> AckInboxResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.ackInbox(inboxIds: inboxIds).trix_serverAckInboxResponse
    }

    static func completeHistorySyncJob(
        baseURLString: String,
        accessToken: String,
        jobId: String,
        cursorJson: String? = nil
    ) async throws -> CompleteHistorySyncJobResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        return try client.completeHistorySyncJob(
            jobId: jobId,
            cursorJson: cursorJson
        ).trix_serverCompleteHistorySyncJobResponse
    }

    static func approvePendingDevice(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        deviceId: String
    ) throws -> ApproveDeviceResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let accountRoot = try identity.accountRootMaterial()
        let response: FfiApproveDeviceResponse

        do {
            let payload = try client.getDeviceApprovePayload(deviceId: deviceId)
            let senderDeviceKeys = try identity.deviceKeyMaterial()
            response = try client.approveDevice(
                deviceId: payload.deviceId,
                accountRootSignature: accountRoot.sign(payload: payload.bootstrapPayload),
                transferBundle: try accountRoot.createDeviceTransferBundle(
                    params: FfiCreateDeviceTransferBundleParams(
                        accountId: payload.accountId,
                        sourceDeviceId: identity.deviceId,
                        targetDeviceId: payload.deviceId,
                        accountSyncChatId: identity.accountSyncChatId
                    ),
                    senderDeviceKeys: senderDeviceKeys,
                    recipientTransportPubkey: payload.transportPubkey
                )
            )
        } catch {
            response = try client.approveDeviceWithAccountRoot(
                deviceId: deviceId,
                accountRoot: accountRoot,
                transferBundle: nil
            )
        }

        return ApproveDeviceResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            deviceStatus: response.deviceStatus.trix_serverDeviceStatus
        )
    }

    static func fetchDeviceTransferBundle(
        baseURLString: String,
        accessToken: String,
        deviceId: String
    ) throws -> DeviceTransferBundleResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.getDeviceTransferBundle(deviceId: deviceId)
        return DeviceTransferBundleResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            transferBundleB64: response.transferBundle.base64EncodedString(),
            uploadedAtUnix: response.uploadedAtUnix
        )
    }

    static func getMe(
        baseURLString: String,
        accessToken: String
    ) throws -> AccountProfileResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let profile = try client.getMe()
        return AccountProfileResponse(
            accountId: profile.accountId,
            handle: profile.handle,
            profileName: profile.profileName,
            profileBio: profile.profileBio,
            deviceId: profile.deviceId,
            deviceStatus: profile.deviceStatus.trix_serverDeviceStatus
        )
    }

    static func listDevices(
        baseURLString: String,
        accessToken: String
    ) throws -> DeviceListResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.listDevices()
        return DeviceListResponse(
            accountId: response.accountId,
            devices: response.devices.map { device in
                DeviceSummary(
                    deviceId: device.deviceId,
                    displayName: device.displayName,
                    platform: device.platform,
                    deviceStatus: device.deviceStatus.trix_serverDeviceStatus,
                    availableKeyPackageCount: device.availableKeyPackageCount
                )
            }
        )
    }

    static func getChatDetail(
        baseURLString: String,
        accessToken: String,
        chatId: String
    ) throws -> ChatDetailResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let detail = try client.getChat(chatId: chatId)
        return ChatDetailResponse(
            chatId: detail.chatId,
            chatType: detail.chatType.trix_chatType,
            title: detail.title,
            lastServerSeq: detail.lastServerSeq,
            pendingMessageCount: detail.pendingMessageCount,
            epoch: detail.epoch,
            lastCommitMessageId: detail.lastCommitMessageId,
            lastMessage: detail.lastMessage?.trix_messageEnvelope,
            participantProfiles: detail.participantProfiles.map(\.trix_chatParticipantProfileSummary),
            members: detail.members.map { member in
                ChatMemberSummary(
                    accountId: member.accountId,
                    role: member.role,
                    membershipStatus: member.membershipStatus
                )
            },
            deviceMembers: detail.deviceMembers.map { device in
                ChatDeviceSummary(
                    deviceId: device.deviceId,
                    accountId: device.accountId,
                    displayName: device.displayName,
                    platform: device.platform,
                    leafIndex: device.leafIndex,
                    credentialIdentityB64: device.credentialIdentity.base64EncodedString()
                )
            }
        )
    }

    static func revokeDevice(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        deviceId: String,
        reason: String
    ) throws -> RevokeDeviceResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.revokeDeviceWithAccountRoot(
            deviceId: deviceId,
            reason: reason,
            accountRoot: try identity.accountRootMaterial()
        )

        return RevokeDeviceResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            deviceStatus: response.deviceStatus.trix_serverDeviceStatus
        )
    }

    private static func makeClient(
        baseURLString: String,
        accessToken: String? = nil
    ) throws -> FfiServerApiClient {
        let client = try FfiServerApiClient(baseUrl: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        if let accessToken {
            try client.setAccessToken(accessToken: accessToken)
        }
        return client
    }
}

private extension FfiDeviceStatus {
    var trix_serverDeviceStatus: DeviceStatus {
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

private extension FfiServiceStatus {
    var trix_serverServiceStatus: ServiceStatus {
        switch self {
        case .ok:
            return .ok
        case .degraded:
            return .degraded
        }
    }
}

private extension FfiHealthResponse {
    var trix_serverHealthResponse: HealthResponse {
        HealthResponse(
            service: service,
            status: status.trix_serverServiceStatus,
            version: version,
            uptimeMs: uptimeMs
        )
    }
}

private extension FfiVersionResponse {
    var trix_serverVersionResponse: VersionResponse {
        VersionResponse(
            service: service,
            version: version,
            gitSha: gitSha
        )
    }
}

private extension FfiChatType {
    var trix_serverChatType: ChatType {
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
    var trix_serverMessageKind: MessageKind {
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
    var trix_serverContentType: ContentType {
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

private extension FfiChatParticipantProfile {
    var trix_serverChatParticipantProfileSummary: ChatParticipantProfileSummary {
        ChatParticipantProfileSummary(
            accountId: accountId,
            handle: handle,
            profileName: profileName,
            profileBio: profileBio
        )
    }
}

private extension FfiChatSummary {
    var trix_serverChatSummary: ChatSummary {
        ChatSummary(
            chatId: chatId,
            chatType: chatType.trix_serverChatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: lastMessage?.trix_serverMessageEnvelope,
            participantProfiles: participantProfiles.map(\.trix_serverChatParticipantProfileSummary)
        )
    }
}

private extension FfiMessageEnvelope {
    var trix_serverMessageEnvelope: MessageEnvelope {
        MessageEnvelope(
            messageId: messageId,
            chatId: chatId,
            serverSeq: serverSeq,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            epoch: epoch,
            messageKind: messageKind.trix_serverMessageKind,
            contentType: contentType.trix_serverContentType,
            ciphertextB64: ciphertext.base64EncodedString(),
            aadJson: aadJson.trix_serverJSONValue,
            createdAtUnix: createdAtUnix
        )
    }
}

private extension FfiChatHistory {
    var trix_serverChatHistoryResponse: ChatHistoryResponse {
        ChatHistoryResponse(
            chatId: chatId,
            messages: messages.map(\.trix_serverMessageEnvelope)
        )
    }
}

private extension FfiHistorySyncJobType {
    var trix_serverHistorySyncJobType: HistorySyncJobType {
        switch self {
        case .initialSync:
            return .initialSync
        case .chatBackfill:
            return .chatBackfill
        case .deviceRekey:
            return .deviceRekey
        }
    }
}

private extension FfiHistorySyncJobStatus {
    var trix_serverHistorySyncJobStatus: HistorySyncJobStatus {
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

private extension HistorySyncJobRole {
    var trix_ffiHistorySyncJobRole: FfiHistorySyncJobRole {
        switch self {
        case .source:
            return .source
        case .target:
            return .target
        }
    }
}

private extension FfiHistorySyncJobRole {
    var trix_serverHistorySyncJobRole: HistorySyncJobRole {
        switch self {
        case .source:
            return .source
        case .target:
            return .target
        }
    }
}

private extension FfiAccountProfile {
    var trix_serverAccountProfileResponse: AccountProfileResponse {
        AccountProfileResponse(
            accountId: accountId,
            handle: handle,
            profileName: profileName,
            profileBio: profileBio,
            deviceId: deviceId,
            deviceStatus: deviceStatus.trix_serverDeviceStatus
        )
    }
}

private extension FfiAuthSession {
    var trix_authSessionResponse: AuthSessionResponse {
        AuthSessionResponse(
            accessToken: accessToken,
            expiresAtUnix: expiresAtUnix,
            accountId: accountId,
            deviceStatus: deviceStatus.trix_serverDeviceStatus
        )
    }
}

private extension FfiDeviceSummary {
    var trix_serverDeviceSummary: DeviceSummary {
        DeviceSummary(
            deviceId: deviceId,
            displayName: displayName,
            platform: platform,
            deviceStatus: deviceStatus.trix_serverDeviceStatus,
            availableKeyPackageCount: availableKeyPackageCount
        )
    }
}

private extension FfiDeviceList {
    var trix_serverDeviceListResponse: DeviceListResponse {
        DeviceListResponse(
            accountId: accountId,
            devices: devices.map(\.trix_serverDeviceSummary)
        )
    }
}

private extension FfiReservedKeyPackage {
    var trix_serverReservedKeyPackage: ReservedKeyPackage {
        ReservedKeyPackage(
            keyPackageId: keyPackageId,
            deviceId: deviceId,
            cipherSuite: cipherSuite,
            keyPackageB64: keyPackage.base64EncodedString()
        )
    }
}

private extension Array where Element == FfiReservedKeyPackage {
    func trix_serverAccountKeyPackagesResponse(accountId: String) -> AccountKeyPackagesResponse {
        AccountKeyPackagesResponse(
            accountId: accountId,
            packages: map(\.trix_serverReservedKeyPackage)
        )
    }
}

private extension FfiHistorySyncJob {
    func trix_serverHistorySyncJobSummary(role: HistorySyncJobRole?) -> HistorySyncJobSummary {
        HistorySyncJobSummary(
            jobId: jobId,
            role: role ?? .source,
            jobType: jobType.trix_serverHistorySyncJobType,
            jobStatus: jobStatus.trix_serverHistorySyncJobStatus,
            sourceDeviceId: sourceDeviceId,
            targetDeviceId: targetDeviceId,
            chatId: chatId,
            createdAtUnix: createdAtUnix,
            updatedAtUnix: updatedAtUnix
        )
    }
}

private extension Array where Element == FfiHistorySyncJob {
    func trix_serverHistorySyncJobListResponse(role: HistorySyncJobRole?) -> HistorySyncJobListResponse {
        HistorySyncJobListResponse(jobs: map { $0.trix_serverHistorySyncJobSummary(role: role) })
    }
}

private extension FfiAppendHistorySyncChunkResponse {
    var trix_serverAppendHistorySyncChunkResponse: AppendHistorySyncChunkResponse {
        AppendHistorySyncChunkResponse(
            jobId: jobId,
            chunkId: chunkId,
            jobStatus: jobStatus.trix_serverHistorySyncJobStatus
        )
    }
}

private extension FfiHistorySyncChunk {
    var trix_serverHistorySyncChunkSummary: HistorySyncChunkSummary {
        HistorySyncChunkSummary(
            chunkId: chunkId,
            sequenceNo: sequenceNo,
            payload: payload,
            cursorJson: cursorJson,
            isFinal: isFinal,
            createdAtUnix: uploadedAtUnix
        )
    }
}

private extension FfiChatMember {
    var trix_serverChatMemberSummary: ChatMemberSummary {
        ChatMemberSummary(
            accountId: accountId,
            role: role,
            membershipStatus: membershipStatus
        )
    }
}

private extension FfiChatDeviceMember {
    var trix_serverChatDeviceSummary: ChatDeviceSummary {
        ChatDeviceSummary(
            deviceId: deviceId,
            accountId: accountId,
            displayName: displayName,
            platform: platform,
            leafIndex: leafIndex,
            credentialIdentityB64: credentialIdentity.base64EncodedString()
        )
    }
}

private extension FfiChatDetail {
    var trix_serverChatDetailResponse: ChatDetailResponse {
        ChatDetailResponse(
            chatId: chatId,
            chatType: chatType.trix_serverChatType,
            title: title,
            lastServerSeq: lastServerSeq,
            pendingMessageCount: pendingMessageCount,
            epoch: epoch,
            lastCommitMessageId: lastCommitMessageId,
            lastMessage: lastMessage?.trix_serverMessageEnvelope,
            participantProfiles: participantProfiles.map(\.trix_serverChatParticipantProfileSummary),
            members: members.map(\.trix_serverChatMemberSummary),
            deviceMembers: deviceMembers.map(\.trix_serverChatDeviceSummary)
        )
    }
}

private extension FfiInboxItem {
    var trix_serverInboxItem: InboxItem {
        InboxItem(
            inboxId: inboxId,
            message: message.trix_serverMessageEnvelope
        )
    }
}

private extension FfiInbox {
    var trix_serverInboxResponse: InboxResponse {
        InboxResponse(items: items.map(\.trix_serverInboxItem))
    }
}

private extension FfiLeaseInboxResponse {
    var trix_serverLeaseInboxResponse: LeaseInboxResponse {
        LeaseInboxResponse(
            leaseOwner: leaseOwner,
            leaseExpiresAtUnix: leaseExpiresAtUnix,
            items: items.map(\.trix_serverInboxItem)
        )
    }
}

private extension FfiAckInboxResponse {
    var trix_serverAckInboxResponse: AckInboxResponse {
        AckInboxResponse(ackedInboxIds: ackedInboxIds)
    }
}

private extension FfiCompleteHistorySyncJobResponse {
    var trix_serverCompleteHistorySyncJobResponse: CompleteHistorySyncJobResponse {
        CompleteHistorySyncJobResponse(
            jobId: jobId,
            jobStatus: jobStatus.trix_serverHistorySyncJobStatus
        )
    }
}

private extension String {
    var trix_serverJSONValue: JSONValue {
        guard let data = data(using: .utf8) else {
            return .string(self)
        }

        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(self)
    }
}
