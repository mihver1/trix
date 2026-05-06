import Foundation
import MatrixRustSDK
#if os(iOS)
import UIKit
#endif

actor MatrixRustSDKAdapter: MatrixService {
    private var client: Client?
    private var syncService: SyncService?
    private var syncTask: Task<Void, Never>?
    private var roomListService: RoomListService?
    private var roomListListeners: [SDKRoomListListener] = []
    private var roomListHandles: [RoomListEntriesWithDynamicAdaptersResult] = []
    private var roomsByID: [String: Room] = [:]
    private var timelineStateByRoomID: [String: SDKTimelineState] = [:]
    private var verificationController: SessionVerificationController?
    private var verificationDelegate: SDKSessionVerificationDelegate?
    private var verificationFlow: MatrixDeviceVerificationFlow = .idle

    func login(userID: String, password: String, serverURL: URL) async throws -> MatrixSession {
        let localpart = try Self.localpart(from: userID)
        let storeID = UUID().uuidString
        let paths = try Self.paths(for: storeID)
        let client = try await makeClient(serverURL: serverURL, paths: paths)

        try await client.login(
            username: localpart,
            password: password,
            initialDeviceName: Self.defaultDeviceName,
            deviceId: nil
        )

        self.client = client
        resetVerificationFlow()
        let sdkSession = try client.session()
        return MatrixSession(sdkSession: sdkSession, sdkStoreID: storeID)
    }

    func restore(session: MatrixSession) async throws -> MatrixAccount {
        let paths = try Self.paths(for: session.sdkStoreID)
        let client = try await Self.clientBuilder(paths: paths)
            .homeserverUrl(url: session.homeserverURL.absoluteString)
            .build()

        try await client.restoreSession(session: session.sdkSession)
        self.client = client
        resetVerificationFlow()

        return MatrixAccount(
            userID: session.userID,
            displayName: Self.displayName(from: session.userID),
            deviceID: session.deviceID
        )
    }

    func logout(session: MatrixSession) async throws {
        var sdkLogoutError: Error?
        do {
            let activeClient = try await resolvedClient(session: session)
            try await activeClient.logout()
        } catch {
            sdkLogoutError = error
        }

        await syncService?.stop()
        syncTask?.cancel()
        syncTask = nil
        syncService = nil
        roomListService = nil
        roomListHandles = []
        roomListListeners = []
        roomsByID = [:]
        timelineStateByRoomID = [:]
        verificationController = nil
        verificationDelegate = nil
        verificationFlow = .idle
        client = nil

        try? FileManager.default.removeItem(at: Self.dataRoot(for: session.sdkStoreID))
        try? FileManager.default.removeItem(at: Self.cacheRoot(for: session.sdkStoreID))

        if let sdkLogoutError {
            throw sdkLogoutError
        }
    }

    func rooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        let sdkRooms = await cachedRooms(client: client)
        roomsByID = Dictionary(uniqueKeysWithValues: sdkRooms.map { ($0.id(), $0) })

        let joinedRooms = await Self.joinedRooms(from: sdkRooms)
        var summaries: [MatrixRoomSummary] = []
        for room in joinedRooms {
            summaries.append(await Self.summary(from: room))
        }

        return summaries.sorted { lhs, rhs in
            lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    func timeline(roomID: String, session: MatrixSession) async throws -> [MatrixTimelineItem] {
        let room = try await room(for: roomID, session: session)

        if timelineStateByRoomID[roomID] == nil {
            let timeline = try await room.timeline()
            let listener = SDKTimelineListener()
            let handle = await timeline.addListener(listener: listener)
            timelineStateByRoomID[roomID] = SDKTimelineState(
                timeline: timeline,
                listener: listener,
                handle: handle
            )
            for _ in 0..<6 {
                if !listener.snapshot().isEmpty {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if listener.snapshot().isEmpty {
                _ = try? await timeline.paginateBackwards(numEvents: 30)
            }
        }

        guard let state = timelineStateByRoomID[roomID] else {
            return []
        }

        return state.listener.snapshot().compactMap { item in
            Self.timelineItem(from: item, roomID: roomID)
        }
    }

    func sendText(_ text: String, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw MatrixClientError.emptyMessage
        }

        _ = try await timeline(roomID: roomID, session: session)
        guard let state = timelineStateByRoomID[roomID] else {
            throw MatrixClientError.missingSession
        }

        let message = messageEventContentFromMarkdown(md: body)
        _ = try await state.timeline.send(msg: message)

        return MatrixTimelineItem(
            id: "$local-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true,
            attachment: nil
        )
    }

    func sendAttachment(_ attachment: MatrixAttachmentUpload, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        guard !attachment.data.isEmpty else {
            throw MatrixClientError.emptyAttachment
        }

        _ = try await timeline(roomID: roomID, session: session)
        guard let state = timelineStateByRoomID[roomID] else {
            throw MatrixClientError.missingSession
        }

        let parameters = UploadParameters(
            source: .data(bytes: attachment.data, filename: attachment.filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )
        let size = UInt64(attachment.data.count)

        do {
            let handle: SendAttachmentJoinHandle
            if attachment.isImage {
                handle = try state.timeline.sendImage(
                    params: parameters,
                    thumbnailSource: nil,
                    imageInfo: ImageInfo(
                        height: nil,
                        width: nil,
                        mimetype: attachment.mimeType,
                        size: size,
                        thumbnailInfo: nil,
                        thumbnailSource: nil,
                        blurhash: nil,
                        isAnimated: nil
                    )
                )
            } else {
                handle = try state.timeline.sendFile(
                    params: parameters,
                    fileInfo: FileInfo(
                        mimetype: attachment.mimeType,
                        size: size,
                        thumbnailInfo: nil,
                        thumbnailSource: nil
                    )
                )
            }
            try await handle.join()
        } catch {
            throw MatrixClientError.attachmentTransferFailed
        }

        return MatrixTimelineItem(
            id: "$local-attachment-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: attachment.filename,
            isLocalEcho: true,
            attachment: MatrixTimelineAttachment(
                kind: attachment.isImage ? .image : .file,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.data.count,
                sourceJSON: nil
            )
        )
    }

    func downloadAttachment(_ attachment: MatrixTimelineAttachment, session: MatrixSession) async throws -> MatrixAttachmentDownload {
        guard let sourceJSON = attachment.sourceJSON else {
            throw MatrixClientError.attachmentDownloadUnavailable
        }

        let client = try await resolvedClient(session: session)
        do {
            let mediaSource = try MediaSource.fromJson(json: sourceJSON)
            let data = try await client.getMediaContent(mediaSource: mediaSource)
            return MatrixAttachmentDownload(
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: data
            )
        } catch {
            throw MatrixClientError.attachmentTransferFailed
        }
    }

    func members(roomID: String, session: MatrixSession) async throws -> [MatrixRoomMember] {
        let room = try await room(for: roomID, session: session)
        let iterator = try await room.members()
        var members: [MatrixRoomMember] = []

        while let chunk = iterator.nextChunk(chunkSize: 64), !chunk.isEmpty {
            members.append(contentsOf: chunk.map { MatrixRustSDKAdapter.roomMember(from: $0) })
        }

        return members.sorted { lhs, rhs in
            if lhs.membership != rhs.membership {
                return lhs.membership.sortOrder < rhs.membership.sortOrder
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func inviteUser(_ userID: String, roomID: String, session: MatrixSession) async throws {
        let normalizedUserID = try MatrixRustSDKAdapter.normalizedMatrixUserID(userID)
        let room = try await room(for: roomID, session: session)
        try await room.inviteUserById(userId: normalizedUserID)
    }

    func removeUser(_ userID: String, roomID: String, session: MatrixSession) async throws {
        let normalizedUserID = try MatrixRustSDKAdapter.normalizedMatrixUserID(userID)
        let room = try await room(for: roomID, session: session)
        try await room.kickUser(userId: normalizedUserID, reason: nil)
    }

    func deviceVerificationStatus(session: MatrixSession) async throws -> MatrixDeviceVerificationStatus {
        let client = try await resolvedClient(session: session)
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()

        let verificationState = Self.deviceVerificationState(from: encryption.verificationState())
        let hasDevicesToVerifyAgainst = try await encryption.hasDevicesToVerifyAgainst()
        let isLastDevice = try await encryption.isLastDevice()
        let recoveryState = Self.recoveryState(from: encryption.recoveryState())
        let backupState = Self.backupState(from: encryption.backupState())
        let backupExistsOnServer = try? await encryption.backupExistsOnServer()
        let ed25519Fingerprint = await encryption.ed25519Key()
        let curve25519IdentityKey = await encryption.curve25519Key()

        return MatrixDeviceVerificationStatus(
            userID: session.userID,
            deviceID: session.deviceID,
            state: verificationState,
            hasDevicesToVerifyAgainst: hasDevicesToVerifyAgainst,
            isLastDevice: isLastDevice,
            recoveryState: recoveryState,
            backupState: backupState,
            backupExistsOnServer: backupExistsOnServer,
            ed25519Fingerprint: ed25519Fingerprint,
            curve25519IdentityKey: curve25519IdentityKey,
            updatedAt: Date()
        )
    }

    #if DEBUG
    func debugDeviceVerificationSnapshot(session: MatrixSession) async throws -> MatrixDeviceVerificationDebugSnapshot {
        let client = try await resolvedClient(session: session)
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()

        let state = Self.deviceVerificationState(from: encryption.verificationState())
        let hasDevicesToVerifyAgainst = try await encryption.hasDevicesToVerifyAgainst()
        let isLastDevice = try await encryption.isLastDevice()
        let sdkDeviceMatchesSession = Self.debugBool {
            try client.deviceId() == session.deviceID
        }
        let backupState = Self.debugBackupState(from: encryption.backupState())
        let backupExistsOnServer = await Self.debugAsyncBool {
            try await encryption.backupExistsOnServer()
        }
        let recoveryState = Self.debugRecoveryState(from: encryption.recoveryState())
        let userIdentity: MatrixUserIdentityDebugState
        do {
            if let identity = try await encryption.userIdentity(userId: session.userID, fallbackToServer: true) {
                userIdentity = .present(
                    isVerified: identity.isVerified(),
                    wasPreviouslyVerified: identity.wasPreviouslyVerified(),
                    hasVerificationViolation: identity.hasVerificationViolation(),
                    hasMasterKey: identity.masterKey() != nil
                )
            } else {
                userIdentity = .missing
            }
        } catch {
            userIdentity = .lookupFailed
        }

        return MatrixDeviceVerificationDebugSnapshot(
            state: state,
            hasDevicesToVerifyAgainst: hasDevicesToVerifyAgainst,
            isLastDevice: isLastDevice,
            sdkDeviceMatchesSession: sdkDeviceMatchesSession,
            backupState: backupState,
            backupExistsOnServer: backupExistsOnServer,
            recoveryState: recoveryState,
            userIdentity: userIdentity
        )
    }
    #endif

    func deviceVerificationFlow(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await sessionVerificationController(session: session)
        return verificationFlow
    }

    func requestDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        let client = try await resolvedClient(session: session)
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()
        guard try await encryption.hasDevicesToVerifyAgainst() else {
            throw MatrixClientError.noEligibleDeviceForVerification
        }

        let controller = try await sessionVerificationController(session: session)
        try await controller.requestDeviceVerification()
        setVerificationFlow(phase: .requestSent)
        return verificationFlow
    }

    func acceptDeviceVerificationRequest(
        _ request: MatrixDeviceVerificationRequest,
        session: MatrixSession
    ) async throws -> MatrixDeviceVerificationFlow {
        let controller = try await sessionVerificationController(session: session)
        try await controller.acknowledgeVerificationRequest(
            senderId: request.senderUserID,
            flowId: request.flowID
        )
        try await controller.acceptVerificationRequest()
        setVerificationFlow(phase: .accepted, request: request)
        return verificationFlow
    }

    func startSasDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        let controller = try await sessionVerificationController(session: session)
        try await controller.startSasVerification()
        setVerificationFlow(phase: .sasStarted)
        return verificationFlow
    }

    func approveDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        let controller = try await sessionVerificationController(session: session)
        try await controller.approveVerification()
        if verificationFlow.phase != .finished {
            setVerificationFlow(phase: .approved)
        }
        return verificationFlow
    }

    func declineDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        let controller = try await sessionVerificationController(session: session)
        try await controller.declineVerification()
        setVerificationFlow(phase: .cancelled)
        return verificationFlow
    }

    func cancelDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        let controller = try await sessionVerificationController(session: session)
        try await controller.cancelVerification()
        setVerificationFlow(phase: .cancelled)
        return verificationFlow
    }

    func setUpRecovery(session: MatrixSession) async throws -> String {
        let client = try await resolvedClient(session: session)
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()

        guard encryption.recoveryState() == .disabled else {
            throw MatrixClientError.recoverySetupUnavailable
        }

        let listener = SDKRecoveryProgressListener()

        do {
            let recoveryKey = try await encryption.enableRecovery(
                waitForBackupsToUpload: false,
                passphrase: nil,
                progressListener: listener
            )
            if listener.uploadFailed {
                throw MatrixClientError.recoveryKeySetupFailed
            }
            return recoveryKey
        } catch let error as MatrixClientError {
            throw error
        } catch {
            throw MatrixClientError.recoveryKeySetupFailed
        }
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: MatrixSession) async throws -> MatrixDeviceVerificationStatus {
        let trimmedKey = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw MatrixClientError.recoveryKeyRequired
        }

        let client = try await resolvedClient(session: session)
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()
        let recoveryState = encryption.recoveryState()
        guard recoveryState == .enabled || recoveryState == .incomplete else {
            throw MatrixClientError.recoveryKeyConfirmationUnavailable
        }

        do {
            try await encryption.recoverAndFixBackup(recoveryKey: trimmedKey)
            return try await deviceVerificationStatus(session: session)
        } catch {
            throw MatrixClientError.recoveryKeyConfirmationFailed
        }
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        let client = try await resolvedClient(session: session)
        let roomID = try await client.createRoom(
            request: CreateRoomParameters(
                name: name,
                isEncrypted: true,
                isDirect: true,
                visibility: .private,
                preset: .privateChat,
                invite: [inviteeUserID]
            )
        )

        try await ensureSyncStarted(client: client)
        try? await Task.sleep(for: .seconds(1))

        guard let room = try client.getRoom(roomId: roomID) else {
            throw MatrixClientError.roomUnavailable
        }

        roomsByID[roomID] = room
        return await Self.summary(from: room)
    }

    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        let client = try await resolvedClient(session: session)
        let roomID = try await client.createRoom(
            request: CreateRoomParameters(
                name: name,
                isEncrypted: true,
                isDirect: false,
                visibility: .private,
                preset: .privateChat,
                invite: inviteeUserIDs
            )
        )

        try await ensureSyncStarted(client: client)
        try? await Task.sleep(for: .seconds(1))

        guard let room = try client.getRoom(roomId: roomID) else {
            throw MatrixClientError.roomUnavailable
        }

        roomsByID[roomID] = room
        return await Self.summary(from: room)
    }

    func invitations(session: MatrixSession) async throws -> [MatrixRoomInvite] {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        let sdkRooms = await cachedRooms(client: client)
        roomsByID = Dictionary(uniqueKeysWithValues: sdkRooms.map { ($0.id(), $0) })

        var invitations: [MatrixRoomInvite] = []
        for room in await Self.invitedRooms(from: sdkRooms) {
            invitations.append(await Self.invitation(from: room))
        }

        return invitations.sorted { lhs, rhs in
            lhs.receivedAt > rhs.receivedAt
        }
    }

    func acceptInvitation(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        let room = try await invitedRoom(for: roomID, session: session)
        try await room.join()
        roomsByID[room.id()] = room
        try? await Task.sleep(for: .seconds(1))
        return await Self.summary(from: room)
    }

    func declineInvitation(roomID: String, session: MatrixSession) async throws {
        let room = try await invitedRoom(for: roomID, session: session)
        try await room.leave()
        roomsByID.removeValue(forKey: room.id())
        timelineStateByRoomID.removeValue(forKey: room.id())
        try? await Task.sleep(for: .milliseconds(500))
    }

    func joinInvitedRooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        var joinedRooms: [MatrixRoomSummary] = []
        for _ in 0..<10 {
            let currentRooms = await cachedRooms(client: client)
            let invitedRooms = await Self.invitedRooms(from: currentRooms)
            if invitedRooms.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            for room in invitedRooms {
                try await room.join()
                roomsByID[room.id()] = room
                joinedRooms.append(await Self.summary(from: room))
            }
            break
        }

        return joinedRooms
    }

    func joinRoom(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        for _ in 0..<15 {
            if let room = try client.getRoom(roomId: roomID) {
                try await room.join()
                roomsByID[room.id()] = room
                try? await Task.sleep(for: .seconds(1))
                return await Self.summary(from: room)
            }
            do {
                let joinedRoom = try await client.joinRoomById(roomId: roomID)
                roomsByID[joinedRoom.id()] = joinedRoom
                try? await Task.sleep(for: .seconds(1))
                return await Self.summary(from: joinedRoom)
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        throw MatrixClientError.roomUnavailable
    }

    private func resolvedClient(session: MatrixSession) async throws -> Client {
        if let client {
            return client
        }

        _ = try await restore(session: session)
        guard let client else {
            throw MatrixClientError.missingSession
        }
        return client
    }

    private func room(for roomID: String, session: MatrixSession) async throws -> Room {
        if let room = roomsByID[roomID] {
            return room
        }

        _ = try await rooms(session: session)
        guard let room = roomsByID[roomID] else {
            throw MatrixClientError.roomUnavailable
        }
        return room
    }

    private func invitedRoom(for roomID: String, session: MatrixSession) async throws -> Room {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        for _ in 0..<8 {
            if let room = roomsByID[roomID], await Self.isInvited(room) {
                return room
            }

            if let room = try client.getRoom(roomId: roomID), await Self.isInvited(room) {
                roomsByID[room.id()] = room
                return room
            }

            let rooms = await cachedRooms(client: client)
            roomsByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id(), $0) })
            if let room = rooms.first(where: { $0.id() == roomID }), await Self.isInvited(room) {
                return room
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw MatrixClientError.inviteUnavailable
    }

    private func sessionVerificationController(session: MatrixSession) async throws -> SessionVerificationController {
        if let verificationController {
            return verificationController
        }

        let client = try await resolvedClient(session: session)
        await client.encryption().waitForE2eeInitializationTasks()
        let controller = try await client.getSessionVerificationController()
        let delegate = SDKSessionVerificationDelegate { [weak self] flow in
            Task {
                await self?.applyVerificationFlow(flow)
            }
        }
        controller.setDelegate(delegate: delegate)
        verificationController = controller
        verificationDelegate = delegate
        return controller
    }

    private func resetVerificationFlow() {
        verificationController = nil
        verificationDelegate = nil
        verificationFlow = .idle
    }

    private func applyVerificationFlow(_ flow: MatrixDeviceVerificationFlow) {
        setVerificationFlow(
            phase: flow.phase,
            request: flow.request,
            challenge: flow.challenge,
            updatedAt: flow.updatedAt
        )
    }

    private func setVerificationFlow(
        phase: MatrixDeviceVerificationFlowPhase,
        request: MatrixDeviceVerificationRequest? = nil,
        challenge: MatrixDeviceVerificationChallenge? = nil,
        updatedAt: Date = Date()
    ) {
        let shouldPreserveRequest: Bool
        switch phase {
        case .accepted, .sasStarted, .challengeReceived:
            shouldPreserveRequest = true
        case .idle, .requestSent, .incomingRequest, .approved, .finished, .cancelled, .failed:
            shouldPreserveRequest = false
        }

        verificationFlow = MatrixDeviceVerificationFlow(
            phase: phase,
            request: request ?? (shouldPreserveRequest ? verificationFlow.request : nil),
            challenge: challenge,
            updatedAt: updatedAt
        )
    }

    private func cachedRooms(client: Client) async -> [Room] {
        var mergedRooms = roomsByID

        for room in client.rooms() {
            mergedRooms[room.id()] = room
        }

        for listener in roomListListeners {
            for room in listener.snapshot() {
                mergedRooms[room.id()] = room
            }
        }

        for room in await directRooms(client: client) {
            mergedRooms[room.id()] = room
        }

        return Array(mergedRooms.values)
    }

    private func directRooms(client: Client) async -> [Room] {
        guard let directAccountData = try? await client.accountData(eventType: "m.direct"),
              let data = directAccountData.data(using: .utf8),
              let roomIDsByUser = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return []
        }

        var directRooms: [Room] = []
        var seenRoomIDs = Set<String>()
        for roomID in roomIDsByUser.values.flatMap({ $0 }) where seenRoomIDs.insert(roomID).inserted {
            if let room = sdkRoom(roomID: roomID, client: client) {
                directRooms.append(room)
            }
        }
        return directRooms
    }

    private func sdkRoom(roomID: String, client: Client) -> Room? {
        if let room = roomsByID[roomID] {
            return room
        }

        if let room = try? client.getRoom(roomId: roomID) {
            return room
        }

        if let room = try? roomListService?.room(roomId: roomID) {
            return room
        }

        return nil
    }

    private func makeClient(serverURL: URL, paths: SDKSessionPaths) async throws -> Client {
        try await Self.clientBuilder(paths: paths)
            .serverNameOrHomeserverUrl(serverNameOrUrl: serverURL.absoluteString)
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .build()
    }

    private static func clientBuilder(paths: SDKSessionPaths) -> ClientBuilder {
        ClientBuilder()
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .sessionPaths(
                dataPath: paths.data.path(percentEncoded: false),
                cachePath: paths.cache.path(percentEncoded: false)
            )
    }

    private func ensureSyncStarted(client: Client) async throws {
        if syncService != nil {
            return
        }

        let syncService = try await client.syncService().finish()
        let roomListService = syncService.roomListService()
        let roomListFilters: [RoomListEntriesDynamicFilterKind] = [
            .all(filters: []),
            .any(filters: [
                .category(expect: .people),
                .category(expect: .group),
                .invite,
            ]),
        ]
        var listeners: [SDKRoomListListener] = []
        var handles: [RoomListEntriesWithDynamicAdaptersResult] = []

        for filter in roomListFilters {
            let listener = SDKRoomListListener()
            let handle = try await roomListService
                .allRooms()
                .entriesWithDynamicAdapters(pageSize: 100, listener: listener)
            _ = handle.controller().setFilter(kind: filter)
            listeners.append(listener)
            handles.append(handle)
        }

        self.syncService = syncService
        self.roomListService = roomListService
        self.roomListListeners = listeners
        self.roomListHandles = handles
        self.syncTask = Task {
            await syncService.start()
        }

        try? await Task.sleep(for: .milliseconds(750))
    }
}

private struct SDKSessionPaths {
    let data: URL
    let cache: URL
}

#if DEBUG
struct MatrixDeviceVerificationDebugSnapshot: Equatable, Sendable {
    let state: MatrixDeviceVerificationState
    let hasDevicesToVerifyAgainst: Bool
    let isLastDevice: Bool
    let sdkDeviceMatchesSession: MatrixDebugBool
    let backupState: String
    let backupExistsOnServer: MatrixDebugBool
    let recoveryState: String
    let userIdentity: MatrixUserIdentityDebugState

    var liveSmokeDescription: String {
        [
            "verificationState=\(state.rawValue)",
            "hasDevicesToVerifyAgainst=\(hasDevicesToVerifyAgainst)",
            "isLastDevice=\(isLastDevice)",
            "sdkDeviceMatchesSession=\(sdkDeviceMatchesSession.liveSmokeDescription)",
            "backupState=\(backupState)",
            "backupExistsOnServer=\(backupExistsOnServer.liveSmokeDescription)",
            "recoveryState=\(recoveryState)",
            "userIdentity=\(userIdentity.liveSmokeDescription)",
        ].joined(separator: " ")
    }
}

enum MatrixDebugBool: Equatable, Sendable {
    case value(Bool)
    case lookupFailed

    var liveSmokeDescription: String {
        switch self {
        case .value(let value):
            return "\(value)"
        case .lookupFailed:
            return "lookupFailed"
        }
    }
}

enum MatrixUserIdentityDebugState: Equatable, Sendable {
    case present(
        isVerified: Bool,
        wasPreviouslyVerified: Bool,
        hasVerificationViolation: Bool,
        hasMasterKey: Bool
    )
    case missing
    case lookupFailed

    var liveSmokeDescription: String {
        switch self {
        case .present(let isVerified, let wasPreviouslyVerified, let hasVerificationViolation, let hasMasterKey):
            return [
                "present",
                "isVerified=\(isVerified)",
                "wasPreviouslyVerified=\(wasPreviouslyVerified)",
                "hasVerificationViolation=\(hasVerificationViolation)",
                "hasMasterKey=\(hasMasterKey)",
            ].joined(separator: ",")
        case .missing:
            return "missing"
        case .lookupFailed:
            return "lookupFailed"
        }
    }
}
#endif

private struct SDKTimelineState {
    let timeline: Timeline
    let listener: SDKTimelineListener
    let handle: TaskHandle
}

private final class SDKRoomListListener: RoomListEntriesListener, @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [Room] = []

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        lock.withLock {
            for update in roomEntriesUpdate {
                switch update {
                case .append(let values):
                    rooms.append(contentsOf: values)
                case .clear:
                    rooms.removeAll()
                case .pushFront(let room):
                    rooms.insert(room, at: 0)
                case .pushBack(let room):
                    rooms.append(room)
                case .popFront:
                    if !rooms.isEmpty {
                        rooms.removeFirst()
                    }
                case .popBack:
                    _ = rooms.popLast()
                case .insert(let index, let room):
                    rooms.insert(room, at: min(Int(index), rooms.count))
                case .set(let index, let room):
                    let roomIndex = Int(index)
                    guard rooms.indices.contains(roomIndex) else {
                        return
                    }
                    rooms[roomIndex] = room
                case .remove(let index):
                    let roomIndex = Int(index)
                    guard rooms.indices.contains(roomIndex) else {
                        return
                    }
                    rooms.remove(at: roomIndex)
                case .truncate(let length):
                    let keptCount = min(Int(length), rooms.count)
                    rooms.removeSubrange(keptCount..<rooms.count)
                case .reset(values: let values):
                    rooms = values
                }
            }
        }
    }

    func snapshot() -> [Room] {
        lock.withLock {
            rooms
        }
    }
}

private final class SDKTimelineListener: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimelineItem] = []

    func onUpdate(diff: [TimelineDiff]) {
        lock.withLock {
            for update in diff {
                switch update {
                case .append(let values):
                    items.append(contentsOf: values)
                case .clear:
                    items.removeAll()
                case .pushFront(let item):
                    items.insert(item, at: 0)
                case .pushBack(let item):
                    items.append(item)
                case .popFront:
                    if !items.isEmpty {
                        items.removeFirst()
                    }
                case .popBack:
                    _ = items.popLast()
                case .insert(let index, let item):
                    items.insert(item, at: min(Int(index), items.count))
                case .set(let index, let item):
                    let itemIndex = Int(index)
                    guard items.indices.contains(itemIndex) else {
                        return
                    }
                    items[itemIndex] = item
                case .remove(let index):
                    let itemIndex = Int(index)
                    guard items.indices.contains(itemIndex) else {
                        return
                    }
                    items.remove(at: itemIndex)
                case .truncate(let length):
                    let keptCount = min(Int(length), items.count)
                    items.removeSubrange(keptCount..<items.count)
                case .reset(values: let values):
                    items = values
                }
            }
        }
    }

    func snapshot() -> [TimelineItem] {
        lock.withLock {
            items
        }
    }
}

private final class SDKSessionVerificationDelegate: SessionVerificationControllerDelegate, @unchecked Sendable {
    private let onUpdate: @Sendable (MatrixDeviceVerificationFlow) -> Void

    init(onUpdate: @escaping @Sendable (MatrixDeviceVerificationFlow) -> Void) {
        self.onUpdate = onUpdate
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        onUpdate(
            MatrixDeviceVerificationFlow(
                phase: .incomingRequest,
                request: MatrixDeviceVerificationRequest(
                    flowID: details.flowId,
                    senderUserID: details.senderProfile.userId,
                    senderDisplayName: details.senderProfile.displayName,
                    deviceID: details.deviceId,
                    deviceDisplayName: details.deviceDisplayName,
                    firstSeenAt: Date(timeIntervalSince1970: TimeInterval(details.firstSeenTimestamp) / 1_000)
                ),
                challenge: nil,
                updatedAt: Date()
            )
        )
    }

    func didAcceptVerificationRequest() {
        emit(phase: .accepted)
    }

    func didStartSasVerification() {
        emit(phase: .sasStarted)
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        onUpdate(
            MatrixDeviceVerificationFlow(
                phase: .challengeReceived,
                request: nil,
                challenge: Self.challenge(from: data),
                updatedAt: Date()
            )
        )
    }

    func didFail() {
        emit(phase: .failed)
    }

    func didCancel() {
        emit(phase: .cancelled)
    }

    func didFinish() {
        emit(phase: .finished)
    }

    private func emit(phase: MatrixDeviceVerificationFlowPhase) {
        onUpdate(
            MatrixDeviceVerificationFlow(
                phase: phase,
                request: nil,
                challenge: nil,
                updatedAt: Date()
            )
        )
    }

    private static func challenge(from data: SessionVerificationData) -> MatrixDeviceVerificationChallenge {
        switch data {
        case .emojis(let emojis, _):
            return .emojis(
                emojis.map {
                    MatrixDeviceVerificationEmoji(
                        symbol: $0.symbol(),
                        description: $0.description()
                    )
                }
            )
        case .decimals(let values):
            return .decimals(values.map(String.init))
        }
    }
}

private final class SDKRecoveryProgressListener: EnableRecoveryProgressListener, @unchecked Sendable {
    private let lock = NSLock()
    private var hasUploadFailed = false

    var uploadFailed: Bool {
        lock.withLock {
            hasUploadFailed
        }
    }

    func onUpdate(status: EnableRecoveryProgress) {
        if status == .roomKeyUploadError {
            lock.withLock {
                hasUploadFailed = true
            }
        }
    }
}

private extension MatrixRustSDKAdapter {
    static var defaultDeviceName: String {
        #if os(iOS)
        return "Trix iOS"
        #elseif os(macOS)
        return Host.current().localizedName ?? "This Mac"
        #else
        return "Trix"
        #endif
    }

    static func localpart(from userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":") else {
            throw MatrixClientError.invalidCredentials
        }

        let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
        let serverName = String(trimmed[trimmed.index(after: separator)...])
        guard !localpart.isEmpty,
              serverName == MatrixClientConfiguration.serverName else {
            throw MatrixClientError.invalidCredentials
        }

        return localpart
    }

    static func paths(for storeID: String) throws -> SDKSessionPaths {
        let data = dataRoot(for: storeID)
        let cache = cacheRoot(for: storeID)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return SDKSessionPaths(data: data, cache: cache)
    }

    static func dataRoot(for storeID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrixMatrix", isDirectory: true)
            .appendingPathComponent(storeID, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }

    static func cacheRoot(for storeID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrixMatrix", isDirectory: true)
            .appendingPathComponent(storeID, isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }

    static func displayName(from userID: String) -> String {
        let withoutAt = userID.dropFirst()
        let localpart = withoutAt.split(separator: ":").first.map(String.init) ?? String(withoutAt)
        return localpart.capitalized
    }

    static func normalizedMatrixUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":"),
              separator != trimmed.index(after: trimmed.startIndex) else {
            throw MatrixClientError.invalidMatrixUserID
        }

        let serverName = String(trimmed[trimmed.index(after: separator)...])
        guard serverName == MatrixClientConfiguration.serverName else {
            throw MatrixClientError.invalidMatrixUserID
        }

        return trimmed
    }

    static func roomMember(from member: RoomMember) -> MatrixRoomMember {
        MatrixRoomMember(
            userID: member.userId,
            displayName: member.displayName,
            membership: membership(from: member.membership)
        )
    }

    static func membership(from state: MembershipState) -> MatrixRoomMembership {
        switch state {
        case .join:
            return .joined
        case .invite:
            return .invited
        case .leave:
            return .left
        case .ban:
            return .banned
        case .knock, .custom:
            return .unknown
        }
    }

    static func summary(from room: Room) async -> MatrixRoomSummary {
        let info = try? await room.roomInfo()
        let latestEvent = await room.latestEvent()
        let preview = messageBody(from: latestEvent) ?? "No messages yet"
        let timestamp = latestTimestamp(from: latestEvent)
        let sdkEncryptionState = await room.isEncrypted()
        let isEncrypted = info?.encryptionState == .encrypted || sdkEncryptionState
        let isDirect: Bool
        if let infoIsDirect = info?.isDirect {
            isDirect = infoIsDirect
        } else {
            isDirect = await room.isDirect()
        }
        let name = roomDisplayName(room: room, info: info, isDirect: isDirect)

        return MatrixRoomSummary(
            id: room.id(),
            name: name,
            kind: isDirect ? .direct : .group,
            isEncrypted: isEncrypted,
            unreadCount: Int(info?.numUnreadNotifications ?? info?.numUnreadMessages ?? 0),
            lastMessagePreview: preview,
            lastActivityAt: timestamp
        )
    }

    static func joinedRooms(from rooms: [Room]) async -> [Room] {
        var joinedRooms: [Room] = []
        for room in rooms {
            if await isJoined(room) {
                joinedRooms.append(room)
            }
        }
        return joinedRooms
    }

    static func invitedRooms(from rooms: [Room]) async -> [Room] {
        var invitedRooms: [Room] = []
        for room in rooms {
            if await isInvited(room) {
                invitedRooms.append(room)
            }
        }
        return invitedRooms
    }

    static func invitation(from room: Room) async -> MatrixRoomInvite {
        let info = try? await room.roomInfo()
        let latestEvent = await room.latestEvent()
        let sdkEncryptionState = await room.isEncrypted()
        let isEncrypted = info?.encryptionState == .encrypted || sdkEncryptionState
        let inviter: RoomMember?
        if let infoInviter = info?.inviter {
            inviter = infoInviter
        } else {
            inviter = try? await room.inviter()
        }
        let isDirect: Bool
        if let infoIsDirect = info?.isDirect {
            isDirect = infoIsDirect
        } else {
            isDirect = await room.isDirect()
        }
        let name = roomDisplayName(room: room, info: info, isDirect: isDirect)

        return MatrixRoomInvite(
            id: room.id(),
            roomName: name,
            kind: isDirect ? .direct : .group,
            isEncrypted: isEncrypted,
            inviterUserID: inviter?.userId,
            inviterDisplayName: inviter?.displayName,
            receivedAt: latestTimestamp(from: latestEvent)
        )
    }

    static func isJoined(_ room: Room) async -> Bool {
        let info = try? await room.roomInfo()
        return info?.membership == .joined || room.membership() == .joined
    }

    static func isInvited(_ room: Room) async -> Bool {
        let info = try? await room.roomInfo()
        return info?.membership == .invited || room.membership() == .invited
    }

    static func roomDisplayName(room: Room, info: RoomInfo?, isDirect: Bool) -> String {
        if let displayName = nonEmpty(info?.displayName) {
            return displayName
        }

        if let displayName = nonEmpty(room.displayName()) {
            return displayName
        }

        if isDirect,
           let heroName = directHeroName(room: room, info: info) {
            return heroName
        }

        return room.id()
    }

    static func directHeroName(room: Room, info: RoomInfo?) -> String? {
        let ownUserID = room.ownUserId()
        let infoHeroes = info?.heroes ?? []
        let heroes = infoHeroes.isEmpty ? room.heroes() : infoHeroes
        guard let hero = heroes.first(where: { $0.userId != ownUserID }) ?? heroes.first else {
            return nil
        }

        return nonEmpty(hero.displayName) ?? nonEmpty(hero.userId)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func timelineItem(from sdkItem: TimelineItem, roomID: String) -> MatrixTimelineItem? {
        guard let event = sdkItem.asEvent(),
              case let .msgLike(content: msgLike) = event.content,
              case let .message(content: messageContent) = msgLike.kind else {
            return nil
        }

        let attachment = Self.timelineAttachment(from: messageContent.msgType)
        let body = attachment?.filename ?? messageContent.body

        return MatrixTimelineItem(
            id: sdkItem.uniqueId().id,
            roomID: roomID,
            sender: event.sender,
            timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1_000),
            body: body,
            isLocalEcho: event.isOwn,
            attachment: attachment
        )
    }

    static func timelineAttachment(from messageType: MessageType) -> MatrixTimelineAttachment? {
        switch messageType {
        case .image(let content):
            return MatrixTimelineAttachment(
                kind: .image,
                filename: content.filename,
                mimeType: content.info?.mimetype,
                sizeBytes: intSize(from: content.info?.size),
                sourceJSON: content.source.toJson()
            )
        case .file(let content):
            return MatrixTimelineAttachment(
                kind: .file,
                filename: content.filename,
                mimeType: content.info?.mimetype,
                sizeBytes: intSize(from: content.info?.size),
                sourceJSON: content.source.toJson()
            )
        default:
            return nil
        }
    }

    static func intSize(from size: UInt64?) -> Int? {
        guard let size,
              size <= UInt64(Int.max) else {
            return nil
        }

        return Int(size)
    }

    static func latestTimestamp(from latestEvent: LatestEventValue) -> Date {
        switch latestEvent {
        case .remote(let timestamp, _, _, _, _),
             .remoteInvite(let timestamp, _, _),
             .local(let timestamp, _, _, _, _):
            return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
        case .none:
            return .distantPast
        }
    }

    static func messageBody(from latestEvent: LatestEventValue) -> String? {
        switch latestEvent {
        case .remote(_, let sender, _, _, let content),
             .local(_, let sender, _, let content, _):
            if let body = messageBody(from: content) {
                return "\(sender): \(body)"
            }
            return nil
        case .remoteInvite(_, let inviter, _):
            return inviter.map { "\($0) invited you" }
        case .none:
            return nil
        }
    }

    static func messageBody(from content: TimelineItemContent) -> String? {
        guard case let .msgLike(content: msgLike) = content else {
            return nil
        }

        switch msgLike.kind {
        case .message(let message):
            return message.body
        case .sticker(let body, _, _):
            return body
        case .unableToDecrypt:
            return "Message unavailable"
        case .redacted:
            return "Message deleted"
        default:
            return nil
        }
    }

    static func deviceVerificationState(from sdkState: VerificationState) -> MatrixDeviceVerificationState {
        switch sdkState {
        case .unknown:
            return .unknown
        case .verified:
            return .verified
        case .unverified:
            return .unverified
        @unknown default:
            return .unknown
        }
    }

    static func recoveryState(from sdkState: RecoveryState) -> MatrixRecoveryState {
        switch sdkState {
        case .unknown:
            return .unknown
        case .enabled:
            return .enabled
        case .disabled:
            return .disabled
        case .incomplete:
            return .incomplete
        @unknown default:
            return .unknown
        }
    }

    static func backupState(from sdkState: BackupState) -> MatrixBackupState {
        switch sdkState {
        case .unknown:
            return .unknown
        case .creating:
            return .creating
        case .enabling:
            return .enabling
        case .resuming:
            return .resuming
        case .enabled:
            return .enabled
        case .downloading:
            return .downloading
        case .disabling:
            return .disabling
        @unknown default:
            return .unknown
        }
    }

    #if DEBUG
    static func debugBool(_ load: () throws -> Bool) -> MatrixDebugBool {
        do {
            return .value(try load())
        } catch {
            return .lookupFailed
        }
    }

    static func debugAsyncBool(_ load: () async throws -> Bool) async -> MatrixDebugBool {
        do {
            return .value(try await load())
        } catch {
            return .lookupFailed
        }
    }

    static func debugBackupState(from state: BackupState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .creating:
            return "creating"
        case .enabling:
            return "enabling"
        case .resuming:
            return "resuming"
        case .enabled:
            return "enabled"
        case .downloading:
            return "downloading"
        case .disabling:
            return "disabling"
        @unknown default:
            return "unknown"
        }
    }

    static func debugRecoveryState(from state: RecoveryState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .enabled:
            return "enabled"
        case .disabled:
            return "disabled"
        case .incomplete:
            return "incomplete"
        @unknown default:
            return "unknown"
        }
    }
    #endif
}

private extension MatrixSession {
    init(sdkSession: Session, sdkStoreID: String) {
        self.init(
            userID: sdkSession.userId,
            deviceID: sdkSession.deviceId,
            homeserverURL: URL(string: sdkSession.homeserverUrl) ?? MatrixClientConfiguration.homeserverURL,
            accessToken: sdkSession.accessToken,
            refreshToken: sdkSession.refreshToken,
            oidcData: sdkSession.oidcData,
            sdkStoreID: sdkStoreID,
            createdAt: Date()
        )
    }

    var sdkSession: Session {
        Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userID,
            deviceId: deviceID,
            homeserverUrl: homeserverURL.absoluteString,
            oidcData: oidcData,
            slidingSyncVersion: .native
        )
    }
}
