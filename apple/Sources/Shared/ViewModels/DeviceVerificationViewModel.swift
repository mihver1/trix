import Foundation

@MainActor
final class DeviceVerificationViewModel: ObservableObject {
    @Published private(set) var status: MatrixDeviceVerificationStatus?
    @Published private(set) var flow: MatrixDeviceVerificationFlow = .idle
    @Published private(set) var isLoading = false
    @Published private(set) var actionInFlight: MatrixDeviceVerificationAction?
    @Published private(set) var errorMessage: String?
    @Published private(set) var displayedRecoveryKey: String?
    @Published var recoveryKeyConfirmation = ""

    func reload(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            status = try await service.deviceVerificationStatus(session: session)
            flow = try await service.deviceVerificationFlow(session: session)
        } catch {
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func requestVerification(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        await perform(.request) {
            flow = try await service.requestDeviceVerification(session: session)
        }
    }

    func acceptRequest(
        _ request: MatrixDeviceVerificationRequest,
        session: MatrixSession,
        service: MatrixDeviceVerificationService
    ) async {
        await perform(.accept) {
            flow = try await service.acceptDeviceVerificationRequest(request, session: session)
        }
    }

    func startSas(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        await perform(.startSas) {
            flow = try await service.startSasDeviceVerification(session: session)
        }
    }

    func approve(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        await perform(.approve) {
            flow = try await service.approveDeviceVerification(session: session)
            status = try await service.deviceVerificationStatus(session: session)
        }
    }

    func decline(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        await perform(.decline) {
            flow = try await service.declineDeviceVerification(session: session)
        }
    }

    func cancel(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        await perform(.cancel) {
            flow = try await service.cancelDeviceVerification(session: session)
        }
    }

    func setUpRecovery(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        await perform(.setUpRecovery) {
            displayedRecoveryKey = try await service.setUpRecovery(session: session)
            status = try await service.deviceVerificationStatus(session: session)
        }
    }

    func confirmRecoveryKey(session: MatrixSession, service: MatrixDeviceVerificationService) async {
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
        _ action: MatrixDeviceVerificationAction,
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
            errorMessage = error.matrixUserFacingMessage
        }
    }
}

enum MatrixDeviceVerificationAction: Equatable {
    case request
    case accept
    case startSas
    case approve
    case decline
    case cancel
    case setUpRecovery
    case confirmRecoveryKey
}
