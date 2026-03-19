import CryptoKit
import Foundation
import Security

struct LocalDeviceIdentity: Codable {
    let accountId: String
    let deviceId: String
    let accountSyncChatId: String
    let deviceDisplayName: String
    let platform: String
    let credentialIdentity: Data
    let accountRootPrivateKeyRaw: Data
    let transportPrivateKeyRaw: Data
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
            transportPrivateKeyRaw: transportPrivateKeyRaw
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
    case invalidPrivateKeyMaterial
    case invalidChallengeEncoding
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
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
    func signChallenge(_ challengeBytes: Data) throws -> Data {
        let transportPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: transportPrivateKeyRaw
        )
        return try transportPrivateKey.signature(for: challengeBytes)
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
