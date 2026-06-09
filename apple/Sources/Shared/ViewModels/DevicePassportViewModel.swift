import Foundation

@MainActor
final class DevicePassportViewModel: ObservableObject {
    @Published private(set) var snapshot: TrixDevicePassportSnapshot?
    @Published private(set) var notices: [TrixDevicePassportNotice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var actionInFlight: String?
    @Published private(set) var errorMessage: String?

    private var directoryClaimCursor: Int64 = 0

    var isCurrentDeviceReadOnly: Bool {
        snapshot?.isCurrentDeviceReadOnly == true
    }

    var currentDeviceBlockMessage: String? {
        guard isCurrentDeviceReadOnly else {
            return nil
        }
        return "Confirm this device on another Trix device before sending private messages."
    }

    var currentApprovalChallenge: String? {
        snapshot?.currentApprovalRequest?.challenge
    }

    func clear() {
        snapshot = nil
        notices = []
        isLoading = false
        actionInFlight = nil
        errorMessage = nil
        directoryClaimCursor = 0
    }

    func syncCurrentDevice(
        session: TrixSession,
        deviceVerificationService: TrixDeviceVerificationService,
        passportService: TrixDevicePassportService
    ) async {
        guard !isLoading else {
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let status = try await deviceVerificationService.deviceVerificationStatus(session: session)
            let request = try TrixDevicePassportCurrentDeviceMetadata.request(session: session, status: status)
            let device = try await passportService.upsertCurrentDevice(request, session: session)
            var loadedSnapshot = try await passportService.state(session: session, deviceID: device.deviceID)
            if loadedSnapshot.needsCurrentDeviceApprovalRequest {
                _ = try await passportService.createApprovalRequest(deviceID: device.deviceID, session: session)
                loadedSnapshot = try await passportService.state(session: session, deviceID: device.deviceID)
            }
            snapshot = loadedSnapshot
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func reload(
        session: TrixSession,
        passportService: TrixDevicePassportService
    ) async {
        guard let deviceID = snapshot?.currentDevice?.deviceID else {
            return
        }
        await perform("reload") {
            snapshot = try await passportService.state(session: session, deviceID: deviceID)
        }
    }

    func approve(
        _ request: TrixDevicePassportApprovalRequest,
        session: TrixSession,
        passportService: TrixDevicePassportService,
        descriptorService: TrixDevicePassportDescriptorService
    ) async {
        guard let approverDeviceID = snapshot?.currentDevice?.deviceID else {
            errorMessage = TrixClientError.devicePassportApprovalRequired.trixUserFacingMessage
            return
        }
        await perform("approve") {
            let result = try await passportService.approveApprovalRequest(
                id: request.id,
                approverDeviceID: approverDeviceID,
                session: session
            )
            let descriptor = try TrixDevicePassportApprovalDescriptor(claim: result.claim)
            _ = try await descriptorService.sendDevicePassportApprovalDescriptor(descriptor, session: session)
            snapshot = try await passportService.state(session: session, deviceID: approverDeviceID)
        }
    }

    func decline(
        _ request: TrixDevicePassportApprovalRequest,
        session: TrixSession,
        passportService: TrixDevicePassportService
    ) async {
        guard let approverDeviceID = snapshot?.currentDevice?.deviceID else {
            errorMessage = TrixClientError.devicePassportApprovalRequired.trixUserFacingMessage
            return
        }
        await perform("decline") {
            _ = try await passportService.declineApprovalRequest(
                id: request.id,
                approverDeviceID: approverDeviceID,
                session: session
            )
            snapshot = try await passportService.state(session: session, deviceID: approverDeviceID)
        }
    }

    func syncDirectoryClaims(
        session: TrixSession,
        passportService: TrixDevicePassportService,
        descriptorService: TrixDevicePassportDescriptorService,
        deviceVerificationService: TrixDeviceVerificationService
    ) async {
        do {
            let page = try await passportService.directoryClaims(since: directoryClaimCursor, session: session)
            directoryClaimCursor = max(directoryClaimCursor, page.nextCursor)
            for claim in page.claims where claim.userID.caseInsensitiveCompare(session.userID) != .orderedSame {
                let proof = try await descriptorService.devicePassportClaimProof(for: claim, session: session)
                let decision = try await TrixDevicePassportClaimProcessor.apply(
                    claim: claim,
                    proof: proof,
                    session: session,
                    deviceService: deviceVerificationService
                )
                if decision != .autoTrust {
                    mergeNotice(from: claim)
                }
            }
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func dismissNotice(
        _ notice: TrixDevicePassportNotice,
        session: TrixSession,
        passportService: TrixDevicePassportService
    ) async {
        await perform("dismiss") {
            try await passportService.dismissNotice(
                targetUserID: notice.userID,
                severity: notice.severity,
                session: session
            )
            notices.removeAll { $0.id == notice.id }
        }
    }

    private func mergeNotice(from claim: TrixDevicePassportDirectoryClaim) {
        let severity = claim.kind == .reset ? .high : claim.severity
        let notice = TrixDevicePassportNotice(
            userID: claim.userID,
            deviceLabel: nil,
            severity: severity,
            claimID: claim.id
        )
        notices.removeAll { $0.id == notice.id }
        notices.append(notice)
        notices.sort { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity == .high
            }
            return lhs.userID < rhs.userID
        }
    }

    private func perform(_ action: String, operation: () async throws -> Void) async {
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
