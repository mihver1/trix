import Foundation

@MainActor
final class DeviceVerificationViewModel: ObservableObject {
    @Published private(set) var status: MatrixDeviceVerificationStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func reload(session: MatrixSession, service: MatrixDeviceVerificationService) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            status = try await service.deviceVerificationStatus(session: session)
        } catch {
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func clear() {
        status = nil
        isLoading = false
        errorMessage = nil
    }
}
