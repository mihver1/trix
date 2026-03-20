import Foundation
import Security

enum LocalDeviceTrustState: String, Codable {
    case active
    case pendingApproval
}

struct LocalDeviceIdentity: Codable {
    let accountId: String
    let deviceId: String
    let accountSyncChatId: String?
    let deviceDisplayName: String
    let platform: String
    let credentialIdentity: Data
    let accountRootPrivateKeyRaw: Data?
    let transportPrivateKeyRaw: Data
    let trustState: LocalDeviceTrustState

    init(
        accountId: String,
        deviceId: String,
        accountSyncChatId: String?,
        deviceDisplayName: String,
        platform: String,
        credentialIdentity: Data,
        accountRootPrivateKeyRaw: Data?,
        transportPrivateKeyRaw: Data,
        trustState: LocalDeviceTrustState
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.accountSyncChatId = accountSyncChatId
        self.deviceDisplayName = deviceDisplayName
        self.platform = platform
        self.credentialIdentity = credentialIdentity
        self.accountRootPrivateKeyRaw = accountRootPrivateKeyRaw
        self.transportPrivateKeyRaw = transportPrivateKeyRaw
        self.trustState = trustState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        accountSyncChatId = try container.decodeIfPresent(String.self, forKey: .accountSyncChatId)
        deviceDisplayName = try container.decode(String.self, forKey: .deviceDisplayName)
        platform = try container.decode(String.self, forKey: .platform)
        credentialIdentity = try container.decode(Data.self, forKey: .credentialIdentity)
        accountRootPrivateKeyRaw = try container.decodeIfPresent(Data.self, forKey: .accountRootPrivateKeyRaw)
        transportPrivateKeyRaw = try container.decode(Data.self, forKey: .transportPrivateKeyRaw)
        trustState = try container.decodeIfPresent(LocalDeviceTrustState.self, forKey: .trustState) ?? .active
    }
}

struct DeviceBootstrapMaterial {
    let credentialIdentity: Data
    private let accountRootPrivateKeyRaw: Data
    private let transportPrivateKeyRaw: Data

    static func generate() throws -> DeviceBootstrapMaterial {
        let accountRootPrivateKey = FfiAccountRootMaterial.generate()
        let transportPrivateKey = FfiDeviceKeyMaterial.generate()

        return DeviceBootstrapMaterial(
            credentialIdentity: try Data.trix_random(count: 32),
            accountRootPrivateKeyRaw: accountRootPrivateKey.privateKeyBytes(),
            transportPrivateKeyRaw: transportPrivateKey.privateKeyBytes()
        )
    }

    func accountRootMaterial() throws -> FfiAccountRootMaterial {
        try accountRootPrivateKeyRaw.trix_accountRootMaterial()
    }

    func deviceKeyMaterial() throws -> FfiDeviceKeyMaterial {
        try transportPrivateKeyRaw.trix_deviceKeyMaterial()
    }

    func makeLocalIdentity(
        accountId: String,
        deviceId: String,
        accountSyncChatId: String,
        deviceDisplayName: String,
        platform: String
    ) -> LocalDeviceIdentity {
        LocalDeviceIdentity(
            accountId: accountId,
            deviceId: deviceId,
            accountSyncChatId: accountSyncChatId,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentity: credentialIdentity,
            accountRootPrivateKeyRaw: accountRootPrivateKeyRaw,
            transportPrivateKeyRaw: transportPrivateKeyRaw,
            trustState: .active
        )
    }

    func makeLinkedLocalIdentity(
        accountId: String,
        deviceId: String,
        deviceDisplayName: String,
        platform: String
    ) -> LocalDeviceIdentity {
        LocalDeviceIdentity(
            accountId: accountId,
            deviceId: deviceId,
            accountSyncChatId: nil,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentity: credentialIdentity,
            accountRootPrivateKeyRaw: nil,
            transportPrivateKeyRaw: transportPrivateKeyRaw,
            trustState: .pendingApproval
        )
    }

}

struct LocalDeviceIdentityStore {
    private let keychain: KeychainStore
    private let account = "local-device-identity"

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func load() throws -> LocalDeviceIdentity? {
        guard let data = try keychain.load(account: account) else {
            return nil
        }

        return try JSONDecoder().decode(LocalDeviceIdentity.self, from: data)
    }

    func save(_ identity: LocalDeviceIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try keychain.save(data, account: account)
    }

    func delete() throws {
        try keychain.delete(account: account)
    }
}

enum LocalDeviceIdentityError: LocalizedError {
    case accountRootKeyUnavailable
    case invalidPrivateKeyMaterial
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .accountRootKeyUnavailable:
            return "This device does not have shared account root key material yet."
        case .invalidPrivateKeyMaterial:
            return "Stored device key material is invalid."
        case let .randomGenerationFailed(status):
            return "Secure random generation failed (\(status))."
        }
    }
}

extension LocalDeviceIdentity {
    var hasAccountRootKey: Bool {
        accountRootPrivateKeyRaw != nil
    }

    func accountRootMaterial() throws -> FfiAccountRootMaterial {
        guard let accountRootPrivateKeyRaw else {
            throw LocalDeviceIdentityError.accountRootKeyUnavailable
        }

        return try accountRootPrivateKeyRaw.trix_accountRootMaterial()
    }

    func deviceKeyMaterial() throws -> FfiDeviceKeyMaterial {
        try transportPrivateKeyRaw.trix_deviceKeyMaterial()
    }

    func markingActive() -> LocalDeviceIdentity {
        LocalDeviceIdentity(
            accountId: accountId,
            deviceId: deviceId,
            accountSyncChatId: accountSyncChatId,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentity: credentialIdentity,
            accountRootPrivateKeyRaw: accountRootPrivateKeyRaw,
            transportPrivateKeyRaw: transportPrivateKeyRaw,
            trustState: .active
        )
    }
}

private extension Data {
    func trix_accountRootMaterial() throws -> FfiAccountRootMaterial {
        do {
            return try FfiAccountRootMaterial.fromPrivateKey(privateKey: self)
        } catch {
            throw LocalDeviceIdentityError.invalidPrivateKeyMaterial
        }
    }

    func trix_deviceKeyMaterial() throws -> FfiDeviceKeyMaterial {
        do {
            return try FfiDeviceKeyMaterial.fromPrivateKey(privateKey: self)
        } catch {
            throw LocalDeviceIdentityError.invalidPrivateKeyMaterial
        }
    }
}

extension Data {
    static func trix_random(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }

        guard status == errSecSuccess else {
            throw LocalDeviceIdentityError.randomGenerationFailed(status)
        }

        return data
    }
}
