import Foundation
import UIKit

struct CreateAccountForm {
    var profileName = ""
    var handle = ""
    var profileBio = ""
    var deviceDisplayName = UIDevice.current.name
    let platform = "ios"

    var canSubmit: Bool {
        !profileName.trix_trimmed().isEmpty && !deviceDisplayName.trix_trimmed().isEmpty
    }
}

struct LinkExistingAccountForm {
    var linkPayload = ""
    var deviceDisplayName = UIDevice.current.name
    let platform = "ios"

    var canSubmit: Bool {
        !linkPayload.trix_trimmed().isEmpty && !deviceDisplayName.trix_trimmed().isEmpty
    }
}

struct DashboardData {
    let session: AuthSessionResponse
    let profile: AccountProfileResponse
    let devices: [DeviceSummary]
    let historySyncJobs: [HistorySyncJobSummary]

    var sessionExpirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(session.expiresAtUnix))
    }

    var currentDevice: DeviceSummary? {
        devices.first { $0.deviceId == profile.deviceId }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var localIdentity: LocalDeviceIdentity?
    @Published private(set) var dashboard: DashboardData?
    @Published private(set) var activeLinkIntent: CreateLinkIntentResponse?
    @Published private(set) var systemSnapshot: ServerSnapshot?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let identityStore: LocalDeviceIdentityStore
    private var hasStarted = false

    init(identityStore: LocalDeviceIdentityStore = LocalDeviceIdentityStore()) {
        self.identityStore = identityStore
    }

    var hasProvisionedIdentity: Bool {
        localIdentity != nil
    }

    var isAwaitingApproval: Bool {
        localIdentity?.trustState == .pendingApproval && dashboard == nil
    }

    var canManageAccountDevices: Bool {
        localIdentity?.hasAccountRootKey ?? false
    }

    func start(baseURLString: String) async {
        guard !hasStarted else {
            return
        }

        hasStarted = true

        do {
            localIdentity = try identityStore.load()
        } catch {
            errorMessage = error.localizedDescription
        }

        await refresh(baseURLString: baseURLString)
    }

    func refresh(baseURLString: String) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)

            if let localIdentity {
                do {
                    try await refreshAuthenticatedState(client: client, identity: localIdentity)
                } catch let error as APIError where isPendingApprovalAuthFailure(error, identity: localIdentity) {
                    dashboard = nil
                    systemSnapshot = try? await fetchSystemSnapshot(client: client)
                    lastUpdatedAt = Date()
                }
            } else {
                dashboard = nil
                systemSnapshot = try await fetchSystemSnapshot(client: client)
                lastUpdatedAt = Date()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccount(baseURLString: String, form: CreateAccountForm) async {
        guard !isLoading else {
            return
        }

        let profileName = form.profileName.trix_trimmed()
        let deviceDisplayName = form.deviceDisplayName.trix_trimmed()

        guard !profileName.isEmpty else {
            errorMessage = "Profile name must not be empty."
            return
        }
        guard !deviceDisplayName.isEmpty else {
            errorMessage = "Device name must not be empty."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
            let request = try bootstrapMaterial.makeCreateAccountRequest(
                profileName: profileName,
                handle: form.handle.trix_trimmedOrNil(),
                profileBio: form.profileBio.trix_trimmedOrNil(),
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )
            let response: CreateAccountResponse = try await client.post("/v0/accounts", body: request)
            let localIdentity = bootstrapMaterial.makeLocalIdentity(
                accountId: response.accountId,
                deviceId: response.deviceId,
                accountSyncChatId: response.accountSyncChatId,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity

            try await refreshAuthenticatedState(client: client, identity: localIdentity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeLinkIntent(
        baseURLString: String,
        payload: LinkIntentPayload,
        form: LinkExistingAccountForm
    ) async {
        guard !isLoading else {
            return
        }

        let deviceDisplayName = form.deviceDisplayName.trix_trimmed()
        guard !deviceDisplayName.isEmpty else {
            errorMessage = "Device name must not be empty."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
            let request = try bootstrapMaterial.makeCompleteLinkIntentRequest(
                linkToken: payload.linkToken,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )
            let response: CompleteLinkIntentResponse = try await client.post(
                "/v0/devices/link-intents/\(payload.linkIntentId)/complete",
                body: request
            )
            let localIdentity = bootstrapMaterial.makeLinkedLocalIdentity(
                accountId: response.accountId,
                deviceId: response.pendingDeviceId,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            dashboard = nil
            activeLinkIntent = nil
            systemSnapshot = try await fetchSystemSnapshot(client: client)
            lastUpdatedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetLocalDevice() {
        do {
            try identityStore.delete()
            localIdentity = nil
            dashboard = nil
            activeLinkIntent = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createLinkIntent(baseURLString: String) async {
        guard !isLoading else {
            return
        }

        guard let identity = localIdentity else {
            errorMessage = "Local identity is missing."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let session = try await authenticate(client: client, identity: identity)
            let response: CreateLinkIntentResponse = try await client.post(
                "/v0/devices/link-intents",
                body: EmptyRequest(),
                accessToken: session.accessToken
            )
            activeLinkIntent = response
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissActiveLinkIntent() {
        activeLinkIntent = nil
    }

    func revokeDevice(
        baseURLString: String,
        deviceId: String,
        reason: String
    ) async {
        guard !isLoading else {
            return
        }

        let trimmedReason = reason.trix_trimmed()
        guard !trimmedReason.isEmpty else {
            errorMessage = "Revoke reason must not be empty."
            return
        }

        guard let identity = localIdentity else {
            errorMessage = "Local identity is missing."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let session = try await authenticate(client: client, identity: identity)
            let signature = try identity.signDeviceRevoke(deviceId: deviceId, reason: trimmedReason)

            let _: RevokeDeviceResponse = try await client.post(
                "/v0/devices/\(deviceId)/revoke",
                body: RevokeDeviceRequest(
                    reason: trimmedReason,
                    accountRootSignatureB64: signature.base64EncodedString()
                ),
                accessToken: session.accessToken
            )

            try await refreshAuthenticatedState(client: client, identity: identity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeHistorySyncJob(
        baseURLString: String,
        jobId: String
    ) async {
        guard !isLoading else {
            return
        }

        guard let identity = localIdentity else {
            errorMessage = "Local identity is missing."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let session = try await authenticate(client: client, identity: identity)

            let _: CompleteHistorySyncJobResponse = try await client.post(
                "/v0/history-sync/jobs/\(jobId)/complete",
                body: CompleteHistorySyncJobRequest(cursorJson: nil),
                accessToken: session.accessToken
            )

            try await refreshAuthenticatedState(client: client, identity: identity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAuthenticatedState(
        client: APIClient,
        identity: LocalDeviceIdentity
    ) async throws {
        async let systemSnapshot = fetchSystemSnapshot(client: client)
        let session = try await authenticate(client: client, identity: identity)
        async let profile: AccountProfileResponse = client.get(
            "/v0/accounts/me",
            accessToken: session.accessToken
        )
        async let devices: DeviceListResponse = client.get(
            "/v0/devices",
            accessToken: session.accessToken
        )
        async let historySyncJobs: HistorySyncJobListResponse = client.get(
            "/v0/history-sync/jobs?limit=50",
            accessToken: session.accessToken
        )

        if identity.trustState != .active {
            let activeIdentity = identity.markingActive()
            try identityStore.save(activeIdentity)
            localIdentity = activeIdentity
        }

        self.systemSnapshot = try await systemSnapshot
        dashboard = try await DashboardData(
            session: session,
            profile: profile,
            devices: devices.devices,
            historySyncJobs: historySyncJobs.jobs
        )
        lastUpdatedAt = Date()
    }

    private func authenticate(
        client: APIClient,
        identity: LocalDeviceIdentity
    ) async throws -> AuthSessionResponse {
        let challenge: AuthChallengeResponse = try await client.post(
            "/v0/auth/challenge",
            body: AuthChallengeRequest(deviceId: identity.deviceId)
        )
        let challengeBytes = try Data.trix_base64Decoded(challenge.challengeB64)
        let signatureBytes = try identity.signChallenge(challengeBytes)

        return try await client.post(
            "/v0/auth/session",
            body: AuthSessionRequest(
                deviceId: identity.deviceId,
                challengeId: challenge.challengeId,
                signatureB64: signatureBytes.base64EncodedString()
            )
        )
    }

    private func fetchSystemSnapshot(client: APIClient) async throws -> ServerSnapshot {
        async let health: HealthResponse = client.get("/v0/system/health")
        async let version: VersionResponse = client.get("/v0/system/version")

        return try await ServerSnapshot(health: health, version: version)
    }

    private func isPendingApprovalAuthFailure(
        _ error: APIError,
        identity: LocalDeviceIdentity
    ) -> Bool {
        guard identity.trustState == .pendingApproval else {
            return false
        }

        if case let .http(statusCode, message) = error {
            return statusCode == 401 && (message?.contains("device is not active") ?? false)
        }

        return false
    }
}

private extension String {
    func trix_trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trix_trimmedOrNil() -> String? {
        let trimmed = trix_trimmed()
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct EmptyRequest: Encodable {}
