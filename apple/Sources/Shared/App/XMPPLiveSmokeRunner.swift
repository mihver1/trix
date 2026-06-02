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

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TRIX_XMPP_LIVE_SMOKE_MODE"] != nil
    }

    private enum Mode: String {
        case login
        case sessionRestore = "session-restore"
        case roster
        case roomList = "room-list"
        case search
        case peerDevices = "peer-devices"
        case secondDeviceFingerprint = "second-device-fingerprint"
        case ownDeviceRevocation = "own-device-revocation"
        case trustPeer = "trust-peer"
        case profile
        case profileUpdate = "profile-update"
        case blockedSend = "blocked-send"
        case timeline
        case sendTimeline = "send-timeline"
        case timelineRestart = "timeline-restart"
        case groupTimelineRestart = "group-timeline-restart"
        case timelineRelaunchSeed = "timeline-relaunch-seed"
        case timelineRelaunchVerify = "timeline-relaunch-verify"
        case dmE2EE = "dm-e2ee"
        case dmReaction = "dm-reaction"
        case dmReply = "dm-reply"
        case dmEditRetract = "dm-edit-retract"
        case dmAttachment = "dm-attachment"
        case deliveryReceipt = "delivery-receipt"
        case typing
        case groupE2EE = "group-e2ee"
        case groupAttachment = "group-attachment"
        case groupMention = "group-mention"
        case groupThread = "group-thread"
        case groupLeave = "group-leave"
        case groupCallLabMedia = "group-call-lab-media"
        case callEchoAssistant = "call-echo-assistant"
        case readMarkers = "read-markers"

        var requiresKeychainStorage: Bool {
            switch self {
            case .sessionRestore, .timelineRelaunchSeed, .timelineRelaunchVerify:
                return true
            case .login, .roster, .roomList, .search, .peerDevices,
                 .secondDeviceFingerprint, .ownDeviceRevocation, .trustPeer, .profile,
                 .profileUpdate, .blockedSend, .timeline, .sendTimeline, .timelineRestart,
                 .groupTimelineRestart, .dmE2EE, .dmReaction, .dmReply, .dmEditRetract,
                 .dmAttachment, .deliveryReceipt, .typing, .groupE2EE, .groupAttachment,
                 .groupMention, .groupThread, .groupLeave, .groupCallLabMedia,
                 .callEchoAssistant, .readMarkers:
                return false
            }
        }

        var requiresCredentials: Bool {
            switch self {
            case .timelineRelaunchVerify:
                return false
            case .login, .sessionRestore, .roster, .roomList, .search, .peerDevices,
                 .secondDeviceFingerprint, .ownDeviceRevocation, .trustPeer, .profile,
                 .profileUpdate, .blockedSend, .timeline, .sendTimeline, .timelineRestart,
                 .groupTimelineRestart, .timelineRelaunchSeed, .dmE2EE, .dmReaction, .dmReply,
                 .dmEditRetract, .dmAttachment, .deliveryReceipt, .typing, .groupE2EE,
                 .groupAttachment, .groupMention, .groupThread, .groupLeave,
                 .groupCallLabMedia, .callEchoAssistant, .readMarkers:
                return true
            }
        }
    }

    private struct RelaunchMarker: Codable {
        let version: Int
        let roomID: String
        let beforeCount: Int
        let beforeIDs: [String]
        let seededMessageID: String?
        let seededAt: Date
        let seedPID: Int32
    }

    private struct Configuration {
        let mode: Mode
        let userID: String
        let password: String
        let peerID: String?
        let peerPassword: String?
        let thirdID: String?
        let thirdPassword: String?
        let echoID: String?
        let echoPassword: String?
        let searchTerm: String?
        let profileDisplayName: String?
        let profileBio: String?
        let profileStatusMessage: String?
        let profileWebsite: String?
        let allowSend: Bool
        let allowTrust: Bool
        let allowProfileUpdate: Bool
        let serverURL: URL
        let relaunchMarkerPath: String
        let relaunchSessionService: String
        let relaunchSessionAccount: String
        let relaunchCleanup: Bool
        let secondDeviceProfile: String
        let ownDeviceRevocationTarget: String?
        let callLabProfilePrefix: String
        let callLabHoldSeconds: TimeInterval
        let echoDelaySeconds: TimeInterval
        let usesKeychainStorage: Bool

        var omemoPersistence: TrixOMEMOPersistence {
            guard usesKeychainStorage else {
                return .memory
            }

            switch mode {
            case .login, .sessionRestore, .typing:
                return .memory
            case .roster, .roomList, .search, .peerDevices, .secondDeviceFingerprint,
                 .ownDeviceRevocation, .trustPeer, .profile, .profileUpdate, .blockedSend,
                 .timeline, .sendTimeline, .timelineRestart, .groupTimelineRestart,
                 .timelineRelaunchSeed, .timelineRelaunchVerify, .dmE2EE, .dmAttachment,
                 .dmReaction, .dmReply, .dmEditRetract, .deliveryReceipt, .groupE2EE,
                 .groupAttachment, .groupMention, .groupThread, .groupLeave,
                 .groupCallLabMedia, .callEchoAssistant, .readMarkers:
                return .keychain
            }
        }

        static var environment: Self? {
            let environment = ProcessInfo.processInfo.environment
            guard let modeValue = environment["TRIX_XMPP_LIVE_SMOKE_MODE"],
                  let mode = Mode(rawValue: modeValue) else {
                return nil
            }

            let userID: String
            let password: String
            if mode.requiresCredentials {
                guard let configuredUserID = environment["TRIX_XMPP_LIVE_SMOKE_USER_ID"],
                      let configuredPassword = environment["TRIX_XMPP_LIVE_SMOKE_PASSWORD"],
                      !configuredUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !configuredPassword.isEmpty else {
                    status("configuration missing_credentials")
                    return nil
                }
                userID = configuredUserID
                password = configuredPassword
            } else {
                userID = environment["TRIX_XMPP_LIVE_SMOKE_USER_ID"] ?? ""
                password = environment["TRIX_XMPP_LIVE_SMOKE_PASSWORD"] ?? ""
            }

            let serverURL = environment["TRIX_XMPP_LIVE_SMOKE_SERVER_URL"]
                .flatMap(URL.init(string:)) ?? XMPPClientConfiguration.connectionURL
            let relaunchMarkerPath = environment["TRIX_XMPP_LIVE_SMOKE_RELAUNCH_MARKER_PATH"] ??
                URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("trix-xmpp-timeline-relaunch-marker.json")
                .path

            return Self(
                mode: mode,
                userID: userID,
                password: password,
                peerID: environment["TRIX_XMPP_LIVE_SMOKE_PEER_ID"],
                peerPassword: environment["TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD"],
                thirdID: environment["TRIX_XMPP_LIVE_SMOKE_THIRD_ID"],
                thirdPassword: environment["TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD"],
                echoID: environment["TRIX_XMPP_LIVE_SMOKE_ECHO_ID"],
                echoPassword: environment["TRIX_XMPP_LIVE_SMOKE_ECHO_PASSWORD"],
                searchTerm: environment["TRIX_XMPP_LIVE_SMOKE_SEARCH_TERM"],
                profileDisplayName: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_DISPLAY_NAME"],
                profileBio: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_BIO"],
                profileStatusMessage: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_STATUS"],
                profileWebsite: environment["TRIX_XMPP_LIVE_SMOKE_PROFILE_WEBSITE"],
                allowSend: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND"] == "1",
                allowTrust: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST"] == "1",
                allowProfileUpdate: environment["TRIX_XMPP_LIVE_SMOKE_ALLOW_PROFILE_UPDATE"] == "1",
                serverURL: serverURL,
                relaunchMarkerPath: relaunchMarkerPath,
                relaunchSessionService: environment["TRIX_XMPP_LIVE_SMOKE_RELAUNCH_SESSION_SERVICE"] ??
                    "com.softgrid.trix.live-smoke.relaunch-session",
                relaunchSessionAccount: environment["TRIX_XMPP_LIVE_SMOKE_RELAUNCH_SESSION_ACCOUNT"] ??
                    "timeline-relaunch",
                relaunchCleanup: environment["TRIX_XMPP_LIVE_SMOKE_RELAUNCH_CLEANUP"] != "0",
                secondDeviceProfile: environment["TRIX_XMPP_LIVE_SMOKE_SECOND_DEVICE_PROFILE"] ?? "second-device",
                ownDeviceRevocationTarget: environment["TRIX_XMPP_LIVE_SMOKE_REVOKE_DEVICE_ID"],
                callLabProfilePrefix: environment["TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX"] ?? "call-lab",
                callLabHoldSeconds: Self.positiveTimeInterval(
                    environment["TRIX_XMPP_LIVE_SMOKE_CALL_LAB_HOLD_SECONDS"],
                    fallback: 10
                ),
                echoDelaySeconds: Self.positiveTimeInterval(
                    environment["TRIX_XMPP_LIVE_SMOKE_ECHO_DELAY_SECONDS"],
                    fallback: 2
                ),
                usesKeychainStorage: environment["TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN"] == "1"
            )
        }

        private static func positiveTimeInterval(_ value: String?, fallback: TimeInterval) -> TimeInterval {
            guard let value,
                  let parsed = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed > 0 else {
                return fallback
            }
            return parsed
        }
    }

    static func installIfRequested() {
        guard let configuration = Configuration.environment else {
            if isRequested {
                exit(1)
            }
            return
        }

        if configuration.mode.requiresKeychainStorage && !configuration.usesKeychainStorage {
            status("skip reason=keychain_smoke_default_disabled mode=\(configuration.mode.rawValue)")
            exit(0)
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

        do {
            if configuration.mode == .timelineRelaunchVerify {
                try await runTimelineRelaunchVerifySmoke(configuration: configuration)
                status("finish ok")
                exit(0)
            }

            let service = primarySmokeService(configuration: configuration)
            let session = try await service.login(
                userID: configuration.userID,
                password: configuration.password,
                serverURL: configuration.serverURL
            )
            status("login ok user=\(session.userID) resource=\(session.deviceID)")

            var shouldLogout = true
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

            case .secondDeviceFingerprint:
                try await Self.runSecondDeviceFingerprintSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .ownDeviceRevocation:
                try await Self.runOwnDeviceRevocationSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

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

            case .groupTimelineRestart:
                try await runGroupTimelineRestartSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .timelineRelaunchSeed:
                try await runTimelineRelaunchSeedSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )
                shouldLogout = false

            case .timelineRelaunchVerify:
                try await runTimelineRelaunchVerifySmoke(configuration: configuration)

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

            case .dmReply:
                try await runDMReplySmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .dmEditRetract:
                try await runDMEditRetractSmoke(
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

            case .groupMention:
                try await runGroupMentionSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .groupThread:
                try await runGroupThreadSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .groupLeave:
                try await runGroupLeaveSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .groupCallLabMedia:
                try await runGroupCallLabMediaSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .callEchoAssistant:
                try await runCallEchoAssistantSmoke(
                    configuration: configuration,
                    service: service,
                    session: session
                )

            case .readMarkers:
                try await runReadMarkersSmoke(
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

            if shouldLogout {
                try? await service.logout(session: session)
            }
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

    private static func runSecondDeviceFingerprintSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        let secondProfileName = smokeSecondDeviceProfileName(configuration.secondDeviceProfile)
        let secondService = smokeService(configuration: configuration, profileName: secondProfileName)
        let secondSession = try await secondService.login(
            userID: configuration.userID,
            password: configuration.password,
            serverURL: configuration.serverURL
        )
        status("second-device-fingerprint second-login ok profile=\(secondProfileName) resource=\(secondSession.deviceID)")

        do {
            let primaryStatus = try await service.deviceVerificationStatus(session: session)
            let secondStatus = try await secondService.deviceVerificationStatus(session: secondSession)
            guard primaryStatus.deviceID != secondStatus.deviceID else {
                status("second-device-fingerprint failed distinct_local_devices=false")
                throw TrixClientError.ownDeviceUnavailable
            }

            let publishedDevices = try await service.refreshPeerDeviceIdentities(userID: session.userID, session: session)
            guard let secondDevice = publishedDevices.first(where: { $0.deviceID == secondStatus.deviceID }) else {
                status("second-device-fingerprint failed second_device_missing=true")
                throw TrixClientError.ownDeviceUnavailable
            }

            let activePublishedDeviceCount = publishedDevices.filter(\.isActive).count
            let allKnownActiveDeviceIDs = Set([primaryStatus.deviceID] + publishedDevices.filter(\.isActive).map(\.deviceID))
            let localFingerprintPresent = !(primaryStatus.ed25519Fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let secondFingerprintPresent = secondDevice.hasFingerprint
            let manualTrustRequired = !secondDevice.canSendEncrypted

            guard allKnownActiveDeviceIDs.count >= 2 else {
                status("second-device-fingerprint failed active_count=\(allKnownActiveDeviceIDs.count)")
                throw TrixClientError.ownDeviceUnavailable
            }
            guard secondDevice.isActive else {
                status("second-device-fingerprint failed second_active=false")
                throw TrixClientError.ownDeviceUnavailable
            }
            guard localFingerprintPresent && secondFingerprintPresent else {
                status("second-device-fingerprint failed fingerprint_present=false local=\(localFingerprintPresent) second=\(secondFingerprintPresent)")
                throw TrixClientError.ownDeviceUnavailable
            }
            guard manualTrustRequired else {
                status("second-device-fingerprint failed manual_trust_required=false")
                throw TrixClientError.ownDeviceUnavailable
            }

            status(
                "second-device-fingerprint ok local=\(primaryStatus.deviceID) second=\(secondStatus.deviceID) active=\(activePublishedDeviceCount) fingerprint_local=\(localFingerprintPresent) fingerprint_second=\(secondFingerprintPresent) manual_trust_required=\(manualTrustRequired)"
            )
            try? await secondService.logout(session: secondSession)
        } catch {
            try? await secondService.logout(session: secondSession)
            throw error
        }
    }

    private static func runOwnDeviceRevocationSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        let secondProfileName = smokeSecondDeviceProfileName(configuration.secondDeviceProfile)
        let secondService = smokeService(configuration: configuration, profileName: secondProfileName)
        let secondSession = try await secondService.login(
            userID: configuration.userID,
            password: configuration.password,
            serverURL: configuration.serverURL
        )
        status("own-device-revocation second-login ok profile=\(secondProfileName) resource=\(secondSession.deviceID)")

        do {
            let localStatus = try await service.deviceVerificationStatus(session: session)
            let secondStatus = try await secondService.deviceVerificationStatus(session: secondSession)
            guard localStatus.deviceID != secondStatus.deviceID else {
                status("own-device-revocation failed distinct_local_devices=false")
                throw TrixClientError.ownDeviceUnavailable
            }

            let preDevices = try await service.refreshPeerDeviceIdentities(userID: session.userID, session: session)
            let explicitTarget = configuration.ownDeviceRevocationTarget?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let targetDeviceID = (explicitTarget?.isEmpty == false ? explicitTarget! : secondStatus.deviceID)
            guard preDevices.contains(where: { $0.deviceID == targetDeviceID && $0.isActive }) else {
                status("own-device-revocation failed target_active=false target=\(targetDeviceID)")
                throw TrixClientError.ownDeviceUnavailable
            }

            status("own-device-revocation pre ok active=\(preDevices.filter(\.isActive).count) target=\(targetDeviceID)")
            let postDevices = try await service.revokeOwnDevice(deviceID: targetDeviceID, session: session)
            let stillActive = postDevices.contains(where: { $0.deviceID == targetDeviceID && $0.isActive })
            guard !stillActive else {
                status("own-device-revocation failed target_still_active=true target=\(targetDeviceID)")
                throw TrixClientError.ownDeviceRevocationFailed
            }

            let removed = !postDevices.contains(where: { $0.deviceID == targetDeviceID })
            let markedInactive = postDevices.contains(where: { $0.deviceID == targetDeviceID && !$0.isActive })
            status(
                "own-device-revocation ok target=\(targetDeviceID) removed=\(removed) inactive=\(markedInactive) remaining_active=\(postDevices.filter(\.isActive).count)"
            )
            try? await secondService.logout(session: secondSession)
        } catch {
            try? await secondService.logout(session: secondSession)
            throw error
        }
    }

    private static func runGroupTimelineRestartSmoke(
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
        status("group-timeline-restart login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-timeline-restart login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Group Restart Smoke \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-timeline-restart create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-timeline-restart",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                statusPrefix: "group-timeline-restart",
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
                statusPrefix: "group-timeline-restart",
                service: service,
                session: session
            )
            status(
                "group-timeline-restart members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)"
            )
            let peerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                statusPrefix: "group-timeline-restart",
                service: peerService,
                session: peerSession
            )
            status(
                "group-timeline-restart members ok role=peer count=\(peerMembers.count) joined=\(peerMembers.filter { $0.membership == .joined }.count)"
            )
            let thirdMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                statusPrefix: "group-timeline-restart",
                service: thirdService,
                session: loggedInThirdSession
            )
            status(
                "group-timeline-restart members ok role=third count=\(thirdMembers.count) joined=\(thirdMembers.filter { $0.membership == .joined }.count)"
            )

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
                statusPrefix: "group-timeline-restart"
            )

            let messageBody = "smoke-group-restart-\(UUID().uuidString)"
            let sentItem = try await service.sendText(messageBody, roomID: room.id, session: session)
            status("group-timeline-restart send ok id=\(sentItem.id)")

            guard try await waitForGroupMessage(
                messageID: sentItem.id,
                expectedBody: messageBody,
                expectedSender: session.userID,
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-timeline-restart",
                service: peerService,
                session: peerSession
            ) else {
                status("group-timeline-restart failed receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            guard try await waitForGroupMessage(
                messageID: sentItem.id,
                expectedBody: messageBody,
                expectedSender: session.userID,
                roomID: room.id,
                role: "third",
                statusPrefix: "group-timeline-restart",
                service: thirdService,
                session: loggedInThirdSession
            ) else {
                status("group-timeline-restart failed receive=false role=third")
                throw TrixClientError.xmppConnectionFailed
            }

            let beforeItems = try await service.timeline(roomID: room.id, session: session)
            guard !beforeItems.isEmpty else {
                status("group-timeline-restart failed empty_before")
                throw TrixClientError.roomUnavailable
            }
            if let diagnostics = try await service.timelineDiagnostics(roomID: room.id, session: session) {
                status("group-timeline-restart before diagnostics \(timelineDiagnosticsSummary(diagnostics))")
            }

            try? await service.logout(session: session)
            let restoredService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
            let restoredAccount = try await restoredService.restore(session: session)
            status("group-timeline-restart restore ok user=\(restoredAccount.userID) resource=\(restoredAccount.deviceID)")

            let afterItems = try await restoredService.timeline(roomID: room.id, session: session)
            let overlapCount = Set(beforeItems.map(\.id)).intersection(Set(afterItems.map(\.id))).count
            guard overlapCount > 0 else {
                status("group-timeline-restart failed overlap=0 after=\(afterItems.count)")
                try? await restoredService.logout(session: session)
                throw TrixClientError.roomUnavailable
            }

            let localEchoCount = afterItems.filter(\.isLocalEcho).count
            let sentCount = afterItems.filter { $0.deliveryState == .sent }.count
            let deliveredCount = afterItems.filter { $0.deliveryState == .delivered }.count
            status(
                "group-timeline-restart ok before=\(beforeItems.count) after=\(afterItems.count) overlap=\(overlapCount) local=\(localEchoCount) sent=\(sentCount) delivered=\(deliveredCount)"
            )
            if let diagnostics = try await restoredService.timelineDiagnostics(roomID: room.id, session: session) {
                status("group-timeline-restart after diagnostics \(timelineDiagnosticsSummary(diagnostics))")
            }
            try? await restoredService.logout(session: session)

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
        } catch {
            if let thirdSession {
                try? await thirdService.logout(session: thirdSession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runTimelineRelaunchSeedSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
        let peerID = try requiredPeerID(configuration.peerID)
        let room = try await service.createEncryptedDirectRoom(
            inviteeUserID: peerID,
            name: "",
            session: session
        )

        var sentMessageID: String?
        if configuration.allowSend {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "timeline-relaunch-seed"
            )
            let sentItem = try await service.sendText(
                "smoke-relaunch-\(UUID().uuidString)",
                roomID: room.id,
                session: session
            )
            sentMessageID = sentItem.id
            status("timeline-relaunch-seed send ok id=\(sentItem.id)")
        }

        let beforeItems = try await service.timeline(roomID: peerID, session: session)
        guard !beforeItems.isEmpty else {
            status("timeline-relaunch-seed failed empty_before")
            throw TrixClientError.roomUnavailable
        }
        if let diagnostics = try await service.timelineDiagnostics(roomID: peerID, session: session) {
            status("timeline-relaunch-seed diagnostics \(timelineDiagnosticsSummary(diagnostics))")
        }

        let marker = RelaunchMarker(
            version: 1,
            roomID: peerID,
            beforeCount: beforeItems.count,
            beforeIDs: Array(beforeItems.map(\.id).prefix(64)),
            seededMessageID: sentMessageID,
            seededAt: Date(),
            seedPID: getpid()
        )
        try writeRelaunchMarker(marker, path: configuration.relaunchMarkerPath)

        let store = makeRelaunchSessionStore(configuration: configuration)
        try? store.clearSession()
        try store.saveSession(session)
        status("timeline-relaunch-seed marker ok before=\(beforeItems.count) ids=\(marker.beforeIDs.count)")
        status("timeline-relaunch-seed save ok path=\(configuration.relaunchMarkerPath)")
        status("timeline-relaunch-seed ready pid=\(getpid())")
    }

    private static func runTimelineRelaunchVerifySmoke(
        configuration: Configuration
    ) async throws {
        status("timeline-relaunch-verify start pid=\(getpid())")

        let marker = try readRelaunchMarker(path: configuration.relaunchMarkerPath)
        let store = makeRelaunchSessionStore(configuration: configuration)
        guard let restoredSession = try store.loadSession() else {
            status("timeline-relaunch-verify failed missing_saved_session")
            throw TrixClientError.missingSession
        }

        let restoredService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let restoredAccount = try await restoredService.restore(session: restoredSession)
        status("timeline-relaunch-verify restore ok user=\(restoredAccount.userID) resource=\(restoredAccount.deviceID)")

        let afterItems = try await restoredService.timeline(roomID: marker.roomID, session: restoredSession)
        let overlapCount = Set(marker.beforeIDs).intersection(Set(afterItems.map(\.id))).count
        guard overlapCount > 0 else {
            status("timeline-relaunch-verify failed overlap=0 before=\(marker.beforeCount) after=\(afterItems.count)")
            try? await restoredService.logout(session: restoredSession)
            throw TrixClientError.roomUnavailable
        }

        let localEchoCount = afterItems.filter(\.isLocalEcho).count
        let sentCount = afterItems.filter { $0.deliveryState == .sent }.count
        let deliveredCount = afterItems.filter { $0.deliveryState == .delivered }.count
        status(
            "timeline-relaunch-verify ok before=\(marker.beforeCount) after=\(afterItems.count) overlap=\(overlapCount) local=\(localEchoCount) sent=\(sentCount) delivered=\(deliveredCount)"
        )
        if let diagnostics = try await restoredService.timelineDiagnostics(roomID: marker.roomID, session: restoredSession) {
            status("timeline-relaunch-verify diagnostics \(timelineDiagnosticsSummary(diagnostics))")
        }

        try? await restoredService.logout(session: restoredSession)
        if configuration.relaunchCleanup {
            try? store.clearSession()
            try? FileManager.default.removeItem(atPath: configuration.relaunchMarkerPath)
            status("timeline-relaunch-verify cleanup ok marker_removed=true keychain_cleared=true")
        }
    }

    private static func runDMReplySmoke(
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
        status("dm-reply peer-login ok resource=\(peerSession.deviceID)")

        do {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "dm-reply"
            )

            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let rootBody = "smoke-reply-root-\(UUID().uuidString)"
            let rootItem = try await service.sendText(rootBody, roomID: room.id, session: session)
            status("dm-reply root-send ok id=\(rootItem.id)")

            guard try await waitForDirectMessage(
                messageID: rootItem.id,
                expectedBody: rootBody,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                statusPrefix: "dm-reply",
                service: peerService,
                session: peerSession
            ) else {
                status("dm-reply failed root_receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            let request = TrixTextMessageSendRequest(
                text: "smoke-reply-\(UUID().uuidString)",
                roomID: room.id,
                metadata: TrixTextMessageSendMetadata(
                    replyTo: TrixReplyReference(
                        targetMessageID: rootItem.id,
                        targetSenderID: session.userID,
                        targetRoomID: room.id
                    )
                )
            )
            let roomService = service as any TrixRoomService
            let replyItem: TrixTimelineItem
            do {
                replyItem = try await roomService.sendText(request, session: session)
            } catch TrixClientError.messageMetadataUnavailable {
                status("dm-reply blocked service_api=false reply_metadata=false target_id=true")
                throw TrixClientError.messageMetadataUnavailable
            }
            status("dm-reply reply-send ok id=\(replyItem.id) target=\(rootItem.id)")

            guard try await waitForDirectTimelineItem(
                messageID: replyItem.id,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                statusPrefix: "dm-reply",
                service: peerService,
                session: peerSession,
                predicate: { item in
                    item.replyTo?.targetMessageID == rootItem.id
                }
            ) else {
                status("dm-reply failed reply_metadata=false role=peer id=\(replyItem.id)")
                throw TrixClientError.xmppConnectionFailed
            }

            try? await peerService.logout(session: peerSession)
            status("dm-reply ok replies=1")
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runDMEditRetractSmoke(
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
        status("dm-edit-retract peer-login ok resource=\(peerSession.deviceID)")

        do {
            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "dm-edit-retract"
            )

            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: peerID,
                name: "",
                session: session
            )
            let rootBody = "smoke-edit-root-\(UUID().uuidString)"
            let rootItem = try await service.sendText(rootBody, roomID: room.id, session: session)
            status("dm-edit-retract root-send ok id=\(rootItem.id)")

            guard try await waitForDirectMessage(
                messageID: rootItem.id,
                expectedBody: rootBody,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                statusPrefix: "dm-edit-retract",
                service: peerService,
                session: peerSession
            ) else {
                status("dm-edit-retract failed root_receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            let roomService = service as any TrixRoomService
            let editedItem: TrixTimelineItem
            do {
                editedItem = try await roomService.editText(
                    TrixMessageEditRequest(
                        messageID: rootItem.id,
                        roomID: room.id,
                        newText: "smoke-edited-\(UUID().uuidString)"
                    ),
                    session: session
                )
            } catch TrixClientError.messageEditUnavailable {
                status("dm-edit-retract blocked service_api=false edit_api=false target_id=true")
                throw TrixClientError.messageEditUnavailable
            }
            status("dm-edit-retract edit ok id=\(editedItem.id) target=\(rootItem.id) edited=\(editedItem.isEdited)")

            guard try await waitForDirectTimelineItem(
                messageID: rootItem.id,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                statusPrefix: "dm-edit-retract",
                service: peerService,
                session: peerSession,
                predicate: { item in
                    item.isEdited
                }
            ) else {
                status("dm-edit-retract failed edit_receive=false role=peer id=\(rootItem.id)")
                throw TrixClientError.xmppConnectionFailed
            }

            let retractedItem: TrixTimelineItem
            do {
                retractedItem = try await roomService.retractMessage(
                    TrixMessageRetractionRequest(
                        messageID: rootItem.id,
                        roomID: room.id
                    ),
                    session: session
                )
            } catch TrixClientError.messageRetractionUnavailable {
                status("dm-edit-retract blocked service_api=false retract_api=false target_id=true")
                throw TrixClientError.messageRetractionUnavailable
            }
            status("dm-edit-retract retract ok id=\(retractedItem.id) target=\(rootItem.id) retracted=\(retractedItem.isRetracted)")

            guard try await waitForDirectTimelineItem(
                messageID: rootItem.id,
                expectedSender: session.userID,
                roomID: session.userID,
                role: "peer",
                statusPrefix: "dm-edit-retract",
                service: peerService,
                session: peerSession,
                predicate: { item in
                    item.isRetracted
                }
            ) else {
                status("dm-edit-retract failed retract_receive=false role=peer id=\(rootItem.id)")
                throw TrixClientError.xmppConnectionFailed
            }

            try? await peerService.logout(session: peerSession)
            status("dm-edit-retract ok edits=1 retractions=1")
        } catch {
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runReadMarkersSmoke(
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
        let secondaryService = XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("read-markers peer-login ok resource=\(peerSession.deviceID)")

        var secondarySession: TrixSession?
        do {
            let loggedInSecondarySession = try await secondaryService.login(
                userID: configuration.userID,
                password: configuration.password,
                serverURL: configuration.serverURL
            )
            secondarySession = loggedInSecondarySession
            status("read-markers secondary-login ok same_account=true resource=\(loggedInSecondarySession.deviceID)")

            try await ensureTrustedPeer(
                peerID: peerID,
                service: service,
                session: session,
                allowTrust: configuration.allowTrust,
                statusPrefix: "read-markers owner-peer"
            )
            try await ensureTrustedPeer(
                peerID: session.userID,
                service: peerService,
                session: peerSession,
                allowTrust: configuration.allowTrust,
                statusPrefix: "read-markers peer-owner"
            )

            let room = try await peerService.createEncryptedDirectRoom(
                inviteeUserID: session.userID,
                name: "",
                session: peerSession
            )
            let markerBody = "smoke-marker-\(UUID().uuidString)"
            let sentItem = try await peerService.sendText(markerBody, roomID: room.id, session: peerSession)
            status("read-markers send ok id=\(sentItem.id)")

            guard try await waitForDirectMessage(
                messageID: sentItem.id,
                expectedBody: markerBody,
                expectedSender: peerSession.userID,
                roomID: peerID,
                role: "owner",
                statusPrefix: "read-markers",
                service: service,
                session: session
            ) else {
                status("read-markers failed receive=false role=owner")
                throw TrixClientError.xmppConnectionFailed
            }

            let roomService = service as any TrixRoomService
            let markerState: TrixRoomReadMarkerState
            do {
                markerState = try await roomService.markRoomDisplayed(
                    TrixRoomDisplayedMarkerRequest(
                        roomID: peerID,
                        messageID: sentItem.id
                    ),
                    session: session
                )
            } catch TrixClientError.readMarkerUnavailable {
                status("read-markers blocked service_api=false marker_api=false target_id=true")
                throw TrixClientError.readMarkerUnavailable
            }
            status("read-markers mark ok id=\(markerState.displayedMessageID) same_account=false")

            let secondaryRoomService = secondaryService as any TrixRoomService
            let secondaryState = try await secondaryRoomService.readMarkerState(roomID: peerID, session: loggedInSecondarySession)
            let secondaryConverged = secondaryState?.displayedMessageID == sentItem.id
            status("read-markers secondary-state ok converged=\(secondaryConverged)")

            let peerRoomService = peerService as any TrixRoomService
            let peerState = try await peerRoomService.readMarkerState(roomID: session.userID, session: peerSession)
            let peerObserved = peerState?.displayedMessageID == sentItem.id
            status("read-markers peer-state ok observed=\(peerObserved)")

            guard secondaryConverged else {
                status("read-markers failed same_account_convergence=false id=\(sentItem.id)")
                throw TrixClientError.readMarkerUnavailable
            }

            try? await secondaryService.logout(session: loggedInSecondarySession)
            try? await peerService.logout(session: peerSession)
            status("read-markers ok same_account_convergence=true peer_observed=\(peerObserved)")
        } catch {
            if let secondarySession {
                try? await secondaryService.logout(session: secondarySession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
        }
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

    private static func runGroupMentionSmoke(
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
        status("group-mention login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-mention login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Mention Smoke \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-mention create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-mention",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                statusPrefix: "group-mention",
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
                statusPrefix: "group-mention",
                service: service,
                session: session
            )
            status("group-mention members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)")

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
                statusPrefix: "group-mention"
            )

            let mentionToken = "@peer"
            let mentionText = "\(mentionToken) \(UUID().uuidString)"
            let request = TrixTextMessageSendRequest(
                text: mentionText,
                roomID: room.id,
                metadata: TrixTextMessageSendMetadata(
                    mentions: [
                        TrixMentionReference(
                            targetUserID: peerID,
                            range: TrixTextReferenceRange(begin: 0, end: mentionToken.count)
                        )
                    ]
                )
            )
            let roomService = service as any TrixRoomService
            let sentItem: TrixTimelineItem
            do {
                sentItem = try await roomService.sendText(request, session: session)
            } catch TrixClientError.messageMetadataUnavailable {
                status("group-mention blocked service_api=false mention_metadata=false target_jids=1")
                throw TrixClientError.messageMetadataUnavailable
            }
            status("group-mention send ok id=\(sentItem.id) mentions=\(sentItem.mentions.count)")

            guard try await waitForGroupTimelineItem(
                messageID: sentItem.id,
                expectedSender: session.userID,
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-mention",
                service: peerService,
                session: peerSession,
                predicate: { item in
                    item.mentions.contains { mention in
                        mention.targetUserID.caseInsensitiveCompare(peerID) == .orderedSame
                    }
                }
            ) else {
                status("group-mention failed mention_receive=false role=peer id=\(sentItem.id)")
                throw TrixClientError.xmppConnectionFailed
            }

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
            status("group-mention ok mentioned_peers=1")
        } catch {
            if let thirdSession {
                try? await thirdService.logout(session: thirdSession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runGroupThreadSmoke(
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
        status("group-thread login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-thread login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Thread Smoke \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-thread create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-thread",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                statusPrefix: "group-thread",
                service: thirdService,
                session: loggedInThirdSession
            )
            guard peerRoom.id.lowercased() == room.id.lowercased(),
                  thirdRoom.id.lowercased() == room.id.lowercased() else {
                throw TrixClientError.roomUnavailable
            }

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
                statusPrefix: "group-thread"
            )

            let rootBody = "smoke-thread-root-\(UUID().uuidString)"
            let rootItem = try await service.sendText(rootBody, roomID: room.id, session: session)
            status("group-thread root-send ok id=\(rootItem.id)")

            guard try await waitForGroupMessage(
                messageID: rootItem.id,
                expectedBody: rootBody,
                expectedSender: session.userID,
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-thread",
                service: peerService,
                session: peerSession
            ) else {
                status("group-thread failed root_receive=false role=peer")
                throw TrixClientError.xmppConnectionFailed
            }

            let threadID = "trix-thread-\(UUID().uuidString)"
            let request = TrixTextMessageSendRequest(
                text: "smoke-thread-\(UUID().uuidString)",
                roomID: room.id,
                metadata: TrixTextMessageSendMetadata(
                    thread: TrixThreadReference(
                        threadID: threadID,
                        rootMessageID: rootItem.id,
                        parentMessageID: rootItem.id
                    )
                )
            )
            let roomService = service as any TrixRoomService
            let threadedItem: TrixTimelineItem
            do {
                threadedItem = try await roomService.sendText(request, session: session)
            } catch TrixClientError.messageMetadataUnavailable {
                status("group-thread blocked service_api=false thread_metadata=false root_id=true")
                throw TrixClientError.messageMetadataUnavailable
            }
            status("group-thread send ok id=\(threadedItem.id) root=\(rootItem.id) thread_id=true")

            for (role, roleService, roleSession) in [
                ("peer", peerService, peerSession),
                ("third", thirdService, loggedInThirdSession),
            ] {
                guard try await waitForGroupTimelineItem(
                    messageID: threadedItem.id,
                    expectedSender: session.userID,
                    roomID: room.id,
                    role: role,
                    statusPrefix: "group-thread",
                    service: roleService,
                    session: roleSession,
                    predicate: { item in
                        item.thread?.threadID == threadID
                    }
                ) else {
                    status("group-thread failed thread_receive=false role=\(role) id=\(threadedItem.id)")
                    throw TrixClientError.xmppConnectionFailed
                }
            }

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
            status("group-thread ok threaded_peers=2")
        } catch {
            if let thirdSession {
                try? await thirdService.logout(session: thirdSession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    private static func runGroupLeaveSmoke(
        configuration: Configuration,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws {
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
        status("group-leave login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-leave login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Leave Smoke \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-leave create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-leave",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                statusPrefix: "group-leave",
                service: thirdService,
                session: loggedInThirdSession
            )
            guard peerRoom.id.lowercased() == room.id.lowercased(),
                  thirdRoom.id.lowercased() == room.id.lowercased() else {
                throw TrixClientError.roomUnavailable
            }

            let expectedBeforeLeave = [session.userID, peerID, thirdID]
            let ownerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedBeforeLeave,
                statusPrefix: "group-leave",
                service: service,
                session: session
            )
            status("group-leave members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)")
            let peerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedBeforeLeave,
                statusPrefix: "group-leave",
                service: peerService,
                session: peerSession
            )
            status("group-leave members ok role=peer count=\(peerMembers.count) joined=\(peerMembers.filter { $0.membership == .joined }.count)")
            let thirdMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedBeforeLeave,
                statusPrefix: "group-leave",
                service: thirdService,
                session: loggedInThirdSession
            )
            status("group-leave members ok role=third count=\(thirdMembers.count) joined=\(thirdMembers.filter { $0.membership == .joined }.count)")

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
                statusPrefix: "group-leave"
            )

            try await peerService.leaveGroup(roomID: room.id, session: peerSession)
            status("group-leave leave ok role=peer room=\(room.id)")

            guard try await Self.waitForGroupRoomVisibility(
                roomID: room.id,
                expectedVisible: false,
                role: "peer",
                statusPrefix: "group-leave",
                service: peerService,
                session: peerSession
            ) else {
                status("group-leave failed room_visible=true role=peer")
                throw TrixClientError.roomUnavailable
            }
            status("group-leave rooms ok role=peer visible=false")

            guard try await Self.waitForGroupRoomVisibility(
                roomID: room.id,
                expectedVisible: true,
                role: "owner",
                statusPrefix: "group-leave",
                service: service,
                session: session
            ) else {
                status("group-leave failed room_missing=true role=owner")
                throw TrixClientError.roomUnavailable
            }
            guard try await Self.waitForGroupRoomVisibility(
                roomID: room.id,
                expectedVisible: true,
                role: "third",
                statusPrefix: "group-leave",
                service: thirdService,
                session: loggedInThirdSession
            ) else {
                status("group-leave failed room_missing=true role=third")
                throw TrixClientError.roomUnavailable
            }
            status("group-leave rooms ok role=owner visible=true")
            status("group-leave rooms ok role=third visible=true")

            let expectedAfterLeave = [session.userID, thirdID]
            let ownerMembersAfterLeave = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedAfterLeave,
                statusPrefix: "group-leave",
                service: service,
                session: session
            )
            if ownerMembersAfterLeave.contains(where: { $0.userID.lowercased() == peerID.lowercased() }) {
                status("group-leave failed leaver_still_member=true role=owner")
                throw TrixClientError.roomUnavailable
            }

            let thirdMembersAfterLeave = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedAfterLeave,
                statusPrefix: "group-leave",
                service: thirdService,
                session: loggedInThirdSession
            )
            if thirdMembersAfterLeave.contains(where: { $0.userID.lowercased() == peerID.lowercased() }) {
                status("group-leave failed leaver_still_member=true role=third")
                throw TrixClientError.roomUnavailable
            }
            status("group-leave members ok role=owner retained=2")
            status("group-leave members ok role=third retained=2")

            do {
                _ = try await peerService.sendText("smoke-after-leave-\(UUID().uuidString)", roomID: room.id, session: peerSession)
                status("group-leave failed send_after_leave=true")
                throw TrixClientError.roomUnavailable
            } catch {
                status("group-leave send ok blocked=true")
            }

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
            status("group-leave ok leaver_removed=true remaining_members=2")
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

    @MainActor
    private static func runGroupCallLabMediaSmoke(
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

        let peerService = smokeService(
            configuration: configuration,
            profileName: callLabProfileName(prefix: configuration.callLabProfilePrefix, role: "peer")
        )
        let thirdService = smokeService(
            configuration: configuration,
            profileName: callLabProfileName(prefix: configuration.callLabProfilePrefix, role: "third")
        )
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("group-call-lab-media login ok role=peer resource=\(peerSession.deviceID)")

        var thirdSession: TrixSession?
        var ownerViewModel: TrixCallViewModel?
        var peerViewModel: TrixCallViewModel?
        var roomID: String?
        do {
            let loggedInThirdSession = try await thirdService.login(
                userID: thirdID,
                password: thirdPassword,
                serverURL: configuration.serverURL
            )
            thirdSession = loggedInThirdSession
            status("group-call-lab-media login ok role=third resource=\(loggedInThirdSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Call Lab \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, thirdID],
                session: session
            )
            roomID = room.id
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("group-call-lab-media create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: "group-call-lab-media",
                service: peerService,
                session: peerSession
            )
            let thirdRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "third",
                statusPrefix: "group-call-lab-media",
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
                statusPrefix: "group-call-lab-media",
                service: service,
                session: session
            )
            status("group-call-lab-media members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)")
            let peerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                statusPrefix: "group-call-lab-media",
                service: peerService,
                session: peerSession
            )
            status("group-call-lab-media members ok role=peer count=\(peerMembers.count) joined=\(peerMembers.filter { $0.membership == .joined }.count)")
            let thirdMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: [session.userID, peerID, thirdID],
                statusPrefix: "group-call-lab-media",
                service: thirdService,
                session: loggedInThirdSession
            )
            status("group-call-lab-media members ok role=third count=\(thirdMembers.count) joined=\(thirdMembers.filter { $0.membership == .joined }.count)")

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
                statusPrefix: "group-call-lab-media"
            )

            let ownerCalls = TrixCallViewModel(
                callControlService: HTTPCallControlService(),
                callDescriptorService: service,
                mediaCallService: TrixLiveKitMediaCallService(forceRelayOnly: true, audioProbeEnabled: true)
            )
            let peerCalls = TrixCallViewModel(
                callControlService: HTTPCallControlService(),
                callDescriptorService: peerService,
                mediaCallService: TrixLiveKitMediaCallService(forceRelayOnly: true, audioProbeEnabled: true)
            )
            ownerViewModel = ownerCalls
            peerViewModel = peerCalls

            let holdSeconds = min(max(configuration.callLabHoldSeconds, 1), 60)
            status("group-call-lab-media media config relay_only=true audio_probe=true hold_seconds=\(Int(holdSeconds))")

            await ownerCalls.joinGroupVoiceRoom(roomID: room.id, session: session)
            try requireActiveGroupCall(ownerCalls, roomID: room.id, role: "owner")
            status("group-call-lab-media media join ok role=owner active_call=true")

            _ = try await waitForGroupVoiceState(
                roomID: room.id,
                expectedParticipantID: session.userID,
                service: peerService,
                session: peerSession
            )

            await peerCalls.joinGroupVoiceRoom(roomID: room.id, session: peerSession)
            try requireActiveGroupCall(peerCalls, roomID: room.id, role: "peer")
            status("group-call-lab-media media join ok role=peer active_call=true")

            try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            status("group-call-lab-media media hold ok participants=2 relay_only=true")

            _ = await peerCalls.endCall(roomID: room.id, session: peerSession)
            _ = await ownerCalls.endCall(roomID: room.id, session: session)
            status("group-call-lab-media ok media_evidence_window=true relay_only=true")

            try? await thirdService.logout(session: loggedInThirdSession)
            try? await peerService.logout(session: peerSession)
        } catch {
            if let roomID {
                if let peerViewModel {
                    _ = await peerViewModel.endCall(roomID: roomID, session: peerSession)
                }
                if let ownerViewModel {
                    _ = await ownerViewModel.endCall(roomID: roomID, session: session)
                }
            }
            if let thirdSession {
                try? await thirdService.logout(session: thirdSession)
            }
            try? await peerService.logout(session: peerSession)
            throw error
        }
    }

    @MainActor
    private static func runCallEchoAssistantSmoke(
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

        let statusPrefix = "call-echo-assistant"
        let peerID = try requiredPeerID(configuration.peerID)
        let peerPassword = try requiredPassword(configuration.peerPassword)
        let echoID = try requiredPeerID(configuration.echoID)
        let echoPassword = try requiredPassword(configuration.echoPassword)
        guard Set([session.userID, peerID, echoID].map { $0.lowercased() }).count == 3 else {
            throw TrixClientError.invalidTrixUserID
        }

        let peerService = smokeService(
            configuration: configuration,
            profileName: callLabProfileName(prefix: configuration.callLabProfilePrefix, role: "peer")
        )
        let echoService = smokeService(
            configuration: configuration,
            profileName: callLabProfileName(prefix: configuration.callLabProfilePrefix, role: "echo")
        )
        let peerSession = try await peerService.login(
            userID: peerID,
            password: peerPassword,
            serverURL: configuration.serverURL
        )
        status("\(statusPrefix) login ok role=peer resource=\(peerSession.deviceID)")

        var echoSession: TrixSession?
        var ownerViewModel: TrixCallViewModel?
        var echoViewModel: TrixCallViewModel?
        var roomID: String?
        do {
            let loggedInEchoSession = try await echoService.login(
                userID: echoID,
                password: echoPassword,
                serverURL: configuration.serverURL
            )
            echoSession = loggedInEchoSession
            status("\(statusPrefix) login ok role=echo resource=\(loggedInEchoSession.deviceID)")

            let room = try await service.createEncryptedGroupRoom(
                name: "Trix Call Echo \(UUID().uuidString.prefix(8))",
                inviteeUserIDs: [peerID, echoID],
                session: session
            )
            roomID = room.id
            guard room.kind == .group, room.isEncrypted else {
                throw TrixClientError.e2eeUnavailable
            }
            status("\(statusPrefix) create ok room=\(room.id) invitees=2 encrypted=true")

            let peerRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "peer",
                statusPrefix: statusPrefix,
                service: peerService,
                session: peerSession
            )
            let echoRoom = try await acceptGroupInvitation(
                roomID: room.id,
                role: "echo",
                statusPrefix: statusPrefix,
                service: echoService,
                session: loggedInEchoSession
            )
            guard peerRoom.id.lowercased() == room.id.lowercased(),
                  echoRoom.id.lowercased() == room.id.lowercased() else {
                throw TrixClientError.roomUnavailable
            }

            let expectedUserIDs = [session.userID, peerID, echoID]
            let ownerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedUserIDs,
                statusPrefix: statusPrefix,
                service: service,
                session: session
            )
            status("\(statusPrefix) members ok role=owner count=\(ownerMembers.count) joined=\(ownerMembers.filter { $0.membership == .joined }.count)")
            let peerMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedUserIDs,
                statusPrefix: statusPrefix,
                service: peerService,
                session: peerSession
            )
            status("\(statusPrefix) members ok role=peer count=\(peerMembers.count) joined=\(peerMembers.filter { $0.membership == .joined }.count)")
            let echoMembers = try await waitForGroupMembers(
                roomID: room.id,
                expectedUserIDs: expectedUserIDs,
                statusPrefix: statusPrefix,
                service: echoService,
                session: loggedInEchoSession
            )
            status("\(statusPrefix) members ok role=echo count=\(echoMembers.count) joined=\(echoMembers.filter { $0.membership == .joined }.count)")

            try await ensureGroupTrustGraph(
                ownerID: session.userID,
                ownerService: service,
                ownerSession: session,
                peerID: peerID,
                peerService: peerService,
                peerSession: peerSession,
                thirdID: echoID,
                thirdService: echoService,
                thirdSession: loggedInEchoSession,
                allowTrust: configuration.allowTrust,
                statusPrefix: statusPrefix
            )

            let ownerCalls = TrixCallViewModel(
                callControlService: HTTPCallControlService(),
                callDescriptorService: service,
                mediaCallService: TrixLiveKitMediaCallService(forceRelayOnly: true, audioProbeEnabled: false)
            )
            let echoCalls = TrixCallViewModel(
                callControlService: HTTPCallControlService(),
                callDescriptorService: echoService,
                mediaCallService: TrixLiveKitMediaCallService(forceRelayOnly: true, audioProbeEnabled: true)
            )
            ownerViewModel = ownerCalls
            echoViewModel = echoCalls

            let holdSeconds = min(max(configuration.callLabHoldSeconds, 1), 60)
            let echoDelaySeconds = min(max(configuration.echoDelaySeconds, 1), 30)
            status("\(statusPrefix) media config relay_only=true owner_audio_probe=false echo_audio_probe=true hold_seconds=\(Int(holdSeconds)) configured_delay_seconds=\(Int(echoDelaySeconds))")

            await ownerCalls.joinGroupVoiceRoom(roomID: room.id, session: session)
            try requireActiveGroupCall(ownerCalls, roomID: room.id, role: "owner", statusPrefix: statusPrefix)
            status("\(statusPrefix) media join ok role=owner active_call=true publish_local_audio=true")

            _ = try await waitForGroupVoiceState(
                roomID: room.id,
                expectedParticipantID: session.userID,
                statusPrefix: statusPrefix,
                service: echoService,
                session: loggedInEchoSession
            )

            await echoCalls.joinGroupVoiceRoom(roomID: room.id, session: loggedInEchoSession)
            try requireActiveGroupCall(echoCalls, roomID: room.id, role: "echo", statusPrefix: statusPrefix)
            status("\(statusPrefix) media join ok role=echo active_call=true normal_participant=true")

            _ = try await waitForGroupVoiceState(
                roomID: room.id,
                expectedParticipantID: echoID,
                statusPrefix: statusPrefix,
                service: service,
                session: session
            )

            try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            status("\(statusPrefix) media hold ok participants=2 relay_only=true delayed_audio_echo=false delayed_video_echo=false sdk_blocker=custom_audio_publish_unvalidated")

            _ = await echoCalls.endCall(roomID: room.id, session: loggedInEchoSession)
            _ = await ownerCalls.endCall(roomID: room.id, session: session)
            status("\(statusPrefix) ok e2ee_participant=true diagnostic_only=true")

            try? await echoService.logout(session: loggedInEchoSession)
            try? await peerService.logout(session: peerSession)
        } catch {
            if let roomID {
                if let echoViewModel,
                   let echoSession {
                    _ = await echoViewModel.endCall(roomID: roomID, session: echoSession)
                }
                if let ownerViewModel {
                    _ = await ownerViewModel.endCall(roomID: roomID, session: session)
                }
            }
            if let echoSession {
                try? await echoService.logout(session: echoSession)
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

    private static func waitForGroupRoomVisibility(
        roomID: String,
        expectedVisible: Bool,
        role: String,
        statusPrefix: String,
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> Bool {
        let roomKey = roomID.lowercased()
        for _ in 0..<20 {
            let rooms = try await service.rooms(session: session)
            let isVisible = rooms.contains { $0.id.lowercased() == roomKey }
            if isVisible == expectedVisible {
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        status("\(statusPrefix) failed room_visibility role=\(role) expected_visible=\(expectedVisible)")
        return false
    }

    private static func waitForDirectMessage(
        messageID: String,
        expectedBody: String,
        expectedSender: String,
        roomID: String,
        role: String,
        statusPrefix: String = "dm-e2ee",
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
                status("\(statusPrefix) receive ok role=\(role) id=\(messageID) decrypted=true")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("\(statusPrefix) failed receive_mismatch role=\(role) id=\(messageID)")
        }
        return false
    }

    private static func waitForDirectTimelineItem(
        messageID: String,
        expectedSender: String,
        roomID: String,
        role: String,
        statusPrefix: String,
        service: XMPPMartinService,
        session: TrixSession,
        predicate: (TrixTimelineItem) -> Bool
    ) async throws -> Bool {
        let expectedSenderKey = expectedSender.lowercased()
        var sawID = false
        for _ in 0..<40 {
            let items = try await service.timeline(roomID: roomID, session: session)
            if items.contains(where: { item in
                let senderMatches = item.sender.lowercased() == expectedSenderKey
                let idMatches = item.id == messageID
                sawID = sawID || idMatches
                return !item.isLocalEcho && senderMatches && idMatches && predicate(item)
            }) {
                status("\(statusPrefix) receive ok role=\(role) id=\(messageID) metadata=true")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("\(statusPrefix) failed metadata_mismatch role=\(role) id=\(messageID)")
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
        statusPrefix: String = "group-e2ee",
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
                status("\(statusPrefix) receive ok role=\(role) id=\(messageID) decrypted=true")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("\(statusPrefix) failed receive_mismatch role=\(role) id=\(messageID)")
        }
        return false
    }

    private static func waitForGroupTimelineItem(
        messageID: String,
        expectedSender: String,
        roomID: String,
        role: String,
        statusPrefix: String,
        service: XMPPMartinService,
        session: TrixSession,
        predicate: (TrixTimelineItem) -> Bool
    ) async throws -> Bool {
        let expectedSenderKey = expectedSender.lowercased()
        var sawID = false
        for _ in 0..<40 {
            let items = try await service.timeline(roomID: roomID, session: session)
            if items.contains(where: { item in
                let senderMatches = item.sender.lowercased() == expectedSenderKey
                let idMatches = item.id == messageID
                sawID = sawID || idMatches
                return !item.isLocalEcho && senderMatches && idMatches && predicate(item)
            }) {
                status("\(statusPrefix) receive ok role=\(role) id=\(messageID) metadata=true")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if sawID {
            status("\(statusPrefix) failed metadata_mismatch role=\(role) id=\(messageID)")
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

    private static func makeRelaunchSessionStore(configuration: Configuration) -> KeychainTrixSessionStore {
        KeychainTrixSessionStore(
            service: configuration.relaunchSessionService,
            account: configuration.relaunchSessionAccount,
            legacyService: nil,
            legacyAccount: nil
        )
    }

    private static func writeRelaunchMarker(_ marker: RelaunchMarker, path: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(marker)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func readRelaunchMarker(path: String) throws -> RelaunchMarker {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RelaunchMarker.self, from: data)
    }

    private static func primarySmokeService(configuration: Configuration) -> XMPPMartinService {
        if configuration.mode == .groupCallLabMedia || configuration.mode == .callEchoAssistant {
            return smokeService(
                configuration: configuration,
                profileName: callLabProfileName(prefix: configuration.callLabProfilePrefix, role: "owner")
            )
        }

        return XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
    }

    private static func smokeService(configuration: Configuration, profileName: String?) -> XMPPMartinService {
        #if DEBUG
        if let profileName,
           let profile = TrixLocalProfileConfiguration(rawName: profileName) {
            return XMPPMartinService(localProfile: profile)
        }
        #endif
        return XMPPMartinService(omemoPersistence: configuration.omemoPersistence)
    }

    private static func callLabProfileName(prefix: String, role: String) -> String {
        let normalizedPrefix = TrixLocalProfileConfiguration(rawName: prefix)?.name ?? "call-lab"
        return "\(normalizedPrefix)-\(role)"
    }

    @MainActor
    private static func requireActiveGroupCall(
        _ viewModel: TrixCallViewModel,
        roomID: String,
        role: String,
        statusPrefix: String = "group-call-lab-media"
    ) throws {
        guard viewModel.currentCall(roomID: roomID, kind: .groupVoice) != nil else {
            status("\(statusPrefix) failed active_call=false role=\(role)")
            throw TrixClientError.callMediaUnavailable
        }
    }

    private static func waitForGroupVoiceState(
        roomID: String,
        expectedParticipantID: String,
        statusPrefix: String = "group-call-lab-media",
        service: XMPPMartinService,
        session: TrixSession
    ) async throws -> TrixVoiceRoomState {
        let participantKey = expectedParticipantID.lowercased()
        for attempt in 0..<30 {
            let descriptors = try await service.callDescriptors(roomID: roomID, session: session)
            let state = descriptors
                .compactMap { descriptor -> TrixVoiceRoomState? in
                    guard case .voiceRoomState(let state) = descriptor.descriptor,
                          state.roomID.lowercased() == roomID.lowercased(),
                          state.mediaKey != nil,
                          state.activeParticipantIDs.contains(where: { $0.lowercased() == participantKey }) else {
                        return nil
                    }
                    return state
                }
                .max { lhs, rhs in
                    lhs.updatedAtUnix < rhs.updatedAtUnix
                }
            if let state {
                status("\(statusPrefix) descriptor ok voice_state=true")
                return state
            }

            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        status("\(statusPrefix) failed voice_state=false")
        throw TrixClientError.callDescriptorUnavailable
    }

    private static func smokeSecondDeviceProfileName(_ configuredProfile: String) -> String {
        let base = configuredProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        if base.isEmpty {
            return "second-device-\(suffix)"
        }

        return "\(base)-\(suffix)"
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
        case TrixClientError.messageMetadataUnavailable:
            return "message_metadata_unavailable"
        case TrixClientError.messageEditUnavailable:
            return "message_edit_unavailable"
        case TrixClientError.messageRetractionUnavailable:
            return "message_retraction_unavailable"
        case TrixClientError.readMarkerUnavailable:
            return "read_marker_unavailable"
        case TrixClientError.invalidMessageReference:
            return "invalid_message_reference"
        case TrixClientError.invalidMentionTarget:
            return "invalid_mention_target"
        case TrixClientError.ownDeviceUnavailable:
            return "own_device_unavailable"
        case TrixClientError.currentDeviceRevocationUnavailable:
            return "current_device_revocation_unavailable"
        case TrixClientError.ownDeviceRevocationFailed:
            return "own_device_revocation_failed"
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
            "pages=\(diagnostics.mamPagesScanned)",
            "page_size=\(diagnostics.mamPageSize)",
            "archive_start=\(diagnostics.mamReachedArchiveStart)",
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
