import Foundation

struct ClusterProfileStore {
    private let rootURL: URL

    private var persistenceURL: URL {
        rootURL.appendingPathComponent("cluster_profiles.json", isDirectory: false)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent(AppIdentity.applicationSupportDirectoryName, isDirectory: true)
    }

    func load() throws -> ClusterProfileSnapshot {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            return ClusterProfileSnapshot(profiles: [], lastSelectedClusterID: nil)
        }
        let data = try Data(contentsOf: persistenceURL)
        let file = try JSONDecoder().decode(PersistenceFile.self, from: data)
        return ClusterProfileSnapshot(
            profiles: file.profiles,
            lastSelectedClusterID: file.lastSelectedClusterID
        )
    }

    func save(_ profiles: [ClusterProfile], lastSelectedClusterID: UUID?) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let file = PersistenceFile(
            profiles: profiles,
            lastSelectedClusterID: lastSelectedClusterID
        )
        let data = try JSONEncoder().encode(file)
        try data.write(to: persistenceURL, options: .atomic)
    }

    private struct PersistenceFile: Codable {
        var profiles: [ClusterProfile]
        var lastSelectedClusterID: UUID?

        enum CodingKeys: String, CodingKey {
            case profiles
            case lastSelectedClusterID = "last_selected_cluster_id"
        }
    }
}
