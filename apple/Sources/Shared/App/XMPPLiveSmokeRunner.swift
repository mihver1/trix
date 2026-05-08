import Foundation
import Darwin

enum XMPPLiveSmokeRunner {
    private enum Mode: String {
        case login
        case roster
        case roomList = "room-list"
        case search
        case peerDevices = "peer-devices"
        case trustPeer = "trust-peer"
        case blockedSend = "blocked-send"
        case timeline
        case sendTimeline = "send-timeline"
    }

    private struct Configuration {
        let mode: Mode
        let userID: String
        let password: String
        let peerID: String?
        let searchTerm: String?
        let allowSend: Bool
        let allowTrust: Bool
        let serverURL: URL

        static var environment: Self? {
            let environment = ProcessInfo.processInfo.environment
            guard let modeValue = environment["TRIX_XMPP_LIVE_SMOKE_MODE"],
                  let mode = Mode(rawValue: modeValue) else {
                return nil
            }

            guard let userID = environment["TRIX_XMPP_LIVE_SMOKE_USER_ID"],
                  let password = environment["TRIX_XMPP_LIVE_SMOKE_PASSWORD"],
                  !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !password.isEmpty else {
                status("configuration missing_credentials")
                return nil
            }

            let serverURL = environment["TRIX_XMPP_LIVE_SMOKE_SERVER_URL"]
                .flatMap(URL.init(string:)) ?? XMPPClientConfiguration.connectionURL

            return Self(
                mode: mode,
                userID: userID,
                password: password,
                peerID: environment["TRIX_XMPP_LIVE_SMOKE_PEER_ID"],
                searchTerm: environment["TRIX_XMPP_LIVE_SMOKE_SEARCH_TERM"],
                allowSend: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND"] == "1",
                allowTrust: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST"] == "1",
                serverURL: serverURL
            )
        }
    }

    static func installIfRequested() {
        guard let configuration = Configuration.environment else {
            return
        }

        Task {
            await run(configuration)
        }
    }

    private static func run(_ configuration: Configuration) async {
        status("start mode=\(configuration.mode.rawValue)")

        let service = XMPPMartinService()

        do {
            let session = try await service.login(
                userID: configuration.userID,
                password: configuration.password,
                serverURL: configuration.serverURL
            )
            status("login ok user=\(session.userID) resource=\(session.deviceID)")

            switch configuration.mode {
            case .login:
                break

            case .roster:
                let rooms = try await service.rooms(session: session)
                status("roster ok count=\(rooms.count)")

            case .roomList:
                let rooms = try await service.rooms(session: session)
                let invitations = try await service.invitations(session: session)
                status("room-list ok rooms=\(rooms.count) invitations=\(invitations.count)")

            case .search:
                let searchTerm = configuration.searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let searchTerm, !searchTerm.isEmpty else {
                    throw MatrixClientError.invalidMatrixUserID
                }
                let result = try await service.searchUsers(searchTerm, limit: 20, session: session)
                status("search ok count=\(result.users.count) limited=\(result.limited)")

            case .peerDevices:
                let peerID = try requiredPeerID(configuration.peerID)
                let devices = try await service.refreshPeerDeviceIdentities(userID: peerID, session: session)
                let trustedCount = devices.filter(\.canSendEncrypted).count
                let activeCount = devices.filter(\.isActive).count
                status("peer-devices ok count=\(devices.count) active=\(activeCount) trusted=\(trustedCount)")

            case .trustPeer:
                guard configuration.allowTrust else {
                    throw MatrixClientError.omemoDeviceTrustRequired
                }
                let peerID = try requiredPeerID(configuration.peerID)
                let devices = try await service.refreshPeerDeviceIdentities(userID: peerID, session: session)
                guard let device = devices.first(where: { $0.isActive && !$0.canSendEncrypted }) else {
                    throw MatrixClientError.noEligibleDeviceForVerification
                }
                let updatedDevices = try await service.trustPeerDevice(
                    userID: peerID,
                    deviceID: device.deviceID,
                    session: session
                )
                let trustedCount = updatedDevices.filter(\.canSendEncrypted).count
                let activeCount = updatedDevices.filter(\.isActive).count
                status("trust-peer ok device=\(device.deviceID) active=\(activeCount) trusted=\(trustedCount)")

            case .timeline:
                let peerID = try requiredPeerID(configuration.peerID)
                let items = try await service.timeline(roomID: peerID, session: session)
                let localEchoCount = items.filter(\.isLocalEcho).count
                status("timeline ok count=\(items.count) local=\(localEchoCount)")
                if let diagnostics = try await service.timelineDiagnostics(roomID: peerID, session: session) {
                    status(
                        "timeline diagnostics mam=\(diagnostics.mamQuerySucceeded ? "ok" : "failed") raw=\(diagnostics.mamRawCount) filtered=\(diagnostics.mamFilteredCount) encrypted=\(diagnostics.mamEncryptedCount) decoded=\(diagnostics.mamDecodedCount) cached=\(diagnostics.cachedCount) fallback=\(diagnostics.usedUnfilteredFallback)"
                    )
                }

            case .sendTimeline:
                guard configuration.allowSend else {
                    throw MatrixClientError.e2eeUnavailable
                }
                let peerID = try requiredPeerID(configuration.peerID)
                let room = try await service.createEncryptedDirectRoom(
                    inviteeUserID: peerID,
                    name: "",
                    session: session
                )
                let item = try await service.sendText("smoke-\(UUID().uuidString)", roomID: room.id, session: session)
                status("send-timeline send ok id=\(item.id)")
                let items = try await service.timeline(roomID: peerID, session: session)
                let localEchoCount = items.filter(\.isLocalEcho).count
                status("send-timeline timeline ok count=\(items.count) local=\(localEchoCount)")
                if let diagnostics = try await service.timelineDiagnostics(roomID: peerID, session: session) {
                    status(
                        "send-timeline diagnostics mam=\(diagnostics.mamQuerySucceeded ? "ok" : "failed") raw=\(diagnostics.mamRawCount) filtered=\(diagnostics.mamFilteredCount) encrypted=\(diagnostics.mamEncryptedCount) decoded=\(diagnostics.mamDecodedCount) cached=\(diagnostics.cachedCount) fallback=\(diagnostics.usedUnfilteredFallback)"
                    )
                }

            case .blockedSend:
                let peerID = try requiredPeerID(configuration.peerID)
                let room = try await service.createEncryptedDirectRoom(
                    inviteeUserID: peerID,
                    name: "",
                    session: session
                )

                do {
                    _ = try await service.sendText("smoke", roomID: room.id, session: session)
                    status("blocked-send failed plaintext_send_allowed")
                } catch MatrixClientError.e2eeUnavailable, MatrixClientError.omemoDeviceTrustRequired {
                    status("blocked-send ok omemo_trust_required")
                }

                let rooms = try await service.rooms(session: session)
                status("blocked-send roster count=\(rooms.count)")
            }

            try? await service.logout(session: session)
            status("finish ok")
            exit(0)
        } catch {
            status("finish failed error=\(safeError(error))")
            exit(1)
        }
    }

    private static func requiredPeerID(_ peerID: String?) throws -> String {
        guard let peerID,
              !peerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatrixClientError.invalidMatrixUserID
        }

        return peerID
    }

    private static func safeError(_ error: Error) -> String {
        switch error {
        case let clientError as MatrixClientError:
            return clientError.errorDescription ?? "client_error"
        default:
            return "unexpected_error"
        }
    }

    private static func status(_ message: String) {
        print("TRIX_XMPP_LIVE_SMOKE \(message)")
    }
}
