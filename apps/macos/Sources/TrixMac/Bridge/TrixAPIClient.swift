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

    private let session: URLSession
    private let decoder: JSONDecoder
    private let ffiClient: FfiServerApiClient

    init(baseURL: URL, session: URLSession = .shared) throws {
        self.baseURL = baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        do {
            self.ffiClient = try FfiServerApiClient(baseUrl: baseURL.absoluteString)
        } catch {
            throw Self.mapFFIError(error)
        }
    }

    func fetchHealth() async throws -> HealthResponse {
        try await systemGet("v0/system/health")
    }

    func fetchVersion() async throws -> VersionResponse {
        try await systemGet("v0/system/version")
    }

    func createAccount(_ request: CreateAccountRequest) async throws -> CreateAccountResponse {
        try await callFFI { client in
            try CreateAccountResponse(
                ffiValue: client.createAccount(params: try request.ffiParams())
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

    func fetchCurrentAccount(accessToken: String) async throws -> AccountProfileResponse {
        try await callFFI(accessToken: accessToken) { client in
            try AccountProfileResponse(ffiValue: client.getMe())
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
            return try ChatListResponse(ffiValues: store.listChats())
        }
    }

    func fetchLocalChatDetail(
        databasePath: URL,
        chatId: UUID
    ) async throws -> ChatDetailResponse? {
        try await callFFI { _ in
            let store = try Self.makeLocalHistoryStore(databasePath: databasePath)
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

    func fetchSyncStateSnapshot(statePath: URL) async throws -> SyncStateSnapshot {
        try await callFFI { _ in
            let coordinator = try Self.makeSyncCoordinator(statePath: statePath)
            return try SyncStateSnapshot(ffiValue: coordinator.stateSnapshot())
        }
    }

    private func systemGet<Response: Decodable>(_ path: String) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        let request = URLRequest(url: url)
        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrixAPIError.transport(error)
        }

        return try decode(data: data, response: response)
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

    private func decode<Response: Decodable>(data: Data, response: URLResponse) throws -> Response {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let apiError = try? decoder.decode(ErrorResponse.self, from: data) {
                throw TrixAPIError.server(
                    code: apiError.code,
                    message: apiError.message,
                    statusCode: httpResponse.statusCode
                )
            }

            throw TrixAPIError.invalidResponse
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw TrixAPIError.transport(error)
        }
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
