import Darwin
import Foundation

#if DEBUG
enum MatrixLiveSmokeRunner {
    private static let serviceName = "com.softgrid.trixmatrix.live-smoke"
    private static let adminAccount = "admin-session"

    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE"] == "1" else {
            return
        }

        Task {
            let exitCode = await run()
            fflush(stderr)
            exit(exitCode)
        }
    }

    private static func run() async -> Int32 {
        do {
            switch ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE_MODE"] {
            case "login":
                try await runLogin()
            case "restore":
                try await runRestore()
            case "encrypted-dm":
                try await runEncryptedDM()
            case "encrypted-attachment":
                try await runEncryptedAttachment()
            case "device-verification":
                try await runDeviceVerification()
            case "recovery":
                try await runRecoverySetupConfirmation()
            case "cleanup":
                try await runCleanup()
            default:
                throw MatrixLiveSmokeError.missingMode
            }
            return 0
        } catch {
            emit("failed \(redacted(error))")
            return 2
        }
    }

    private static func runLogin() async throws {
        let admin = try credentials(prefix: "ADMIN")
        let store = adminStore()
        try? store.clearSession()

        let service = MatrixRustSDKAdapter()
        let session = try await service.login(
            userID: admin.userID,
            password: admin.password,
            serverURL: MatrixClientConfiguration.homeserverURL
        )
        try store.saveSession(session)
        let rooms = try await service.rooms(session: session)
        emit("login ok user=\(admin.userID) rooms=\(rooms.count)")
    }

    private static func runRestore() async throws {
        let session = try requireSession()
        let service = MatrixRustSDKAdapter()
        let account = try await service.restore(session: session)
        let rooms = try await service.rooms(session: session)
        emit("restore ok user=\(account.userID) rooms=\(rooms.count)")
    }

    private static func runEncryptedDM() async throws {
        let adminSession = try requireSession()
        let test = try credentials(prefix: "TEST")
        let adminService = MatrixRustSDKAdapter()
        _ = try await adminService.restore(session: adminSession)

        let testService = MatrixRustSDKAdapter()
        let testSession = try await testService.login(
            userID: test.userID,
            password: test.password,
            serverURL: MatrixClientConfiguration.homeserverURL
        )
        _ = try await testService.rooms(session: testSession)

        let room = try await adminService.createEncryptedDirectRoom(
            inviteeUserID: test.userID,
            name: "Trix live smoke",
            session: adminSession
        )
        guard room.isEncrypted else {
            throw MatrixLiveSmokeError.roomNotEncrypted
        }
        emit("encrypted-dm-create ok room=\(room.id)")

        _ = try await testService.joinRoom(roomID: room.id, session: testSession)
        emit("encrypted-dm-join ok")

        for _ in 0..<8 {
            _ = try await adminService.rooms(session: adminSession)
            _ = try? await adminService.timeline(roomID: room.id, session: adminSession)
            try? await Task.sleep(for: .seconds(1))
        }

        let body = "trix-live-smoke-\(UUID().uuidString)"
        _ = try await adminService.sendText(body, roomID: room.id, session: adminSession)
        emit("encrypted-dm-send ok")

        var received = false
        for _ in 0..<20 {
            _ = try await testService.rooms(session: testSession)
            let timeline = try await testService.timeline(roomID: room.id, session: testSession)
            if timeline.contains(where: { $0.body == body }) {
                received = true
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }

        guard received else {
            throw MatrixLiveSmokeError.messageNotReceived
        }
        emit("encrypted-dm-receive ok")

        try? await testService.logout(session: testSession)
    }

    private static func runEncryptedAttachment() async throws {
        let adminSession = try requireSession()
        let test = try credentials(prefix: "TEST")
        let adminService = MatrixRustSDKAdapter()
        _ = try await adminService.restore(session: adminSession)

        let testService = MatrixRustSDKAdapter()
        var testSession: MatrixSession?

        func cleanup() async {
            if let testSession {
                try? await testService.logout(session: testSession)
            }
        }

        do {
            let loggedInTestSession = try await testService.login(
                userID: test.userID,
                password: test.password,
                serverURL: MatrixClientConfiguration.homeserverURL
            )
            testSession = loggedInTestSession
            _ = try await testService.rooms(session: loggedInTestSession)

            let room = try await adminService.createEncryptedDirectRoom(
                inviteeUserID: test.userID,
                name: "Trix live attachment smoke",
                session: adminSession
            )
            guard room.isEncrypted else {
                throw MatrixLiveSmokeError.roomNotEncrypted
            }
            emit("encrypted-attachment-create ok room=\(room.id)")

            _ = try await testService.joinRoom(roomID: room.id, session: loggedInTestSession)
            emit("encrypted-attachment-join ok")

            for _ in 0..<8 {
                _ = try await adminService.rooms(session: adminSession)
                _ = try? await adminService.timeline(roomID: room.id, session: adminSession)
                try? await Task.sleep(for: .seconds(1))
            }

            let filename = "trix-live-attachment-\(UUID().uuidString).txt"
            let payload = Data("trix-live-attachment-payload-\(UUID().uuidString)".utf8)
            let upload = MatrixAttachmentUpload(
                filename: filename,
                mimeType: "text/plain",
                data: payload
            )
            _ = try await adminService.sendAttachment(upload, roomID: room.id, session: adminSession)
            emit("encrypted-attachment-send ok bytes=\(payload.count)")

            var receivedAttachment: MatrixTimelineAttachment?
            for _ in 0..<30 {
                _ = try await testService.rooms(session: loggedInTestSession)
                let timeline = try await testService.timeline(roomID: room.id, session: loggedInTestSession)
                receivedAttachment = timeline
                    .compactMap(\.attachment)
                    .first { $0.filename == filename }
                if receivedAttachment != nil {
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }

            guard let receivedAttachment else {
                throw MatrixLiveSmokeError.attachmentNotReceived
            }
            emit("encrypted-attachment-receive ok bytes=\(receivedAttachment.sizeBytes ?? 0)")

            let download = try await testService.downloadAttachment(
                receivedAttachment,
                session: loggedInTestSession
            )
            guard download.data == payload else {
                throw MatrixLiveSmokeError.attachmentDownloadMismatch
            }
            emit("encrypted-attachment-download ok bytes=\(download.data.count)")

            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    private static func runDeviceVerification() async throws {
        let admin = try credentials(prefix: "ADMIN")
        let existingService = MatrixRustSDKAdapter()
        let newDeviceService = MatrixRustSDKAdapter()
        var existingSession: MatrixSession?
        var newDeviceSession: MatrixSession?

        func cleanup() async {
            if let existingSession {
                _ = try? await existingService.cancelDeviceVerification(session: existingSession)
                try? await existingService.logout(session: existingSession)
            }
            if let newDeviceSession {
                _ = try? await newDeviceService.cancelDeviceVerification(session: newDeviceSession)
                try? await newDeviceService.logout(session: newDeviceSession)
            }
        }

        do {
            let firstSession = try await existingService.login(
                userID: admin.userID,
                password: admin.password,
                serverURL: MatrixClientConfiguration.homeserverURL
            )
            existingSession = firstSession
            _ = try await existingService.rooms(session: firstSession)
            _ = try await existingService.deviceVerificationStatus(session: firstSession)
            _ = try await existingService.deviceVerificationFlow(session: firstSession)
            _ = try await emitVerificationSnapshot(
                "existing initial",
                service: existingService,
                session: firstSession
            )

            let secondSession = try await newDeviceService.login(
                userID: admin.userID,
                password: admin.password,
                serverURL: MatrixClientConfiguration.homeserverURL
            )
            newDeviceSession = secondSession
            _ = try await newDeviceService.rooms(session: secondSession)
            _ = try await newDeviceService.deviceVerificationStatus(session: secondSession)
            _ = try await newDeviceService.deviceVerificationFlow(session: secondSession)
            let newDeviceSnapshot = try await emitVerificationSnapshot(
                "new-device initial",
                service: newDeviceService,
                session: secondSession
            )

            emit("device-verification-sessions ok user=\(admin.userID)")

            guard newDeviceSnapshot.hasDevicesToVerifyAgainst else {
                emit("device-verification-state blocked reason=no-eligible-device \(newDeviceSnapshot.liveSmokeDescription)")
                await cleanup()
                return
            }

            _ = try await newDeviceService.requestDeviceVerification(session: secondSession)
            emit("device-verification-request ok")

            let incomingRequest = try await waitForFlow(
                label: "existing incoming-request",
                service: existingService,
                session: firstSession,
                phases: [.incomingRequest],
                timeoutSeconds: 45
            ).request

            guard let incomingRequest else {
                throw MatrixLiveSmokeError.verificationRequestNotReceived
            }

            _ = try await existingService.acceptDeviceVerificationRequest(
                incomingRequest,
                session: firstSession
            )
            emit("device-verification-accept ok")

            _ = try await waitForFlow(
                label: "new-device accepted",
                service: newDeviceService,
                session: secondSession,
                phases: [.accepted, .sasStarted, .challengeReceived],
                timeoutSeconds: 45
            )

            _ = try await newDeviceService.startSasDeviceVerification(session: secondSession)
            emit("device-verification-sas-start ok")

            try await waitForMatchingChallenges(
                requestingService: newDeviceService,
                requestingSession: secondSession,
                acceptingService: existingService,
                acceptingSession: firstSession,
                timeoutSeconds: 45
            )
            emit("device-verification-challenge ok")

            _ = try await newDeviceService.approveDeviceVerification(session: secondSession)
            _ = try await existingService.approveDeviceVerification(session: firstSession)

            _ = try await waitForFlow(
                label: "new-device finish",
                service: newDeviceService,
                session: secondSession,
                phases: [.finished],
                timeoutSeconds: 45
            )
            _ = try await waitForFlow(
                label: "existing finish",
                service: existingService,
                session: firstSession,
                phases: [.finished],
                timeoutSeconds: 45
            )
            emit("device-verification-finish ok")

            var verificationError: Error?
            do {
                try await waitForVerified(label: "new-device", service: newDeviceService, session: secondSession)
            } catch {
                verificationError = error
            }
            do {
                try await waitForVerified(label: "existing", service: existingService, session: firstSession)
            } catch {
                verificationError = verificationError ?? error
            }
            if let verificationError {
                throw verificationError
            }
            emit("device-verification-state ok")
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    private static func runRecoverySetupConfirmation() async throws {
        guard ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE_ALLOW_RECOVERY_MUTATION"] == "1" else {
            throw MatrixLiveSmokeError.missingRecoveryMutationOptIn
        }

        let account = try credentials(prefix: "RECOVERY")
        try validateRecoverySmokeAccount(account)

        let setupService = MatrixRustSDKAdapter()
        let confirmationService = MatrixRustSDKAdapter()
        var setupSession: MatrixSession?
        var confirmationSession: MatrixSession?

        func cleanup() async {
            if let confirmationSession {
                try? await confirmationService.logout(session: confirmationSession)
            }
            if let setupSession {
                try? await setupService.logout(session: setupSession)
            }
        }

        do {
            let setupSessionValue = try await setupService.login(
                userID: account.userID,
                password: account.password,
                serverURL: MatrixClientConfiguration.homeserverURL
            )
            setupSession = setupSessionValue
            _ = try await setupService.rooms(session: setupSessionValue)

            let setupInitialSnapshot = try await emitRecoverySnapshot(
                "setup initial",
                service: setupService,
                session: setupSessionValue
            )
            guard setupInitialSnapshot.recoveryState == "disabled" else {
                emit("recovery blocked reason=initial-recovery-not-disabled \(setupInitialSnapshot.liveSmokeDescription)")
                throw MatrixLiveSmokeError.recoveryInitialStateNotSetupEligible
            }

            let recoveryKey = try await setupService.setUpRecovery(session: setupSessionValue)
            emit("recovery-setup ok")

            _ = try await waitForRecoveryReady(
                label: "setup",
                service: setupService,
                session: setupSessionValue,
                timeoutSeconds: 60
            )

            let confirmationSessionValue = try await confirmationService.login(
                userID: account.userID,
                password: account.password,
                serverURL: MatrixClientConfiguration.homeserverURL
            )
            confirmationSession = confirmationSessionValue
            _ = try await confirmationService.rooms(session: confirmationSessionValue)

            let confirmationInitialSnapshot = try await emitRecoverySnapshot(
                "confirmation initial",
                service: confirmationService,
                session: confirmationSessionValue
            )
            guard recoveryConfirmationAvailable(confirmationInitialSnapshot) else {
                emit("recovery blocked reason=confirmation-unavailable \(confirmationInitialSnapshot.liveSmokeDescription)")
                throw MatrixLiveSmokeError.recoveryConfirmationStateUnavailable
            }

            _ = try await confirmationService.confirmRecoveryKey(recoveryKey, session: confirmationSessionValue)
            emit("recovery-confirmation ok")

            let finalSnapshot = try await waitForRecoveryReady(
                label: "confirmation",
                service: confirmationService,
                session: confirmationSessionValue,
                timeoutSeconds: 60
            )
            emit("recovery-state ok \(finalSnapshot.liveSmokeDescription)")
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    private static func runCleanup() async throws {
        let store = adminStore()
        if let session = try store.loadSession() {
            let service = MatrixRustSDKAdapter()
            _ = try? await service.restore(session: session)
            try? await service.logout(session: session)
        }
        try? store.clearSession()
        emit("cleanup ok")
    }

    private static func requireSession() throws -> MatrixSession {
        guard let session = try adminStore().loadSession() else {
            throw MatrixClientError.missingSession
        }
        return session
    }

    private static func waitForFlow(
        label: String,
        service: MatrixRustSDKAdapter,
        session: MatrixSession,
        phases: Set<MatrixDeviceVerificationFlowPhase>,
        timeoutSeconds: Int
    ) async throws -> MatrixDeviceVerificationFlow {
        for attempt in 0..<timeoutSeconds {
            let flow = try await service.deviceVerificationFlow(session: session)
            if phases.contains(flow.phase) {
                return flow
            }
            if attempt == 0 || (attempt + 1).isMultiple(of: 10) {
                emit("device-verification-flow \(label) waitSeconds=\(attempt + 1) phase=\(flow.phase.rawValue)")
            }
            if flow.phase == .failed {
                throw MatrixLiveSmokeError.verificationFailed
            }
            if flow.phase == .cancelled {
                throw MatrixLiveSmokeError.verificationCancelled
            }
            try? await Task.sleep(for: .seconds(1))
        }

        throw MatrixLiveSmokeError.verificationTimedOut
    }

    private static func waitForMatchingChallenges(
        requestingService: MatrixRustSDKAdapter,
        requestingSession: MatrixSession,
        acceptingService: MatrixRustSDKAdapter,
        acceptingSession: MatrixSession,
        timeoutSeconds: Int
    ) async throws {
        for attempt in 0..<timeoutSeconds {
            let requestingFlow = try await requestingService.deviceVerificationFlow(session: requestingSession)
            let acceptingFlow = try await acceptingService.deviceVerificationFlow(session: acceptingSession)

            if attempt == 0 || (attempt + 1).isMultiple(of: 10) {
                emit(
                    "device-verification-flow challenge waitSeconds=\(attempt + 1) " +
                    "requestingPhase=\(requestingFlow.phase.rawValue) " +
                    "acceptingPhase=\(acceptingFlow.phase.rawValue) " +
                    "requestingHasChallenge=\(requestingFlow.challenge != nil) " +
                    "acceptingHasChallenge=\(acceptingFlow.challenge != nil)"
                )
            }

            if requestingFlow.phase == .failed || acceptingFlow.phase == .failed {
                throw MatrixLiveSmokeError.verificationFailed
            }
            if requestingFlow.phase == .cancelled || acceptingFlow.phase == .cancelled {
                throw MatrixLiveSmokeError.verificationCancelled
            }

            if let requestingChallenge = requestingFlow.challenge,
               let acceptingChallenge = acceptingFlow.challenge {
                guard requestingChallenge == acceptingChallenge else {
                    throw MatrixLiveSmokeError.verificationChallengeMismatch
                }
                return
            }

            try? await Task.sleep(for: .seconds(1))
        }

        throw MatrixLiveSmokeError.verificationTimedOut
    }

    private static func waitForVerified(
        label: String,
        service: MatrixRustSDKAdapter,
        session: MatrixSession
    ) async throws {
        for attempt in 0..<60 {
            let snapshot = try await service.debugDeviceVerificationSnapshot(session: session)
            if snapshot.state == .verified {
                emit("device-verification-debug \(label) verified \(snapshot.liveSmokeDescription)")
                return
            }

            if attempt == 0 || (attempt + 1).isMultiple(of: 10) {
                emit("device-verification-debug \(label) waitSeconds=\(attempt + 1) \(snapshot.liveSmokeDescription)")
            }
            try? await Task.sleep(for: .seconds(1))
        }

        throw MatrixLiveSmokeError.verificationStateNotVerified
    }

    private static func waitForRecoveryReady(
        label: String,
        service: MatrixRustSDKAdapter,
        session: MatrixSession,
        timeoutSeconds: Int
    ) async throws -> MatrixDeviceVerificationDebugSnapshot {
        for attempt in 0..<timeoutSeconds {
            let snapshot = try await service.debugDeviceVerificationSnapshot(session: session)
            if recoveryReady(snapshot) {
                emit("recovery-debug \(label) ready \(snapshot.liveSmokeDescription)")
                return snapshot
            }

            if attempt == 0 || (attempt + 1).isMultiple(of: 10) {
                emit("recovery-debug \(label) waitSeconds=\(attempt + 1) \(snapshot.liveSmokeDescription)")
            }
            try? await Task.sleep(for: .seconds(1))
        }

        throw MatrixLiveSmokeError.recoveryStateTimedOut
    }

    @discardableResult
    private static func emitVerificationSnapshot(
        _ label: String,
        service: MatrixRustSDKAdapter,
        session: MatrixSession
    ) async throws -> MatrixDeviceVerificationDebugSnapshot {
        let snapshot = try await service.debugDeviceVerificationSnapshot(session: session)
        emit("device-verification-debug \(label) \(snapshot.liveSmokeDescription)")
        return snapshot
    }

    @discardableResult
    private static func emitRecoverySnapshot(
        _ label: String,
        service: MatrixRustSDKAdapter,
        session: MatrixSession
    ) async throws -> MatrixDeviceVerificationDebugSnapshot {
        let snapshot = try await service.debugDeviceVerificationSnapshot(session: session)
        emit("recovery-debug \(label) \(snapshot.liveSmokeDescription)")
        return snapshot
    }

    private static func adminStore() -> KeychainMatrixSessionStore {
        KeychainMatrixSessionStore(service: serviceName, account: adminAccount)
    }

    private static func validateRecoverySmokeAccount(_ credentials: MatrixLiveSmokeCredentials) throws {
        let userID = credentials.userID.lowercased()
        if userID == "@admin:trix.selfhost.ru" {
            throw MatrixLiveSmokeError.recoverySmokeAdminAccountForbidden
        }

        if let adminUserID = ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE_ADMIN_USER_ID"],
           !adminUserID.isEmpty,
           userID == adminUserID.lowercased() {
            throw MatrixLiveSmokeError.recoverySmokeAdminAccountForbidden
        }
    }

    private static func recoveryConfirmationAvailable(_ snapshot: MatrixDeviceVerificationDebugSnapshot) -> Bool {
        snapshot.recoveryState == "enabled" || snapshot.recoveryState == "incomplete"
    }

    private static func recoveryReady(_ snapshot: MatrixDeviceVerificationDebugSnapshot) -> Bool {
        snapshot.recoveryState == "enabled" && hasBackupEvidence(snapshot)
    }

    private static func hasBackupEvidence(_ snapshot: MatrixDeviceVerificationDebugSnapshot) -> Bool {
        snapshot.backupState == "enabled" || snapshot.backupExistsOnServer == .value(true)
    }

    private static func credentials(prefix: String) throws -> MatrixLiveSmokeCredentials {
        let env = ProcessInfo.processInfo.environment
        guard let userID = env["TRIX_MATRIX_LIVE_SMOKE_\(prefix)_USER_ID"],
              let password = env["TRIX_MATRIX_LIVE_SMOKE_\(prefix)_PASSWORD"],
              !userID.isEmpty,
              !password.isEmpty else {
            throw MatrixLiveSmokeError.missingCredentials(prefix)
        }

        return MatrixLiveSmokeCredentials(userID: userID, password: password)
    }

    private static func emit(_ message: String) {
        fputs("TRIX_LIVE_SMOKE \(message)\n", stderr)
    }

    private static func redacted(_ error: Error) -> String {
        let message = error.matrixUserFacingMessage
        let redactedTerms = [
            ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE_ADMIN_PASSWORD"],
            ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE_TEST_PASSWORD"],
            ProcessInfo.processInfo.environment["TRIX_MATRIX_LIVE_SMOKE_RECOVERY_PASSWORD"],
        ].compactMap { $0 }.filter { !$0.isEmpty }

        return redactedTerms.reduce(message) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[redacted]")
        }
    }
}

private struct MatrixLiveSmokeCredentials {
    let userID: String
    let password: String
}

private enum MatrixLiveSmokeError: LocalizedError {
    case missingMode
    case missingCredentials(String)
    case roomNotEncrypted
    case inviteNotJoined
    case messageNotReceived
    case attachmentNotReceived
    case attachmentDownloadMismatch
    case verificationRequestNotReceived
    case verificationChallengeMismatch
    case verificationFailed
    case verificationCancelled
    case verificationTimedOut
    case verificationStateNotVerified
    case missingRecoveryMutationOptIn
    case recoverySmokeAdminAccountForbidden
    case recoveryInitialStateNotSetupEligible
    case recoveryConfirmationStateUnavailable
    case recoveryStateTimedOut

    var errorDescription: String? {
        switch self {
        case .missingMode:
            return "Missing live smoke mode."
        case .missingCredentials(let prefix):
            return "Missing live smoke credentials for \(prefix)."
        case .roomNotEncrypted:
            return "The created Matrix room is not marked encrypted."
        case .inviteNotJoined:
            return "The test user did not join the encrypted room invite."
        case .messageNotReceived:
            return "The encrypted smoke message was not received by the test user."
        case .attachmentNotReceived:
            return "The encrypted smoke attachment was not received by the test user."
        case .attachmentDownloadMismatch:
            return "The downloaded encrypted smoke attachment did not match the sent payload."
        case .verificationRequestNotReceived:
            return "The second Matrix session did not receive the device verification request."
        case .verificationChallengeMismatch:
            return "The Matrix device verification SAS challenges did not match."
        case .verificationFailed:
            return "The Matrix device verification flow failed."
        case .verificationCancelled:
            return "The Matrix device verification flow was cancelled."
        case .verificationTimedOut:
            return "Timed out waiting for Matrix device verification progress."
        case .verificationStateNotVerified:
            return "The Matrix SDK did not report the device as verified after verification finished."
        case .missingRecoveryMutationOptIn:
            return "Recovery live smoke requires TRIX_MATRIX_LIVE_SMOKE_ALLOW_RECOVERY_MUTATION=1 and RECOVERY credentials."
        case .recoverySmokeAdminAccountForbidden:
            return "Recovery live smoke refuses to mutate the admin Matrix account."
        case .recoveryInitialStateNotSetupEligible:
            return "Recovery live smoke account is not in disabled recovery state."
        case .recoveryConfirmationStateUnavailable:
            return "Recovery live smoke confirmation is available only when recovery is enabled or incomplete."
        case .recoveryStateTimedOut:
            return "Timed out waiting for Matrix recovery and key backup state."
        }
    }
}
#else
enum MatrixLiveSmokeRunner {
    static func installIfRequested() {}
}
#endif
