import Foundation

struct PersistedSession: Codable {
    var baseURLString: String
    var accountId: UUID
    var deviceId: UUID
    var accountSyncChatId: UUID?
    var profileName: String
    var handle: String?
    var deviceDisplayName: String
    var deviceStatus: DeviceStatus

    init(
        baseURLString: String,
        accountId: UUID,
        deviceId: UUID,
        accountSyncChatId: UUID?,
        profileName: String,
        handle: String?,
        deviceDisplayName: String,
        deviceStatus: DeviceStatus
    ) {
        self.baseURLString = baseURLString
        self.accountId = accountId
        self.deviceId = deviceId
        self.accountSyncChatId = accountSyncChatId
        self.profileName = profileName
        self.handle = handle
        self.deviceDisplayName = deviceDisplayName
        self.deviceStatus = deviceStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decode(String.self, forKey: .baseURLString)
        accountId = try container.decode(UUID.self, forKey: .accountId)
        deviceId = try container.decode(UUID.self, forKey: .deviceId)
        accountSyncChatId = try container.decodeIfPresent(UUID.self, forKey: .accountSyncChatId)
        profileName = try container.decode(String.self, forKey: .profileName)
        handle = try container.decodeIfPresent(String.self, forKey: .handle)
        deviceDisplayName = try container.decode(String.self, forKey: .deviceDisplayName)
        deviceStatus = try container.decodeIfPresent(DeviceStatus.self, forKey: .deviceStatus) ?? .active
    }
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
