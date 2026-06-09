import XCTest
@testable import Trix

@MainActor
final class DevicePassportTests: XCTestCase {
    func testPendingServiceSyncMarksCurrentDeviceReadOnly() async {
        let snapshot = TrixDevicePassportSnapshot(
            userID: Self.session.userID,
            generation: 1,
            currentDevice: Self.passportDevice(deviceID: "2002", state: .pending),
            currentApprovalRequest: nil,
            pendingApprovalRequests: [],
            serverStateIsTrustAuthority: false
        )
        let viewModel = DevicePassportViewModel()
        let service = MockDevicePassportService(snapshot: snapshot)

        await viewModel.syncCurrentDevice(
            session: Self.session,
            deviceVerificationService: StaticDeviceVerificationService(),
            passportService: service
        )

        XCTAssertTrue(viewModel.isCurrentDeviceReadOnly)
        XCTAssertEqual(viewModel.currentDeviceBlockMessage, "Confirm this device on another Trix device before sending private messages.")
    }

    func testApprovalRequestedDeviceWithoutActiveRequestCreatesFreshApprovalRequest() async {
        let snapshot = TrixDevicePassportSnapshot(
            userID: Self.session.userID,
            generation: 1,
            currentDevice: Self.passportDevice(deviceID: "2002", state: .approvalRequested),
            currentApprovalRequest: nil,
            pendingApprovalRequests: [],
            serverStateIsTrustAuthority: false
        )
        let viewModel = DevicePassportViewModel()
        let service = RecordingDevicePassportService(snapshot: snapshot)

        await viewModel.syncCurrentDevice(
            session: Self.session,
            deviceVerificationService: StaticDeviceVerificationService(),
            passportService: service
        )

        XCTAssertEqual(service.createdApprovalDeviceIDs, ["2002"])
        XCTAssertEqual(viewModel.currentApprovalChallenge, "A1B2C3D4")
    }

    func testCurrentDeviceMetadataUsesXMPPJIDAndRevokedDevicesStayReadOnly() throws {
        let request = try TrixDevicePassportCurrentDeviceMetadata.request(
            session: Self.session,
            status: try StaticDeviceVerificationService.syncStatus(for: Self.session),
            appVersion: "test"
        )

        XCTAssertEqual(request.userID, "me@trix.selfhost.ru")
        XCTAssertTrue(Self.passportDevice(deviceID: "2002", state: .revoked).isCurrentDeviceReadOnly)
    }

    func testServerOnlyClaimDoesNotAutoTrust() {
        let claim = Self.claim(approvedByDeviceID: "1001")
        let decision = TrixDevicePassportClaimProcessor.decision(
            for: claim,
            proof: nil,
            peerDevices: [
                Self.peerDevice(deviceID: "1001", fingerprint: "trusted", trustState: .trusted),
                Self.peerDevice(deviceID: "2002", fingerprint: "new", trustState: .undecided)
            ]
        )

        XCTAssertEqual(decision, .proofRequired)
    }

    func testMatchingProofAndTrustedPriorDeviceAutoTrusts() {
        let targetFingerprint = "new-device-fingerprint"
        let claim = Self.claim(
            fingerprintHash: TrixDevicePassportFingerprint.hash(targetFingerprint),
            approvedByDeviceID: "1001"
        )
        let proof = TrixDevicePassportClaimProof(
            userID: claim.userID,
            deviceID: claim.deviceID,
            generation: claim.generation,
            approvedByDeviceID: "1001",
            approverFingerprintHash: TrixDevicePassportFingerprint.hash("trusted")
        )

        let decision = TrixDevicePassportClaimProcessor.decision(
            for: claim,
            proof: proof,
            peerDevices: [
                Self.peerDevice(deviceID: "1001", fingerprint: "trusted", trustState: .trusted),
                Self.peerDevice(deviceID: "2002", fingerprint: targetFingerprint, trustState: .undecided)
            ]
        )

        XCTAssertEqual(decision, .autoTrust)
    }

    func testFingerprintMismatchBlocksAutoTrust() {
        let claim = Self.claim(
            fingerprintHash: TrixDevicePassportFingerprint.hash("expected"),
            approvedByDeviceID: "1001"
        )
        let proof = TrixDevicePassportClaimProof(
            userID: claim.userID,
            deviceID: claim.deviceID,
            generation: claim.generation,
            approvedByDeviceID: "1001",
            approverFingerprintHash: TrixDevicePassportFingerprint.hash("trusted")
        )

        let decision = TrixDevicePassportClaimProcessor.decision(
            for: claim,
            proof: proof,
            peerDevices: [
                Self.peerDevice(deviceID: "1001", fingerprint: "trusted", trustState: .trusted),
                Self.peerDevice(deviceID: "2002", fingerprint: "different", trustState: .undecided)
            ]
        )

        XCTAssertEqual(decision, .fingerprintMismatch)
    }

    func testDescriptorProofUsesDecryptedSenderFingerprint() throws {
        let targetFingerprint = "new-device-fingerprint"
        let claim = Self.claim(
            fingerprintHash: TrixDevicePassportFingerprint.hash(targetFingerprint),
            approvedByDeviceID: "1001"
        )
        let descriptor = try TrixDevicePassportApprovalDescriptor(claim: claim)
        let received = TrixReceivedDevicePassportDescriptor(
            id: "proof-1",
            roomID: "alice@trix.selfhost.ru",
            senderID: claim.userID,
            senderFingerprint: "trusted",
            timestamp: Date(timeIntervalSince1970: 0),
            descriptor: descriptor,
            isLocalEcho: false
        )

        let proof = TrixDevicePassportClaimProof.proof(for: claim, descriptors: [received])

        XCTAssertEqual(proof?.approvedByDeviceID, "1001")
        XCTAssertEqual(proof?.approverFingerprintHash, TrixDevicePassportFingerprint.hash("trusted"))
    }

    func testDirectoryClaimWithEncryptedDescriptorProofAutoTrusts() async throws {
        let targetFingerprint = "new-device-fingerprint"
        let claim = Self.claim(
            fingerprintHash: TrixDevicePassportFingerprint.hash(targetFingerprint),
            approvedByDeviceID: "1001"
        )
        let descriptor = try TrixDevicePassportApprovalDescriptor(claim: claim)
        let descriptorService = StaticDevicePassportDescriptorService(
            descriptors: [
                TrixReceivedDevicePassportDescriptor(
                    id: "proof-1",
                    roomID: "alice@trix.selfhost.ru",
                    senderID: claim.userID,
                    senderFingerprint: "trusted",
                    timestamp: Date(timeIntervalSince1970: 0),
                    descriptor: descriptor,
                    isLocalEcho: false
                )
            ]
        )
        let deviceService = RecordingDeviceVerificationService(peerDevices: [
            Self.peerDevice(deviceID: "1001", fingerprint: "trusted", trustState: .trusted),
            Self.peerDevice(deviceID: "2002", fingerprint: targetFingerprint, trustState: .undecided),
        ])
        let passportService = MockDevicePassportService(
            directoryClaimsPage: TrixDevicePassportDirectoryClaimsPage(
                recipientUserID: Self.session.userID,
                claims: [claim],
                nextCursor: claim.id
            )
        )
        let viewModel = DevicePassportViewModel()

        await viewModel.syncDirectoryClaims(
            session: Self.session,
            passportService: passportService,
            descriptorService: descriptorService,
            deviceVerificationService: deviceService
        )

        XCTAssertTrue(viewModel.notices.isEmpty)
        XCTAssertEqual(deviceService.trustedDeviceIDs, ["2002"])
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

    private static func passportDevice(
        deviceID: String,
        state: TrixDevicePassportState
    ) -> TrixDevicePassportDevice {
        TrixDevicePassportDevice(
            userID: session.userID,
            deviceID: deviceID,
            generation: 1,
            state: state,
            deviceLabel: "Test device",
            platform: "ios",
            fingerprintHash: "00112233445566778899aabbccddeeff",
            appVersion: nil,
            firstSeenAtUnix: 0,
            lastSeenAtUnix: 0,
            approvedAtUnix: nil,
            approvedByDeviceID: nil,
            revokedAtUnix: nil
        )
    }

    private static func claim(
        fingerprintHash: String = TrixDevicePassportFingerprint.hash("new"),
        approvedByDeviceID: String?
    ) -> TrixDevicePassportDirectoryClaim {
        TrixDevicePassportDirectoryClaim(
            id: 1,
            userID: "@alice:trix.selfhost.ru",
            deviceID: "2002",
            generation: 1,
            kind: .approved,
            severity: .normal,
            fingerprintHash: fingerprintHash,
            proofRequired: true,
            createdAtUnix: 0,
            approvedByDeviceID: approvedByDeviceID
        )
    }

    private static func peerDevice(
        deviceID: String,
        fingerprint: String,
        trustState: TrixPeerDeviceTrustState
    ) -> TrixPeerDeviceIdentity {
        TrixPeerDeviceIdentity(
            userID: "@alice:trix.selfhost.ru",
            deviceID: deviceID,
            fingerprint: fingerprint,
            visualVerification: nil,
            trustState: trustState,
            isActive: true,
            isLocalDevice: false
        )
    }
}

private final class RecordingDevicePassportService: TrixDevicePassportService, @unchecked Sendable {
    private var snapshot: TrixDevicePassportSnapshot
    private(set) var createdApprovalDeviceIDs: [String] = []

    init(snapshot: TrixDevicePassportSnapshot) {
        self.snapshot = snapshot
    }

    func upsertCurrentDevice(_ request: TrixDevicePassportCurrentDeviceRequest, session: TrixSession) async throws -> TrixDevicePassportDevice {
        guard let currentDevice = snapshot.currentDevice else {
            throw TrixClientError.devicePassportUnavailable
        }
        return currentDevice
    }

    func state(session: TrixSession, deviceID: String?) async throws -> TrixDevicePassportSnapshot {
        snapshot
    }

    func createApprovalRequest(deviceID: String, session: TrixSession) async throws -> TrixDevicePassportApprovalRequest {
        createdApprovalDeviceIDs.append(deviceID)
        let approval = TrixDevicePassportApprovalRequest(
            id: "mock-approval",
            userID: session.userID,
            deviceID: deviceID,
            generation: 1,
            challenge: "A1B2C3D4",
            status: .pending,
            createdAtUnix: 0,
            expiresAtUnix: 600,
            decidedAtUnix: nil,
            decidedByDeviceID: nil
        )
        snapshot = TrixDevicePassportSnapshot(
            userID: snapshot.userID,
            generation: snapshot.generation,
            currentDevice: snapshot.currentDevice,
            currentApprovalRequest: approval,
            pendingApprovalRequests: snapshot.pendingApprovalRequests,
            serverStateIsTrustAuthority: snapshot.serverStateIsTrustAuthority
        )
        return approval
    }

    func approveApprovalRequest(id: String, approverDeviceID: String, session: TrixSession) async throws -> TrixDevicePassportApproveResult {
        throw TrixClientError.devicePassportUnavailable
    }

    func declineApprovalRequest(id: String, approverDeviceID: String, session: TrixSession) async throws -> TrixDevicePassportApprovalRequest {
        throw TrixClientError.devicePassportUnavailable
    }

    func directoryClaims(since cursor: Int64, session: TrixSession) async throws -> TrixDevicePassportDirectoryClaimsPage {
        TrixDevicePassportDirectoryClaimsPage(recipientUserID: session.userID, claims: [], nextCursor: cursor)
    }

    func dismissNotice(targetUserID: String, severity: TrixDevicePassportNoticeSeverity, session: TrixSession) async throws {
    }
}

private struct StaticDeviceVerificationService: TrixDeviceVerificationService {
    static func syncStatus(for session: TrixSession) throws -> TrixDeviceVerificationStatus {
        TrixDeviceVerificationStatus(
            userID: session.userID,
            deviceID: "2002",
            state: .verified,
            hasDevicesToVerifyAgainst: true,
            isLastDevice: false,
            recoveryState: .disabled,
            backupState: .unknown,
            backupExistsOnServer: nil,
            ed25519Fingerprint: "static-fingerprint",
            curve25519IdentityKey: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func deviceVerificationStatus(session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        try Self.syncStatus(for: session)
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
        []
    }

    func revokeOwnDevice(deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        []
    }

    func requestDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func acceptDeviceVerificationRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession
    ) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func startSasDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func approveDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func declineDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func cancelDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func setUpRecovery(session: TrixSession) async throws -> String {
        ""
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        try await deviceVerificationStatus(session: session)
    }
}

private struct StaticDevicePassportDescriptorService: TrixDevicePassportDescriptorService {
    let descriptors: [TrixReceivedDevicePassportDescriptor]

    func devicePassportDescriptors(session: TrixSession) async throws -> [TrixReceivedDevicePassportDescriptor] {
        descriptors
    }

    func sendDevicePassportApprovalDescriptor(
        _ descriptor: TrixDevicePassportApprovalDescriptor,
        session: TrixSession
    ) async throws -> [TrixReceivedDevicePassportDescriptor] {
        []
    }

    func devicePassportClaimProof(
        for claim: TrixDevicePassportDirectoryClaim,
        session: TrixSession
    ) async throws -> TrixDevicePassportClaimProof? {
        TrixDevicePassportClaimProof.proof(for: claim, descriptors: descriptors)
    }
}

private final class RecordingDeviceVerificationService: TrixDeviceVerificationService, @unchecked Sendable {
    let peerDevices: [TrixPeerDeviceIdentity]
    private(set) var trustedDeviceIDs: [String] = []

    init(peerDevices: [TrixPeerDeviceIdentity]) {
        self.peerDevices = peerDevices
    }

    func deviceVerificationStatus(session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        try StaticDeviceVerificationService.syncStatus(for: session)
    }

    func deviceVerificationFlow(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func peerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        peerDevices
    }

    func refreshPeerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        peerDevices
    }

    func trustPeerDevice(userID: String, deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        trustedDeviceIDs.append(deviceID)
        return peerDevices
    }

    func revokeOwnDevice(deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        peerDevices
    }

    func requestDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func acceptDeviceVerificationRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession
    ) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func startSasDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func approveDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func declineDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func cancelDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        .idle
    }

    func setUpRecovery(session: TrixSession) async throws -> String {
        ""
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        try StaticDeviceVerificationService.syncStatus(for: session)
    }
}
