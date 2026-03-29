import Foundation

struct AdminSessionStore {
    private let rootURL: URL
    private let keychain: AdminKeychainStore
    private let clock: @Sendable () -> Date

    private var metadataURL: URL {
        rootURL.appendingPathComponent("admin_session_metadata.json", isDirectory: false)
    }

    init(
        rootURL: URL,
        keychain: AdminKeychainStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.keychain = keychain
        self.clock = clock
    }

    static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        try ClusterProfileStore.defaultRootURL(fileManager: fileManager)
    }

    func saveSession(_ response: AdminSessionResponse, clusterID: UUID) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try keychain.saveAccessToken(response.accessToken, for: clusterID)
        var meta = try loadMetadata()
        meta[clusterID] = SessionMetadataEntry(
            expiresAtUnix: response.expiresAtUnix,
            username: response.username
        )
        try saveMetadata(meta)
    }

    func loadSession(clusterID: UUID) throws -> StoredAdminSession? {
        guard let entry = try loadMetadata()[clusterID] else {
            try? keychain.removeAccessToken(for: clusterID)
            return nil
        }
        let now = UInt64(clock().timeIntervalSince1970)
        if entry.expiresAtUnix <= now {
            try clearSession(clusterID: clusterID)
            return nil
        }
        guard let token = try keychain.loadAccessToken(for: clusterID), !token.isEmpty else {
            try clearSession(clusterID: clusterID)
            return nil
        }
        return StoredAdminSession(
            accessToken: token,
            expiresAtUnix: entry.expiresAtUnix,
            username: entry.username
        )
    }

    func clearSession(clusterID: UUID) throws {
        try keychain.removeAccessToken(for: clusterID)
        var meta = try loadMetadata()
        meta.removeValue(forKey: clusterID)
        try saveMetadata(meta)
    }

    private func loadMetadata() throws -> [UUID: SessionMetadataEntry] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: metadataURL)
        let raw = try JSONDecoder().decode([String: SessionMetadataEntry].self, from: data)
        var out: [UUID: SessionMetadataEntry] = [:]
        for (key, value) in raw {
            guard let uuid = UUID(uuidString: key) else { continue }
            out[uuid] = value
        }
        return out
    }

    private func saveMetadata(_ entries: [UUID: SessionMetadataEntry]) throws {
        var raw: [String: SessionMetadataEntry] = [:]
        for (key, value) in entries {
            raw[key.uuidString.lowercased()] = value
        }
        let data = try JSONEncoder().encode(raw)
        try data.write(to: metadataURL, options: .atomic)
    }
}

struct StoredAdminSession: Equatable, Sendable {
    var accessToken: String
    var expiresAtUnix: UInt64
    var username: String
}

private struct SessionMetadataEntry: Codable, Equatable {
    var expiresAtUnix: UInt64
    var username: String

    enum CodingKeys: String, CodingKey {
        case expiresAtUnix = "expires_at_unix"
        case username
    }
}
