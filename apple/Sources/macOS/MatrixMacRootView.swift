import SwiftUI

struct MatrixMacRootView: View {
    @ObservedObject var model: MatrixAppModel

    var body: some View {
        Group {
            if model.isStarting {
                ProgressView("Restoring session")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isAuthenticated {
                MatrixMacWorkspaceView(model: model)
            } else {
                MatrixLoginView(model: model)
                    .frame(minWidth: 520, minHeight: 520)
            }
        }
        .task {
            await model.start()
        }
    }
}

private struct MatrixMacWorkspaceView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingNewRoom = false

    var body: some View {
        NavigationSplitView {
            MatrixMacRoomListView(model: model)
                .navigationTitle("Trix")
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
        } content: {
            MatrixMacTimelineColumn(model: model)
                .navigationSplitViewColumnWidth(min: 480, ideal: 640)
        } detail: {
            MatrixMacRoomContextView(model: model, room: model.selectedRoom)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isShowingNewRoom = true
                } label: {
                    Label("New Room", systemImage: "square.and.pencil")
                }
                .help("New room")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $isShowingNewRoom) {
            MatrixNewRoomView(model: model)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
    }
}

private struct MatrixMacRoomListView: View {
    @ObservedObject var model: MatrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel

    init(model: MatrixAppModel) {
        self.model = model
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
    }

    var body: some View {
        List(selection: $model.selectedRoomID) {
            Section {
                if roomListViewModel.rooms.isEmpty {
                    ContentUnavailableView(
                        "No Rooms",
                        systemImage: "bubble.left",
                        description: Text("Create a room or accept an invite.")
                    )
                } else {
                    ForEach(roomListViewModel.rooms) { room in
                        MatrixMacRoomRow(room: room)
                            .tag(room.id as String?)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await model.selectRoom(room)
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Rooms")
                    Spacer()
                    if roomListViewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if !roomListViewModel.invitations.isEmpty {
                Section("Invites") {
                    ForEach(roomListViewModel.invitations) { invitation in
                        MatrixMacInviteRow(
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
                    }
                }
            }

            if let errorMessage = roomListViewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct MatrixMacTimelineColumn: View {
    @ObservedObject var model: MatrixAppModel

    var body: some View {
        if let selectedRoom = model.selectedRoom {
            MatrixTimelineView(model: model, room: selectedRoom)
        } else {
            ContentUnavailableView(
                "No Room Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Select a Trix chat from the sidebar.")
            )
            .navigationTitle("Messages")
        }
    }
}

private struct MatrixMacRoomContextView: View {
    @ObservedObject var model: MatrixAppModel
    @ObservedObject private var timelineViewModel: TimelineViewModel
    let room: MatrixRoomSummary?
    @State private var selectedInvitees: [MatrixUserProfile] = []
    @State private var members: [MatrixRoomMember] = []
    @State private var commonRooms: [MatrixRoomSummary] = []
    @State private var membersRoomID: String?
    @State private var membershipErrorMessage: String?
    @State private var isLoadingMembers = false
    @State private var isLoadingCommonRooms = false
    @State private var isUpdatingMembership = false

    init(model: MatrixAppModel, room: MatrixRoomSummary?) {
        self.model = model
        self.room = room
        self._timelineViewModel = ObservedObject(wrappedValue: model.timelineViewModel)
    }

    var body: some View {
        if let room {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    roomHeader(room)

                    Divider()

                    if room.kind == .group {
                        groupPeopleSection(room)
                    } else {
                        directContactSection(room)

                        Divider()

                        commonChatsSection
                    }

                    let mediaItems = sharedMediaItems(for: room)
                    if !mediaItems.isEmpty {
                        Divider()
                        sharedMediaSection(mediaItems)
                    }

                    Divider()

                    roomMetadata(room)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(MatrixDesign.screenBackground)
            .navigationTitle(room.kind == .direct ? "Contact" : "Room")
            .task(id: room.id) {
                await loadInspector(room: room)
            }
        } else {
            ContentUnavailableView(
                "No Details",
                systemImage: "sidebar.right",
                description: Text("Select a room to inspect conversation details.")
            )
            .navigationTitle("Details")
        }
    }

    private func roomHeader(_ room: MatrixRoomSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MatrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 54,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(room.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(conversationSubtitle(for: room))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    MatrixStatusPill(
                        title: room.kind == .direct ? "DM" : "Group",
                        systemImage: room.kind.systemImage,
                        tint: room.kind.tint
                    )
                    MatrixStatusPill(
                        title: room.isEncrypted ? "Encrypted" : "Unencrypted",
                        systemImage: room.isEncrypted ? "lock.fill" : "lock.open.fill",
                        tint: room.isEncrypted ? .green : .orange
                    )
                }
            }
        }
    }

    private func groupPeopleSection(_ room: MatrixRoomSummary) -> some View {
        inspectorSection(title: "People", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 10) {
                if isLoadingMembers {
                    ProgressView()
                        .controlSize(.small)
                }

                ForEach(participants(for: room)) { participant in
                    MatrixMacParticipantRow(participant: participant) {
                        if participant.canRemove {
                            Button(role: .destructive) {
                                Task {
                                    await removeUser(participant.userID, from: room)
                                }
                            } label: {
                                Image(systemName: "person.fill.xmark")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isUpdatingMembership)
                            .help("Remove from chat")
                            .accessibilityLabel("Remove \(participant.title)")
                        }
                    }
                }

                MatrixUserDirectoryPickerView(
                    model: model,
                    selection: $selectedInvitees,
                    mode: .single,
                    excludedUserIDs: memberUserIDs(for: room)
                )

                Button {
                    Task {
                        await inviteUser(to: room)
                    }
                } label: {
                    Label("Add", systemImage: "person.badge.plus")
                }
                .disabled(selectedInvitees.isEmpty || isUpdatingMembership)

                if let membershipErrorMessage {
                    Text(membershipErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func directContactSection(_ room: MatrixRoomSummary) -> some View {
        inspectorSection(title: "Contact", systemImage: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 10) {
                if let participant = counterparty(for: room) {
                    MatrixMacParticipantRow(participant: participant)
                } else {
                    Text("No contact details in the loaded timeline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let membershipErrorMessage {
                    Text(membershipErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var commonChatsSection: some View {
        inspectorSection(title: "Common Chats", systemImage: "bubble.left.and.bubble.right") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingCommonRooms {
                    ProgressView()
                        .controlSize(.small)
                } else if commonRooms.isEmpty {
                    Text("No common group chats in this account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(commonRooms) { room in
                        HStack(spacing: 10) {
                            MatrixRoomKindMark(kind: room.kind, size: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(room.lastMessagePreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sharedMediaSection(_ items: [MatrixTimelineItem]) -> some View {
        inspectorSection(title: "Shared Media", systemImage: "photo.on.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    if let attachment = item.attachment {
                        MatrixMacSharedMediaRow(item: item, attachment: attachment)
                    }
                }
            }
        }
    }

    private func roomMetadata(_ room: MatrixRoomSummary) -> some View {
        inspectorSection(title: "Metadata", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 9) {
                MatrixMacMetadataRow(title: "Room ID", value: room.id, isMonospaced: true)
                MatrixMacMetadataRow(
                    title: "Last Activity",
                    value: room.lastActivityAt.formatted(date: .abbreviated, time: .shortened)
                )
                MatrixMacMetadataRow(title: "Unread", value: "\(room.unreadCount)")

                if !room.lastMessagePreview.isEmpty {
                    MatrixMacMetadataRow(title: "Latest", value: room.lastMessagePreview)
                }
            }
        }
    }

    private func inspectorSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadInspector(room: MatrixRoomSummary) async {
        membersRoomID = room.id
        members = []
        commonRooms = []
        selectedInvitees = []
        membershipErrorMessage = nil
        isLoadingMembers = true
        defer {
            isLoadingMembers = false
        }

        do {
            let loadedMembers = try await model.members(roomID: room.id)
            guard !Task.isCancelled else {
                return
            }

            members = loadedMembers

            if room.kind == .direct,
               let counterparty = counterparty(for: room, members: loadedMembers) {
                await loadCommonRooms(with: counterparty.userID, excluding: room.id)
            }
        } catch {
            membershipErrorMessage = error.matrixUserFacingMessage
        }
    }

    private func loadCommonRooms(with userID: String, excluding roomID: String) async {
        isLoadingCommonRooms = true
        defer {
            isLoadingCommonRooms = false
        }

        var matches: [MatrixRoomSummary] = []
        for candidate in model.roomListViewModel.rooms where candidate.id != roomID && candidate.kind == .group {
            do {
                let candidateMembers = try await model.members(roomID: candidate.id)
                if candidateMembers.contains(where: { member in
                    member.membership.isActive && member.userID.caseInsensitiveCompare(userID) == .orderedSame
                }) {
                    matches.append(candidate)
                }
            } catch {
                continue
            }
        }

        guard !Task.isCancelled else {
            return
        }

        commonRooms = matches
    }

    private func inviteUser(to room: MatrixRoomSummary) async {
        guard let selectedInvitee = selectedInvitees.first else {
            return
        }

        isUpdatingMembership = true
        membershipErrorMessage = nil
        defer {
            isUpdatingMembership = false
        }

        do {
            try await model.inviteUser(selectedInvitee.userID, to: room.id)
            selectedInvitees = []
            await loadInspector(room: room)
        } catch {
            membershipErrorMessage = error.matrixUserFacingMessage
        }
    }

    private func removeUser(_ userID: String, from room: MatrixRoomSummary) async {
        isUpdatingMembership = true
        membershipErrorMessage = nil
        defer {
            isUpdatingMembership = false
        }

        do {
            try await model.removeUser(userID, from: room.id)
            await loadInspector(room: room)
        } catch {
            membershipErrorMessage = error.matrixUserFacingMessage
        }
    }

    private func conversationSubtitle(for room: MatrixRoomSummary) -> String {
        if room.kind == .direct,
           let participant = counterparty(for: room) {
            return participant.userID
        }

        if membersRoomID == room.id, !members.isEmpty {
            let count = members.filter(\.membership.isActive).count
            return "\(count) people"
        }

        return room.kind == .direct ? "Direct message" : "Group chat"
    }

    private func memberUserIDs(for room: MatrixRoomSummary) -> Set<String> {
        var userIDs = Set<String>()
        if let currentUserID = model.account?.userID ?? model.session?.userID {
            userIDs.insert(currentUserID)
        }

        if membersRoomID == room.id {
            for member in members where member.membership.isActive {
                userIDs.insert(member.userID)
            }
        }

        return userIDs
    }

    private func participants(for room: MatrixRoomSummary) -> [MatrixMacParticipant] {
        let currentUserID = model.account?.userID ?? model.session?.userID
        let activeMembers = membersRoomID == room.id ? members.filter(\.membership.isActive) : []
        if !activeMembers.isEmpty {
            return activeMembers.map { member in
                MatrixMacParticipant(
                    userID: member.userID,
                    displayName: member.displayName,
                    membership: member.membership,
                    isCurrentUser: member.userID.caseInsensitiveCompare(currentUserID ?? "") == .orderedSame
                )
            }
        }

        var participants: [MatrixMacParticipant] = []
        if let currentUserID {
            participants.append(
                MatrixMacParticipant(
                    userID: currentUserID,
                    displayName: model.account?.displayName,
                    membership: .joined,
                    isCurrentUser: true
                )
            )
        }

        for item in timelineItems(for: room) where item.sender.caseInsensitiveCompare(currentUserID ?? "") != .orderedSame {
            guard !participants.contains(where: { $0.userID.caseInsensitiveCompare(item.sender) == .orderedSame }) else {
                continue
            }

            participants.append(
                MatrixMacParticipant(
                    userID: item.sender,
                    displayName: nil,
                    membership: nil,
                    isCurrentUser: false
                )
            )
        }

        return participants
    }

    private func counterparty(
        for room: MatrixRoomSummary,
        members loadedMembers: [MatrixRoomMember]? = nil
    ) -> MatrixMacParticipant? {
        let currentUserID = model.account?.userID ?? model.session?.userID
        let sourceMembers = loadedMembers ?? (membersRoomID == room.id ? members : [])

        if let member = sourceMembers.first(where: { member in
            member.membership.isActive && member.userID.caseInsensitiveCompare(currentUserID ?? "") != .orderedSame
        }) {
            return MatrixMacParticipant(
                userID: member.userID,
                displayName: member.displayName,
                membership: member.membership,
                isCurrentUser: false
            )
        }

        if let item = timelineItems(for: room).first(where: { item in
            item.sender.caseInsensitiveCompare(currentUserID ?? "") != .orderedSame
        }) {
            return MatrixMacParticipant(
                userID: item.sender,
                displayName: nil,
                membership: nil,
                isCurrentUser: false
            )
        }

        if room.kind == .direct {
            return MatrixMacParticipant(
                userID: room.id,
                displayName: room.name,
                membership: nil,
                isCurrentUser: false
            )
        }

        return nil
    }

    private func sharedMediaItems(for room: MatrixRoomSummary) -> [MatrixTimelineItem] {
        timelineItems(for: room).filter { $0.attachment != nil }
    }

    private func timelineItems(for room: MatrixRoomSummary) -> [MatrixTimelineItem] {
        guard timelineViewModel.roomID == room.id else {
            return []
        }

        return timelineViewModel.items
    }
}

private struct MatrixMacParticipant: Identifiable {
    let userID: String
    let displayName: String?
    let membership: MatrixRoomMembership?
    let isCurrentUser: Bool

    var id: String {
        userID.lowercased()
    }

    var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }

        let localpart = userID
            .dropFirst()
            .split(separator: ":")
            .first
            .map(String.init)

        return localpart?.capitalized ?? userID
    }

    var subtitle: String {
        if isCurrentUser {
            return "You"
        }

        return userID
    }

    var canRemove: Bool {
        !isCurrentUser && membership != .left && membership != .banned
    }
}

private struct MatrixMacParticipantRow<Action: View>: View {
    let participant: MatrixMacParticipant
    @ViewBuilder let action: () -> Action

    init(
        participant: MatrixMacParticipant,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.participant = participant
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            MatrixAvatarView(
                title: participant.title,
                systemImage: "person.fill",
                size: 34,
                tint: participant.isCurrentUser ? .secondary : MatrixDesign.accent
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(participant.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let membership = participant.membership, membership != .joined {
                Text(membership.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            action()
        }
        .padding(.vertical, 3)
    }
}

private struct MatrixMacSharedMediaRow: View {
    let item: MatrixTimelineItem
    let attachment: MatrixTimelineAttachment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MatrixDesign.accent)
                .frame(width: 32, height: 32)
                .background(MatrixDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(mediaSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var mediaSubtitle: String {
        let sender = MatrixMacParticipant(
            userID: item.sender,
            displayName: nil,
            membership: nil,
            isCurrentUser: item.isLocalEcho
        ).title
        let details = attachment.subtitle.isEmpty ? sender : "\(sender) - \(attachment.subtitle)"
        return "\(details) - \(item.timestamp.formatted(date: .omitted, time: .shortened))"
    }
}

private struct MatrixMacMetadataRow: View {
    let title: String
    let value: String
    var isMonospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(isMonospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct MatrixMacRoomRow: View {
    let room: MatrixRoomSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MatrixRoomKindMark(kind: room.kind, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.headline)
                        .lineLimit(1)
                    MatrixRoomSecurityMark(isEncrypted: room.isEncrypted, size: 20)
                }

                Text(room.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(room.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if room.unreadCount > 0 {
                Text("\(room.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MatrixMacInviteRow: View {
    let invitation: MatrixRoomInvite
    let isWorking: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                MatrixRoomKindMark(kind: invitation.kind, size: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(invitation.title)
                            .font(.headline)
                            .lineLimit(1)
                        MatrixRoomSecurityMark(isEncrypted: invitation.isEncrypted, size: 20)
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

struct MatrixMacSettingsView: View {
    @ObservedObject var model: MatrixAppModel
    @ObservedObject private var deviceVerificationViewModel: DeviceVerificationViewModel
    @State private var activeTab: MatrixMacSettingsTab = .account

    init(model: MatrixAppModel) {
        self.model = model
        self._deviceVerificationViewModel = ObservedObject(wrappedValue: model.deviceVerificationViewModel)
    }

    var body: some View {
        NavigationSplitView {
            List(MatrixMacSettingsTab.allCases, selection: $activeTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle(activeTab.title)
        }
        .frame(minWidth: 760, minHeight: 620)
        .task {
            guard model.isAuthenticated else {
                return
            }

            await model.reloadDeviceVerificationStatus()
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch activeTab {
        case .account:
            accountSettings
            profileSettings
        case .security:
            securitySettings
        case .mvp:
            MatrixLimitationsView()
        }
    }

    private var accountSettings: some View {
        GroupBox("Account") {
            VStack(alignment: .leading, spacing: 12) {
                if let account = model.account {
                    LabeledContent("User", value: account.userID)
                    LabeledContent("Device", value: account.deviceID)
                } else {
                    ContentUnavailableView(
                        "Not Signed In",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Sign in from the main window before managing account settings.")
                    )
                }

                if let homeserverURL = model.session?.homeserverURL.absoluteString {
                    LabeledContent("Server", value: homeserverURL)
                }

                Divider()

                HStack(spacing: 10) {
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
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private var profileSettings: some View {
        GroupBox("Profile") {
            MatrixProfileSettingsView(model: model)
                .padding(.vertical, 4)
        }
    }

    private var securitySettings: some View {
        GroupBox("Device Verification And Recovery") {
            VStack(alignment: .leading, spacing: 12) {
                MatrixDeviceVerificationStatusView(
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
                .buttonStyle(.bordered)
                .disabled(!model.isAuthenticated || deviceVerificationViewModel.isLoading)
            }
            .padding(.vertical, 4)
        }
    }
}

private enum MatrixMacSettingsTab: String, CaseIterable, Identifiable {
    case account
    case security
    case mvp

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .account:
            return "Account"
        case .security:
            return "Security"
        case .mvp:
            return "MVP Limits"
        }
    }

    var systemImage: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .security:
            return "checkmark.shield"
        case .mvp:
            return "exclamationmark.triangle"
        }
    }
}
