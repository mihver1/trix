import Foundation

enum TrixAPIError: LocalizedError {
    case invalidResponse
    case invalidPayload(String)
    case server(code: String, message: String, statusCode: Int)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Сервер вернул ответ в неожиданном формате."
        case let .invalidPayload(message):
            return message
        case let .server(_, message, _):
            return message
        case let .transport(error):
            return error.localizedDescription
        }
    }

    var isCredentialFailure: Bool {
        switch self {
        case let .server(_, _, statusCode):
            return statusCode == 401 || statusCode == 404
        default:
            return false
        }
    }
}

enum ServerEndpoint {
    static func normalizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host != nil else {
            return nil
        }

        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }

        return components.url
    }
}

struct TrixAPIClient {
    let baseURL: URL

    private let ffiClient: FfiServerApiClient

    init(baseURL: URL) throws {
        self.baseURL = baseURL

        do {
            self.ffiClient = try FfiServerApiClient(baseUrl: baseURL.absoluteString)
        } catch {
            throw Self.mapFFIError(error)
        }
    }

    func fetchHealth() async throws -> HealthResponse {
        try await callFFI { client in
            try HealthResponse(ffiValue: client.getHealth())
        }
    }

    func fetchVersion() async throws -> VersionResponse {
        try await callFFI { client in
            try VersionResponse(ffiValue: client.getVersion())
        }
    }

    func createAccount(_ request: CreateAccountRequest) async throws -> CreateAccountResponse {
        try await callFFI { client in
            try CreateAccountResponse(
                ffiValue: client.createAccount(params: try request.ffiParams())
            )
        }
    }

    func createAccount(
        handle: String?,
        profileName: String,
        profileBio: String?,
        deviceDisplayName: String,
        identity: DeviceIdentityMaterial
    ) async throws -> CreateAccountResponse {
        guard let accountRoot = identity.accountRootKeyMaterial else {
            throw TrixAPIError.invalidPayload("У этого устройства нет account-root ключа.")
        }

        return try await callFFI { client in
            try CreateAccountResponse(
                ffiValue: try client.createAccountWithMaterials(
                    params: FfiCreateAccountWithMaterialsParams(
                        handle: handle,
                        profileName: profileName,
                        profileBio: profileBio,
                        deviceDisplayName: deviceDisplayName,
                        platform: DeviceIdentityMaterial.platform,
                        credentialIdentity: identity.credentialIdentityData
                    ),
                    accountRoot: accountRoot,
                    deviceKeys: identity.transportKeyMaterial
                )
            )
        }
    }

    func createAuthChallenge(_ request: AuthChallengeRequest) async throws -> AuthChallengeResponse {
        try await callFFI { client in
            AuthChallengeResponse(
                ffiValue: try client.createAuthChallenge(deviceId: request.deviceId.uuidString)
            )
        }
    }

    func createAuthSession(_ request: AuthSessionRequest) async throws -> AuthSessionResponse {
        try await callFFI { client in
            try AuthSessionResponse(
                ffiValue: try client.createAuthSession(
                    deviceId: request.deviceId.uuidString,
                    challengeId: request.challengeId,
                    signature: try TrixCoreCodec.decodeBase64(
                        request.signatureB64,
                        label: "signature_b64"
                    )
                )
            )
        }
    }

    func authenticate(
        deviceId: UUID,
        identity: DeviceIdentityMaterial,
        setAccessToken: Bool = false
    ) async throws -> AuthSessionResponse {
        try await callFFI { client in
            try AuthSessionResponse(
                ffiValue: try client.authenticateWithDeviceKey(
                    deviceId: deviceId.uuidString,
                    deviceKeys: identity.transportKeyMaterial,
                    setAccessToken: setAccessToken
                )
            )
        }
    }

    func fetchCurrentAccount(accessToken: String) async throws -> AccountProfileResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AccountProfileResponse(ffiValue: client.getMe())
        }
    }

    func fetchAccountDirectory(
        accessToken: String,
        query: String? = nil,
        limit: Int? = 20,
        excludeSelf: Bool = true
    ) async throws -> AccountDirectoryResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AccountDirectoryResponse(
                ffiValue: client.searchAccountDirectory(
                    query: query,
                    limit: try limit.map { try TrixCoreCodec.uint32($0, label: "directory limit") },
                    excludeSelf: excludeSelf
                )
            )
        }
    }

    func updateAccountProfile(
        accessToken: String,
        request: UpdateAccountProfileRequest
    ) async throws -> AccountProfileResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AccountProfileResponse(ffiValue: client.updateAccountProfile(params: request.ffiParams()))
        }
    }

    func fetchDevices(accessToken: String) async throws -> DeviceListResponse {
        try await callFFI(accessToken: accessToken) { client in
            try DeviceListResponse(ffiValue: client.listDevices())
        }
    }

    func fetchInbox(
        accessToken: String,
        afterInboxId: UInt64? = nil,
        limit: Int = 50
    ) async throws -> InboxResponse {
        try await callFFI(accessToken: accessToken) { client in
            try InboxResponse(
                ffiValue: client.getInbox(
                    afterInboxId: afterInboxId,
                    limit: try TrixCoreCodec.uint32(limit, label: "inbox limit")
                )
            )
        }
    }

    func leaseInbox(
        accessToken: String,
        request: LeaseInboxRequest
    ) async throws -> LeaseInboxResponse {
        try await callFFI(accessToken: accessToken) { client in
            try LeaseInboxResponse(ffiValue: client.leaseInbox(params: try request.ffiValue()))
        }
    }

    func ackInbox(
        accessToken: String,
        request: AckInboxRequest
    ) async throws -> AckInboxResponse {
        try await callFFI(accessToken: accessToken) { client in
            AckInboxResponse(ffiValue: try client.ackInbox(inboxIds: request.inboxIds))
        }
    }

    func fetchAccountKeyPackages(
        accessToken: String,
        accountId: UUID
    ) async throws -> AccountKeyPackagesResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AccountKeyPackagesResponse(
                accountId: accountId.uuidString,
                packages: client.getAccountKeyPackages(accountId: accountId.uuidString)
            )
        }
    }

    func publishKeyPackages(
        accessToken: String,
        request: PublishKeyPackagesRequest
    ) async throws -> PublishKeyPackagesResponse {
        try await callFFI(accessToken: accessToken) { client in
            try PublishKeyPackagesResponse(
                ffiValue: client.publishKeyPackages(
                    packages: try request.packages.map { try $0.ffiValue() }
                )
            )
        }
    }

    func ensureOwnDeviceKeyPackages(
        accessToken: String,
        deviceId: UUID,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        minimumAvailable: Int = 8,
        targetAvailable: Int = 32
    ) async throws -> PublishKeyPackagesResponse? {
        let response = try await callFFI(accessToken: accessToken) { client in
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            return try client.ensureDeviceKeyPackages(
                facade: facade,
                deviceId: deviceId.uuidString,
                minimumAvailable: try TrixCoreCodec.uint32(
                    minimumAvailable,
                    label: "minimum available key packages"
                ),
                targetAvailable: try TrixCoreCodec.uint32(
                    targetAvailable,
                    label: "target available key packages"
                )
            )
        }

        return try response.map(PublishKeyPackagesResponse.init(ffiValue:))
    }

    func reserveKeyPackages(
        accessToken: String,
        request: ReserveKeyPackagesRequest
    ) async throws -> AccountKeyPackagesResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AccountKeyPackagesResponse(
                accountId: request.accountId.uuidString,
                packages: try client.reserveKeyPackages(
                    accountId: request.accountId.uuidString,
                    deviceIds: request.deviceIds.map(\.uuidString)
                )
            )
        }
    }

    func createLinkIntent(accessToken: String) async throws -> CreateLinkIntentResponse {
        try await callFFI(accessToken: accessToken) { client in
            try CreateLinkIntentResponse(ffiValue: client.createLinkIntent())
        }
    }

    func completeLinkIntent(
        linkIntentId: UUID,
        request: CompleteLinkIntentRequest
    ) async throws -> CompleteLinkIntentResponse {
        try await callFFI { client in
            try CompleteLinkIntentResponse(
                ffiValue: client.completeLinkIntent(
                    linkIntentId: linkIntentId.uuidString,
                    params: try request.ffiParams()
                )
            )
        }
    }

    func completeLinkIntent(
        linkIntentId: UUID,
        linkToken: UUID,
        deviceDisplayName: String,
        identity: DeviceIdentityMaterial,
        mlsStorageRoot: URL,
        initialKeyPackageCount: Int = 32
    ) async throws -> CompleteLinkIntentResponse {
        try await callFFI { client in
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: identity.credentialIdentityData
            )
            let keyPackages = try facade.generatePublishKeyPackages(
                count: try TrixCoreCodec.uint32(
                    initialKeyPackageCount,
                    label: "initial key package count"
                )
            )
            try facade.saveState()

            return try CompleteLinkIntentResponse(
                ffiValue: try client.completeLinkIntentWithDeviceKey(
                    linkIntentId: linkIntentId.uuidString,
                    params: FfiCompleteLinkIntentWithDeviceKeyParams(
                        linkToken: linkToken.uuidString,
                        deviceDisplayName: deviceDisplayName,
                        platform: DeviceIdentityMaterial.platform,
                        credentialIdentity: identity.credentialIdentityData,
                        keyPackages: keyPackages
                    ),
                    deviceKeys: identity.transportKeyMaterial
                )
            )
        }
    }

    func approveDevice(
        accessToken: String,
        deviceId: UUID,
        request: ApproveDeviceRequest
    ) async throws -> ApproveDeviceResponse {
        try await callFFI(accessToken: accessToken) { client in
            try ApproveDeviceResponse(
                ffiValue: try client.approveDevice(
                    deviceId: deviceId.uuidString,
                    accountRootSignature: try TrixCoreCodec.decodeBase64(
                        request.accountRootSignatureB64,
                        label: "account_root_signature_b64"
                    ),
                    transferBundle: try request.transferBundleB64.map {
                        try TrixCoreCodec.decodeBase64($0, label: "transfer_bundle_b64")
                    }
                )
            )
        }
    }

    func approveDevice(
        accessToken: String,
        deviceId: UUID,
        identity: DeviceIdentityMaterial,
        transferBundle: Data? = nil
    ) async throws -> ApproveDeviceResponse {
        guard let accountRoot = identity.accountRootKeyMaterial else {
            throw TrixAPIError.invalidPayload("Approve доступен только на root-capable устройстве.")
        }

        return try await callFFI(accessToken: accessToken) { client in
            try ApproveDeviceResponse(
                ffiValue: try client.approveDeviceWithAccountRoot(
                    deviceId: deviceId.uuidString,
                    accountRoot: accountRoot,
                    transferBundle: transferBundle
                )
            )
        }
    }

    func fetchDeviceApprovePayload(
        accessToken: String,
        deviceId: UUID
    ) async throws -> DeviceApprovePayloadResponse {
        try await callFFI(accessToken: accessToken) { client in
            try DeviceApprovePayloadResponse(
                ffiValue: client.getDeviceApprovePayload(deviceId: deviceId.uuidString)
            )
        }
    }

    func revokeDevice(
        accessToken: String,
        deviceId: UUID,
        request: RevokeDeviceRequest
    ) async throws -> RevokeDeviceResponse {
        try await callFFI(accessToken: accessToken) { client in
            try RevokeDeviceResponse(
                ffiValue: try client.revokeDevice(
                    deviceId: deviceId.uuidString,
                    reason: request.reason,
                    accountRootSignature: try TrixCoreCodec.decodeBase64(
                        request.accountRootSignatureB64,
                        label: "account_root_signature_b64"
                    )
                )
            )
        }
    }

    func revokeDevice(
        accessToken: String,
        deviceId: UUID,
        reason: String,
        identity: DeviceIdentityMaterial
    ) async throws -> RevokeDeviceResponse {
        guard let accountRoot = identity.accountRootKeyMaterial else {
            throw TrixAPIError.invalidPayload("Revoke доступен только на root-capable устройстве.")
        }

        return try await callFFI(accessToken: accessToken) { client in
            try RevokeDeviceResponse(
                ffiValue: try client.revokeDeviceWithAccountRoot(
                    deviceId: deviceId.uuidString,
                    reason: reason,
                    accountRoot: accountRoot
                )
            )
        }
    }

    func fetchHistorySyncJobs(
        accessToken: String,
        status: HistorySyncJobStatus? = nil,
        limit: Int = 50
    ) async throws -> HistorySyncJobListResponse {
        try await callFFI(accessToken: accessToken) { client in
            try HistorySyncJobListResponse(
                ffiValues: client.listHistorySyncJobs(
                    role: nil,
                    status: status?.ffiValue,
                    limit: try TrixCoreCodec.uint32(limit, label: "history sync limit")
                )
            )
        }
    }

    func completeHistorySyncJob(
        accessToken: String,
        jobId: UUID,
        request: CompleteHistorySyncJobRequest
    ) async throws -> CompleteHistorySyncJobResponse {
        try await callFFI(accessToken: accessToken) { client in
            try CompleteHistorySyncJobResponse(
                ffiValue: client.completeHistorySyncJob(
                    jobId: jobId.uuidString,
                    cursorJson: try request.ffiCursorJSONString()
                )
            )
        }
    }

    func fetchChats(accessToken: String) async throws -> ChatListResponse {
        try await callFFI(accessToken: accessToken) { client in
            try ChatListResponse(ffiValues: client.listChats())
        }
    }

    func createChat(
        accessToken: String,
        request: CreateChatRequest
    ) async throws -> CreateChatResponse {
        try await callFFI(accessToken: accessToken) { client in
            try CreateChatResponse(ffiValue: client.createChat(params: try request.ffiValue()))
        }
    }

    func createChatControl(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        creatorAccountId: UUID,
        creatorDeviceId: UUID,
        chatType: ChatType,
        title: String?,
        participantAccountIds: [UUID]
    ) async throws -> CreateChatControlOutcome {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            let outcome = try coordinator.createChatControl(
                client: client,
                store: store,
                facade: facade,
                input: FfiCreateChatControlInput(
                    creatorAccountId: creatorAccountId.uuidString,
                    creatorDeviceId: creatorDeviceId.uuidString,
                    chatType: chatType.ffiValue,
                    title: title,
                    participantAccountIds: participantAccountIds.map(\.uuidString),
                    groupId: nil,
                    commitAadJson: nil,
                    welcomeAadJson: nil
                )
            )
            try store.saveState()
            try facade.saveState()
            try coordinator.saveState()
            return try CreateChatControlOutcome(ffiValue: outcome)
        }
    }

    func sendTextMessage(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        senderAccountId: UUID,
        senderDeviceId: UUID,
        chatId: UUID,
        text: String
    ) async throws -> SendMessageOutcome {
        try await sendMessageBody(
            accessToken: accessToken,
            databasePath: databasePath,
            statePath: statePath,
            mlsStorageRoot: mlsStorageRoot,
            credentialIdentity: credentialIdentity,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            chatId: chatId,
            body: .text(text)
        )
    }

    func sendMessageBody(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        senderAccountId: UUID,
        senderDeviceId: UUID,
        chatId: UUID,
        body: TypedMessageBody
    ) async throws -> SendMessageOutcome {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            let conversation = try Self.prepareConversationIfNeeded(
                store: store,
                facade: facade,
                chatId: chatId
            )

            let outcome = try coordinator.sendMessageBody(
                client: client,
                store: store,
                facade: facade,
                conversation: conversation,
                input: FfiSendMessageInput(
                    senderAccountId: senderAccountId.uuidString,
                    senderDeviceId: senderDeviceId.uuidString,
                    chatId: chatId.uuidString,
                    messageId: nil,
                    body: body.ffiValue(),
                    aadJson: nil
                )
            )
            try store.saveState()
            try facade.saveState()
            try coordinator.saveState()
            return try SendMessageOutcome(ffiValue: outcome)
        }
    }

    func uploadAttachment(
        accessToken: String,
        chatId: UUID,
        payload: Data,
        mimeType: String,
        fileName: String?,
        widthPx: UInt32? = nil,
        heightPx: UInt32? = nil
    ) async throws -> UploadedAttachment {
        try await callFFI(accessToken: accessToken) { client in
            try UploadedAttachment(
                ffiValue: client.uploadAttachment(
                    chatId: chatId.uuidString,
                    payload: payload,
                    params: FfiAttachmentUploadParams(
                        mimeType: mimeType,
                        fileName: fileName,
                        widthPx: widthPx,
                        heightPx: heightPx
                    )
                )
            )
        }
    }

    func downloadAttachment(
        accessToken: String,
        body: TypedMessageBody
    ) async throws -> DownloadedAttachment {
        try await callFFI(accessToken: accessToken) { client in
            try DownloadedAttachment(
                ffiValue: client.downloadAttachment(body: body.ffiValue())
            )
        }
    }

    func addChatMembersControl(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        actorAccountId: UUID,
        actorDeviceId: UUID,
        chatId: UUID,
        participantAccountIds: [UUID]
    ) async throws -> ModifyChatMembersControlOutcome {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            _ = try Self.prepareConversationIfNeeded(
                store: store,
                facade: facade,
                chatId: chatId
            )
            let outcome = try coordinator.addChatMembersControl(
                client: client,
                store: store,
                facade: facade,
                input: FfiModifyChatMembersControlInput(
                    actorAccountId: actorAccountId.uuidString,
                    actorDeviceId: actorDeviceId.uuidString,
                    chatId: chatId.uuidString,
                    participantAccountIds: participantAccountIds.map(\.uuidString),
                    commitAadJson: nil,
                    welcomeAadJson: nil
                )
            )
            try store.saveState()
            try facade.saveState()
            try coordinator.saveState()
            return try ModifyChatMembersControlOutcome(ffiValue: outcome)
        }
    }

    func removeChatMembersControl(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        actorAccountId: UUID,
        actorDeviceId: UUID,
        chatId: UUID,
        participantAccountIds: [UUID]
    ) async throws -> ModifyChatMembersControlOutcome {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            _ = try Self.prepareConversationIfNeeded(
                store: store,
                facade: facade,
                chatId: chatId
            )
            let outcome = try coordinator.removeChatMembersControl(
                client: client,
                store: store,
                facade: facade,
                input: FfiModifyChatMembersControlInput(
                    actorAccountId: actorAccountId.uuidString,
                    actorDeviceId: actorDeviceId.uuidString,
                    chatId: chatId.uuidString,
                    participantAccountIds: participantAccountIds.map(\.uuidString),
                    commitAadJson: nil,
                    welcomeAadJson: nil
                )
            )
            try store.saveState()
            try facade.saveState()
            try coordinator.saveState()
            return try ModifyChatMembersControlOutcome(ffiValue: outcome)
        }
    }

    func addChatDevicesControl(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        actorAccountId: UUID,
        actorDeviceId: UUID,
        chatId: UUID,
        deviceIds: [UUID]
    ) async throws -> ModifyChatDevicesControlOutcome {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            _ = try Self.prepareConversationIfNeeded(
                store: store,
                facade: facade,
                chatId: chatId
            )
            let outcome = try coordinator.addChatDevicesControl(
                client: client,
                store: store,
                facade: facade,
                input: FfiModifyChatDevicesControlInput(
                    actorAccountId: actorAccountId.uuidString,
                    actorDeviceId: actorDeviceId.uuidString,
                    chatId: chatId.uuidString,
                    deviceIds: deviceIds.map(\.uuidString),
                    commitAadJson: nil,
                    welcomeAadJson: nil
                )
            )
            try store.saveState()
            try facade.saveState()
            try coordinator.saveState()
            return try ModifyChatDevicesControlOutcome(ffiValue: outcome)
        }
    }

    func removeChatDevicesControl(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        actorAccountId: UUID,
        actorDeviceId: UUID,
        chatId: UUID,
        deviceIds: [UUID]
    ) async throws -> ModifyChatDevicesControlOutcome {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            _ = try Self.prepareConversationIfNeeded(
                store: store,
                facade: facade,
                chatId: chatId
            )
            let outcome = try coordinator.removeChatDevicesControl(
                client: client,
                store: store,
                facade: facade,
                input: FfiModifyChatDevicesControlInput(
                    actorAccountId: actorAccountId.uuidString,
                    actorDeviceId: actorDeviceId.uuidString,
                    chatId: chatId.uuidString,
                    deviceIds: deviceIds.map(\.uuidString),
                    commitAadJson: nil,
                    welcomeAadJson: nil
                )
            )
            try store.saveState()
            try facade.saveState()
            try coordinator.saveState()
            return try ModifyChatDevicesControlOutcome(ffiValue: outcome)
        }
    }

    func fetchChatDetail(accessToken: String, chatId: UUID) async throws -> ChatDetailResponse {
        try await callFFI(accessToken: accessToken) { client in
            try ChatDetailResponse(ffiValue: client.getChat(chatId: chatId.uuidString))
        }
    }

    func fetchChatHistory(
        accessToken: String,
        chatId: UUID,
        limit: Int = 100
    ) async throws -> ChatHistoryResponse {
        try await callFFI(accessToken: accessToken) { client in
            try ChatHistoryResponse(
                ffiValue: client.getChatHistory(
                    chatId: chatId.uuidString,
                    afterServerSeq: nil,
                    limit: try TrixCoreCodec.uint32(limit, label: "chat history limit")
                )
            )
        }
    }

    func syncChatHistoriesIntoLocalStore(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        limitPerChat: Int = 200
    ) async throws -> LocalHistorySyncResult {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let report = try LocalStoreApplyReport(
                ffiValue: coordinator.syncChatHistoriesIntoStore(
                    client: client,
                    store: store,
                    limitPerChat: try TrixCoreCodec.uint32(limitPerChat, label: "local history sync limit")
                )
            )
            let syncState = try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
            let chats = try ChatListResponse(ffiValues: store.listChats()).chats

            return LocalHistorySyncResult(
                report: report,
                syncState: syncState,
                chats: chats
            )
        }
    }

    func projectLocalChatsIfPossible(
        databasePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        limit: Int = 500
    ) async throws -> Int {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            let clampedLimit = try TrixCoreCodec.uint32(limit, label: "projection limit")
            var projectedChatCount = 0

            for chat in try store.listChats() {
                do {
                    _ = try store.projectChatWithFacade(
                        chatId: chat.chatId,
                        facade: facade,
                        limit: clampedLimit
                    )
                    projectedChatCount += 1
                } catch {
                    continue
                }
            }

            try store.saveState()
            try facade.saveState()
            return projectedChatCount
        }
    }

    func projectLocalChatIfPossible(
        databasePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        chatId: UUID,
        limit: Int = 500
    ) async throws -> Bool {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )

            do {
                _ = try store.projectChatWithFacade(
                    chatId: chatId.uuidString,
                    facade: facade,
                    limit: try TrixCoreCodec.uint32(limit, label: "projection limit")
                )
                try store.saveState()
                try facade.saveState()
                return true
            } catch {
                return false
            }
        }
    }

    func fetchInboxIntoLocalStore(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        afterInboxId: UInt64? = nil,
        limit: Int = 50
    ) async throws -> LocalInboxPollResult {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let inbox = try client.getInbox(
                afterInboxId: afterInboxId,
                limit: try TrixCoreCodec.uint32(limit, label: "local inbox poll limit")
            )
            let lease = FfiLeaseInboxResponse(
                leaseOwner: try coordinator.leaseOwner(),
                leaseExpiresAtUnix: 0,
                items: inbox.items
            )
            let report = try LocalStoreApplyReport(ffiValue: store.applyLeasedInbox(lease: lease))

            for item in inbox.items {
                _ = try coordinator.recordChatServerSeq(
                    chatId: item.message.chatId,
                    serverSeq: item.message.serverSeq
                )
            }

            let syncState = try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
            let chats = try ChatListResponse(ffiValues: store.listChats()).chats

            return LocalInboxPollResult(
                items: try InboxResponse(ffiValue: inbox).items,
                report: report,
                syncState: syncState,
                chats: chats
            )
        }
    }

    func leaseInboxIntoLocalStore(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        leaseOwner: String?,
        limit: Int?,
        afterInboxId: UInt64?,
        leaseTtlSeconds: UInt64?
    ) async throws -> LocalInboxLeaseResult {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let lease = try client.leaseInbox(
                params: FfiLeaseInboxParams(
                    leaseOwner: leaseOwner ?? coordinator.leaseOwner(),
                    limit: try limit.map { try TrixCoreCodec.uint32($0, label: "local inbox lease limit") },
                    afterInboxId: afterInboxId,
                    leaseTtlSeconds: leaseTtlSeconds
                )
            )
            let report = try LocalStoreApplyReport(ffiValue: store.applyLeasedInbox(lease: lease))

            for item in lease.items {
                _ = try coordinator.recordChatServerSeq(
                    chatId: item.message.chatId,
                    serverSeq: item.message.serverSeq
                )
            }

            let syncState = try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
            let chats = try ChatListResponse(ffiValues: store.listChats()).chats

            return LocalInboxLeaseResult(
                lease: try LeaseInboxResponse(ffiValue: lease),
                ackedInboxIds: [],
                report: report,
                syncState: syncState,
                chats: chats
            )
        }
    }

    func ackInboxIntoSyncState(
        accessToken: String,
        statePath: URL,
        inboxIds: [UInt64]
    ) async throws -> LocalInboxAckResult {
        try await callFFI(accessToken: accessToken) { client in
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let response = try coordinator.ackInbox(client: client, inboxIds: inboxIds)

            return try LocalInboxAckResult(
                ackedInboxIds: response.ackedInboxIds.sorted(),
                syncState: SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
            )
        }
    }

    func fetchLocalChats(databasePath: URL) async throws -> ChatListResponse {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath
            )
            return try ChatListResponse(ffiValues: store.listChats())
        }
    }

    func fetchLocalChatListItems(
        databasePath: URL,
        selfAccountId: UUID?
    ) async throws -> [LocalChatListItem] {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath
            )
            return try store.listLocalChatListItems(
                selfAccountId: selfAccountId?.uuidString
            ).map { try LocalChatListItem(ffiValue: $0) }
        }
    }

    func fetchLocalChatListItem(
        databasePath: URL,
        chatId: UUID,
        selfAccountId: UUID?
    ) async throws -> LocalChatListItem? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath,
                chatIds: [chatId.uuidString]
            )
            guard let item = try store.getLocalChatListItem(
                chatId: chatId.uuidString,
                selfAccountId: selfAccountId?.uuidString
            ) else {
                return nil
            }

            return try LocalChatListItem(ffiValue: item)
        }
    }

    func fetchLocalChatDetail(
        databasePath: URL,
        chatId: UUID
    ) async throws -> ChatDetailResponse? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath,
                chatIds: [chatId.uuidString]
            )
            guard let detail = try store.getChat(chatId: chatId.uuidString) else {
                return nil
            }

            return try ChatDetailResponse(ffiValue: detail)
        }
    }

    func fetchLocalChatHistory(
        databasePath: URL,
        chatId: UUID,
        limit: Int = 100
    ) async throws -> ChatHistoryResponse {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try ChatHistoryResponse(
                ffiValue: store.getChatHistory(
                    chatId: chatId.uuidString,
                    afterServerSeq: nil,
                    limit: try TrixCoreCodec.uint32(limit, label: "local chat history limit")
                )
            )
        }
    }

    func fetchLocalTimelineItems(
        databasePath: URL,
        chatId: UUID,
        selfAccountId: UUID?,
        afterServerSeq: UInt64? = nil,
        limit: Int = 200
    ) async throws -> [LocalTimelineItem] {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath,
                chatIds: [chatId.uuidString]
            )
            return try store.getLocalTimelineItems(
                chatId: chatId.uuidString,
                selfAccountId: selfAccountId?.uuidString,
                afterServerSeq: afterServerSeq,
                limit: try TrixCoreCodec.uint32(limit, label: "local timeline limit")
            ).map { try LocalTimelineItem(ffiValue: $0) }
        }
    }

    func fetchLocalChatReadState(
        databasePath: URL,
        chatId: UUID,
        selfAccountId: UUID?
    ) async throws -> LocalChatReadState? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath,
                chatIds: [chatId.uuidString]
            )
            guard let state = try store.getChatReadState(
                chatId: chatId.uuidString,
                selfAccountId: selfAccountId?.uuidString
            ) else {
                return nil
            }

            return try LocalChatReadState(ffiValue: state)
        }
    }

    func markLocalChatRead(
        databasePath: URL,
        chatId: UUID,
        throughServerSeq: UInt64?,
        selfAccountId: UUID?
    ) async throws -> LocalChatReadState {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try LocalChatReadState(
                ffiValue: store.markChatRead(
                    chatId: chatId.uuidString,
                    throughServerSeq: throughServerSeq,
                    selfAccountId: selfAccountId?.uuidString
                )
            )
        }
    }

    func fetchLocalProjectedMessages(
        databasePath: URL,
        chatId: UUID,
        limit: Int = 100
    ) async throws -> [LocalProjectedMessage] {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath,
                chatIds: [chatId.uuidString]
            )
            return try store.getProjectedMessages(
                chatId: chatId.uuidString,
                afterServerSeq: nil,
                limit: try TrixCoreCodec.uint32(limit, label: "projected message limit")
            ).map { try LocalProjectedMessage(ffiValue: $0) }
        }
    }

    func fetchLocalProjectedCursor(
        databasePath: URL,
        chatId: UUID
    ) async throws -> UInt64? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try Self.repairLocalProjectionsIfPossible(
                store: store,
                databasePath: databasePath,
                chatIds: [chatId.uuidString]
            )
            return try store.projectedCursor(chatId: chatId.uuidString)
        }
    }

    func parseMessageBody(
        contentType: ContentType,
        payload: Data
    ) async throws -> TypedMessageBody {
        try await callFFI { _ in
            try TypedMessageBody(
                ffiValue: ffiParseMessageBody(
                    contentType: contentType.ffiValue,
                    payload: payload
                )
            )
        }
    }

    func serializeMessageBody(_ body: TypedMessageBody) async throws -> Data {
        try await callFFI { _ in
            try ffiSerializeMessageBody(body: body.ffiValue())
        }
    }

    func applyChatDetailToLocalStore(
        accessToken: String,
        databasePath: URL,
        chatId: UUID
    ) async throws -> LocalStoreApplyReport {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let detail = try client.getChat(chatId: chatId.uuidString)
            return try LocalStoreApplyReport(ffiValue: store.applyChatDetail(detail: detail))
        }
    }

    func fetchLocalChatReadStates(
        databasePath: URL,
        selfAccountId: UUID?
    ) async throws -> [LocalChatReadState] {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try store.listChatReadStates(
                selfAccountId: selfAccountId?.uuidString
            ).map { try LocalChatReadState(ffiValue: $0) }
        }
    }

    func fetchCiphersuiteLabel(
        mlsStorageRoot: URL,
        credentialIdentity: Data
    ) async throws -> String {
        try await callFFI { _ in
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            return try facade.ciphersuiteLabel()
        }
    }

    // MARK: - Outbox

    func enqueueOutboxMessage(
        databasePath: URL,
        chatId: UUID,
        senderAccountId: UUID,
        senderDeviceId: UUID,
        messageId: UUID,
        body: TypedMessageBody,
        queuedAtUnix: UInt64
    ) async throws -> LocalOutboxItem {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let item = try store.enqueueOutboxMessage(
                chatId: chatId.uuidString,
                senderAccountId: senderAccountId.uuidString,
                senderDeviceId: senderDeviceId.uuidString,
                messageId: messageId.uuidString,
                body: body.ffiValue(),
                queuedAtUnix: queuedAtUnix
            )
            try store.saveState()
            return try LocalOutboxItem(ffiValue: item)
        }
    }

    func fetchOutboxMessages(
        databasePath: URL,
        chatId: UUID? = nil
    ) async throws -> [LocalOutboxItem] {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try store.listOutboxMessages(
                chatId: chatId?.uuidString
            ).map { try LocalOutboxItem(ffiValue: $0) }
        }
    }

    func markOutboxFailure(
        databasePath: URL,
        messageId: UUID,
        failureMessage: String
    ) async throws {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try store.markOutboxFailure(
                messageId: messageId.uuidString,
                failureMessage: failureMessage
            )
            try store.saveState()
        }
    }

    func clearOutboxFailure(
        databasePath: URL,
        messageId: UUID
    ) async throws {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try store.clearOutboxFailure(messageId: messageId.uuidString)
            try store.saveState()
        }
    }

    func removeOutboxMessage(
        databasePath: URL,
        messageId: UUID
    ) async throws {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            try store.removeOutboxMessage(messageId: messageId.uuidString)
            try store.saveState()
        }
    }

    // MARK: - FFI Parity: additional methods aligned with iOS/Android

    func fetchAccount(
        accessToken: String,
        accountId: UUID
    ) async throws -> DirectoryAccountSummary {
        try await callFFI(accessToken: accessToken) { client in
            try DirectoryAccountSummary(ffiValue: client.getAccount(accountId: accountId.uuidString))
        }
    }

    func fetchDeviceTransferBundle(
        accessToken: String,
        deviceId: UUID
    ) async throws -> DeviceTransferBundleResponse {
        try await callFFI(accessToken: accessToken) { client in
            let bundle = try client.getDeviceTransferBundle(deviceId: deviceId.uuidString)
            return DeviceTransferBundleResponse(
                accountId: try TrixCoreCodec.uuid(bundle.accountId, label: "account_id"),
                deviceId: try TrixCoreCodec.uuid(bundle.deviceId, label: "device_id"),
                transferBundle: bundle.transferBundle,
                uploadedAtUnix: bundle.uploadedAtUnix
            )
        }
    }

    func pollOnce(
        accessToken: String,
        databasePath: URL,
        statePath: URL
    ) async throws -> LocalInboxPollResult {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let driver = try FfiRealtimeDriver()
            let outcome = try driver.pollOnce(
                client: client,
                coordinator: coordinator,
                store: store
            )
            let chats = try ChatListResponse(ffiValues: store.listChats()).chats
            let syncState = try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())

            return LocalInboxPollResult(
                items: try outcome.ackedInboxIds.map {
                    InboxItem(inboxId: $0, message: try MessageEnvelope(ffiValue: FfiMessageEnvelope(
                        messageId: UUID().uuidString, chatId: UUID().uuidString, serverSeq: 0,
                        senderAccountId: UUID().uuidString, senderDeviceId: UUID().uuidString,
                        epoch: 0, messageKind: .system, contentType: .chatEvent,
                        ciphertext: Data(), aadJson: "null", createdAtUnix: 0
                    )))
                },
                report: try LocalStoreApplyReport(ffiValue: outcome.report),
                syncState: syncState,
                chats: chats
            )
        }
    }

    func leaseInboxIntoLocalStore(
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        limit: Int? = nil,
        leaseTtlSeconds: UInt64? = nil
    ) async throws -> LocalInboxLeaseResult {
        try await callFFI(accessToken: accessToken) { client in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            let outcome = try coordinator.leaseInboxIntoStore(
                client: client,
                store: store,
                limit: try limit.map { try TrixCoreCodec.uint32($0, label: "lease limit") },
                leaseTtlSeconds: leaseTtlSeconds
            )

            let syncState = try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
            let chats = try ChatListResponse(ffiValues: store.listChats()).chats

            return LocalInboxLeaseResult(
                lease: LeaseInboxResponse(
                    leaseOwner: outcome.leaseOwner,
                    leaseExpiresAtUnix: outcome.leaseExpiresAtUnix,
                    items: []
                ),
                ackedInboxIds: outcome.ackedInboxIds.sorted(),
                report: try LocalStoreApplyReport(ffiValue: outcome.report),
                syncState: syncState,
                chats: chats
            )
        }
    }

    func enqueueOutboxAttachment(
        databasePath: URL,
        chatId: UUID,
        senderAccountId: UUID,
        senderDeviceId: UUID,
        messageId: UUID,
        localPath: String,
        mimeType: String,
        fileName: String?,
        widthPx: UInt32? = nil,
        heightPx: UInt32? = nil,
        queuedAtUnix: UInt64
    ) async throws -> LocalOutboxItem {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let item = try store.enqueueOutboxAttachment(
                chatId: chatId.uuidString,
                senderAccountId: senderAccountId.uuidString,
                senderDeviceId: senderDeviceId.uuidString,
                messageId: messageId.uuidString,
                attachment: FfiLocalOutboxAttachmentDraft(
                    localPath: localPath,
                    mimeType: mimeType,
                    fileName: fileName,
                    widthPx: widthPx,
                    heightPx: heightPx
                ),
                queuedAtUnix: queuedAtUnix
            )
            try store.saveState()
            return try LocalOutboxItem(ffiValue: item)
        }
    }

    func fetchMlsStorageRoot(
        mlsStorageRoot: URL,
        credentialIdentity: Data
    ) async throws -> String? {
        try await callFFI { _ in
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            return try facade.storageRoot()
        }
    }

    func fetchMlsCredentialIdentity(
        mlsStorageRoot: URL,
        credentialIdentity: Data
    ) async throws -> Data {
        try await callFFI { _ in
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            return try facade.credentialIdentity()
        }
    }

    func fetchSyncStatePath(statePath: URL) async throws -> String? {
        try await callFFI { _ in
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            return try coordinator.statePath()
        }
    }

    func fetchSyncStateSnapshot(statePath: URL) async throws -> SyncStateSnapshot {
        try await callFFI { _ in
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            return try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
        }
    }

    private func callFFI<Response: Sendable>(
        accessToken: String? = nil,
        _ operation: @escaping @Sendable (FfiServerApiClient) throws -> Response
    ) async throws -> Response {
        let ffiClient = self.ffiClient

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if let accessToken {
                        try ffiClient.setAccessToken(accessToken: accessToken)
                    } else {
                        try ffiClient.clearAccessToken()
                    }

                    continuation.resume(returning: try operation(ffiClient))
                } catch let error as TrixAPIError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: Self.mapFFIError(error))
                }
            }
        }
    }

    private static func makeLocalHistoryStore(databasePath: URL) throws -> FfiLocalHistoryStore {
        try FfiLocalHistoryStore.newPersistent(databasePath: databasePath.path)
    }

    private static func makeSyncCoordinator(statePath: URL) throws -> FfiSyncCoordinator {
        try FfiSyncCoordinator.newPersistent(statePath: statePath.path)
    }

    private static func makePersistentMlsFacade(
        storageRoot: URL,
        credentialIdentity: Data
    ) throws -> FfiMlsFacade {
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )

        if let loadedFacade = try? FfiMlsFacade.loadPersistent(storageRoot: storageRoot.path) {
            return loadedFacade
        }

        return try FfiMlsFacade.newPersistent(
            credentialIdentity: credentialIdentity,
            storageRoot: storageRoot.path
        )
    }

    private static func repairLocalProjectionsIfPossible(
        store: FfiLocalHistoryStore,
        databasePath: URL,
        chatIds: [String]? = nil,
        limit: Int = 500
    ) throws {
        let workspaceRoot = databasePath.deletingLastPathComponent()
        let mlsStorageRoot = workspaceRoot.appendingPathComponent("mls-state", isDirectory: true)
        guard let facade = try? FfiMlsFacade.loadPersistent(storageRoot: mlsStorageRoot.path) else {
            return
        }

        let targetChatIds = chatIds.map(Set.init)
        let clampedLimit = try TrixCoreCodec.uint32(limit, label: "projection limit")
        var didMutate = false

        for chat in try store.listChats() {
            if let targetChatIds, !targetChatIds.contains(chat.chatId) {
                continue
            }

            let projectedCursor = try store.projectedCursor(chatId: chat.chatId) ?? 0
            if chat.lastServerSeq <= projectedCursor {
                continue
            }

            do {
                let report = try store.projectChatWithFacade(
                    chatId: chat.chatId,
                    facade: facade,
                    limit: clampedLimit
                )
                let refreshedCursor = try store.projectedCursor(chatId: chat.chatId) ?? 0
                if refreshedCursor > projectedCursor || report.projectedMessagesUpserted > 0 {
                    didMutate = true
                }
            } catch {
                continue
            }
        }

        if didMutate {
            try store.saveState()
            try facade.saveState()
        }
    }

    private static func prepareConversationIfNeeded(
        store: FfiLocalHistoryStore,
        facade: FfiMlsFacade,
        chatId: UUID,
        projectionLimit: Int = 500
    ) throws -> FfiMlsConversation {
        if let groupId = try store.chatMlsGroupId(chatId: chatId.uuidString),
           let conversation = try facade.loadGroup(groupId: groupId) {
            return conversation
        }

        guard let conversation = try store.loadOrBootstrapChatConversation(
            chatId: chatId.uuidString,
            facade: facade
        ) else {
            throw TrixAPIError.invalidPayload("Этот чат ещё не готов к отправке с этого Mac.")
        }

        _ = try store.projectChatMessages(
            chatId: chatId.uuidString,
            facade: facade,
            conversation: conversation,
            limit: try TrixCoreCodec.uint32(projectionLimit, label: "bootstrap projection limit")
        )
        return conversation
    }

    private static func mapFFIError(_ error: Error) -> TrixAPIError {
        if let error = error as? TrixAPIError {
            return error
        }

        if let ffiError = error as? TrixFfiError {
            switch ffiError {
            case let .Message(message):
                if let serverError = parseServerError(message) {
                    return serverError
                }
                return .transport(ffiError)
            }
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
