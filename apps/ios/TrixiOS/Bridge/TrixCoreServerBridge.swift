import Foundation

struct TrixCoreServerBridge {
    static func createAccount(
        baseURLString: String,
        form: CreateAccountForm,
        bootstrapMaterial: DeviceBootstrapMaterial
    ) throws -> CreateAccountResponse {
        let client = try makeClient(baseURLString: baseURLString)
        let response = try client.createAccountWithMaterials(
            params: FfiCreateAccountWithMaterialsParams(
                handle: form.handle.trix_trimmedOrNil(),
                profileName: form.profileName.trix_trimmed(),
                profileBio: form.profileBio.trix_trimmedOrNil(),
                deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
                platform: form.platform,
                credentialIdentity: bootstrapMaterial.credentialIdentity
            ),
            accountRoot: try bootstrapMaterial.accountRootMaterial(),
            deviceKeys: try bootstrapMaterial.deviceKeyMaterial()
        )

        return CreateAccountResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            accountSyncChatId: response.accountSyncChatId
        )
    }

    static func createLinkIntent(
        baseURLString: String,
        accessToken: String
    ) throws -> CreateLinkIntentResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.createLinkIntent()
        return CreateLinkIntentResponse(
            linkIntentId: response.linkIntentId,
            qrPayload: response.qrPayload,
            expiresAtUnix: response.expiresAtUnix
        )
    }

    static func searchAccountDirectory(
        baseURLString: String,
        accessToken: String,
        query: String?,
        limit: Int = 20,
        excludeSelf: Bool = true
    ) throws -> [DirectoryAccountSummary] {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.searchAccountDirectory(
            query: query?.trix_trimmedOrNil(),
            limit: limit > 0 ? UInt32(limit) : nil,
            excludeSelf: excludeSelf
        )

        return response.accounts.map { account in
            DirectoryAccountSummary(
                accountId: account.accountId,
                handle: account.handle,
                profileName: account.profileName,
                profileBio: account.profileBio
            )
        }
    }

    static func getAccount(
        baseURLString: String,
        accessToken: String,
        accountId: String
    ) throws -> DirectoryAccountSummary {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let account = try client.getAccount(accountId: accountId)
        return DirectoryAccountSummary(
            accountId: account.accountId,
            handle: account.handle,
            profileName: account.profileName,
            profileBio: account.profileBio
        )
    }

    static func updateAccountProfile(
        baseURLString: String,
        accessToken: String,
        form: EditProfileForm
    ) throws -> AccountProfileResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let profile = try client.updateAccountProfile(
            params: FfiUpdateAccountProfileParams(
                handle: form.handle.trix_trimmedOrNil(),
                profileName: form.profileName.trix_trimmed(),
                profileBio: form.profileBio.trix_trimmedOrNil()
            )
        )

        return AccountProfileResponse(
            accountId: profile.accountId,
            handle: profile.handle,
            profileName: profile.profileName,
            profileBio: profile.profileBio,
            deviceId: profile.deviceId,
            deviceStatus: profile.deviceStatus.trix_deviceStatus
        )
    }

    static func completeLinkIntent(
        baseURLString: String,
        payload: LinkIntentPayload,
        form: LinkExistingAccountForm,
        bootstrapMaterial: DeviceBootstrapMaterial
    ) throws -> CompleteLinkIntentResponse {
        let client = try makeClient(baseURLString: baseURLString)
        let response = try client.completeLinkIntentWithDeviceKey(
            linkIntentId: payload.linkIntentId,
            params: FfiCompleteLinkIntentWithDeviceKeyParams(
                linkToken: payload.linkToken,
                deviceDisplayName: form.deviceDisplayName.trix_trimmed(),
                platform: form.platform,
                credentialIdentity: bootstrapMaterial.credentialIdentity,
                keyPackages: []
            ),
            deviceKeys: try bootstrapMaterial.deviceKeyMaterial()
        )

        return CompleteLinkIntentResponse(
            accountId: response.accountId,
            pendingDeviceId: response.pendingDeviceId,
            deviceStatus: response.deviceStatus.trix_deviceStatus,
            bootstrapPayloadB64: response.bootstrapPayload.base64EncodedString()
        )
    }

    static func authenticate(
        baseURLString: String,
        identity: LocalDeviceIdentity
    ) throws -> AuthSessionResponse {
        let client = try makeClient(baseURLString: baseURLString)
        let session = try client.authenticateWithDeviceKey(
            deviceId: identity.deviceId,
            deviceKeys: try identity.deviceKeyMaterial(),
            setAccessToken: false
        )

        return AuthSessionResponse(
            accessToken: session.accessToken,
            expiresAtUnix: session.expiresAtUnix,
            accountId: session.accountId,
            deviceStatus: session.deviceStatus.trix_deviceStatus
        )
    }

    static func approvePendingDevice(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        deviceId: String
    ) throws -> ApproveDeviceResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.approveDeviceWithAccountRoot(
            deviceId: deviceId,
            accountRoot: try identity.accountRootMaterial(),
            transferBundle: nil
        )

        return ApproveDeviceResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            deviceStatus: response.deviceStatus.trix_deviceStatus
        )
    }

    static func revokeDevice(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        deviceId: String,
        reason: String
    ) throws -> RevokeDeviceResponse {
        let client = try makeClient(baseURLString: baseURLString, accessToken: accessToken)
        let response = try client.revokeDeviceWithAccountRoot(
            deviceId: deviceId,
            reason: reason,
            accountRoot: try identity.accountRootMaterial()
        )

        return RevokeDeviceResponse(
            accountId: response.accountId,
            deviceId: response.deviceId,
            deviceStatus: response.deviceStatus.trix_deviceStatus
        )
    }

    private static func makeClient(
        baseURLString: String,
        accessToken: String? = nil
    ) throws -> FfiServerApiClient {
        let client = try FfiServerApiClient(baseUrl: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        if let accessToken {
            try client.setAccessToken(accessToken: accessToken)
        }
        return client
    }
}

private extension FfiDeviceStatus {
    var trix_deviceStatus: DeviceStatus {
        switch self {
        case .pending:
            return .pending
        case .active:
            return .active
        case .revoked:
            return .revoked
        }
    }
}
