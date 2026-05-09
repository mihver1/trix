import Foundation
import Darwin

enum XMPPLiveSmokeRunner {
    private final class StatusOutput: @unchecked Sendable {
        private let statusFD: Int32

        init() {
            statusFD = dup(STDOUT_FILENO)
        }

        func silenceStandardStreams() {
            let devNull = open("/dev/null", O_WRONLY)
            guard devNull >= 0 else {
                return
            }

            _ = dup2(devNull, STDOUT_FILENO)
            _ = dup2(devNull, STDERR_FILENO)
            close(devNull)
        }

        func writeStatus(_ message: String) {
            let line = "TRIX_XMPP_LIVE_SMOKE \(message)\n"
            line.withCString { pointer in
                _ = Darwin.write(statusFD, pointer, strlen(pointer))
            }
        }
    }

    private static let statusOutput = StatusOutput()

    private enum Mode: String {
        case login
        case sessionRestore = "session-restore"
        case roster
        case roomList = "room-list"
        case search
        case peerDevices = "peer-devices"
        case trustPeer = "trust-peer"
        case profile
        case profileUpdate = "profile-update"
        case blockedSend = "blocked-send"
        case timeline
        case sendTimeline = "send-timeline"
        case deliveryReceipt = "delivery-receipt"
        case typing
        case groupE2EE = "group-e2ee"
    }

    private struct Configuration {
        let mode: Mode
        let userID: String
        let password: String
        let peerID: String?
        let peerPassword: String?
        let thirdID: String?
        let thirdPassword: String?
        let searchTerm: String?
        let profileDisplayName: String?
        let profileBio: String?
        let profileStatusMessage: String?
        let profileWebsite: String?
        let allowSend: Bool
        let allowTrust: Bool
        let allowProfileUpdate: Bool
        let serverURL: URL

        var omemoPersistence: TrixOMEMOPersistence {
            switch mode {
            case .login, .sessionRestore, .typing:
                return .memory
            case .roster, .roomList, .search, .peerDevices, .trustPeer, .profile, .profileUpdate,
                 .blockedSend, .timeline, .sendTimeline, .deliveryReceipt, .groupE2EE:
                return .keychain
            }
        }

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
                peerPassword: environment["TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD"],
                thirdID: environment["TRIX_XMPP_LIVE_SMOKE_THIRD_ID"],
                thirdPassword: environment["TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD"],
                searchTerm: environment["TRIX_XMPP_LIVE_SMOKE_SEARCH_TERM"],
                profileDisplayName: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_DISPLAY_NAME"],
                profileBio: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_BIO"],
                profileStatusMessage: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_STATUS"],
                profileWebsite: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_WEBSITE"],
                allowSend: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND"] == "1",
                allowTrust: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST"] == "1",
                allowProfileUpdate: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_PROFILE_UPDATE"] == "1",
                serverURL: serverURL
            )
        }
    }

    static func installIfRequested() {
        guard let configuration = Configuration.environment else {
            if ProcessInfo.processInfo.environment["TRIX_XMPP_LIVE_SMOKE_MODE"] != nil {
                exit(1)
            }
            return
        }

        statusOutput.silenceStandardStreams()
        disablePersistentStateRestoreForSmoke()
        Task.detached(priority: .userInitiated) {
            await run(configuration)
        }
    }

    private static func disablePersistentStateRestoreForSmoke() {
        #if os(macOS)
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return
        }

        let savedStateURL = libraryURL
            .appendingPathComponent("Saved Application State")
            .appendingPathComponent("\(bundleIdentifier).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
        #endif
    }

    private static func run(_ configuration: Configuration) async {
        status("start mode=\(configuration.mode.rawValue)")

        let service = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)

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

            case .sessionRestore:
                try await runSessionRestoreSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

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
                    throw TrixClientError.invalidTrixUserID
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
                    throw TrixClientError.omemoDeviceTrustRequired
                }
                let peerID = try requiredPeerID(configuration.peerID)
                let devices = try await service.refreshPeerDeviceIdentities(userID: peerID, session: session)
                guard let device = devices.first(where: { $0.isActive && !$0.canSendEncrypted }) else {
                    throw TrixClientError.noEligibleDeviceForVerification
                }
                let updatedDevices = try await service.trustPeerDevice(
                    userID: peerID,
                    deviceID: device.deviceID,
                    session: session
                )
                let trustedCount = updatedDevices.filter(\.canSendEncrypted).count
                let activeCount = updatedDevices.filter(\.isActive).count
                status("trust-peer ok device=\(device.deviceID) active=\(activeCount) trusted=\(trustedCount)")

            case .profile:
                let profile = try await service.profile(userID: session.userID, session: session)
                status(
                    "profile ok has_display_name=\(profile.displayName?.isEmpty == false) has_bio=\(profile.metadata.bio != nil) has_status=\(profile.metadata.statusMessage != nil) has_website=\(profile.metadata.website != nil)"
                )

            case .profileUpdate:
                guard configuration.allowProfileUpdate else {
                    throw TrixClientError.sdkAdapterUnavailable
                }
                let profile = try await service.updateProfile(
                    TrixUserProfileUpdate(
                        displayName: configuration.profileDisplayName ?? "",
                        bio: configuration.profileBio ?? "",
                        statusMessage: configuration.profileStatusMessage ?? "",
                        website: configuration.profileWebsite ?? ""
                    ),
                    session: session
                )
                status(
                    "profile-update ok has_display_name=\(profile.displayName?.isEmpty == false) has_bio=\(profile.metadata.bio != nil) has_status=\(profile.metadata.statusMessage != nil) has_website=\(profile.metadata.website != nil)"
                )

            case .timeline:
                let peerID = try requiredPeerID(configuration.peerID)
                let items = try await service.timeline(roomID: peerID, session: session)
                let localEchoCount = items.filter(\.isLocalEcho).count
                let sentCount = items.filter { $0.deliveryState == .sent }.count
                let deliveredCount = items.filter { $0.deliveryState == .delivered }.count
                status("timeline ok count=\(items.count) local=\(localEchoCount) sent=\(sentCount) delivered=\(deliveredCount)")
                if let diagnostics = try await service.timelineDiagnostics(roomID: peerID, session: session) {
                    status(
                        "timeline diagnostics mam=\(diagnostics.mamQuerySucceeded ? "ok" : "failed") raw=\(diagnostics.mamRawCount) filtered=\(diagnostics.mamFilteredCount) encrypted=\(diagnostics.mamEncryptedCount) decoded=\(diagnostics.mamDecodedCount) local_keys=\(diagnostics.mamLocalKeyCount) account_from=\(diagnostics.mamAccountSenderCount) peer_from=\(diagnostics.mamPeerSenderCount) cached=\(diagnostics.cachedCount) fallback=\(diagnostics.usedUnfilteredFallback)"
                    )
                }

            case .sendTimeline:
                guard configuration.allowSend else {
                    throw TrixClientError.e2eeUnavailable
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
                let sentCount = items.filter { $0.deliveryState == .sent }.count
                let deliveredCount = items.filter { $0.deliveryState == .delivered }.count
                status("send-timeline timeline ok count=\(items.count) local=\(localEchoCount) sent=\(sentCount) delivered=\(deliveredCount)")
                if let diagnostics = try await service.timelineDiagnostics(roomID: peerID, session: session) {
                    status(
                        "send-timeline diagnostics mam=\(diagnostics.mamQuerySucceeded ? "ok" : "failed") raw=\(diagnostics.mamRawCount) filtered=\(diagnostics.mamFilteredCount) encrypted=\(diagnostics.mamEncryptedCount) decoded=\(diagnostics.mamDecodedCount) local_keys=\(diagnostics.mamLocalKeyCount) account_from=\(diagnostics.mamAccountSenderCount) peer_from=\(diagnostics.mamPeerSenderCount) cached=\(diagnostics.cachedCount) fallback=\(diagnostics.usedUnfilteredFallback)"
                    )
                }

            case .deliveryReceipt:
                try await runDeliveryReceiptSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .typing:
                try await runTypingSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .groupE2EE:
                try await runGroupE2EESmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

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
                } catch TrixClientError.e2eeUnavailable, TrixClientError.omemoDeviceTrustRequired {
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

    private static func runGroupE2EESmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        guard configuration.allowSend else {
            throw TrixClientError.e2eeUnavailable
        }
        guard configuration.allowTrust else {
            throw TrixClientError.omemoDeviceTrustRequired
        }

        let peerID = try requiredPeerID(configuration.peerID)
        let peerPassword = try requiredPassword(configuration.peerPassword)
        let thirdID = try requiredPeerID(configuration.thirdID)
        let thirdPassword = try requiredPassword(configuration.thirdPassword)
        guard Set([session.userID, peerID, thirdID].map { $0.lowercased() }).count == 3 else {
            throw TrixClientError.invalidTrixUserID
        }

        let peerService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let thirdService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("group-e2ee login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-e2ee login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Smoke \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-e2ee create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                service: thirdService,
                session: loggedInThirdSession
            )
            guard peerRoom.id.lowercased() == room.id.lowercased(),
                  thirdRoom.id.lowercased() == room.id.lowercased() else {
                throw TrixClientError.roomUnavailable
            }

            let ownerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                service: service,
                session: session
            )
            status("group-e2ee members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)")
            let peerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                service: peerService,
                session: peerSession
            )
            status("group-e2ee members ok role=peer count=\(peerMembers.count) joined=\(peerMembers.filter { $0.membership == .joined }.count)")
            let thirdMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                service: thirdService,
                session: loggedInThirdSession
            )
            status("group-e2ee members ok role=third count=\(thirdMembers.count) joined=\(thirdMembers.filter { $0.membership == .joined }.count)")

            try await ensureGroupTrustGraph(
                ownerID: session.userID,
                ownerService: service,
                ownerSession: session,
                peerID: peerID,
                peerService: peerService,
                peerSession: peerSession,
                thirdID: thirdID,
                thirdService: thirdService,
                thirdSession: loggedInThirdSession,
                allowTrust: configuration.allowTrust
            )

            let messageBody = "smoke-group-\(UUID().uuidString)"
            let sentItem = try await service.sendText(messageBody, roomID: room.id, session: session)
            status("group-e2ee send ok id=\(sentItem.id)")

            guard try await waitForGroupMessage(
                messageID: sentItem.id,
                expectedBody: messageBody,
                expectedSender: session.userID,
                roomID: room.id,
                role: "peer",
                service: peerService,
                session: peerSession
            ) else {
                status("group-e2ee failed receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            guard try await waitForGroupMessage(
                messageID: sentItem.id,
                expectedBody: messageBody,
                expectedSender: session.userID,
                roomID: room.id,
                role: "third",
                service: thirdService,
                session: loggedInThirdSession
            ) else {
                status("group-e2ee failed receive=false role=third")
                throw TrixClientError.xmppConnectionFailed
            }

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
            status("group-e2ee ok decrypted_peers=2")
        } catch {
            if let thirdSession {
                try? await thirdService.logout(session: thirdSession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runSessionRestoreSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        let store = KeychainTrixSessionStore(
            service: "com.softgrid.trix.live-smoke.session",
            account: "xmpp-session-restore",
            legacyService: nil,
            legacyAccount: nil
        )
        try? store.clearSession()
        try store.saveSession(session)
        status("session-restore save ok")

        guard let restoredSession = try store.loadSession() else {
            throw TrixClientError.missingSession
        }
        status("session-restore load ok user=\(restoredSession.userID) resource=\(restoredSession.deviceID)")

        let restoredService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let restoredAccount = try await restoredService.restore(session: restoredSession)
        status("session-restore restore ok user=\(restoredAccount.userID) resource=\(restoredAccount.deviceID)")

        try? await restoredService.logout(session: restoredSession)
        try? await service.logout(session: session)
        try store.clearSession()
        if try store.loadSession() != nil {
            throw TrixClientError.keychainFailure("smoke session was not cleared")
        }
        status("session-restore clear ok")
    }

    private static func runTypingSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        let peerID = try requiredPeerID(configuration.peerID)
        guard let peerPassword = configuration.peerPassword,
              !peerPassword.isEmpty else {
            throw TrixClientError.invalidCredentials
        }

        let peerService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("typing peer-login ok user=\(peerSession.userID) resource=\(peerSession.deviceID)")

        do {
            try await peerService.sendTypingState(.composing, roomID: session.userID, session: peerSession)
            guard try await waitForTypingState(
                roomID: peerID,
                expected: true,
                service: service,
                session: session
            ) else {
                status("typing failed composing=false")
                throw TrixClientError.xmppConnectionFailed
            }

            status("typing composing ok")
            try await peerService.sendTypingState(.paused, roomID: session.userID, session: peerSession)
            guard try await waitForTypingState(
                roomID: peerID,
                expected: false,
                service: service,
                session: session
            ) else {
                status("typing failed paused=false")
                throw TrixClientError.xmppConnectionFailed
            }

            status("typing paused ok")
            try? await peerService.logout(session: peerSession)
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runDeliveryReceiptSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        guard configuration.allowSend else {
            throw TrixClientError.e2eeUnavailable
        }

        let peerID = try requiredPeerID(configuration.peerID)
        guard let peerPassword = configuration.peerPassword,
              !peerPassword.isEmpty else {
            throw TrixClientError.invalidCredentials
        }

        let peerService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("delivery-receipt peer-login ok user=\(peerSession.userID) resource=\(peerSession.deviceID)")

        do {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "delivery-receipt"
            )

            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let item = try await service.sendText("smoke-\(UUID().uuidString)", roomID: room.id, session: session)
            status("delivery-receipt send ok id=\(item.id)")

            guard try await waitForDeliveredState(
                messageID: item.id,
                roomID: peerID,
                service: service,
                session: session
            ) else {
                status("delivery-receipt failed delivered=false")
                throw TrixClientError.xmppConnectionFailed
            }

            status("delivery-receipt ok delivered=true")
            try? await peerService.logout(session: peerSession)
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func ensureTrustedPeer(
        peerID: String,
        service: XMPPMartinService,
        session: TrixSession,
        allowTrust: Bool,
        statusPrefix: String
    ) async throws {
        var lastDevices: [TrixPeerDeviceIdentity] = []
        for attempt in 0..<20 {
            let devices = try await service.refreshPeerDeviceIdentities(userID: peerID, session: session)
            lastDevices = devices
            if devices.contains(where: \.canSendEncrypted) {
                status("\(statusPrefix) peer-trust ok active=\(devices.filter(\.isActive).count) trusted=\(devices.filter(\.canSendEncrypted).count)")
                return
            }

            guard allowTrust else {
                throw TrixClientError.omemoDeviceTrustRequired
            }

            if let device = devices.first(where: \.isActive) {
                let updatedDevices = try await service.trustPeerDevice(
                    userID: peerID,
                    deviceID: device.deviceID,
                    session: session
                )
                lastDevices = updatedDevices
                if updatedDevices.contains(where: \.canSendEncrypted) {
                    status("\(statusPrefix) peer-trust ok active=\(updatedDevices.filter(\.isActive).count) trusted=\(updatedDevices.filter(\.canSendEncrypted).count)")
                    return
                }
            }

            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        if lastDevices.contains(where: \.isActive) {
            throw TrixClientError.omemoDeviceTrustRequired
        }
        throw TrixClientError.noEligibleDeviceForVerification
    }

    private static func ensureGroupTrustGraph(
        ownerID: String,
        ownerService: XMPPMartinService,
        ownerSession: TrixSession,
        peerID: String,
        peerService: XMPPMartinService,
        peerSession: TrixSession,
        thirdID: String,
        thirdService: XMPPMartinService,
        thirdSession: TrixSession,
        allowTrust: Bool
    ) async throws {
        try await ensureTrustedPeer(
            peerID: peerID,
            service: ownerService,
            session: ownerSession,
            allowTrust: allowTrust,
            statusPrefix: "group-e2ee trust owner-peer"
        )
        try await ensureTrustedPeer(
            peerID: thirdID,
            service: ownerService,
            session: ownerSession,
            allowTrust: allowTrust,
            statusPrefix: "group-e2ee trust owner-third"
        )
        try await ensureTrustedPeer(
            peerID: ownerID,
            service: peerService,
            session: peerSession,
            allowTrust: allowTrust,
            statusPrefix: "group-e2ee trust peer-owner"
        )
        try await ensureTrustedPeer(
            peerID: thirdID,
            service: peerService,
            session: peerSession,
            allowTrust: allowTrust,
            statusPrefix: "group-e2ee trust peer-third"
        )
        try await ensureTrustedPeer(
            peerID: ownerID,
            service: thirdService,
            session: thirdSession,
            allowTrust: allowTrust,
            statusPrefix: "group-e2ee trust third-owner"
        )
        try await ensureTrustedPeer(
            peerID: peerID,
            service: thirdService,
            session: thirdSession,
            allowTrust: allowTrust,
            statusPrefix: "group-e2ee trust third-peer"
        )
        status("group-e2ee trust-checks ok checks=6")
    }

    private static func acceptGroupInvitation(
        roomID: String,
        role: String,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        for attempt in 0..<30 {
            let invitations = try await service.invitations(session: session)
            if invitations.contains(where: { $0.id.lowercased() == roomID.lowercased() }) {
                status("group-e2ee invite ok role=\(role) pending=\(invitations.count)")
                let summary = try await service.acceptInvitation(roomID: roomID, session: session)
                guard summary.kind == .group, summary.isEncrypted else {
                    throw TrixClientError.e2eeUnavailable
                }
                status("group-e2ee join ok role=\(role)")
                return summary
            }

            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        status("group-e2ee failed invite_missing role=\(role)")
        throw TrixClientError.inviteUnavailable
    }

    private static func waitForGroupMembers(
        roomID: String,
        expectedUserIDs: [String],
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> [TrixRoomMember] {
        let expected = Set(expectedUserIDs.map { $0.lowercased() })
        var lastMembers: [TrixRoomMember] = []
        for attempt in 0..<20 {
            let members = try await service.members(roomID: roomID, session: session)
            lastMembers = members
            let joined = Set(
                members
                    .filter { $0.membership == .joined }
                    .map { $0.userID.lowercased() }
            )
            if expected.isSubset(of: joined) {
                return members
            }

            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        status("group-e2ee failed members_missing count=\(lastMembers.count)")
        throw TrixClientError.roomUnavailable
    }

    private static func waitForGroupMessage(
        messageID: String,
        expectedBody: String,
        expectedSender: String,
        roomID: String,
        role: String,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> Bool {
        let expectedSenderKey = expectedSender.lowercased()
        var sawID = false
        for _ in 0..<40 {
            let items = try await service.timeline(roomID: roomID, session: session)
            if items.contains(where: { item in
                let senderMatches = item.sender.lowercased() == expectedSenderKey
                let idMatches = item.id == messageID
                let bodyMatches = item.body == expectedBody
                sawID = sawID || idMatches
                return !item.isLocalEcho && senderMatches && idMatches && bodyMatches
            }) {
                status("group-e2ee receive ok role=\(role) id=\(messageID) decrypted=true")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("group-e2ee failed receive_mismatch role=\(role) id=\(messageID)")
        }
        return false
    }

    private static func waitForDeliveredState(
        messageID: String,
        roomID: String,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> Bool {
        for _ in 0..<20 {
            let items = try await service.timeline(roomID: roomID, session: session)
            if items.contains(where: { $0.id == messageID && $0.deliveryState == .delivered }) {
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        return false
    }

    private static func waitForTypingState(
        roomID: String,
        expected: Bool,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> Bool {
        for _ in 0..<20 {
            let state = try await service.typingState(roomID: roomID, session: session)
            if state.hasTypingUsers == expected {
                return true
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        return false
    }

    private static func requiredPeerID(_ peerID: String?) throws -> String {
        guard let peerID,
              !peerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.invalidTrixUserID
        }

        return peerID
    }

    private static func requiredPassword(_ password: String?) throws -> String {
        guard let password,
              !password.isEmpty else {
            throw TrixClientError.invalidCredentials
        }

        return password
    }

    private static func safeError(_ error: Error) -> String {
        switch error {
        case let clientError as TrixClientError:
            return clientError.errorDescription ?? "client_error"
        default:
            return "unexpected_error"
        }
    }

    private static func status(_ message: String) {
        statusOutput.writeStatus(message)
    }
}
