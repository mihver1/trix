import Foundation
import Security

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
            return statusCode == 401
        default:
            return false
        }
    }

    var isMissingServerState: Bool {
        switch self {
        case let .server(_, _, statusCode):
            return statusCode == 404
        default:
            return false
        }
    }

    var isTransportFailure: Bool {
        if case .transport = self {
            return true
        }
        return false
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
    private let session: URLSession

    init(baseURL: URL) throws {
        self.baseURL = baseURL
        self.session = .shared

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

    func registerApplePushToken(
        accessToken: String,
        request: RegisterApplePushTokenRequest
    ) async throws -> RegisterApplePushTokenResponse {
        try await performJSONRequest(
            path: "/v0/devices/push-token",
            method: "PUT",
            accessToken: accessToken,
            body: request,
            responseType: RegisterApplePushTokenResponse.self
        )
    }

    func deleteApplePushToken(accessToken: String) async throws {
        try await performEmptyRequest(
            path: "/v0/devices/push-token",
            method: "DELETE",
            accessToken: accessToken
        )
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
        role: HistorySyncJobRole = .source,
        status: HistorySyncJobStatus? = nil,
        limit: Int = 50
    ) async throws -> HistorySyncJobListResponse {
        try await callFFI(accessToken: accessToken) { client in
            try HistorySyncJobListResponse(
                ffiValues: client.listHistorySyncJobs(
                    role: role.ffiValue,
                    status: status?.ffiValue,
                    limit: try TrixCoreCodec.uint32(limit, label: "history sync limit")
                ),
                role: role
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

    func fetchHistorySyncChunks(
        accessToken: String,
        jobId: UUID
    ) async throws -> [HistorySyncChunkSummary] {
        try await callFFI(accessToken: accessToken) { client in
            try client.getHistorySyncChunks(jobId: jobId.uuidString)
                .map(HistorySyncChunkSummary.init)
        }
    }

    func appendHistorySyncChunk(
        accessToken: String,
        jobId: UUID,
        sequenceNo: UInt64,
        payload: Data,
        cursorJson: JSONValue?,
        isFinal: Bool
    ) async throws -> AppendHistorySyncChunkResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AppendHistorySyncChunkResponse(
                ffiValue: client.appendHistorySyncChunk(
                    jobId: jobId.uuidString,
                    sequenceNo: sequenceNo,
                    payload: payload,
                    cursorJson: try TrixCoreCodec.encodeJSONString(cursorJson),
                    isFinal: isFinal
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

    func fetchLocalChatReadCursor(
        databasePath: URL,
        chatId: UUID
    ) async throws -> UInt64? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try store.chatReadCursor(chatId: chatId.uuidString)
        }
    }

    func fetchLocalChatUnreadCount(
        databasePath: URL,
        chatId: UUID,
        selfAccountId: UUID?
    ) async throws -> UInt64? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try store.chatUnreadCount(
                chatId: chatId.uuidString,
                selfAccountId: selfAccountId?.uuidString
            )
        }
    }

    func setLocalChatReadCursor(
        databasePath: URL,
        chatId: UUID,
        readCursorServerSeq: UInt64?,
        selfAccountId: UUID?
    ) async throws -> LocalChatReadState {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            return try LocalChatReadState(
                ffiValue: store.setChatReadCursor(
                    chatId: chatId.uuidString,
                    readCursorServerSeq: readCursorServerSeq,
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

    func fetchChatSyncCursor(
        statePath: URL,
        chatId: UUID
    ) async throws -> UInt64? {
        try await callFFI { _ in
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            return try coordinator.chatCursor(chatId: chatId.uuidString)
        }
    }

    func fetchMlsSignaturePublicKey(
        mlsStorageRoot: URL,
        credentialIdentity: Data
    ) async throws -> Data {
        try await callFFI { _ in
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            return try facade.signaturePublicKey()
        }
    }

    func fetchLocalChatMlsDiagnostics(
        databasePath: URL,
        mlsStorageRoot: URL,
        credentialIdentity: Data,
        chatId: UUID
    ) async throws -> LocalChatMlsDiagnostics? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
            let facade = try Self.makePersistentMlsFacade(
                storageRoot: mlsStorageRoot,
                credentialIdentity: credentialIdentity
            )
            guard let conversation = try? Self.prepareConversationIfNeeded(
                store: store,
                facade: facade,
                chatId: chatId
            ) else {
                return nil
            }

            let members = try facade.members(conversation: conversation)
            let ratchetTree = try conversation.exportRatchetTree()
            return LocalChatMlsDiagnostics(
                memberCount: members.count,
                ratchetTreeBytes: ratchetTree.count
            )
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

    private func performJSONRequest<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        accessToken: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        let url = absoluteURL(for: path)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            throw TrixAPIError.invalidPayload(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            return try decodeJSONResponse(response: response, data: data, as: responseType)
        } catch let error as TrixAPIError {
            throw error
        } catch {
            throw TrixAPIError.transport(error)
        }
    }

    private func performEmptyRequest(
        path: String,
        method: String,
        accessToken: String
    ) async throws {
        let url = absoluteURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TrixAPIError.invalidResponse
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw decodeServerError(statusCode: httpResponse.statusCode, data: data)
            }
        } catch let error as TrixAPIError {
            throw error
        } catch {
            throw TrixAPIError.transport(error)
        }
    }

    private func absoluteURL(for path: String) -> URL {
        if let url = URL(string: path, relativeTo: baseURL)?.absoluteURL {
            return url
        }
        return baseURL
    }

    private func decodeJSONResponse<Response: Decodable>(
        response: URLResponse,
        data: Data,
        as responseType: Response.Type
    ) throws -> Response {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw decodeServerError(statusCode: httpResponse.statusCode, data: data)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw TrixAPIError.invalidPayload(error.localizedDescription)
        }
    }

    private func decodeServerError(statusCode: Int, data: Data) -> TrixAPIError {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let envelope = try? decoder.decode(ServerErrorEnvelope.self, from: data) {
            return .server(
                code: envelope.code,
                message: envelope.message,
                statusCode: statusCode
            )
        }

        return .server(
            code: "server_error",
            message: HTTPURLResponse.localizedString(forStatusCode: statusCode),
            statusCode: statusCode
        )
    }

    private static func makeLocalHistoryStore(databasePath: URL) throws -> FfiLocalHistoryStore {
        if let clientStore = try makeWorkspaceClientStore(
            workspaceRoot: databasePath.deletingLastPathComponent()
        ) {
            let clientDatabasePath = clientStore.databasePath()
            guard !clientDatabasePath.isEmpty else {
                throw TrixAPIError.invalidPayload("Unified client store returned an empty database path.")
            }
            let historyStore = clientStore.historyStore()
            guard let resolvedDatabasePath = try historyStore.databasePath(),
                  resolvedDatabasePath == clientDatabasePath
            else {
                throw TrixAPIError.invalidPayload("Unified history store returned an unexpected database path.")
            }
            return historyStore
        }

        return try FfiLocalHistoryStore.newPersistent(databasePath: databasePath.path)
    }

    private static func makeSyncCoordinator(statePath: URL) throws -> FfiSyncCoordinator {
        if let clientStore = try makeWorkspaceClientStore(
            workspaceRoot: statePath.deletingLastPathComponent()
        ) {
            return clientStore.syncCoordinator()
        }

        return try FfiSyncCoordinator.newPersistent(statePath: statePath.path)
    }

    private static func makePersistentMlsFacade(
        storageRoot: URL,
        credentialIdentity: Data
    ) throws -> FfiMlsFacade {
        if let clientStore = try makeWorkspaceClientStore(
            workspaceRoot: storageRoot.deletingLastPathComponent()
        ) {
            guard !clientStore.mlsStorageRoot().isEmpty else {
                throw TrixAPIError.invalidPayload("Unified client store returned an empty MLS storage root.")
            }
            return try clientStore.openMlsFacade(credentialIdentity: credentialIdentity)
        }

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
        let resolvedDatabasePath = if let persistedDatabasePath = try store.databasePath() {
            URL(fileURLWithPath: persistedDatabasePath)
        } else {
            databasePath
        }
        let workspaceRoot = resolvedDatabasePath.deletingLastPathComponent()
        let mlsStorageRoot = resolvedPersistentMlsStorageRoot(workspaceRoot: workspaceRoot)
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

    private static func makeWorkspaceClientStore(workspaceRoot: URL) throws -> FfiClientStore? {
        let fileManager = FileManager.default
        let unifiedDatabasePath = workspaceRoot.appendingPathComponent("state-v1.db")
        let legacyState = legacyWorkspaceState(workspaceRoot: workspaceRoot)
        let hasUnifiedStore = fileManager.fileExists(atPath: unifiedDatabasePath.path)

        let attachmentsRoot = workspaceRoot.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)

        let databaseKey = try WorkspaceDatabaseKeyStore().getOrCreate(workspaceRoot: workspaceRoot)
        do {
            try prepareLegacyWorkspaceMigrationIfNeeded(
                workspaceRoot: workspaceRoot,
                legacyState: legacyState,
                hasUnifiedStore: hasUnifiedStore
            )

            return try FfiClientStore.open(
                config: FfiClientStoreConfig(
                    databasePath: unifiedDatabasePath.path,
                    databaseKey: databaseKey,
                    attachmentCacheRoot: attachmentsRoot.path
                )
            )
        } catch {
            if !hasUnifiedStore && legacyState.exists {
                return nil
            }
            throw error
        }
    }

    private static func legacyWorkspaceState(workspaceRoot: URL) -> LegacyWorkspaceState {
        let legacyHistoryPath = workspaceRoot.appendingPathComponent("local-history.sqlite")
        let legacyMigrationHistoryPath = workspaceRoot.appendingPathComponent("trix-client.db")
        let legacySyncPath = workspaceRoot.appendingPathComponent("sync-state.sqlite")
        let legacyMlsRoot = workspaceRoot.appendingPathComponent("mls-state", isDirectory: true)
        let fileManager = FileManager.default

        return LegacyWorkspaceState(
            historyPath: legacyHistoryPath,
            migrationHistoryPath: legacyMigrationHistoryPath,
            syncPath: legacySyncPath,
            mlsRoot: legacyMlsRoot,
            hasHistory: fileManager.fileExists(atPath: legacyHistoryPath.path)
                || fileManager.fileExists(atPath: legacyMigrationHistoryPath.path),
            hasSync: fileManager.fileExists(atPath: legacySyncPath.path),
            hasMls: fileManager.fileExists(atPath: legacyMlsRoot.path)
        )
    }

    private static func prepareLegacyWorkspaceMigrationIfNeeded(
        workspaceRoot: URL,
        legacyState: LegacyWorkspaceState,
        hasUnifiedStore: Bool
    ) throws {
        let unifiedMlsRoot = workspaceRoot.appendingPathComponent("mls", isDirectory: true)

        if !hasUnifiedStore,
           legacyState.hasHistory,
           !FileManager.default.fileExists(atPath: legacyState.migrationHistoryPath.path),
           FileManager.default.fileExists(atPath: legacyState.historyPath.path) {
            try copyItemIfNeeded(
                from: legacyState.historyPath,
                to: legacyState.migrationHistoryPath
            )
            try copySQLiteSidecarIfNeeded(
                from: legacyState.historyPath,
                to: legacyState.migrationHistoryPath,
                suffix: "-shm"
            )
            try copySQLiteSidecarIfNeeded(
                from: legacyState.historyPath,
                to: legacyState.migrationHistoryPath,
                suffix: "-wal"
            )
        }

        if legacyState.hasMls,
           !FileManager.default.fileExists(atPath: unifiedMlsRoot.path),
           FileManager.default.fileExists(atPath: legacyState.mlsRoot.path) {
            try copyItemIfNeeded(
                from: legacyState.mlsRoot,
                to: unifiedMlsRoot
            )
        }
    }

    private static func resolvedPersistentMlsStorageRoot(workspaceRoot: URL) -> URL {
        let unifiedMlsRoot = workspaceRoot.appendingPathComponent("mls", isDirectory: true)
        if FileManager.default.fileExists(atPath: unifiedMlsRoot.path) {
            return unifiedMlsRoot
        }

        return workspaceRoot.appendingPathComponent("mls-state", isDirectory: true)
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

    fileprivate static func randomDatabaseKey(count: Int = 32) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
        return bytes
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

private struct ServerErrorEnvelope: Decodable {
    let code: String
    let message: String
}

private struct LegacyWorkspaceState {
    let historyPath: URL
    let migrationHistoryPath: URL
    let syncPath: URL
    let mlsRoot: URL
    let hasHistory: Bool
    let hasSync: Bool
    let hasMls: Bool

    var exists: Bool {
        hasHistory || hasSync || hasMls
    }
}

private struct WorkspaceDatabaseKeyStore {
    private let keychainStore = KeychainStore()

    func getOrCreate(workspaceRoot: URL) throws -> Data {
        let account = "workspace-core-store-key-v1:\(workspaceRoot.lastPathComponent.lowercased())"
        if let existing = try keychainStore.loadData(account: account) {
            return existing
        }

        let generated = try TrixAPIClient.randomDatabaseKey()
        try keychainStore.save(generated, account: account)
        return generated
    }
}
