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
        case timelineRestart = "timeline-restart"
        case dmE2EE = "dm-e2ee"
        case dmReaction = "dm-reaction"
        case dmAttachment = "dm-attachment"
        case deliveryReceipt = "delivery-receipt"
        case typing
        case groupE2EE = "group-e2ee"
        case groupAttachment = "group-attachment"
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
                 .blockedSend, .timeline, .sendTimeline, .timelineRestart, .dmE2EE, .dmAttachment,
                 .dmReaction, .deliveryReceipt, .groupE2EE, .groupAttachment:
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
                    status("timeline diagnostics \(timelineDiagnosticsSummary(diagnostics))")
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
                    status("send-timeline diagnostics \(timelineDiagnosticsSummary(diagnostics))")
                }

            case .timelineRestart:
                try await runTimelineRestartSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .dmE2EE:
                try await runDME2EESmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .dmAttachment:
                try await runDMAttachmentSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .dmReaction:
                try await runDMReactionSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

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

            case .groupAttachment:
                try await runGroupAttachmentSmoke(
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

    private static func runTimelineRestartSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        let peerID = try requiredPeerID(configuration.peerID)
        if configuration.allowSend {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "timeline-restart"
            )
            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let sentItem = try await service.sendText("smoke-restart-\(UUID().uuidString)", roomID: room.id, session: session)
            status("timeline-restart send ok id=\(sentItem.id)")
        }

        let beforeItems = try await service.timeline(roomID: peerID, session: session)
        guard !beforeItems.isEmpty else {
            status("timeline-restart failed empty_before")
            throw TrixClientError.roomUnavailable
        }

        if let diagnostics = try await service.timelineDiagnostics(roomID: peerID, session: session) {
            status("timeline-restart before diagnostics \(timelineDiagnosticsSummary(diagnostics))")
        }

        try? await service.logout(session: session)
        let restoredService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let restoredAccount = try await restoredService.restore(session: session)
        status("timeline-restart restore ok user=\(restoredAccount.userID) resource=\(restoredAccount.deviceID)")

        let afterItems = try await restoredService.timeline(roomID: peerID, session: session)
        let beforeIDs = Set(beforeItems.map(\.id))
        let afterIDs = Set(afterItems.map(\.id))
        let overlapCount = beforeIDs.intersection(afterIDs).count
        guard overlapCount > 0 else {
            status("timeline-restart failed overlap=0 after=\(afterItems.count)")
            try? await restoredService.logout(session: session)
            throw TrixClientError.roomUnavailable
        }

        let localEchoCount = afterItems.filter(\.isLocalEcho).count
        let sentCount = afterItems.filter { $0.deliveryState == .sent }.count
        let deliveredCount = afterItems.filter { $0.deliveryState == .delivered }.count
        status(
            "timeline-restart ok before=\(beforeItems.count) after=\(afterItems.count) overlap=\(overlapCount) local=\(localEchoCount) sent=\(sentCount) delivered=\(deliveredCount)"
        )
        if let diagnostics = try await restoredService.timelineDiagnostics(roomID: peerID, session: session) {
            status("timeline-restart after diagnostics \(timelineDiagnosticsSummary(diagnostics))")
        }

        try? await restoredService.logout(session: session)
    }

    private static func runDME2EESmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        guard configuration.allowSend else {
            throw TrixClientError.e2eeUnavailable
        }

        let peerID = try requiredPeerID(configuration.peerID)
        let peerPassword = try requiredPassword(configuration.peerPassword)
        let peerService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("dm-e2ee peer-login ok resource=\(peerSession.deviceID)")

        do {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "dm-e2ee"
            )

            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let messageBody = "smoke-dm-\(UUID().uuidString)"
            let sentItem = try await service.sendText(messageBody, roomID: room.id, session: session)
            status("dm-e2ee send ok id=\(sentItem.id)")

            guard try await waitForDirectMessage(
                messageID: sentItem.id,
                expectedBody: messageBody,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                service: peerService,
                session: peerSession
            ) else {
                status("dm-e2ee failed receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            try? await peerService.logout(session: peerSession)
            status("dm-e2ee ok decrypted_peers=1")
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runDMReactionSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        guard configuration.allowSend else {
            throw TrixClientError.e2eeUnavailable
        }

        let peerID = try requiredPeerID(configuration.peerID)
        let peerPassword = try requiredPassword(configuration.peerPassword)
        let peerService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("dm-reaction peer-login ok resource=\(peerSession.deviceID)")

        do {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "dm-reaction owner-peer"
            )
            try await ensureTrustedPeer(
                peerID: session.userID,
                service: peerService,
                session: peerSession,
                allowTrust: configuration.allowTrust,
                statusPrefix: "dm-reaction peer-owner"
            )

            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let messageBody = "smoke-reaction-\(UUID().uuidString)"
            let sentItem = try await service.sendText(messageBody, roomID: room.id, session: session)
            status("dm-reaction send ok id=\(sentItem.id)")

            guard try await waitForDirectMessage(
                messageID: sentItem.id,
                expectedBody: messageBody,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                service: peerService,
                session: peerSession
            ) else {
                status("dm-reaction failed receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            let reactions = try await peerService.setReaction("👍", messageID: sentItem.id, roomID: session.userID, session: peerSession)
            guard reactions.contains(where: { $0.sender.lowercased() == peerSession.userID.lowercased() && $0.emoji == "👍" }) else {
                status("dm-reaction failed local_reaction_missing role=peer")
                throw TrixClientError.reactionsUnavailable
            }
            status("dm-reaction react ok role=peer id=\(sentItem.id)")

            guard try await waitForReaction(
                messageID: sentItem.id,
                emoji: "👍",
                reactorID: peerSession.userID,
                roomID: peerID,
                role: "owner",
                service: service,
                session: session
            ) else {
                status("dm-reaction failed receive=false role=owner")
                throw TrixClientError.xmppConnectionFailed
            }

            try? await peerService.logout(session: peerSession)
            status("dm-reaction ok reactors=1")
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runDMAttachmentSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        guard configuration.allowSend else {
            throw TrixClientError.e2eeUnavailable
        }

        let peerID = try requiredPeerID(configuration.peerID)
        let peerPassword = try requiredPassword(configuration.peerPassword)
        let peerService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("dm-attachment peer-login ok resource=\(peerSession.deviceID)")

        do {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "dm-attachment"
            )

            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let availability = try await service.attachmentSendAvailability(roomID: room.id, session: session)
            guard availability.canSend else {
                throw TrixClientError.omemoDeviceTrustRequired
            }
            status("dm-attachment availability ok recipients=\(availability.recipientUserIDs.count)")

            let attachment = try smokeImageAttachment()
            let sentItem = try await service.sendAttachment(attachment, roomID: room.id, session: session)
            guard sentItem.attachment != nil else {
                throw TrixClientError.attachmentDownloadUnavailable
            }
            status("dm-attachment send ok id=\(sentItem.id) encrypted=true")

            guard try await waitForAttachmentDownload(
                messageID: sentItem.id,
                expectedUpload: attachment,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                statusPrefix: "dm-attachment",
                service: peerService,
                session: peerSession
            ) else {
                status("dm-attachment failed download=false role=peer")
                throw TrixClientError.attachmentDecryptionFailed
            }

            try? await peerService.logout(session: peerSession)
            status("dm-attachment ok downloaded_peers=1")
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runGroupAttachmentSmoke(
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
        status("group-attachment login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-attachment login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Attachment Smoke \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-attachment create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-attachment",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                statusPrefix: "group-attachment",
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
                statusPrefix: "group-attachment",
                service: service,
                session: session
            )
            status("group-attachment members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)")
            let peerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                statusPrefix: "group-attachment",
                service: peerService,
                session: peerSession
            )
            status("group-attachment members ok role=peer count=\(peerMembers.count) joined=\(peerMembers.filter { $0.membership == .joined }.count)")
            let thirdMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                statusPrefix: "group-attachment",
                service: thirdService,
                session: loggedInThirdSession
            )
            status("group-attachment members ok role=third count=\(thirdMembers.count) joined=\(thirdMembers.filter { $0.membership == .joined }.count)")

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
                allowTrust: configuration.allowTrust,
                statusPrefix: "group-attachment"
            )

            let availability = try await service.attachmentSendAvailability(roomID: room.id, session: session)
            guard availability.canSend else {
                throw TrixClientError.groupOmemoDeviceTrustRequired
            }
            status("group-attachment availability ok recipients=\(availability.recipientUserIDs.count)")

            let attachment = try smokeImageAttachment()
            let sentItem = try await service.sendAttachment(attachment, roomID: room.id, session: session)
            guard sentItem.attachment != nil else {
                throw TrixClientError.attachmentDownloadUnavailable
            }
            status("group-attachment send ok id=\(sentItem.id) encrypted=true")

            guard try await waitForAttachmentDownload(
                messageID: sentItem.id,
                expectedUpload: attachment,
                expectedSender: session.userID,
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-attachment",
                service: peerService,
                session: peerSession
            ) else {
                status("group-attachment failed download=false role=peer")
                throw TrixClientError.attachmentDecryptionFailed
            }

            guard try await waitForAttachmentDownload(
                messageID: sentItem.id,
                expectedUpload: attachment,
                expectedSender: session.userID,
                roomID: room.id,
                role: "third",
                statusPrefix: "group-attachment",
                service: thirdService,
                session: loggedInThirdSession
            ) else {
                status("group-attachment failed download=false role=third")
                throw TrixClientError.attachmentDecryptionFailed
            }

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
            status("group-attachment ok downloaded_peers=2")
        } catch {
            if let thirdSession {
                try? await thirdService.logout(session: thirdSession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
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
        allowTrust: Bool,
        statusPrefix: String = "group-e2ee"
    ) async throws {
        try await ensureTrustedPeer(
            peerID: peerID,
            service: ownerService,
            session: ownerSession,
            allowTrust: allowTrust,
            statusPrefix: "\(statusPrefix) trust owner-peer"
        )
        try await ensureTrustedPeer(
            peerID: thirdID,
            service: ownerService,
            session: ownerSession,
            allowTrust: allowTrust,
            statusPrefix: "\(statusPrefix) trust owner-third"
        )
        try await ensureTrustedPeer(
            peerID: ownerID,
            service: peerService,
            session: peerSession,
            allowTrust: allowTrust,
            statusPrefix: "\(statusPrefix) trust peer-owner"
        )
        try await ensureTrustedPeer(
            peerID: thirdID,
            service: peerService,
            session: peerSession,
            allowTrust: allowTrust,
            statusPrefix: "\(statusPrefix) trust peer-third"
        )
        try await ensureTrustedPeer(
            peerID: ownerID,
            service: thirdService,
            session: thirdSession,
            allowTrust: allowTrust,
            statusPrefix: "\(statusPrefix) trust third-owner"
        )
        try await ensureTrustedPeer(
            peerID: peerID,
            service: thirdService,
            session: thirdSession,
            allowTrust: allowTrust,
            statusPrefix: "\(statusPrefix) trust third-peer"
        )
        status("\(statusPrefix) trust-checks ok checks=6")
    }

    private static func acceptGroupInvitation(
        roomID: String,
        role: String,
        statusPrefix: String = "group-e2ee",
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        for attempt in 0..<30 {
            let invitations = try await service.invitations(session: session)
            if invitations.contains(where: { $0.id.lowercased() == roomID.lowercased() }) {
                status("\(statusPrefix) invite ok role=\(role) pending=\(invitations.count)")
                let summary = try await service.acceptInvitation(roomID: roomID, session: session)
                guard summary.kind == .group, summary.isEncrypted else {
                    throw TrixClientError.e2eeUnavailable
                }
                status("\(statusPrefix) join ok role=\(role)")
                return summary
            }

            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        status("\(statusPrefix) failed invite_missing role=\(role)")
        throw TrixClientError.inviteUnavailable
    }

    private static func waitForGroupMembers(
        roomID: String,
        expectedUserIDs: [String],
        statusPrefix: String = "group-e2ee",
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

        status("\(statusPrefix) failed members_missing count=\(lastMembers.count)")
        throw TrixClientError.roomUnavailable
    }

    private static func waitForDirectMessage(
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
                status("dm-e2ee receive ok role=\(role) id=\(messageID) decrypted=true")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("dm-e2ee failed receive_mismatch role=\(role) id=\(messageID)")
        }
        return false
    }

    private static func waitForReaction(
        messageID: String,
        emoji: String,
        reactorID: String,
        roomID: String,
        role: String,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> Bool {
        let reactorKey = reactorID.lowercased()
        var sawID = false
        for _ in 0..<40 {
            let items = try await service.timeline(roomID: roomID, session: session)
            if let item = items.first(where: { $0.id == messageID }) {
                sawID = true
                if item.reactions.contains(where: { $0.sender.lowercased() == reactorKey && $0.emoji == emoji }) {
                    let aggregateCount = item.reactionAggregates.first(where: { $0.emoji == emoji })?.count ?? 0
                    status("dm-reaction receive ok role=\(role) id=\(messageID) aggregate=\(aggregateCount)")
                    return true
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("dm-reaction failed reaction_missing role=\(role) id=\(messageID)")
        }
        return false
    }

    private static func waitForAttachmentDownload(
        messageID: String,
        expectedUpload: TrixAttachmentUpload,
        expectedSender: String,
        roomID: String,
        role: String,
        statusPrefix: String,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> Bool {
        let expectedSenderKey = expectedSender.lowercased()
        var sawID = false
        for _ in 0..<40 {
            let items = try await service.timeline(roomID: roomID, session: session)
            let matchingItems = items.filter { item in
                let senderMatches = item.sender.lowercased() == expectedSenderKey
                let idMatches = item.id == messageID
                sawID = sawID || idMatches
                return !item.isLocalEcho && senderMatches && idMatches && item.attachment != nil
            }

            for item in matchingItems {
                guard let attachment = item.attachment else {
                    continue
                }

                do {
                    let download = try await service.downloadAttachment(attachment, session: session)
                    guard download.data == expectedUpload.data,
                          download.mimeType == Optional(expectedUpload.mimeType),
                          download.isImage == expectedUpload.isImage else {
                        status("\(statusPrefix) failed attachment_mismatch role=\(role) id=\(messageID)")
                        return false
                    }

                    status(
                        "\(statusPrefix) download ok role=\(role) id=\(messageID) bytes=\(download.data.count) image=\(download.isImage)"
                    )
                    return true
                } catch {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("\(statusPrefix) failed attachment_download_unavailable role=\(role) id=\(messageID)")
        }
        return false
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

    private static func smokeImageAttachment() throws -> TrixAttachmentUpload {
        let base64PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64PNG) else {
            throw TrixClientError.attachmentTransferFailed
        }

        return TrixAttachmentUpload(
            filename: "trix-smoke-image.png",
            mimeType: "image/png",
            data: data
        )
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

    private static func timelineDiagnosticsSummary(_ diagnostics: XMPPTimelineDiagnostics) -> String {
        [
            "mam=\(diagnostics.mamQuerySucceeded ? "ok" : "failed")",
            "raw=\(diagnostics.mamRawCount)",
            "filtered=\(diagnostics.mamFilteredCount)",
            "encrypted=\(diagnostics.mamEncryptedCount)",
            "decoded=\(diagnostics.mamDecodedCount)",
            "local_keys=\(diagnostics.mamLocalKeyCount)",
            "account_from=\(diagnostics.mamAccountSenderCount)",
            "account_missing_local_key=\(diagnostics.mamAccountSenderMissingLocalKeyCount)",
            "peer_from=\(diagnostics.mamPeerSenderCount)",
            "cache_loaded=\(diagnostics.localCacheLoadedCount)",
            "cached=\(diagnostics.cachedCount)",
            "fallback=\(diagnostics.usedUnfilteredFallback)",
        ].joined(separator: " ")
    }

    private static func status(_ message: String) {
        statusOutput.writeStatus(message)
    }
}
