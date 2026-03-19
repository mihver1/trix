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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func fetchHealth() async throws -> HealthResponse {
        try await get("v0/system/health")
    }

    func fetchVersion() async throws -> VersionResponse {
        try await get("v0/system/version")
    }

    func createAccount(_ request: CreateAccountRequest) async throws -> CreateAccountResponse {
        try await post("v0/accounts", body: request)
    }

    func createAuthChallenge(_ request: AuthChallengeRequest) async throws -> AuthChallengeResponse {
        try await post("v0/auth/challenge", body: request)
    }

    func createAuthSession(_ request: AuthSessionRequest) async throws -> AuthSessionResponse {
        try await post("v0/auth/session", body: request)
    }

    func fetchCurrentAccount(accessToken: String) async throws -> AccountProfileResponse {
        try await get("v0/accounts/me", accessToken: accessToken)
    }

    func fetchDevices(accessToken: String) async throws -> DeviceListResponse {
        try await get("v0/devices", accessToken: accessToken)
    }

    func fetchInbox(
        accessToken: String,
        afterInboxId: UInt64? = nil,
        limit: Int = 50
    ) async throws -> InboxResponse {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        if let afterInboxId {
            queryItems.append(URLQueryItem(name: "after_inbox_id", value: String(afterInboxId)))
        }

        return try await get(
            "v0/inbox",
            queryItems: queryItems,
            accessToken: accessToken
        )
    }

    func leaseInbox(
        accessToken: String,
        request: LeaseInboxRequest
    ) async throws -> LeaseInboxResponse {
        try await post(
            "v0/inbox/lease",
            body: request,
            accessToken: accessToken
        )
    }

    func ackInbox(
        accessToken: String,
        request: AckInboxRequest
    ) async throws -> AckInboxResponse {
        try await post(
            "v0/inbox/ack",
            body: request,
            accessToken: accessToken
        )
    }

    func fetchAccountKeyPackages(
        accessToken: String,
        accountId: UUID
    ) async throws -> AccountKeyPackagesResponse {
        try await get(
            "v0/accounts/\(accountId.uuidString)/key-packages",
            accessToken: accessToken
        )
    }

    func publishKeyPackages(
        accessToken: String,
        request: PublishKeyPackagesRequest
    ) async throws -> PublishKeyPackagesResponse {
        try await post(
            "v0/key-packages:publish",
            body: request,
            accessToken: accessToken
        )
    }

    func reserveKeyPackages(
        accessToken: String,
        request: ReserveKeyPackagesRequest
    ) async throws -> AccountKeyPackagesResponse {
        try await post(
            "v0/key-packages:reserve",
            body: request,
            accessToken: accessToken
        )
    }

    func createLinkIntent(accessToken: String) async throws -> CreateLinkIntentResponse {
        try await post(
            "v0/devices/link-intents",
            body: Optional<String>.none,
            accessToken: accessToken
        )
    }

    func completeLinkIntent(
        linkIntentId: UUID,
        request: CompleteLinkIntentRequest
    ) async throws -> CompleteLinkIntentResponse {
        try await post(
            "v0/devices/link-intents/\(linkIntentId.uuidString)/complete",
            body: request
        )
    }

    func approveDevice(
        accessToken: String,
        deviceId: UUID,
        request: ApproveDeviceRequest
    ) async throws -> ApproveDeviceResponse {
        try await post(
            "v0/devices/\(deviceId.uuidString)/approve",
            body: request,
            accessToken: accessToken
        )
    }

    func fetchDeviceApprovePayload(
        accessToken: String,
        deviceId: UUID
    ) async throws -> DeviceApprovePayloadResponse {
        try await get(
            "v0/devices/\(deviceId.uuidString)/approve-payload",
            accessToken: accessToken
        )
    }

    func revokeDevice(
        accessToken: String,
        deviceId: UUID,
        request: RevokeDeviceRequest
    ) async throws -> RevokeDeviceResponse {
        try await post(
            "v0/devices/\(deviceId.uuidString)/revoke",
            body: request,
            accessToken: accessToken
        )
    }

    func fetchHistorySyncJobs(
        accessToken: String,
        status: HistorySyncJobStatus? = nil,
        limit: Int = 50
    ) async throws -> HistorySyncJobListResponse {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let status {
            queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
        }

        return try await get(
            "v0/history-sync/jobs",
            queryItems: queryItems,
            accessToken: accessToken
        )
    }

    func completeHistorySyncJob(
        accessToken: String,
        jobId: UUID,
        request: CompleteHistorySyncJobRequest
    ) async throws -> CompleteHistorySyncJobResponse {
        try await post(
            "v0/history-sync/jobs/\(jobId.uuidString)/complete",
            body: request,
            accessToken: accessToken
        )
    }

    func fetchChats(accessToken: String) async throws -> ChatListResponse {
        try await get("v0/chats", accessToken: accessToken)
    }

    func fetchChatDetail(accessToken: String, chatId: UUID) async throws -> ChatDetailResponse {
        try await get("v0/chats/\(chatId.uuidString)", accessToken: accessToken)
    }

    func fetchChatHistory(
        accessToken: String,
        chatId: UUID,
        limit: Int = 100
    ) async throws -> ChatHistoryResponse {
        try await get(
            "v0/chats/\(chatId.uuidString)/history",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            accessToken: accessToken
        )
    }

    private func get<Response: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        accessToken: String? = nil
    ) async throws -> Response {
        try await perform(
            path: path,
            queryItems: queryItems,
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        accessToken: String? = nil
    ) async throws -> Response {
        try await perform(
            path: path,
            queryItems: [],
            method: "POST",
            body: body,
            accessToken: accessToken
        )
    }

    private func post<Response: Decodable>(
        _ path: String,
        body: String?,
        accessToken: String? = nil
    ) async throws -> Response {
        try await perform(
            path: path,
            queryItems: [],
            method: "POST",
            body: body,
            accessToken: accessToken
        )
    }

    private func perform<Body: Encodable, Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Body?,
        accessToken: String?
    ) async throws -> Response {
        let endpoint = try endpointURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TrixAPIError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                    throw TrixAPIError.server(
                        code: errorResponse.code,
                        message: errorResponse.message,
                        statusCode: httpResponse.statusCode
                    )
                }

                throw TrixAPIError.server(
                    code: "http_\(httpResponse.statusCode)",
                    message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                    statusCode: httpResponse.statusCode
                )
            }

            return try decoder.decode(Response.self, from: data)
        } catch let error as TrixAPIError {
            throw error
        } catch {
            throw TrixAPIError.transport(error)
        }
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: true
        ) else {
            throw TrixAPIError.invalidPayload("Не удалось собрать URL запроса.")
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw TrixAPIError.invalidPayload("Не удалось собрать URL запроса.")
        }

        return url
    }
}
