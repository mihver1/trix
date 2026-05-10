import SwiftUI

enum TrixRoomListMode {
    case sidebar
    case phoneInbox
}

struct TrixRoomListView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel
    @State private var isShowingNewRoom = false
    @State private var phoneSelectedRoomID: String?
    let mode: TrixRoomListMode

    init(model: TrixAppModel, mode: TrixRoomListMode = .sidebar) {
        self.model = model
        self.mode = mode
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
    }

    var body: some View {
        styledList
            .toolbar {
                Button {
                    isShowingNewRoom = true
                } label: {
                    Label("New Room", systemImage: "square.and.pencil")
                }
                .help("New room")
            }
            .sheet(isPresented: $isShowingNewRoom) {
                TrixNewRoomView(model: model)
            }
            .navigationDestination(isPresented: phoneRoomIsPresented) {
                phoneTimelineDestination
            }
    }

    @ViewBuilder
    private var styledList: some View {
        switch mode {
        case .sidebar:
            roomList
                .listStyle(.sidebar)
                .refreshable {
                    await model.reloadRooms()
                }
        case .phoneInbox:
            #if os(iOS)
            VStack(spacing: 0) {
                if let account = model.account {
                    TrixInboxAccountHeader(
                        account: account,
                        isLoading: roomListViewModel.isLoading,
                        unreadCount: roomListViewModel.totalUnreadCount,
                        invitationCount: roomListViewModel.invitations.count,
                        pushRegistration: model.pushRegistration,
                        pushRegistrationBlocker: model.pushRegistrationBlocker,
                        refresh: {
                            Task {
                                await model.reloadRooms()
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                }

                roomList
                    .listStyle(.plain)
                    .refreshable {
                        await model.reloadRooms()
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: 86)
                    }
                    .trixScrollContentBackgroundHidden()
            }
            .background(TrixDesign.screenBackground)
            #else
            roomList
                .listStyle(.sidebar)
                .refreshable {
                    await model.reloadRooms()
                }
            #endif
        }
    }

    @ViewBuilder
    private var roomList: some View {
        switch mode {
        case .phoneInbox:
            List {
                roomListContent
            }
        case .sidebar:
            List(selection: $model.selectedRoomID) {
                roomListContent
            }
        }
    }

    @ViewBuilder
    private var roomListContent: some View {
        if mode == .phoneInbox {
            invitesSection
            roomsSection
        } else {
            roomsSection
            invitesSection
        }

        errorSection
    }

    @ViewBuilder
    private var roomsSection: some View {
        Section {
            if roomListViewModel.rooms.isEmpty {
                TrixEmptyStateView(
                    title: "No Rooms",
                    systemImage: "bubble.left",
                    message: "Create a room or accept an invite."
                )
            } else {
                ForEach(roomListViewModel.rooms) { room in
                    roomRow(room)
                }
            }
        } header: {
            HStack {
                Text(mode == .phoneInbox ? "Recent" : "Rooms")
                Spacer()
                if roomListViewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var invitesSection: some View {
        if !roomListViewModel.invitations.isEmpty {
            Section("Invites") {
                ForEach(roomListViewModel.invitations) { invitation in
                    inviteRow(invitation)
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage = roomListViewModel.errorMessage ?? model.errorMessage {
            Section {
                TrixBannerView(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .red
                )
            }
        }
    }

    private func inviteRow(_ invitation: TrixRoomInvite) -> some View {
        TrixInviteRow(
            invitation: invitation,
            isWorking: roomListViewModel.invitationActionRoomID == invitation.id,
            accept: {
                Task {
                    await model.acceptInvitation(invitation)
                }
            },
            decline: {
                Task {
                    await model.declineInvitation(invitation)
                }
            }
        )
        .trixInviteSwipeActions(
            isEnabled: roomListViewModel.invitationActionRoomID != invitation.id,
            accept: {
                Task {
                    await model.acceptInvitation(invitation)
                }
            },
            decline: {
                Task {
                    await model.declineInvitation(invitation)
                }
            }
        )
    }

    @ViewBuilder
    private func roomRow(_ room: TrixRoomSummary) -> some View {
        if mode == .phoneInbox {
            Button {
                openPhoneRoom(room)
            } label: {
                TrixRoomRow(room: room, mode: mode)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.visible)
        } else {
            TrixRoomRow(room: room, mode: mode)
                .tag(room.id as String?)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task {
                        await model.selectRoom(room)
                    }
                }
        }
    }

    private func openPhoneRoom(_ room: TrixRoomSummary) {
        model.selectedRoomID = room.id
        phoneSelectedRoomID = room.id
    }

    private var phoneRoomIsPresented: Binding<Bool> {
        Binding(
            get: { phoneSelectedRoomID != nil },
            set: { isPresented in
                if !isPresented {
                    phoneSelectedRoomID = nil
                }
            }
        )
    }

    @ViewBuilder
    private var phoneTimelineDestination: some View {
        if let roomID = phoneSelectedRoomID,
           let room = roomListViewModel.rooms.first(where: { $0.id == roomID }) {
            TrixTimelineView(model: model, room: room)
        } else {
            TrixEmptyStateView(
                title: "Room unavailable",
                systemImage: "exclamationmark.bubble",
                message: "The room is no longer present in the latest Trix sync."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TrixDesign.screenBackground)
        }
    }
}

struct TrixSettingsView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel
    @ObservedObject private var deviceVerificationViewModel: DeviceVerificationViewModel

    init(model: TrixAppModel) {
        self.model = model
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
        self._deviceVerificationViewModel = ObservedObject(wrappedValue: model.deviceVerificationViewModel)
    }

    var body: some View {
        Form {
            Section("Account") {
                if let account = model.account {
                    LabeledContent("User", value: account.userID)
                    LabeledContent("Device", value: account.deviceID)
                } else {
                    TrixEmptyStateView(
                        title: "Not Signed In",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        message: "Sign in before managing account settings."
                    )
                }

                if let homeserverURL = model.session?.homeserverURL.absoluteString {
                    LabeledContent("Server", value: homeserverURL)
                }

                Button {
                    Task {
                        await model.reloadRooms()
                    }
                } label: {
                    Label("Refresh Rooms", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isAuthenticated)

                Button(role: .destructive) {
                    Task {
                        await model.logout()
                    }
                } label: {
                    Label(model.isLoggingOut ? "Logging Out" : "Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(!model.isAuthenticated || model.isLoggingOut)
            }

            Section("Account State") {
                LabeledContent("Session", value: model.isAuthenticated ? "Signed in" : "Signed out")
                LabeledContent("Rooms", value: "\(roomListViewModel.rooms.count)")
                LabeledContent("Invites", value: "\(roomListViewModel.invitations.count)")
                LabeledContent("Unread", value: "\(roomListViewModel.totalUnreadCount)")
                LabeledContent("Push", value: pushRegistrationStatus)
            }

            Section("Profile") {
                TrixProfileSettingsView(model: model)
            }

            Section("Device Verification And Recovery") {
                TrixDeviceVerificationStatusView(
                    viewModel: deviceVerificationViewModel,
                    requestVerification: {
                        Task {
                            await model.requestDeviceVerification()
                        }
                    },
                    acceptRequest: { request in
                        Task {
                            await model.acceptDeviceVerificationRequest(request)
                        }
                    },
                    startSas: {
                        Task {
                            await model.startSasDeviceVerification()
                        }
                    },
                    approve: {
                        Task {
                            await model.approveDeviceVerification()
                        }
                    },
                    decline: {
                        Task {
                            await model.declineDeviceVerification()
                        }
                    },
                    cancel: {
                        Task {
                            await model.cancelDeviceVerification()
                        }
                    },
                    trustAccountDevice: { device in
                        Task {
                            await model.trustAccountDevice(device)
                        }
                    },
                    setUpRecovery: {
                        Task {
                            await model.setUpRecovery()
                        }
                    },
                    confirmRecoveryKey: {
                        Task {
                            await model.confirmRecoveryKey()
                        }
                    },
                    dismissRecoveryKey: {
                        deviceVerificationViewModel.dismissRecoveryKey()
                    }
                )

                Button {
                    Task {
                        await model.reloadDeviceVerificationStatus()
                    }
                } label: {
                    Label("Refresh Verification", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isAuthenticated || deviceVerificationViewModel.isLoading)
            }

            Section {
                TrixLimitationsView()
            }
        }
        .trixScrollContentBackgroundHidden()
        .background(TrixDesign.screenBackground)
        .task {
            guard model.isAuthenticated else {
                return
            }

            await model.reloadDeviceVerificationStatus()
        }
    }

    private var pushRegistrationStatus: String {
        if model.pushRegistration != nil {
            return "Registered"
        }

        return model.pushRegistrationBlocker?.label ?? "Unknown"
    }
}

private extension RoomListViewModel {
    var totalUnreadCount: Int {
        rooms.reduce(0) { partialResult, room in
            partialResult + max(room.unreadCount, 0)
        }
    }
}

private struct TrixInboxAccountHeader: View {
    let account: TrixAccount
    let isLoading: Bool
    let unreadCount: Int
    let invitationCount: Int
    let pushRegistration: TrixPushRegistration?
    let pushRegistrationBlocker: TrixPushRegistrationBlocker?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TrixAvatarView(
                    title: account.displayName.isEmpty ? account.userID : account.displayName,
                    systemImage: "person.crop.circle",
                    size: 32
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName.isEmpty ? "Trix" : account.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(account.userID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(action: refresh) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .accessibilityLabel("Refresh rooms")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TrixStatusPill(
                        title: unreadCount == 0 ? "No unread" : "\(min(unreadCount, 99)) unread",
                        systemImage: unreadCount == 0 ? "checkmark.circle" : "circle.fill",
                        tint: unreadCount == 0 ? Color.secondary : TrixDesign.accent
                    )

                    TrixStatusPill(
                        title: invitationCount == 0 ? "No invites" : "\(invitationCount) invite\(invitationCount == 1 ? "" : "s")",
                        systemImage: invitationCount == 0 ? "person.badge.plus" : "person.crop.circle.badge.plus",
                        tint: invitationCount == 0 ? Color.secondary : Color.orange
                    )
                }

                TrixStatusPill(
                    title: pushStatusTitle,
                    systemImage: pushRegistration == nil ? "bell.slash" : "bell.badge",
                    tint: pushRegistration == nil ? Color.secondary : Color.green
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pushStatusTitle: String {
        if pushRegistration != nil {
            return "Push ready"
        }

        return pushRegistrationBlocker?.label ?? "Push unknown"
    }
}

private struct TrixRoomRow: View {
    let room: TrixRoomSummary
    let mode: TrixRoomListMode

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if mode == .phoneInbox {
                Circle()
                    .fill(room.unreadCount > 0 ? TrixDesign.accent : Color.clear)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: mode == .phoneInbox ? 50 : 34,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TrixRoomKindMark(kind: room.kind, size: 20)

                    Text(room.name)
                        .font(.headline.weight(room.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)

                    TrixRoomSecurityMark(isEncrypted: room.isEncrypted, size: 20)

                    Spacer(minLength: 8)

                    if mode == .phoneInbox {
                        Text(room.lastActivityAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption.weight(room.unreadCount > 0 ? .semibold : .regular))
                            .foregroundStyle(room.unreadCount > 0 ? TrixDesign.accent : Color.secondary)
                            .monospacedDigit()
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(room.lastMessagePreview)
                        .font(.subheadline.weight(room.unreadCount > 0 ? .semibold : .regular))
                        .foregroundStyle(room.unreadCount > 0 ? Color.primary : Color.secondary)
                        .lineLimit(mode == .phoneInbox ? 2 : 1)

                    Spacer(minLength: 8)

                    if room.unreadCount > 0 {
                        Text(room.unreadCount > 99 ? "99+" : "\(room.unreadCount)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(TrixDesign.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }

                if mode != .phoneInbox {
                    Text(room.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, mode == .phoneInbox ? 10 : 4)
        .padding(.horizontal, mode == .phoneInbox ? 4 : 0)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let unread = room.unreadCount > 0 ? ", \(room.unreadCount) unread" : ", no unread messages"
        let encrypted = room.isEncrypted ? ", encrypted" : ", not encrypted"
        return "\(room.name), \(room.kind.label)\(unread)\(encrypted), \(room.lastMessagePreview)"
    }
}

private struct TrixInviteRow: View {
    let invitation: TrixRoomInvite
    let isWorking: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                TrixAvatarView(
                    title: invitation.title,
                    systemImage: invitation.kind.systemImage,
                    size: 36,
                    tint: invitation.kind.tint
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TrixRoomKindMark(kind: invitation.kind, size: 20)

                        Text(invitation.title)
                            .font(.headline)
                            .lineLimit(1)

                        TrixRoomSecurityMark(isEncrypted: invitation.isEncrypted, size: 20)
                    }

                    Text(invitation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    accept()
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Accept", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                Button(role: .destructive) {
                    decline()
                } label: {
                    Label("Decline", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

private extension View {
    @ViewBuilder
    func trixInviteSwipeActions(
        isEnabled: Bool,
        accept: @escaping () -> Void,
        decline: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                accept()
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .tint(.green)
            .disabled(!isEnabled)

            Button(role: .destructive) {
                decline()
            } label: {
                Label("Decline", systemImage: "xmark")
            }
            .disabled(!isEnabled)
        }
        #else
        self
        #endif
    }
}
