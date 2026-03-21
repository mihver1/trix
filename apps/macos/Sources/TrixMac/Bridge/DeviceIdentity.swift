import Foundation

struct StoredDeviceIdentity {
    let accountRootSeed: Data?
    let transportSeed: Data
    let credentialIdentity: Data
}

struct DeviceTransferBundleInput {
    let accountId: UUID
    let sourceDeviceId: UUID
    let targetDeviceId: UUID
    let accountSyncChatId: UUID?
    let recipientTransportPubkey: Data
}

struct ImportedAccountRootResult {
    let identity: DeviceIdentityMaterial
    let accountSyncChatId: UUID?
}

enum DeviceIdentityMaterialError: LocalizedError {
    case invalidTransferBundle
    case transferBundleIdentityMismatch
    case transferBundlePublicKeyMismatch

    var errorDescription: String? {
        switch self {
        case .invalidTransferBundle:
            return "The device transfer bundle is invalid or cannot be decrypted by this device."
        case .transferBundleIdentityMismatch:
            return "The device transfer bundle does not belong to this account or target device."
        case .transferBundlePublicKeyMismatch:
            return "The device transfer bundle contains mismatched account root key material."
        }
    }
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
        let bootstrapMessage = accountRootMaterial.accountBootstrapPayload(
            transportPubkey: transportPublicKey,
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
        guard let accountRootMaterial else {
            throw TrixAPIError.invalidPayload("Approve доступен только на root-capable устройстве.")
        }

        return accountRootMaterial.sign(
            payload: accountRootMaterial.accountBootstrapPayload(
                transportPubkey: transportPublicKey,
                credentialIdentity: credentialIdentity
            )
        )
        .base64EncodedString()
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

    func createDeviceTransferBundle(_ input: DeviceTransferBundleInput) throws -> Data {
        guard let accountRootMaterial else {
            throw TrixAPIError.invalidPayload("Approve доступен только на root-capable устройстве.")
        }

        return try accountRootMaterial.createDeviceTransferBundle(
            params: FfiCreateDeviceTransferBundleParams(
                accountId: input.accountId.uuidString,
                sourceDeviceId: input.sourceDeviceId.uuidString,
                targetDeviceId: input.targetDeviceId.uuidString,
                accountSyncChatId: input.accountSyncChatId?.uuidString
            ),
            senderDeviceKeys: transportMaterial,
            recipientTransportPubkey: input.recipientTransportPubkey
        )
    }

    func importingAccountRoot(
        fromTransferBundle transferBundle: Data,
        accountId: UUID,
        deviceId: UUID,
        accountSyncChatId: UUID?
    ) throws -> ImportedAccountRootResult {
        let importedBundle: FfiImportedDeviceTransferBundle
        do {
            importedBundle = try transportMaterial.decryptDeviceTransferBundle(bundle: transferBundle)
        } catch {
            throw DeviceIdentityMaterialError.invalidTransferBundle
        }

        guard importedBundle.accountId == accountId.uuidString,
              importedBundle.targetDeviceId == deviceId.uuidString
        else {
            throw DeviceIdentityMaterialError.transferBundleIdentityMismatch
        }

        let importedAccountRoot = try FfiAccountRootMaterial.fromPrivateKey(
            privateKey: importedBundle.accountRootPrivateKey
        )
        guard importedAccountRoot.publicKeyBytes() == importedBundle.accountRootPublicKey else {
            throw DeviceIdentityMaterialError.transferBundlePublicKeyMismatch
        }

        return ImportedAccountRootResult(
            identity: DeviceIdentityMaterial(
                accountRootMaterial: importedAccountRoot,
                transportMaterial: transportMaterial,
                credentialIdentity: credentialIdentity
            ),
            accountSyncChatId: importedBundle.accountSyncChatId.flatMap(UUID.init(uuidString:))
                ?? accountSyncChatId
        )
    }

    var hasAccountRootKey: Bool {
        accountRootMaterial != nil
    }

    var accountRootKeyMaterial: FfiAccountRootMaterial? {
        accountRootMaterial
    }

    var transportKeyMaterial: FfiDeviceKeyMaterial {
        transportMaterial
    }

    var credentialIdentityData: Data {
        credentialIdentity
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
