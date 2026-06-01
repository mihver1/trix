import Foundation
import Security

struct TrixAdminAPIClient {
    var baseURL: URL
    var bearerToken: String
    var session: URLSession = .shared

    func sessionInfo() async throws -> TrixAdminSession {
        try await get(path: "/v1/admin/session")
    }

    func searchUsers(query: String, limit: Int = 100) async throws -> [TrixAdminUser] {
        let response: TrixAdminUserSearchResponse = try await get(
            path: "/v1/admin/users",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ]
        )
        return response.users
    }

    func provisionUser(localpart: String, password: String) async throws -> TrixAdminUserMutationResponse {
        try await send(
            path: "/v1/admin/users",
            method: "POST",
            body: TrixAdminProvisionUserRequest(localpart: localpart, password: password)
        )
    }

    func resetPassword(localpart: String, password: String) async throws -> TrixAdminUserMutationResponse {
        try await send(
            path: "/v1/admin/users/\(pathEscaped(localpart))/reset-password",
            method: "POST",
            body: TrixAdminPasswordRequest(password: password)
        )
    }

    func disableUser(localpart: String, reason: String) async throws -> TrixAdminUserMutationResponse {
        try await send(
            path: "/v1/admin/users/\(pathEscaped(localpart))/disable",
            method: "POST",
            body: TrixAdminDisableUserRequest(reason: reason.isEmpty ? nil : reason)
        )
    }

    func enableUser(localpart: String) async throws -> TrixAdminUserMutationResponse {
        try await sendWithoutBody(path: "/v1/admin/users/\(pathEscaped(localpart))/enable", method: "POST")
    }

    func opsStatus() async throws -> TrixAdminOpsStatus {
        try await get(path: "/v1/admin/ops/status")
    }

    func metricsSummary() async throws -> TrixAdminMetricsSummary {
        try await get(path: "/v1/admin/metrics/summary")
    }

    func mediaStorage() async throws -> TrixAdminMediaStorage {
        try await get(path: "/v1/admin/media/storage")
    }

    func recentLogs(service: String, limit: Int) async throws -> TrixAdminRecentLogs {
        try await get(
            path: "/v1/admin/logs/recent",
            queryItems: [
                URLQueryItem(name: "service", value: service),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ]
        )
    }

    func recentAudit(limit: Int) async throws -> TrixAdminRecentAudit {
        try await get(
            path: "/v1/admin/audit/recent",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(limit)"),
            ]
        )
    }

    func sendWakePush(_ request: TrixAdminWakePushRequest) async throws -> TrixAdminJSONResponse {
        try await send(path: "/v1/admin/push/test/wake", method: "POST", body: request)
    }

    func sendVoIPPush(_ request: TrixAdminVoIPPushRequest) async throws -> TrixAdminJSONResponse {
        try await send(path: "/v1/admin/push/test/voip", method: "POST", body: request)
    }

    func deleteFeatureFlag(key: String) async throws -> TrixFeatureFlagSnapshot {
        try await sendWithoutBody(path: "/v1/admin/feature-flags/\(pathEscaped(key))", method: "DELETE")
    }

    private func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        var request = URLRequest(url: try endpoint(path: path, queryItems: queryItems))
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendWithoutBody<Response: Decodable>(
        path: String,
        method: String
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = method
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func endpoint(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TrixAdminAPIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let finalURL = components.url else {
            throw TrixAdminAPIError.invalidURL
        }
        return finalURL
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TrixAdminAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TrixAdminAPIError.requestFailed(http.statusCode, message)
        }
    }

    private func pathEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

enum TrixAdminAPIError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The admin server URL is invalid."
        case .invalidResponse:
            "The admin server returned an invalid response."
        case let .requestFailed(status, message):
            "Admin request failed with HTTP \(status): \(message)"
        }
    }
}

struct TrixAdminCredentialStore {
    private let service = "com.softgrid.trix.admin"
    private let account = "admin-api-token"

    func loadToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return ""
        }
        return token
    }

    func saveToken(_ token: String) {
        deleteToken()
        guard !token.isEmpty, let data = token.data(using: .utf8) else {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct TrixAdminSession: Decodable {
    var role: String
    var serverTimeUnix: UInt64
    var capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case role
        case serverTimeUnix = "server_time_unix"
        case capabilities
    }
}

struct TrixAdminUserSearchResponse: Decodable {
    var users: [TrixAdminUser]
}

struct TrixAdminUser: Decodable, Identifiable, Hashable {
    var id: String { jid }
    var localpart: String
    var jid: String
    var displayName: String?
    var status: String

    enum CodingKeys: String, CodingKey {
        case localpart
        case jid
        case displayName = "display_name"
        case status
    }
}

struct TrixAdminProvisionUserRequest: Encodable {
    var localpart: String
    var password: String
}

struct TrixAdminPasswordRequest: Encodable {
    var password: String
}

struct TrixAdminDisableUserRequest: Encodable {
    var reason: String?
}

struct TrixAdminUserMutationResponse: Decodable {
    var jid: String
    var changed: Bool
}

struct TrixAdminOpsStatus: Decodable {
    var ejabberdAPI: String
    var pushGateway: String
    var mediaStorage: String

    enum CodingKeys: String, CodingKey {
        case ejabberdAPI = "ejabberd_api"
        case pushGateway = "push_gateway"
        case mediaStorage = "media_storage"
    }
}

struct TrixAdminMetricsSummary: Decodable {
    var checkedAtUnix: UInt64
    var enabledFeatureFlags: Int
    var totalFeatureFlags: Int
    var mediaTotalBytes: UInt64
    var mediaFileCount: UInt64
    var ejabberdAPIReachable: Bool
    var pushGatewayReachable: Bool

    enum CodingKeys: String, CodingKey {
        case checkedAtUnix = "checked_at_unix"
        case enabledFeatureFlags = "enabled_feature_flags"
        case totalFeatureFlags = "total_feature_flags"
        case mediaTotalBytes = "media_total_bytes"
        case mediaFileCount = "media_file_count"
        case ejabberdAPIReachable = "ejabberd_api_reachable"
        case pushGatewayReachable = "push_gateway_reachable"
    }
}

struct TrixAdminMediaStorage: Decodable {
    var status: String
    var rootPath: String
    var totalBytes: UInt64
    var fileCount: UInt64
    var newestModifiedUnix: UInt64?

    enum CodingKeys: String, CodingKey {
        case status
        case rootPath = "root_path"
        case totalBytes = "total_bytes"
        case fileCount = "file_count"
        case newestModifiedUnix = "newest_modified_unix"
    }
}

struct TrixAdminRecentLogs: Decodable {
    var service: String
    var status: String
    var lines: [String]
}

struct TrixAdminRecentAudit: Decodable {
    var status: String
    var events: [TrixAdminAuditEvent]
}

struct TrixAdminAuditEvent: Decodable, Identifiable, Hashable {
    var id: String {
        "\(timestampUnix)-\(action)-\(target)-\(outcome)"
    }

    var timestampUnix: UInt64
    var actor: String
    var action: String
    var target: String
    var outcome: String
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case timestampUnix = "timestamp_unix"
        case actor
        case action
        case target
        case outcome
        case detail
    }
}

struct TrixAdminWakePushRequest: Encodable {
    var tokenHex: String
    var environment: String
    var account: String?
    var room: String?
    var badge: UInt32?

    enum CodingKeys: String, CodingKey {
        case tokenHex = "token_hex"
        case environment
        case account
        case room
        case badge
    }
}

struct TrixAdminVoIPPushRequest: Encodable {
    var account: String
    var callID: String

    enum CodingKeys: String, CodingKey {
        case account
        case callID = "call_id"
    }
}

struct TrixAdminJSONResponse: Decodable {
    var values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: TrixAdminJSONValue].self)
        values = object.mapValues(\.displayValue)
    }
}

enum TrixAdminJSONValue: Decodable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case null
    case object

    var displayValue: String {
        switch self {
        case let .string(value):
            value
        case let .bool(value):
            value ? "true" : "false"
        case let .int(value):
            "\(value)"
        case let .double(value):
            "\(value)"
        case .null:
            "null"
        case .object:
            "..."
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .object
        }
    }
}
