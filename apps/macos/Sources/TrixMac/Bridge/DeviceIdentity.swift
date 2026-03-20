import Foundation

struct StoredDeviceIdentity {
    let accountRootSeed: Data?
    let transportSeed: Data
    let credentialIdentity: Data
}

struct DeviceIdentityMaterial {
    static let platform = "macos"

    private let accountRootMaterial: FfiAccountRootMaterial?
    private let transportMaterial: FfiDeviceKeyMaterial
    private let credentialIdentity: Data

    init(storedIdentity: StoredDeviceIdentity) throws {
        if let accountRootSeed = storedIdentity.accountRootSeed {
            self.accountRootMaterial = try FfiAccountRootMaterial.fromPrivateKey(
                privateKey: accountRootSeed
            )
        } else {
            self.accountRootMaterial = nil
        }
        self.transportMaterial = try FfiDeviceKeyMaterial.fromPrivateKey(
            privateKey: storedIdentity.transportSeed
        )
        self.credentialIdentity = storedIdentity.credentialIdentity
    }

    static func make(
        profileName: String,
        handle: String?,
        deviceDisplayName: String,
        platform: String
    ) throws -> DeviceIdentityMaterial {
        let accountRootMaterial = FfiAccountRootMaterial.generate()
        let transportMaterial = FfiDeviceKeyMaterial.generate()

        let payload = CredentialIdentityPayload(
            version: 1,
            platform: platform,
            profileName: profileName,
            handle: handle,
            deviceDisplayName: deviceDisplayName,
            createdAtUnix: UInt64(Date().timeIntervalSince1970)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let credentialIdentity = try encoder.encode(payload)

        return DeviceIdentityMaterial(
            accountRootMaterial: accountRootMaterial,
            transportMaterial: transportMaterial,
            credentialIdentity: credentialIdentity
        )
    }

    static func makeLinkedDevice(
        deviceDisplayName: String,
        platform: String,
        profileName: String = "Linked Account"
    ) throws -> DeviceIdentityMaterial {
        let transportMaterial = FfiDeviceKeyMaterial.generate()

        let payload = CredentialIdentityPayload(
            version: 1,
            platform: platform,
            profileName: profileName,
            handle: nil,
            deviceDisplayName: deviceDisplayName,
            createdAtUnix: UInt64(Date().timeIntervalSince1970)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let credentialIdentity = try encoder.encode(payload)

        return DeviceIdentityMaterial(
            accountRootMaterial: nil,
            transportMaterial: transportMaterial,
            credentialIdentity: credentialIdentity
        )
    }

    func makeCreateAccountRequest(
        handle: String?,
        profileName: String,
        profileBio: String?,
        deviceDisplayName: String
    ) throws -> CreateAccountRequest {
        guard let accountRootMaterial else {
            throw TrixAPIError.invalidPayload("У этого устройства нет account-root ключа.")
        }

        let transportPublicKey = transportMaterial.publicKeyBytes()
        let bootstrapMessage = Self.bootstrapMessage(
            transportPublicKey: transportPublicKey,
            credentialIdentity: credentialIdentity
        )

        let signature = accountRootMaterial.sign(payload: bootstrapMessage)

        return CreateAccountRequest(
            handle: handle,
            profileName: profileName,
            profileBio: profileBio,
            deviceDisplayName: deviceDisplayName,
            platform: Self.platform,
            credentialIdentityB64: credentialIdentity.base64EncodedString(),
            accountRootPubkeyB64: accountRootMaterial.publicKeyBytes().base64EncodedString(),
            accountRootSignatureB64: signature.base64EncodedString(),
            transportPubkeyB64: transportPublicKey.base64EncodedString()
        )
    }

    func makeCompleteLinkIntentRequest(
        linkToken: UUID,
        deviceDisplayName: String
    ) -> CompleteLinkIntentRequest {
        CompleteLinkIntentRequest(
            linkToken: linkToken.uuidString,
            deviceDisplayName: deviceDisplayName,
            platform: Self.platform,
            credentialIdentityB64: credentialIdentity.base64EncodedString(),
            transportPubkeyB64: transportMaterial.publicKeyBytes().base64EncodedString(),
            keyPackages: []
        )
    }

    func transportSignatureB64(for challenge: Data) throws -> String {
        let signature = transportMaterial.sign(payload: challenge)
        return signature.base64EncodedString()
    }

    func accountBootstrapSignatureB64(
        transportPublicKey: Data,
        credentialIdentity: Data
    ) throws -> String {
        try accountRootSignatureB64(
            for: Self.bootstrapMessage(
                transportPublicKey: transportPublicKey,
                credentialIdentity: credentialIdentity
            ),
            errorMessage: "Approve доступен только на root-capable устройстве."
        )
    }

    func accountRootSignatureB64(
        for payload: Data,
        errorMessage: String = "У этого устройства нет account-root ключа."
    ) throws -> String {
        guard let accountRootMaterial else {
            throw TrixAPIError.invalidPayload(errorMessage)
        }

        let signature = accountRootMaterial.sign(payload: payload)
        return signature.base64EncodedString()
    }

    func revokeSignatureB64(deviceID: UUID, reason: String) throws -> String {
        guard let accountRootMaterial else {
            throw TrixAPIError.invalidPayload("Revoke доступен только на root-capable устройстве.")
        }

        let signature = accountRootMaterial.sign(
            payload: Self.revokeMessage(deviceID: deviceID, reason: reason)
        )
        return signature.base64EncodedString()
    }

    var hasAccountRootKey: Bool {
        accountRootMaterial != nil
    }

    var storedIdentity: StoredDeviceIdentity {
        StoredDeviceIdentity(
            accountRootSeed: accountRootMaterial?.privateKeyBytes(),
            transportSeed: transportMaterial.privateKeyBytes(),
            credentialIdentity: credentialIdentity
        )
    }

    var transportPublicKeyB64: String {
        transportMaterial.publicKeyBytes().base64EncodedString()
    }

    var credentialIdentityB64: String {
        credentialIdentity.base64EncodedString()
    }

    static func bootstrapMessage(
        transportPublicKey: Data,
        credentialIdentity: Data
    ) -> Data {
        var message = Data("trix-account-bootstrap:v1".utf8)
        message.append(bigEndian: UInt32(transportPublicKey.count))
        message.append(transportPublicKey)
        message.append(bigEndian: UInt32(credentialIdentity.count))
        message.append(credentialIdentity)
        return message
    }

    static func revokeMessage(deviceID: UUID, reason: String) -> Data {
        let deviceID = Data(deviceID.uuidString.utf8)
        let reason = Data(reason.utf8)

        var message = Data("trix-device-revoke:v1".utf8)
        message.append(bigEndian: UInt32(deviceID.count))
        message.append(deviceID)
        message.append(bigEndian: UInt32(reason.count))
        message.append(reason)
        return message
    }

    private init(
        accountRootMaterial: FfiAccountRootMaterial?,
        transportMaterial: FfiDeviceKeyMaterial,
        credentialIdentity: Data
    ) {
        self.accountRootMaterial = accountRootMaterial
        self.transportMaterial = transportMaterial
        self.credentialIdentity = credentialIdentity
    }
}

private struct CredentialIdentityPayload: Codable {
    let version: Int
    let platform: String
    let profileName: String
    let handle: String?
    let deviceDisplayName: String
    let createdAtUnix: UInt64
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) { buffer in
            append(contentsOf: buffer)
        }
    }
}
