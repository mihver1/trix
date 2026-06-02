import XCTest
@testable import Trix

@MainActor
final class DeviceVerificationTests: XCTestCase {
    func testVisualFingerprintBuildsLosslessSymbolSequence() {
        let visual = TrixDeviceVisualVerification.visualFingerprint(
            "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
        )

        XCTAssertEqual(visual?.kind, .fingerprintDisplayTransform)
        XCTAssertEqual(visual?.symbols.count, 32)
        XCTAssertEqual(visual?.decimalGroups.count, 4)
        XCTAssertFalse(visual?.symbolSummary.isEmpty ?? true)
        XCTAssertEqual(visual?.pixelArt.colorIndexes.count, 25)
        XCTAssertGreaterThan(visual?.pixelArt.filledCellCount ?? 0, 0)
        XCTAssertEqual(
            visual?.pixelArt.colorIndex(row: 0, column: 0),
            visual?.pixelArt.colorIndex(row: 0, column: 4)
        )

        let rendered = visual?.symbols.map(\.symbol).joined()
        XCTAssertEqual(rendered, "🅰️🅰️🅱️🅱️🌜🌜🎯🎯📧📧🎏🎏0️⃣0️⃣1️⃣1️⃣2️⃣2️⃣3️⃣3️⃣4️⃣4️⃣5️⃣5️⃣6️⃣6️⃣7️⃣7️⃣8️⃣8️⃣9️⃣9️⃣")
    }

    func testVisualFingerprintDiffersForDifferentRawFingerprints() {
        let left = TrixDeviceVisualVerification.visualFingerprint(
            "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
        )
        let right = TrixDeviceVisualVerification.visualFingerprint(
            "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:98"
        )

        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertNotEqual(left?.symbols.map(\.symbol), right?.symbols.map(\.symbol))
        XCTAssertNotEqual(left?.pixelArt.colorIndexes, right?.pixelArt.colorIndexes)
    }

    func testRawFingerprintsAreGroupedForNarrowLayouts() {
        let grouped = TrixFingerprintFormatting.grouped(
            "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
        )

        XCTAssertEqual(grouped, "AABBCCDD EEFF0011\n22334455 66778899")
    }

    func testMockVerificationFlowUsesVisualChallengeAndExplicitTrust() async throws {
        let service = MockTrixService(now: Date(timeIntervalSince1970: 0))
        let session = Self.session

        let devicesBeforeTrust = try await service.peerDeviceIdentities(
            userID: "@alice:trix.selfhost.ru",
            session: session
        )
        XCTAssertEqual(devicesBeforeTrust.first?.trustState, .undecided)
        XCTAssertNotNil(devicesBeforeTrust.first?.visualVerification)

        let requested = try await service.requestDeviceVerification(session: session)
        XCTAssertEqual(requested.phase, .requestSent)

        let accepted = try await service.acceptDeviceVerificationRequest(Self.request, session: session)
        XCTAssertEqual(accepted.phase, .accepted)

        let challenge = try await service.startSasDeviceVerification(session: session)
        XCTAssertEqual(challenge.phase, .challengeReceived)
        guard case .emojis(let symbols) = challenge.challenge else {
            return XCTFail("Expected a visual emoji challenge")
        }
        XCTAssertEqual(symbols.count, 5)

        let finished = try await service.approveDeviceVerification(session: session)
        XCTAssertEqual(finished.phase, .finished)

        _ = try await service.requestDeviceVerification(session: session)
        let cancelledByDecline = try await service.declineDeviceVerification(session: session)
        XCTAssertEqual(cancelledByDecline.phase, .cancelled)

        _ = try await service.requestDeviceVerification(session: session)
        let cancelled = try await service.cancelDeviceVerification(session: session)
        XCTAssertEqual(cancelled.phase, .cancelled)

        let trusted = try await service.trustPeerDevice(
            userID: "@alice:trix.selfhost.ru",
            deviceID: "1001",
            session: session
        )
        XCTAssertEqual(trusted.first?.trustState, .trusted)
        XCTAssertEqual(trusted.first?.canSendEncrypted, true)
    }

    func testVerificationViewModelSurfacesServiceFailure() async {
        let viewModel = DeviceVerificationViewModel()
        let service = FailingDeviceVerificationService()

        await viewModel.requestVerification(session: Self.session, service: service)

        XCTAssertEqual(viewModel.flow.phase, .idle)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testMockServiceRevokesOwnDevice() async throws {
        let service = MockTrixService(now: Date(timeIntervalSince1970: 0))
        let session = Self.session

        let before = try await service.refreshPeerDeviceIdentities(userID: session.userID, session: session)
        XCTAssertTrue(before.contains(where: { $0.deviceID == "1001" && $0.isActive }))
        XCTAssertTrue(before.contains(where: { $0.deviceID == "2002" && $0.isActive }))

        let after = try await service.revokeOwnDevice(deviceID: "1001", session: session)
        XCTAssertFalse(after.contains(where: { $0.deviceID == "1001" && $0.isActive }))
        XCTAssertTrue(after.contains(where: { $0.deviceID == "2002" && $0.isActive }))
    }

    func testViewModelRevokeOwnDeviceUpdatesList() async {
        let viewModel = DeviceVerificationViewModel()
        let service = MockTrixService(now: Date(timeIntervalSince1970: 0))
        let session = Self.session

        await viewModel.reload(session: session, service: service)
        guard let target = viewModel.accountDevices.first(where: { !$0.isLocalDevice && $0.deviceID == "1001" }) else {
            return XCTFail("Expected an own non-current device to revoke")
        }

        await viewModel.revokeOwnDevice(target, session: session, service: service)

        XCTAssertFalse(viewModel.accountDevices.contains(where: { $0.deviceID == "1001" && $0.isActive }))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testActiveUntrustedOwnDevicesBlockEncryptedSend() {
        let activeTrusted = Self.device(deviceID: "1001", trustState: .trusted, isActive: true)
        let activeUntrusted = Self.device(deviceID: "2002", trustState: .undecided, isActive: true)
        let inactiveUntrusted = Self.device(deviceID: "3003", trustState: .undecided, isActive: false)
        let localUntrusted = Self.device(deviceID: "4004", trustState: .undecided, isActive: true, isLocalDevice: true)

        XCTAssertFalse(
            XMPPMartinService.hasActiveUntrustedOwnAccountDevices(
                [activeTrusted, inactiveUntrusted, localUntrusted],
                localDeviceID: "4004"
            )
        )
        XCTAssertTrue(
            XMPPMartinService.hasActiveUntrustedOwnAccountDevices(
                [activeTrusted, activeUntrusted],
                localDeviceID: "4004"
            )
        )
        XCTAssertFalse(
            XMPPMartinService.hasActiveUntrustedOwnAccountDevices(
                [activeUntrusted],
                localDeviceID: "2002"
            )
        )
    }

    private static let session = TrixSession(
        userID: "@me:trix.selfhost.ru",
        deviceID: "TEST",
        homeserverURL: XMPPClientConfiguration.connectionURL,
        accessToken: "test-password",
        refreshToken: nil,
        oidcData: nil,
        sdkStoreID: "test",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    private static let request = TrixDeviceVerificationRequest(
        flowID: "mock-flow",
        senderUserID: "@me:trix.selfhost.ru",
        senderDisplayName: "Me",
        deviceID: "TEST",
        deviceDisplayName: "iPhone",
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )

    private static func device(
        deviceID: String,
        trustState: TrixPeerDeviceTrustState,
        isActive: Bool,
        isLocalDevice: Bool = false
    ) -> TrixPeerDeviceIdentity {
        TrixPeerDeviceIdentity(
            userID: session.userID,
            deviceID: deviceID,
            fingerprint: "AA:BB",
            visualVerification: nil,
            trustState: trustState,
            isActive: isActive,
            isLocalDevice: isLocalDevice
        )
    }
}

private struct FailingDeviceVerificationService: TrixDeviceVerificationService {
    func deviceVerificationStatus(session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        throw TrixClientError.e2eeUnavailable
    }

    func deviceVerificationFlow(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func peerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        []
    }

    func refreshPeerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        []
    }

    func trustPeerDevice(userID: String, deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        throw TrixClientError.e2eeUnavailable
    }

    func revokeOwnDevice(deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        throw TrixClientError.e2eeUnavailable
    }

    func requestDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        throw TrixClientError.e2eeUnavailable
    }

    func acceptDeviceVerificationRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession
    ) async throws -> TrixDeviceVerificationFlow {
        throw TrixClientError.e2eeUnavailable
    }

    func startSasDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        throw TrixClientError.e2eeUnavailable
    }

    func approveDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        throw TrixClientError.e2eeUnavailable
    }

    func declineDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        throw TrixClientError.e2eeUnavailable
    }

    func cancelDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func setUpRecovery(session: TrixSession) async throws -> String {
        throw TrixClientError.e2eeUnavailable
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        throw TrixClientError.e2eeUnavailable
    }
}
