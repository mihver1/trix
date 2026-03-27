import Testing
@testable import TrixMac

@Test
func credentialFailureOnlyTreatsUnauthorizedAsSessionInvalidation() {
    #expect(TrixAPIError.server(code: "unauthorized", message: "invalid access token", statusCode: 401).isCredentialFailure)
    #expect(!TrixAPIError.server(code: "not_found", message: "account not found", statusCode: 404).isCredentialFailure)
}

@Test
func restoreDispositionPreservesActiveSessionWhenServerStateIsMissing() {
    let disposition = sessionRestoreErrorDisposition(
        deviceStatus: .active,
        error: .server(code: "not_found", message: "active device not found", statusCode: 404)
    )

    #expect(disposition == .preserveActiveSession)
}

@Test
func restoreDispositionRestartsPendingLinkWhenServerDropsPendingDevice() {
    let disposition = sessionRestoreErrorDisposition(
        deviceStatus: .pending,
        error: .server(code: "not_found", message: "active device not found", statusCode: 404)
    )

    #expect(disposition == .restartPendingLink)
}
