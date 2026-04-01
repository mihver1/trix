import Foundation
import Security
import Testing
@testable import TrixMac

@Test
func credentialFailureOnlyTreatsUnauthorizedAsSessionInvalidation() {
    #expect(TrixAPIError.server(code: "unauthorized", message: "invalid access token", statusCode: 401).isCredentialFailure)
    #expect(!TrixAPIError.server(code: "not_found", message: "account not found", statusCode: 404).isCredentialFailure)
}

@Test
func transportFailureIsReportedSeparately() {
    #expect(TrixAPIError.transport(URLError(.notConnectedToInternet)).isTransportFailure)
    #expect(!TrixAPIError.server(code: "unauthorized", message: "invalid access token", statusCode: 401).isTransportFailure)
}

@Test
func restoreDispositionRequiresRelinkWhenServerStateIsMissingForActiveDevice() {
    let disposition = sessionRestoreErrorDisposition(
        deviceStatus: .active,
        error: .server(code: "not_found", message: "active device not found", statusCode: 404)
    )

    #expect(disposition == .preserveActiveSessionRequiresRelink)
}

@Test
func restoreDispositionRestartsPendingLinkWhenServerDropsPendingDevice() {
    let disposition = sessionRestoreErrorDisposition(
        deviceStatus: .pending,
        error: .server(code: "not_found", message: "active device not found", statusCode: 404)
    )

    #expect(disposition == .restartPendingLink)
}

@Test
func restoreDispositionPreservesReconnectForCredentialFailure() {
    let disposition = sessionRestoreErrorDisposition(
        deviceStatus: .active,
        error: .server(code: "unauthorized", message: "invalid access token", statusCode: 401)
    )

    #expect(disposition == .preserveActiveSession)
}

@Test
func relinkRequiredMessageExplainsReconnectWillNotHelp() {
    let message = relinkRequiredRestoreFailureMessage(
        for: .server(code: "not_found", message: "active device not found", statusCode: 404)
    )

    #expect(message.contains("reconnect уже не поможет"))
    #expect(message.contains("link flow"))
}

@Test
func missingStoredIdentityRecoveryPlanRequiresRelinkWhenSessionExists() {
    let plan = missingStoredIdentityRecoveryPlan(hasPersistedSession: true)

    #expect(plan?.mode == .localKeysMissing)
    #expect(plan?.message.contains("device keys") == true)
    #expect(plan?.message.contains("не поможет") == true)
}

@Test
func missingStoredIdentityRecoveryPlanIsNilWithoutPersistedSession() {
    #expect(missingStoredIdentityRecoveryPlan(hasPersistedSession: false) == nil)
}

@Test
func offlineCachedAccountProfileUsesPersistedSessionShape() {
    let session = PersistedSession(
        baseURLString: "https://example.test",
        accountId: UUID(),
        deviceId: UUID(),
        accountSyncChatId: nil,
        profileName: "Offline User",
        handle: "offline",
        deviceDisplayName: "Offline Mac",
        deviceStatus: .active
    )

    let profile = offlineCachedAccountProfile(for: session)

    #expect(profile.accountId == session.accountId)
    #expect(profile.deviceId == session.deviceId)
    #expect(profile.profileName == "Offline User")
    #expect(profile.handle == "offline")
    #expect(profile.deviceStatus == DeviceStatus.active)
}

@Test
func keychainDeletionFailureIgnoresInvalidOwnerEdit() {
    #expect(shouldIgnoreKeychainDeletionFailure(KeychainStoreError.unhandledStatus(errSecInvalidOwnerEdit)))
    #expect(!shouldIgnoreKeychainDeletionFailure(KeychainStoreError.unhandledStatus(errSecInteractionNotAllowed)))
}
