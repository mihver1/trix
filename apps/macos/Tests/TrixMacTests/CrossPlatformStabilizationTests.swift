import Foundation
import Testing
@testable import TrixMac

@Test
func selectedChatReconciliationReloadsChangedSelection() {
    let selectedChatID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let otherChatID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    let action = selectedChatReconciliationAction(
        selectedChatID: selectedChatID,
        visibleChatIDs: [selectedChatID, otherChatID],
        changedChatIDs: Set([selectedChatID])
    )

    #expect(action == .load(selectedChatID))
}

@Test
func selectedChatReconciliationMovesToFirstVisibleWhenSelectionDisappears() {
    let selectedChatID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let nextChatID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let lastChatID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    let action = selectedChatReconciliationAction(
        selectedChatID: selectedChatID,
        visibleChatIDs: [nextChatID, lastChatID],
        changedChatIDs: Set<UUID>()
    )

    #expect(action == .load(nextChatID))
}

@Test
func selectedChatReconciliationClearsWhenNoVisibleChatsRemain() {
    let selectedChatID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    let action = selectedChatReconciliationAction(
        selectedChatID: selectedChatID,
        visibleChatIDs: [],
        changedChatIDs: Set<UUID>()
    )

    #expect(action == .clear)
}

@Test
func selectedChatReconciliationKeepsNilSelectionStable() {
    let visibleChatID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    let action = selectedChatReconciliationAction(
        selectedChatID: nil,
        visibleChatIDs: [visibleChatID],
        changedChatIDs: Set([visibleChatID])
    )

    #expect(action == .keep)
}

@Test
func workspaceSelectionPreferenceFallsBackWhenPreferredChatDisappears() {
    let selectedChatID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let remainingChatID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let removedChatID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    let resolved = resolvedWorkspaceSelectedChatID(
        selectionPreference: .prefer(removedChatID),
        currentSelectedChatID: selectedChatID,
        visibleLocalChatIDs: [remainingChatID],
        serverChatIDs: [remainingChatID]
    )

    #expect(resolved == remainingChatID)
}

@Test
func workspaceSelectionPreferenceCanForceNewChatSelection() {
    let currentSelectedChatID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let newChatID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    let resolved = resolvedWorkspaceSelectedChatID(
        selectionPreference: .force(newChatID),
        currentSelectedChatID: currentSelectedChatID,
        visibleLocalChatIDs: [currentSelectedChatID],
        serverChatIDs: [currentSelectedChatID]
    )

    #expect(resolved == newChatID)
}

@Test
func deviceTransferBundleTargetsRecipientTransportKey() throws {
    let sourceIdentity = try DeviceIdentityMaterial.make(
        profileName: "Source",
        handle: "source",
        deviceDisplayName: "Source Mac",
        platform: DeviceIdentityMaterial.platform
    )
    let recipientKeys = FfiDeviceKeyMaterial.generate()
    let accountId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let sourceDeviceId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let targetDeviceId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let accountSyncChatId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    let transferBundle = try sourceIdentity.createDeviceTransferBundle(
        DeviceTransferBundleInput(
            accountId: accountId,
            sourceDeviceId: sourceDeviceId,
            targetDeviceId: targetDeviceId,
            accountSyncChatId: accountSyncChatId,
            recipientTransportPubkey: recipientKeys.publicKeyBytes()
        )
    )
    let imported = try recipientKeys.decryptDeviceTransferBundle(bundle: transferBundle)

    #expect(!transferBundle.isEmpty)
    #expect(imported.accountId == accountId.uuidString)
    #expect(imported.sourceDeviceId == sourceDeviceId.uuidString)
    #expect(imported.targetDeviceId == targetDeviceId.uuidString)
    #expect(imported.accountSyncChatId == accountSyncChatId.uuidString)
    #expect(!imported.accountRootPrivateKey.isEmpty)
}

@Test
func websocketSessionReplacementReasonsThatShouldReconnectStayRecoverable() {
    #expect(isRecoverableRealtimeSessionReplacement("replaced by a newer websocket session"))
    #expect(isRecoverableRealtimeSessionReplacement("server shutting down"))
    #expect(!isRecoverableRealtimeSessionReplacement("manual disconnect"))
}
