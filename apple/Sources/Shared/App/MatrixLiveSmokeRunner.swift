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
            case "device-verification":
                try await runDeviceVerification()
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
            try await emitVerificationSnapshot(
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
            try await emitVerificationSnapshot(
                "new-device initial",
                service: newDeviceService,
                session: secondSession
            )

            emit("device-verification-sessions ok user=\(admin.userID)")

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

    private static func emitVerificationSnapshot(
        _ label: String,
        service: MatrixRustSDKAdapter,
        session: MatrixSession
    ) async throws {
        let snapshot = try await service.debugDeviceVerificationSnapshot(session: session)
        emit("device-verification-debug \(label) \(snapshot.liveSmokeDescription)")
    }

    private static func adminStore() -> KeychainMatrixSessionStore {
        KeychainMatrixSessionStore(service: serviceName, account: adminAccount)
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
    case verificationRequestNotReceived
    case verificationChallengeMismatch
    case verificationFailed
    case verificationCancelled
    case verificationTimedOut
    case verificationStateNotVerified

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
        }
    }
}
#else
enum MatrixLiveSmokeRunner {
    static func installIfRequested() {}
}
#endif
