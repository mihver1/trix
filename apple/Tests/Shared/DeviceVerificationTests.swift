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
