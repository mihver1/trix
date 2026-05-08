import Foundation

@MainActor
final class MatrixAppModel: ObservableObject {
    @Published private(set) var session: MatrixSession?
    @Published private(set) var account: MatrixAccount?
    @Published private(set) var isStarting = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isLoggingOut = false
    @Published var errorMessage: String?
    @Published var selectedRoomID: String?

    let roomListViewModel: RoomListViewModel
    let timelineViewModel: TimelineViewModel
    let deviceVerificationViewModel: DeviceVerificationViewModel

    private let sessionStore: MatrixSessionStore
    private let matrixService: MatrixService
    private var hasStarted = false
    private let foregroundRefreshInterval: Duration = .seconds(10)

    init(
        sessionStore: MatrixSessionStore = KeychainMatrixSessionStore(),
        matrixService: MatrixService = XMPPMartinService()
    ) {
        self.sessionStore = sessionStore
        self.matrixService = matrixService
        self.roomListViewModel = RoomListViewModel()
        self.timelineViewModel = TimelineViewModel()
        self.deviceVerificationViewModel = DeviceVerificationViewModel()
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var selectedRoom: MatrixRoomSummary? {
        guard let selectedRoomID else {
            return nil
        }

        return roomListViewModel.rooms.first { $0.id == selectedRoomID }
    }

    func start() async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isStarting = true
        defer { isStarting = false }

        do {
            guard let restoredSession = try sessionStore.loadSession() else {
                return
            }

            session = restoredSession
            account = try await matrixService.restore(session: restoredSession)
            await reloadRooms()
            await reloadDeviceVerificationStatus()
        } catch {
            self.session = nil
            self.account = nil
            self.selectedRoomID = nil
            self.roomListViewModel.clear()
            self.timelineViewModel.clear()
            self.deviceVerificationViewModel.clear()
            try? sessionStore.clearSession()
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func login(userID: String, password: String) async {
        guard !isLoggingIn else {
            return
        }

        isLoggingIn = true
        errorMessage = nil
        defer { isLoggingIn = false }

        do {
            let newSession = try await matrixService.login(
                userID: userID,
                password: password,
                serverURL: XMPPClientConfiguration.connectionURL
            )
            try sessionStore.saveSession(newSession)
            session = newSession
            account = try await matrixService.restore(session: newSession)
            await reloadRooms()
            await reloadDeviceVerificationStatus()
        } catch {
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func logout() async {
        guard let session, !isLoggingOut else {
            return
        }

        isLoggingOut = true
        errorMessage = nil
        defer { isLoggingOut = false }

        do {
            try await matrixService.logout(session: session)
        } catch {
            errorMessage = error.matrixUserFacingMessage
        }

        try? sessionStore.clearSession()
        self.session = nil
        self.account = nil
        self.selectedRoomID = nil
        self.roomListViewModel.clear()
        self.timelineViewModel.clear()
        self.deviceVerificationViewModel.clear()
    }

    func reloadRooms() async {
        guard let session else {
            roomListViewModel.clear()
            return
        }

        await roomListViewModel.reload(session: session, service: matrixService)
        reconcileSelectedRoom()

        if let selectedRoomID {
            await loadTimeline(roomID: selectedRoomID)
        }
    }

    func refreshForeground() async {
        guard let session, !isLoggingOut else {
            return
        }

        await roomListViewModel.reload(
            session: session,
            service: matrixService,
            showsLoading: false
        )
        reconcileSelectedRoom()

        if let selectedRoomID {
            await timelineViewModel.load(
                roomID: selectedRoomID,
                session: session,
                service: matrixService,
                showsLoading: false
            )
        }
    }

    func runForegroundRefreshLoop() async {
        guard isAuthenticated else {
            return
        }

        while !Task.isCancelled && isAuthenticated {
            try? await Task.sleep(for: foregroundRefreshInterval)
            guard !Task.isCancelled else {
                return
            }

            await refreshForeground()
        }
    }

    func selectRoom(_ room: MatrixRoomSummary) async {
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
    }

    func loadTimeline(roomID: String) async {
        guard let session else {
            timelineViewModel.clear()
            return
        }

        await timelineViewModel.load(roomID: roomID, session: session, service: matrixService)
    }

    func send(text: String) async {
        guard let session, let selectedRoomID else {
            return
        }

        await timelineViewModel.send(
            text: text,
            roomID: selectedRoomID,
            session: session,
            service: matrixService
        )
        await roomListViewModel.reload(session: session, service: matrixService)
    }

    func sendAttachment(_ attachment: MatrixAttachmentUpload) async {
        guard let session, let selectedRoomID else {
            return
        }

        await timelineViewModel.sendAttachment(
            attachment,
            roomID: selectedRoomID,
            session: session,
            service: matrixService
        )
        await roomListViewModel.reload(session: session, service: matrixService)
    }

    func downloadAttachment(for item: MatrixTimelineItem) async {
        guard let session else {
            return
        }

        await timelineViewModel.downloadAttachment(
            for: item,
            session: session,
            service: matrixService
        )
    }

    func members(roomID: String) async throws -> [MatrixRoomMember] {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        return try await matrixService.members(roomID: roomID, session: session)
    }

    func peerDeviceIdentities(for userID: String, refresh: Bool = false) async throws -> [MatrixPeerDeviceIdentity] {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        if refresh {
            return try await matrixService.refreshPeerDeviceIdentities(userID: userID, session: session)
        }

        return try await matrixService.peerDeviceIdentities(userID: userID, session: session)
    }

    func trustPeerDevice(userID: String, deviceID: String) async throws -> [MatrixPeerDeviceIdentity] {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        let devices = try await matrixService.trustPeerDevice(userID: userID, deviceID: deviceID, session: session)
        await roomListViewModel.reload(session: session, service: matrixService)
        return devices
    }

    func inviteUser(_ userID: String, to roomID: String) async throws {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        try await matrixService.inviteUser(userID, roomID: roomID, session: session)
        await reloadRooms()
    }

    func removeUser(_ userID: String, from roomID: String) async throws {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        try await matrixService.removeUser(userID, roomID: roomID, session: session)
        await reloadRooms()
    }

    func searchUsers(_ searchTerm: String, limit: Int = 20) async throws -> MatrixUserSearchResult {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        return try await matrixService.searchUsers(searchTerm, limit: limit, session: session)
    }

    func profile(userID: String? = nil) async throws -> MatrixUserProfile {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        return try await matrixService.profile(userID: userID ?? session.userID, session: session)
    }

    func updateDisplayName(_ displayName: String) async throws -> MatrixUserProfile {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        let profile = try await matrixService.updateDisplayName(displayName, session: session)
        account = MatrixAccount(
            userID: profile.userID,
            displayName: profile.displayName ?? "",
            deviceID: session.deviceID
        )
        return profile
    }

    func updateProfile(_ update: MatrixUserProfileUpdate) async throws -> MatrixUserProfile {
        guard let session else {
            throw MatrixClientError.missingSession
        }

        let profile = try await matrixService.updateProfile(update, session: session)
        account = MatrixAccount(
            userID: profile.userID,
            displayName: profile.displayName ?? "",
            deviceID: session.deviceID
        )
        return profile
    }

    func createEncryptedDirectRoom(inviteeUserID: String, roomName: String) async -> Bool {
        guard let session else {
            return false
        }

        guard let room = await roomListViewModel.createEncryptedDirectRoom(
            inviteeUserID: inviteeUserID,
            roomName: roomName,
            session: session,
            service: matrixService
        ) else {
            return false
        }

        await reloadRooms()
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
        return true
    }

    func createEncryptedGroupRoom(name: String, inviteeUserIDs: [String]) async -> Bool {
        guard let session else {
            return false
        }

        guard let room = await roomListViewModel.createEncryptedGroupRoom(
            name: name,
            inviteeUserIDs: inviteeUserIDs,
            session: session,
            service: matrixService
        ) else {
            return false
        }

        await reloadRooms()
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
        return true
    }

    func reloadDeviceVerificationStatus() async {
        guard let session else {
            deviceVerificationViewModel.clear()
            return
        }

        await deviceVerificationViewModel.reload(session: session, service: matrixService)
    }

    func requestDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.requestVerification(session: session, service: matrixService)
    }

    func acceptDeviceVerificationRequest(_ request: MatrixDeviceVerificationRequest) async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.acceptRequest(
            request,
            session: session,
            service: matrixService
        )
    }

    func startSasDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.startSas(session: session, service: matrixService)
    }

    func approveDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.approve(session: session, service: matrixService)
    }

    func declineDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.decline(session: session, service: matrixService)
    }

    func cancelDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.cancel(session: session, service: matrixService)
    }

    func setUpRecovery() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.setUpRecovery(session: session, service: matrixService)
    }

    func confirmRecoveryKey() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.confirmRecoveryKey(session: session, service: matrixService)
    }

    func acceptInvitation(_ invitation: MatrixRoomInvite) async {
        guard let session else {
            return
        }

        guard let room = await roomListViewModel.acceptInvitation(
            invitation,
            session: session,
            service: matrixService
        ) else {
            return
        }

        await reloadRooms()
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
    }

    func declineInvitation(_ invitation: MatrixRoomInvite) async {
        guard let session else {
            return
        }

        let didDecline = await roomListViewModel.declineInvitation(
            invitation,
            session: session,
            service: matrixService
        )

        if didDecline {
            await reloadRooms()
        }
    }

    private func reconcileSelectedRoom() {
        if let selectedRoomID,
           roomListViewModel.rooms.contains(where: { $0.id == selectedRoomID }) {
            return
        }

        selectedRoomID = roomListViewModel.rooms.first?.id
    }
}

extension MatrixAppModel {
    static func makeDefault() -> MatrixAppModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TRIX_MATRIX_USE_MOCK_SERVICE"] == "1" {
            return MatrixAppModel(
                sessionStore: MatrixMockSessionStore(),
                matrixService: MockMatrixService()
            )
        }
        #endif

        return MatrixAppModel()
    }
}

#if DEBUG
private struct MatrixMockSessionStore: MatrixSessionStore {
    func loadSession() throws -> MatrixSession? {
        MatrixSession(
            userID: "@me:trix.selfhost.ru",
            deviceID: "MOCK-IPHONE",
            homeserverURL: XMPPClientConfiguration.connectionURL,
            accessToken: "debug-placeholder-session",
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "mock-ui-demo",
            createdAt: Date()
        )
    }

    func saveSession(_ session: MatrixSession) throws {
    }

    func clearSession() throws {
    }
}
#endif
