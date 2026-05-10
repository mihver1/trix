import Foundation

@MainActor
final class DeviceVerificationViewModel: ObservableObject {
    @Published private(set) var status: TrixDeviceVerificationStatus?
    @Published private(set) var flow: TrixDeviceVerificationFlow = .idle
    @Published private(set) var accountDevices: [TrixPeerDeviceIdentity] = []
    @Published private(set) var accountDeviceRefreshMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var actionInFlight: TrixDeviceVerificationAction?
    @Published private(set) var errorMessage: String?
    @Published private(set) var displayedRecoveryKey: String?
    @Published var recoveryKeyConfirmation = ""

    func reload(session: TrixSession, service: TrixDeviceVerificationService) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedStatus = try await service.deviceVerificationStatus(session: session)
            status = loadedStatus
            flow = try await service.deviceVerificationFlow(session: session)
            await reloadAccountDevices(session: session, service: service, status: loadedStatus)
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func requestVerification(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.request) {
            flow = try await service.requestDeviceVerification(session: session)
        }
    }

    func acceptRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession,
        service: TrixDeviceVerificationService
    ) async {
        await perform(.accept) {
            flow = try await service.acceptDeviceVerificationRequest(request, session: session)
        }
    }

    func startSas(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.startSas) {
            flow = try await service.startSasDeviceVerification(session: session)
        }
    }

    func approve(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.approve) {
            flow = try await service.approveDeviceVerification(session: session)
            status = try await service.deviceVerificationStatus(session: session)
        }
    }

    func decline(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.decline) {
            flow = try await service.declineDeviceVerification(session: session)
        }
    }

    func cancel(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.cancel) {
            flow = try await service.cancelDeviceVerification(session: session)
        }
    }

    func setUpRecovery(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.setUpRecovery) {
            displayedRecoveryKey = try await service.setUpRecovery(session: session)
            status = try await service.deviceVerificationStatus(session: session)
        }
    }

    func confirmRecoveryKey(session: TrixSession, service: TrixDeviceVerificationService) async {
        await perform(.confirmRecoveryKey) {
            status = try await service.confirmRecoveryKey(recoveryKeyConfirmation, session: session)
            recoveryKeyConfirmation = ""
        }
    }

    func trustAccountDevice(
        _ device: TrixPeerDeviceIdentity,
        session: TrixSession,
        service: TrixDeviceVerificationService
    ) async {
        guard !device.isLocalDevice else {
            return
        }

        await perform(.trustAccountDevice) {
            let trustedDevices = try await service.trustPeerDevice(
                userID: device.userID,
                deviceID: device.deviceID,
                session: session
            )
            let loadedStatus = try await service.deviceVerificationStatus(session: session)
            status = loadedStatus
            accountDevices = Self.mergedAccountDevices(
                localStatus: loadedStatus,
                remoteDevices: trustedDevices
            )
            accountDeviceRefreshMessage = nil
        }
    }

    func dismissRecoveryKey() {
        displayedRecoveryKey = nil
    }

    func clear() {
        status = nil
        flow = .idle
        accountDevices = []
        accountDeviceRefreshMessage = nil
        isLoading = false
        actionInFlight = nil
        errorMessage = nil
        displayedRecoveryKey = nil
        recoveryKeyConfirmation = ""
    }

    private func perform(
        _ action: TrixDeviceVerificationAction,
        operation: () async throws -> Void
    ) async {
        guard actionInFlight == nil else {
            return
        }

        actionInFlight = action
        errorMessage = nil
        defer { actionInFlight = nil }

        do {
            try await operation()
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    private func reloadAccountDevices(
        session: TrixSession,
        service: TrixDeviceVerificationService,
        status: TrixDeviceVerificationStatus
    ) async {
        do {
            let remoteDevices = try await service.refreshPeerDeviceIdentities(
                userID: session.userID,
                session: session
            )
            accountDevices = Self.mergedAccountDevices(
                localStatus: status,
                remoteDevices: remoteDevices
            )
            accountDeviceRefreshMessage = nil
        } catch {
            accountDevices = Self.mergedAccountDevices(
                localStatus: status,
                remoteDevices: []
            )
            accountDeviceRefreshMessage = "Published account devices could not be refreshed: \(error.trixUserFacingMessage)"
        }
    }

    private static func mergedAccountDevices(
        localStatus: TrixDeviceVerificationStatus,
        remoteDevices: [TrixPeerDeviceIdentity]
    ) -> [TrixPeerDeviceIdentity] {
        let localDevice = TrixPeerDeviceIdentity(
            userID: localStatus.userID,
            deviceID: localStatus.deviceID,
            fingerprint: localStatus.ed25519Fingerprint ?? "",
            trustState: localStatus.state == .verified ? .verified : .undecided,
            isActive: true,
            isLocalDevice: true
        )

        var devicesByID: [String: TrixPeerDeviceIdentity] = [:]
        for device in remoteDevices {
            devicesByID[device.deviceID] = device
        }
        devicesByID[localDevice.deviceID] = localDevice

        return devicesByID.values.sorted { lhs, rhs in
            if lhs.isLocalDevice != rhs.isLocalDevice {
                return lhs.isLocalDevice
            }

            if lhs.canSendEncrypted != rhs.canSendEncrypted {
                return lhs.canSendEncrypted && !rhs.canSendEncrypted
            }

            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }

            return lhs.deviceID < rhs.deviceID
        }
    }
}

enum TrixDeviceVerificationAction: Equatable {
    case request
    case accept
    case startSas
    case approve
    case decline
    case cancel
    case setUpRecovery
    case confirmRecoveryKey
    case trustAccountDevice
}
