import Foundation

protocol AdminAPIProtocol: Sendable {
    func createSession(
        cluster: ClusterProfile,
        username: String,
        password: String
    ) async throws -> AdminSessionResponse

    func deleteSession(cluster: ClusterProfile, accessToken: String) async throws

    func fetchOverview(cluster: ClusterProfile, accessToken: String) async throws -> AdminOverviewResponse

    func fetchRegistrationSettings(
        cluster: ClusterProfile,
        accessToken: String
    ) async throws -> AdminRegistrationSettingsResponse

    func updateRegistrationSettings(
        cluster: ClusterProfile,
        accessToken: String,
        allowPublicAccountRegistration: Bool
    ) async throws -> AdminRegistrationSettingsResponse

    func fetchServerSettings(cluster: ClusterProfile, accessToken: String) async throws -> AdminServerSettingsResponse

    func updateServerSettings(
        cluster: ClusterProfile,
        accessToken: String,
        patch: PatchAdminServerSettingsRequest
    ) async throws -> AdminServerSettingsResponse

    func fetchUsers(
        cluster: ClusterProfile,
        accessToken: String,
        query: String?,
        status: String?,
        cursor: String?,
        limit: Int?
    ) async throws -> AdminUserListResponse

    func fetchUserDetail(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID
    ) async throws -> AdminUserSummary

    func provisionUser(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminUserProvisionRequest
    ) async throws -> CreateAdminUserProvisionResponse

    func disableUser(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID,
        reason: String?
    ) async throws

    func reactivateUser(cluster: ClusterProfile, accessToken: String, accountId: UUID) async throws

    // MARK: - Feature flags

    func fetchFeatureFlagDefinitions(cluster: ClusterProfile, accessToken: String) async throws
        -> AdminFeatureFlagDefinitionListResponse

    func createFeatureFlagDefinition(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminFeatureFlagDefinitionRequest
    ) async throws -> AdminFeatureFlagDefinition

    func patchFeatureFlagDefinition(
        cluster: ClusterProfile,
        accessToken: String,
        flagKey: String,
        patch: PatchAdminFeatureFlagDefinitionRequest
    ) async throws -> AdminFeatureFlagDefinition

    func fetchFeatureFlagOverrides(
        cluster: ClusterProfile,
        accessToken: String,
        query: FeatureFlagOverrideListQuery
    ) async throws -> AdminFeatureFlagOverrideListResponse

    func createFeatureFlagOverride(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminFeatureFlagOverrideRequest
    ) async throws -> AdminFeatureFlagOverride

    func patchFeatureFlagOverride(
        cluster: ClusterProfile,
        accessToken: String,
        overrideId: UUID,
        patch: PatchAdminFeatureFlagOverrideRequest
    ) async throws -> AdminFeatureFlagOverride

    func deleteFeatureFlagOverride(cluster: ClusterProfile, accessToken: String, overrideId: UUID) async throws

    // MARK: - Debug metrics

    func fetchDebugMetricSessions(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID?,
        limit: Int?
    ) async throws -> AdminDebugMetricSessionListResponse

    func createDebugMetricSession(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminDebugMetricSessionRequest
    ) async throws -> AdminDebugMetricSessionResponse

    func revokeDebugMetricSession(cluster: ClusterProfile, accessToken: String, sessionId: UUID) async throws

    func fetchDebugMetricBatches(
        cluster: ClusterProfile,
        accessToken: String,
        sessionId: UUID,
        limit: Int?
    ) async throws -> AdminDebugMetricBatchListResponse
}

struct FeatureFlagOverrideListQuery: Equatable, Sendable {
    var flagKey: String?
    var scope: AdminFeatureFlagScope?
    var platform: String?
    var accountId: UUID?
    var deviceId: UUID?
}

struct AdminAPIClient: Sendable, AdminAPIProtocol {
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        self.jsonDecoder = decoder
        let encoder = JSONEncoder()
        self.jsonEncoder = encoder
    }

    // MARK: - Session

    func createSession(
        cluster: ClusterProfile,
        username: String,
        password: String
    ) async throws -> AdminSessionResponse {
        let body = AdminSessionRequest(username: username, password: password)
        let data = try jsonEncoder.encode(body)
        let (responseData, response) = try await send(
            cluster: cluster,
            path: "v0/admin/session",
            method: "POST",
            accessToken: nil,
            body: data
        )
        return try decode(AdminSessionResponse.self, from: responseData, response: response)
    }

    func deleteSession(cluster: ClusterProfile, accessToken: String) async throws {
        let (_, response) = try await send(
            cluster: cluster,
            path: "v0/admin/session",
            method: "DELETE",
            accessToken: accessToken,
            body: nil
        )
        try throwIfNotSuccess(response, body: nil)
    }

    // MARK: - Overview & settings

    func fetchOverview(cluster: ClusterProfile, accessToken: String) async throws -> AdminOverviewResponse {
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/overview",
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminOverviewResponse.self, from: data, response: response)
    }

    func fetchRegistrationSettings(
        cluster: ClusterProfile,
        accessToken: String
    ) async throws -> AdminRegistrationSettingsResponse {
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/settings/registration",
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminRegistrationSettingsResponse.self, from: data, response: response)
    }

    func updateRegistrationSettings(
        cluster: ClusterProfile,
        accessToken: String,
        allowPublicAccountRegistration: Bool
    ) async throws -> AdminRegistrationSettingsResponse {
        let body = try jsonEncoder.encode(
            PatchAdminRegistrationSettingsRequest(allowPublicAccountRegistration: allowPublicAccountRegistration)
        )
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/settings/registration",
            method: "PATCH",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminRegistrationSettingsResponse.self, from: data, response: response)
    }

    func fetchServerSettings(cluster: ClusterProfile, accessToken: String) async throws -> AdminServerSettingsResponse {
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/settings/server",
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminServerSettingsResponse.self, from: data, response: response)
    }

    func updateServerSettings(
        cluster: ClusterProfile,
        accessToken: String,
        patch: PatchAdminServerSettingsRequest
    ) async throws -> AdminServerSettingsResponse {
        let body = try jsonEncoder.encode(patch)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/settings/server",
            method: "PATCH",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminServerSettingsResponse.self, from: data, response: response)
    }

    // MARK: - Users

    func fetchUsers(
        cluster: ClusterProfile,
        accessToken: String,
        query: String? = nil,
        status: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> AdminUserListResponse {
        let baseURL = try adminURL(cluster: cluster, path: "v0/admin/users")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AdminAPIError.invalidURL
        }
        var queryItems: [URLQueryItem] = []
        if let query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let status {
            queryItems.append(URLQueryItem(name: "status", value: status))
        }
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw AdminAPIError.invalidURL
        }
        let (data, response) = try await send(
            url: url,
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminUserListResponse.self, from: data, response: response)
    }

    func fetchUserDetail(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID
    ) async throws -> AdminUserSummary {
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/users/\(accountId.uuidString.lowercased())",
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminUserSummary.self, from: data, response: response)
    }

    func provisionUser(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminUserProvisionRequest
    ) async throws -> CreateAdminUserProvisionResponse {
        let body = try jsonEncoder.encode(request)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/users",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
        return try decode(CreateAdminUserProvisionResponse.self, from: data, response: response)
    }

    func disableUser(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID,
        reason: String? = nil
    ) async throws {
        let body: Data?
        if let reason {
            body = try jsonEncoder.encode(AdminDisableAccountRequest(reason: reason))
        } else {
            body = nil
        }
        let (_, response) = try await send(
            cluster: cluster,
            path: "v0/admin/users/\(accountId.uuidString.lowercased())/disable",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
        try throwIfNotSuccess(response, body: nil)
    }

    func reactivateUser(cluster: ClusterProfile, accessToken: String, accountId: UUID) async throws {
        let (_, response) = try await send(
            cluster: cluster,
            path: "v0/admin/users/\(accountId.uuidString.lowercased())/reactivate",
            method: "POST",
            accessToken: accessToken,
            body: nil
        )
        try throwIfNotSuccess(response, body: nil)
    }

    // MARK: - Feature flags

    func fetchFeatureFlagDefinitions(
        cluster: ClusterProfile,
        accessToken: String
    ) async throws -> AdminFeatureFlagDefinitionListResponse {
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/feature-flags/definitions",
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminFeatureFlagDefinitionListResponse.self, from: data, response: response)
    }

    func createFeatureFlagDefinition(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminFeatureFlagDefinitionRequest
    ) async throws -> AdminFeatureFlagDefinition {
        let body = try jsonEncoder.encode(request)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/feature-flags/definitions",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminFeatureFlagDefinition.self, from: data, response: response)
    }

    func patchFeatureFlagDefinition(
        cluster: ClusterProfile,
        accessToken: String,
        flagKey: String,
        patch: PatchAdminFeatureFlagDefinitionRequest
    ) async throws -> AdminFeatureFlagDefinition {
        let enc = Self.pathEncodeFeatureFlagKey(flagKey)
        let body = try jsonEncoder.encode(patch)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/feature-flags/definitions/\(enc)",
            method: "PATCH",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminFeatureFlagDefinition.self, from: data, response: response)
    }

    func fetchFeatureFlagOverrides(
        cluster: ClusterProfile,
        accessToken: String,
        query: FeatureFlagOverrideListQuery
    ) async throws -> AdminFeatureFlagOverrideListResponse {
        let baseURL = try adminURL(cluster: cluster, path: "v0/admin/feature-flags/overrides")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AdminAPIError.invalidURL
        }
        var items: [URLQueryItem] = []
        if let flagKey = query.flagKey {
            items.append(URLQueryItem(name: "flag_key", value: flagKey))
        }
        if let scope = query.scope {
            items.append(URLQueryItem(name: "scope", value: scope.rawValue))
        }
        if let platform = query.platform {
            items.append(URLQueryItem(name: "platform", value: platform))
        }
        if let accountId = query.accountId {
            items.append(URLQueryItem(name: "account_id", value: accountId.uuidString.lowercased()))
        }
        if let deviceId = query.deviceId {
            items.append(URLQueryItem(name: "device_id", value: deviceId.uuidString.lowercased()))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let url = components.url else {
            throw AdminAPIError.invalidURL
        }
        let (data, response) = try await send(url: url, method: "GET", accessToken: accessToken, body: nil)
        return try decode(AdminFeatureFlagOverrideListResponse.self, from: data, response: response)
    }

    func createFeatureFlagOverride(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminFeatureFlagOverrideRequest
    ) async throws -> AdminFeatureFlagOverride {
        let body = try jsonEncoder.encode(request)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/feature-flags/overrides",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminFeatureFlagOverride.self, from: data, response: response)
    }

    func patchFeatureFlagOverride(
        cluster: ClusterProfile,
        accessToken: String,
        overrideId: UUID,
        patch: PatchAdminFeatureFlagOverrideRequest
    ) async throws -> AdminFeatureFlagOverride {
        let body = try jsonEncoder.encode(patch)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/feature-flags/overrides/\(overrideId.uuidString.lowercased())",
            method: "PATCH",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminFeatureFlagOverride.self, from: data, response: response)
    }

    func deleteFeatureFlagOverride(cluster: ClusterProfile, accessToken: String, overrideId: UUID) async throws {
        let (_, response) = try await send(
            cluster: cluster,
            path: "v0/admin/feature-flags/overrides/\(overrideId.uuidString.lowercased())",
            method: "DELETE",
            accessToken: accessToken,
            body: nil
        )
        try throwIfNotSuccess(response, body: nil)
    }

    // MARK: - Debug metrics

    func fetchDebugMetricSessions(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID?,
        limit: Int?
    ) async throws -> AdminDebugMetricSessionListResponse {
        let baseURL = try adminURL(cluster: cluster, path: "v0/admin/debug/metric-sessions")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AdminAPIError.invalidURL
        }
        var items: [URLQueryItem] = []
        if let accountId {
            items.append(URLQueryItem(name: "account_id", value: accountId.uuidString.lowercased()))
        }
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let url = components.url else {
            throw AdminAPIError.invalidURL
        }
        let (data, response) = try await send(url: url, method: "GET", accessToken: accessToken, body: nil)
        return try decode(AdminDebugMetricSessionListResponse.self, from: data, response: response)
    }

    func createDebugMetricSession(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminDebugMetricSessionRequest
    ) async throws -> AdminDebugMetricSessionResponse {
        let body = try jsonEncoder.encode(request)
        let (data, response) = try await send(
            cluster: cluster,
            path: "v0/admin/debug/metric-sessions",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
        return try decode(AdminDebugMetricSessionResponse.self, from: data, response: response)
    }

    func revokeDebugMetricSession(cluster: ClusterProfile, accessToken: String, sessionId: UUID) async throws {
        let (_, response) = try await send(
            cluster: cluster,
            path: "v0/admin/debug/metric-sessions/\(sessionId.uuidString.lowercased())",
            method: "DELETE",
            accessToken: accessToken,
            body: nil
        )
        try throwIfNotSuccess(response, body: nil)
    }

    func fetchDebugMetricBatches(
        cluster: ClusterProfile,
        accessToken: String,
        sessionId: UUID,
        limit: Int?
    ) async throws -> AdminDebugMetricBatchListResponse {
        var path = "v0/admin/debug/metric-sessions/\(sessionId.uuidString.lowercased())/batches"
        if let limit {
            path += "?limit=\(limit)"
        }
        let (data, response) = try await send(
            cluster: cluster,
            path: path,
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        return try decode(AdminDebugMetricBatchListResponse.self, from: data, response: response)
    }

    // MARK: - Internals

    private static func pathEncodeFeatureFlagKey(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
    }

    private func adminURL(cluster: ClusterProfile, path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: cluster.baseURL) else {
            throw AdminAPIError.invalidURL
        }
        return url.absoluteURL
    }

    private func send(
        cluster: ClusterProfile,
        path: String,
        method: String,
        accessToken: String?,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try adminURL(cluster: cluster, path: path)
        return try await send(url: url, method: method, accessToken: accessToken, body: body)
    }

    private func send(
        url: URL,
        method: String,
        accessToken: String?,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdminAPIError.unexpectedStatus(-1, nil)
        }
        return (data, http)
    }

    private func throwIfNotSuccess(_ response: HTTPURLResponse, body: Data?) throws {
        guard (200 ... 299).contains(response.statusCode) else {
            let text = body.flatMap { String(data: $0, encoding: .utf8) }
            throw AdminAPIError.unexpectedStatus(response.statusCode, text)
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        response: HTTPURLResponse
    ) throws -> T {
        try throwIfNotSuccess(response, body: data)
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw AdminAPIError.decodingFailed(error)
        }
    }
}
