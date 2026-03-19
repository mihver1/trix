import Foundation

struct PersistedSession: Codable {
    let baseURLString: String
    let accountId: UUID
    let deviceId: UUID
    let accountSyncChatId: UUID
    let profileName: String
    let handle: String?
    let deviceDisplayName: String
}

struct SessionStore {
    private let directoryName: String
    private let fileName: String

    init(
        directoryName: String = "TrixMac",
        fileName: String = "session.json"
    ) {
        self.directoryName = directoryName
        self.fileName = fileName
    }

    func load() throws -> PersistedSession? {
        let fileURL = try sessionFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(PersistedSession.self, from: data)
    }

    func save(_ session: PersistedSession) throws {
        let fileURL = try sessionFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        let fileURL = try sessionFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func sessionFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appending(path: directoryName)
            .appending(path: fileName)
    }
}
