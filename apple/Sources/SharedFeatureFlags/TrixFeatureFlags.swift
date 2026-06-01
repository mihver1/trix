import Foundation

struct TrixFeatureFlagSnapshot: Codable, Equatable {
    var version: UInt64
    var updatedAtUnix: UInt64
    var flags: [TrixFeatureFlag]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAtUnix = "updated_at_unix"
        case flags
    }

    static let empty = TrixFeatureFlagSnapshot(version: 0, updatedAtUnix: 0, flags: [])

    func flag(_ key: String) -> TrixFeatureFlag? {
        flags.first { $0.key == key }
    }
}

struct TrixFeatureFlag: Codable, Identifiable, Equatable {
    var id: String { key }

    var key: String
    var enabled: Bool
    var rolloutPercentage: Int
    var clientVisible: Bool
    var description: String
    var updatedAtUnix: UInt64

    enum CodingKeys: String, CodingKey {
        case key
        case enabled
        case rolloutPercentage = "rollout_percentage"
        case clientVisible = "client_visible"
        case description
        case updatedAtUnix = "updated_at_unix"
    }
}

struct TrixFeatureFlagContext: Equatable {
    var stableID: String

    init(stableID: String) {
        self.stableID = stableID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct TrixFeatureFlagEvaluator {
    var snapshot: TrixFeatureFlagSnapshot

    func isEnabled(_ key: String, context: TrixFeatureFlagContext) -> Bool {
        guard let flag = snapshot.flag(key), flag.enabled else {
            return false
        }

        guard flag.rolloutPercentage < 100 else {
            return true
        }
        guard flag.rolloutPercentage > 0 else {
            return false
        }

        return rolloutBucket(key: key, stableID: context.stableID) < UInt32(flag.rolloutPercentage)
    }

    private func rolloutBucket(key: String, stableID: String) -> UInt32 {
        let value = "\(key):\(stableID)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return UInt32(hash % 100)
    }
}

struct TrixFeatureFlagHTTPClient {
    var baseURL: URL
    var bearerToken: String?
    var session: URLSession = .shared

    func fetchClientSnapshot() async throws -> TrixFeatureFlagSnapshot {
        try await get(path: "/v1/feature-flags/snapshot", requiresBearer: false)
    }

    func fetchAdminSnapshot() async throws -> TrixFeatureFlagSnapshot {
        try await get(path: "/v1/admin/feature-flags", requiresBearer: true)
    }

    func saveAdminFlag(_ flag: TrixFeatureFlag) async throws -> TrixFeatureFlagSnapshot {
        let request = TrixFeatureFlagUpdateRequest(
            key: flag.key,
            enabled: flag.enabled,
            rolloutPercentage: flag.rolloutPercentage,
            clientVisible: flag.clientVisible,
            description: flag.description
        )
        return try await send(
            path: "/v1/admin/feature-flags/\(flag.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? flag.key)",
            method: "PUT",
            body: request,
            requiresBearer: true
        )
    }

    private func get<T: Decodable>(path: String, requiresBearer: Bool) async throws -> T {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "GET"
        applyHeaders(to: &request, requiresBearer: requiresBearer)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        requiresBearer: Bool
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        applyHeaders(to: &request, requiresBearer: requiresBearer)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func applyHeaders(to request: inout URLRequest, requiresBearer: Bool) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard requiresBearer, let bearerToken, !bearerToken.isEmpty else {
            return
        }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }

    private func endpoint(path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw TrixFeatureFlagClientError.invalidURL
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TrixFeatureFlagClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TrixFeatureFlagClientError.requestFailed(http.statusCode, message)
        }
    }
}

struct TrixFeatureFlagUpdateRequest: Encodable {
    var key: String
    var enabled: Bool
    var rolloutPercentage: Int
    var clientVisible: Bool
    var description: String

    enum CodingKeys: String, CodingKey {
        case key
        case enabled
        case rolloutPercentage = "rollout_percentage"
        case clientVisible = "client_visible"
        case description
    }
}

enum TrixFeatureFlagClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The feature flag server URL is invalid."
        case .invalidResponse:
            "The feature flag server returned an invalid response."
        case let .requestFailed(status, message):
            "Feature flag request failed with HTTP \(status): \(message)"
        }
    }
}
