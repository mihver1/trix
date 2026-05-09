import Foundation

@MainActor
final class DeviceVerificationViewModel: ObservableObject {
    @Published private(set) var status: TrixDeviceVerificationStatus?
    @Published private(set) var flow: TrixDeviceVerificationFlow = .idle
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
            status = try await service.deviceVerificationStatus(session: session)
            flow = try await service.deviceVerificationFlow(session: session)
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

    func dismissRecoveryKey() {
        displayedRecoveryKey = nil
    }

    func clear() {
        status = nil
        flow = .idle
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
}
