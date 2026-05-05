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
        }
    }
}
#else
enum MatrixLiveSmokeRunner {
    static func installIfRequested() {}
}
#endif
