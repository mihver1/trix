import CryptoKit
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
        let accountRootPrivateKey = Curve25519.Signing.PrivateKey()
        let transportPrivateKey = Curve25519.Signing.PrivateKey()

        return DeviceBootstrapMaterial(
            credentialIdentity: try Data.trix_random(count: 32),
            accountRootPrivateKeyRaw: accountRootPrivateKey.rawRepresentation,
            transportPrivateKeyRaw: transportPrivateKey.rawRepresentation
        )
    }

    func makeCreateAccountRequest(
        profileName: String,
        handle: String?,
        profileBio: String?,
        deviceDisplayName: String,
        platform: String
    ) throws -> CreateAccountRequest {
        let accountRootPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: accountRootPrivateKeyRaw
        )
        let transportPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: transportPrivateKeyRaw
        )
        let transportPublicKey = transportPrivateKey.publicKey.rawRepresentation
        let accountRootPublicKey = accountRootPrivateKey.publicKey.rawRepresentation
        let bootstrapMessage = Self.bootstrapMessage(
            transportPublicKey: transportPublicKey,
            credentialIdentity: credentialIdentity
        )
        let bootstrapSignature = try accountRootPrivateKey.signature(for: bootstrapMessage)

        return CreateAccountRequest(
            handle: handle,
            profileName: profileName,
            profileBio: profileBio,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentityB64: credentialIdentity.base64EncodedString(),
            accountRootPubkeyB64: accountRootPublicKey.base64EncodedString(),
            accountRootSignatureB64: bootstrapSignature.base64EncodedString(),
            transportPubkeyB64: transportPublicKey.base64EncodedString()
        )
    }

    func makeCompleteLinkIntentRequest(
        linkToken: String,
        deviceDisplayName: String,
        platform: String
    ) throws -> CompleteLinkIntentRequest {
        let transportPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: transportPrivateKeyRaw
        )
        let transportPublicKey = transportPrivateKey.publicKey.rawRepresentation

        return CompleteLinkIntentRequest(
            linkToken: linkToken,
            deviceDisplayName: deviceDisplayName,
            platform: platform,
            credentialIdentityB64: credentialIdentity.base64EncodedString(),
            transportPubkeyB64: transportPublicKey.base64EncodedString(),
            keyPackages: []
        )
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

    private static func bootstrapMessage(
        transportPublicKey: Data,
        credentialIdentity: Data
    ) -> Data {
        var message = Data("trix-account-bootstrap:v1".utf8)
        message.append(trix_bigEndianLength(transportPublicKey.count))
        message.append(transportPublicKey)
        message.append(trix_bigEndianLength(credentialIdentity.count))
        message.append(credentialIdentity)
        return message
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
    case invalidChallengeEncoding
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .accountRootKeyUnavailable:
            return "This device does not have shared account root key material yet."
        case .invalidPrivateKeyMaterial:
            return "Stored device key material is invalid."
        case .invalidChallengeEncoding:
            return "Server challenge payload is invalid."
        case let .randomGenerationFailed(status):
            return "Secure random generation failed (\(status))."
        }
    }
}

extension LocalDeviceIdentity {
    var hasAccountRootKey: Bool {
        accountRootPrivateKeyRaw != nil
    }

    func signChallenge(_ challengeBytes: Data) throws -> Data {
        let transportPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: transportPrivateKeyRaw
        )
        return try transportPrivateKey.signature(for: challengeBytes)
    }

    func signDeviceRevoke(deviceId: String, reason: String) throws -> Data {
        try signAccountRootMessage(
            Self.revokeMessage(deviceId: deviceId, reason: reason)
        )
    }

    func signAccountBootstrapPayload(_ payload: Data) throws -> Data {
        try signAccountRootMessage(payload)
    }

    private func signAccountRootMessage(_ message: Data) throws -> Data {
        guard let accountRootPrivateKeyRaw else {
            throw LocalDeviceIdentityError.accountRootKeyUnavailable
        }

        let accountRootPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: accountRootPrivateKeyRaw
        )
        return try accountRootPrivateKey.signature(for: message)
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

    private static func revokeMessage(deviceId: String, reason: String) -> Data {
        let deviceIdData = Data(deviceId.utf8)
        let reasonData = Data(reason.utf8)

        var message = Data("trix-device-revoke:v1".utf8)
        message.append(trix_bigEndianLength(deviceIdData.count))
        message.append(deviceIdData)
        message.append(trix_bigEndianLength(reasonData.count))
        message.append(reasonData)
        return message
    }
}

private extension Curve25519.Signing.PrivateKey {
    init(rawRepresentation: Data) throws {
        do {
            try self.init(rawRepresentation: rawRepresentation)
        } catch {
            throw LocalDeviceIdentityError.invalidPrivateKeyMaterial
        }
    }
}

private func trix_bigEndianLength(_ count: Int) -> Data {
    let value = UInt32(count).bigEndian
    return withUnsafeBytes(of: value) { Data($0) }
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

    static func trix_base64Decoded(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else {
            throw LocalDeviceIdentityError.invalidChallengeEncoding
        }

        return data
    }
}
