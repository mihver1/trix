import Foundation

enum ClusterAuthMode: String, Codable, Sendable, CaseIterable, Hashable {
    case localCredentials = "local_credentials"
}

struct ClusterProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var baseURL: URL
    var environmentLabel: String
    var authMode: ClusterAuthMode

    init(
        id: UUID,
        displayName: String,
        baseURL: URL,
        environmentLabel: String,
        authMode: ClusterAuthMode = .localCredentials
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.environmentLabel = environmentLabel
        self.authMode = authMode
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case baseURL = "base_url"
        case environmentLabel = "environment_label"
        case authMode = "auth_mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        let urlString = try c.decode(String.self, forKey: .baseURL)
        guard let url = URL(string: urlString) else {
            throw DecodingError.dataCorruptedError(forKey: .baseURL, in: c, debugDescription: "Invalid base URL")
        }
        baseURL = url
        environmentLabel = try c.decode(String.self, forKey: .environmentLabel)
        authMode = try c.decodeIfPresent(ClusterAuthMode.self, forKey: .authMode) ?? .localCredentials
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(baseURL.absoluteString, forKey: .baseURL)
        try c.encode(environmentLabel, forKey: .environmentLabel)
        try c.encode(authMode, forKey: .authMode)
    }
}

struct ClusterProfileSnapshot: Equatable, Sendable {
    var profiles: [ClusterProfile]
    var lastSelectedClusterID: UUID?
}
