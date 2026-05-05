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

    init(
        sessionStore: MatrixSessionStore = KeychainMatrixSessionStore(),
        matrixService: MatrixService = MatrixRustSDKAdapter()
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
                serverURL: MatrixClientConfiguration.homeserverURL
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

        if selectedRoomID == nil {
            selectedRoomID = roomListViewModel.rooms.first?.id
        }

        if let selectedRoomID {
            await loadTimeline(roomID: selectedRoomID)
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
}
