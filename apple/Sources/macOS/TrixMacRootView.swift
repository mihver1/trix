import AppKit
import SwiftUI

struct TrixMacRootView: View {
    @ObservedObject var model: TrixAppModel

    var body: some View {
        Group {
            if model.isStarting {
                TrixStartupRestoreView(status: model.startupStatus)
            } else if model.isAuthenticated {
                TrixMacWorkspaceView(model: model)
            } else {
                TrixLoginView(model: model)
                    .frame(minWidth: 520, minHeight: 520)
            }
        }
        .task {
            await model.start()
        }
    }
}

private struct TrixMacWorkspaceView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var callViewModel: TrixCallViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isShowingNewRoom = false
    @State private var isWorkspaceWindowActive = true

    init(model: TrixAppModel) {
        self.model = model
        self._callViewModel = ObservedObject(wrappedValue: model.callViewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            TrixActiveCallSurfaceHost(model: model, placement: .workspace)

            NavigationSplitView {
                TrixMacRoomListView(model: model)
                    .navigationTitle("Trix")
                    .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
            } content: {
                TrixMacTimelineColumn(model: model)
                    .navigationSplitViewColumnWidth(min: 480, ideal: 640)
            } detail: {
                TrixMacRoomContextView(model: model, room: model.selectedRoom)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
            }
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
            TrixNewRoomView(model: model)
        }
        .background {
            TrixMacWindowActivityObserver { isActive in
                isWorkspaceWindowActive = isActive
            }
        }
        .task(id: scenePhase) {
            await model.setApplicationIsActive(scenePhase == .active)
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
        .task(id: activeCallWindowToken) {
            guard activeCallWindowToken != nil else {
                dismissWindow(id: TrixActiveCallWindowID)
                return
            }

            openWindow(id: TrixActiveCallWindowID)
        }
    }

    private var activeCallWindowToken: String? {
        guard !isWorkspaceWindowActive else {
            return nil
        }

        return TrixActiveCallPresentation.presentation(model: model)?.id
    }
}

private struct TrixMacWindowActivityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attachSoon(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.attachSoon(to: nsView)
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        var onChange: (Bool) -> Void
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        func attachSoon(to view: NSView) {
            DispatchQueue.main.async { @MainActor [weak self, weak view] in
                guard let self, let window = view?.window else {
                    return
                }

                self.attach(to: window)
            }
        }

        private func attach(to window: NSWindow) {
            guard observedWindow !== window else {
                publish(window)
                return
            }

            removeObservers()
            observedWindow = window

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishObservedWindow()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishObservedWindow()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishObservedWindow()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishObservedWindow()
                    }
                },
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: NSApplication.shared,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishObservedWindow()
                    }
                },
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApplication.shared,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishObservedWindow()
                    }
                },
            ]

            publish(window)
        }

        private func publishObservedWindow() {
            guard let observedWindow else {
                return
            }

            publish(observedWindow)
        }

        private func publish(_ window: NSWindow) {
            onChange(NSApplication.shared.isActive && window.isKeyWindow && !window.isMiniaturized)
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }
    }
}

private struct TrixMacRoomListView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel
    @ObservedObject private var callViewModel: TrixCallViewModel
    @State private var directSearchUserIDInProgress: String?
    @StateObject private var roomSearchViewModel = TrixUserDirectorySearchViewModel()

    init(model: TrixAppModel) {
        self.model = model
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
        self._callViewModel = ObservedObject(wrappedValue: model.callViewModel)
    }

    var body: some View {
        List(selection: selectedRoomBinding) {
            searchSection

            Section {
                if roomListViewModel.rooms.isEmpty {
                    ContentUnavailableView(
                        "No Rooms",
                        systemImage: "bubble.left",
                        description: Text("Create a room or accept an invite.")
                    )
                } else if visibleRooms.isEmpty {
                    Text("No matching chats")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(visibleRooms) { room in
                        TrixMacRoomRow(
                            room: room,
                            notificationProfile: model.roomNotificationProfile(for: room.id),
                            callIndicator: TrixRoomCallIndicator(state: callViewModel.callLifecycleState(roomID: room.id))
                        )
                            .tag(room.id as String?)
                            .contentShape(Rectangle())
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

            peopleSection

            if !roomListViewModel.invitations.isEmpty {
                Section("Invites") {
                    ForEach(roomListViewModel.invitations) { invitation in
                        TrixMacInviteRow(
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
        .task(id: roomSearchViewModel.query) {
            await roomSearchViewModel.search(
                excluding: searchExcludedUserIDs,
                limit: 20,
                searchUsers: { query, limit in
                    try await model.searchUsers(query, limit: limit)
                }
            )
        }
    }

    private var selectedRoomBinding: Binding<String?> {
        Binding(
            get: { model.selectedRoomID },
            set: { roomID in
                selectRoom(roomID: roomID)
            }
        )
    }

    private func selectRoom(roomID: String?) {
        guard let roomID else {
            model.selectedRoomID = nil
            return
        }

        guard let room = roomListViewModel.rooms.first(where: { $0.id == roomID }) else {
            model.selectedRoomID = roomID
            return
        }

        openRoom(room)
    }

    private func openRoom(_ room: TrixRoomSummary) {
        model.prepareRoomSelection(room)
        Task {
            await model.selectRoom(room)
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            TrixRoomSearchField(
                query: $roomSearchViewModel.query,
                isSearching: roomSearchViewModel.isSearching
            )

            if let errorMessage = roomSearchViewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if shouldShowNoSearchMatches {
                Text("No matches")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if roomSearchViewModel.isLimited {
                Text("More people available")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        if !directoryPeopleResults.isEmpty {
            Section("People") {
                ForEach(directoryPeopleResults) { profile in
                    Button {
                        openDirectoryUser(profile)
                    } label: {
                        TrixRoomDirectoryUserSearchRow(
                            profile: profile,
                            isWorking: isCreatingDirectRoom(for: profile)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(directSearchUserIDInProgress != nil)
                }
            }
        }
    }

    private func openDirectoryUser(_ profile: TrixUserProfile) {
        if let existingRoom = existingDirectRoom(for: profile) {
            openRoom(existingRoom)
            return
        }

        directSearchUserIDInProgress = profile.userID
        Task {
            _ = await model.createEncryptedDirectRoom(
                inviteeUserID: profile.userID,
                roomName: profile.title
            )
            directSearchUserIDInProgress = nil
        }
    }

    private func existingDirectRoom(for profile: TrixUserProfile) -> TrixRoomSummary? {
        roomListViewModel.rooms.first { room in
            room.kind == .direct &&
                room.id.caseInsensitiveCompare(profile.userID) == .orderedSame
        }
    }

    private func isCreatingDirectRoom(for profile: TrixUserProfile) -> Bool {
        guard let userID = directSearchUserIDInProgress else {
            return false
        }

        return userID.caseInsensitiveCompare(profile.userID) == .orderedSame
    }

    private var visibleRooms: [TrixRoomSummary] {
        TrixRoomSearch.matchingRooms(
            roomListViewModel.rooms,
            query: roomSearchViewModel.query,
            directoryResults: roomSearchViewModel.results
        )
    }

    private var directoryPeopleResults: [TrixUserProfile] {
        TrixRoomSearch.peopleResults(
            roomSearchViewModel.results,
            query: roomSearchViewModel.query,
            rooms: roomListViewModel.rooms,
            currentUserID: model.session?.userID
        )
    }

    private var shouldShowNoSearchMatches: Bool {
        !TrixRoomSearch.normalizedQuery(roomSearchViewModel.query).isEmpty &&
            !roomSearchViewModel.isSearching &&
            visibleRooms.isEmpty &&
            directoryPeopleResults.isEmpty &&
            roomSearchViewModel.errorMessage == nil
    }

    private var searchExcludedUserIDs: Set<String> {
        guard let userID = model.session?.userID else {
            return []
        }

        return [userID]
    }
}

private struct TrixMacTimelineColumn: View {
    @ObservedObject var model: TrixAppModel

    var body: some View {
        if let selectedRoom = model.selectedRoom {
            TrixTimelineView(model: model, room: selectedRoom)
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

private struct TrixMacRoomContextView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var timelineViewModel: TimelineViewModel
    let room: TrixRoomSummary?
    @State private var selectedInvitees: [TrixUserProfile] = []
    @State private var members: [TrixRoomMember] = []
    @State private var commonRooms: [TrixRoomSummary] = []
    @State private var directUserActivity: TrixUserActivity?
    @State private var membersRoomID: String?
    @State private var membershipErrorMessage: String?
    @State private var isLoadingMembers = false
    @State private var isLoadingCommonRooms = false
    @State private var isUpdatingMembership = false
    @State private var isCommonChatsExpanded = true
    @State private var isSharedMediaExpanded = true

    init(model: TrixAppModel, room: TrixRoomSummary?) {
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
            .background(TrixDesign.screenBackground)
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

    @ViewBuilder
    private func roomHeader(_ room: TrixRoomSummary) -> some View {
        if room.kind == .direct {
            directRoomHeader(room)
        } else {
            groupRoomHeader(room)
        }
    }

    private func directRoomHeader(_ room: TrixRoomSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 50,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(room.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                TrixUserActivityIndicator(
                    activity: directUserActivity,
                    font: .callout,
                    foregroundStyle: .secondary
                )
            }

            Spacer(minLength: 8)

            TrixRoomSecurityMark(isEncrypted: room.isEncrypted, size: 22)
                .help(room.isEncrypted ? "Encrypted" : "Not encrypted")
        }
    }

    private func groupRoomHeader(_ room: TrixRoomSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 50,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(room.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(conversationSubtitle(for: room))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            TrixRoomSecurityMark(isEncrypted: room.isEncrypted, size: 22)
                .help(room.isEncrypted ? "Encrypted" : "Not encrypted")
        }
    }

    private func groupPeopleSection(_ room: TrixRoomSummary) -> some View {
        inspectorSection(title: "People", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 10) {
                if isLoadingMembers {
                    ProgressView()
                        .controlSize(.small)
                }

                ForEach(participants(for: room)) { participant in
                    TrixMacParticipantRow(participant: participant) {
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

                TrixUserDirectoryPickerView(
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

    private var commonChatsSection: some View {
        inspectorCollapsibleSection(
            title: "Common Chats",
            systemImage: "bubble.left.and.bubble.right",
            count: commonRooms.count,
            isExpanded: $isCommonChatsExpanded
        ) {
            boundedInspectorList(
                itemCount: commonRooms.count,
                scrollThreshold: 4,
                maxHeight: 168
            ) {
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
                        Button {
                            openRoom(room)
                        } label: {
                            TrixMacCommonRoomRow(room: room)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(room.name)")
                        .accessibilityLabel("Open \(room.name)")
                    }
                }
            }
        }
    }

    private func sharedMediaSection(_ items: [TrixTimelineItem]) -> some View {
        inspectorCollapsibleSection(
            title: "Shared Media",
            systemImage: "photo.on.rectangle",
            count: items.count,
            isExpanded: $isSharedMediaExpanded
        ) {
            boundedInspectorList(
                itemCount: items.count,
                scrollThreshold: 5,
                maxHeight: 300
            ) {
                ForEach(items) { item in
                    if let attachment = item.attachment {
                        TrixMacSharedMediaRow(
                            item: item,
                            attachment: attachment,
                            preview: timelineViewModel.inlineAttachmentPreviews[item.id],
                            isDownloading: timelineViewModel.downloadingAttachmentID == item.id,
                            isLoadingPreview: timelineViewModel.inlineAttachmentPreviewLoadingIDs.contains(item.id),
                            previewFailure: timelineViewModel.inlineAttachmentPreviewFailures[item.id],
                            open: {
                                Task {
                                    await model.downloadAttachment(for: item)
                                }
                            },
                            loadPreview: {
                                Task {
                                    await model.loadInlineAttachmentPreview(for: item)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private func roomMetadata(_ room: TrixRoomSummary) -> some View {
        inspectorSection(title: "Metadata", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 9) {
                TrixMacMetadataRow(title: "Room ID", value: room.id, isMonospaced: true)
                TrixMacMetadataRow(
                    title: "Last Activity",
                    value: room.lastActivityAt.formatted(date: .abbreviated, time: .shortened)
                )
                TrixMacMetadataRow(title: "Unread", value: "\(room.unreadCount)")

                if !room.lastMessagePreview.isEmpty {
                    TrixMacMetadataRow(title: "Latest", value: room.lastMessagePreview)
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

    private func inspectorCollapsibleSection<Content: View>(
        title: String,
        systemImage: String,
        count: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: isExpanded.wrappedValue ? 10 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)

                    Spacer(minLength: 8)

                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(TrixDesign.secondarySurface, in: Capsule())

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")

            if isExpanded.wrappedValue {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func boundedInspectorList<Content: View>(
        itemCount: Int,
        scrollThreshold: Int,
        maxHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if itemCount > scrollThreshold {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func loadInspector(room: TrixRoomSummary) async {
        membersRoomID = room.id
        members = []
        commonRooms = []
        directUserActivity = nil
        selectedInvitees = []
        membershipErrorMessage = nil
        isLoadingMembers = true
        defer {
            isLoadingMembers = false
        }

        if room.kind == .direct {
            await loadDirectUserActivity(userID: room.id)
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
            membershipErrorMessage = error.trixUserFacingMessage
        }
    }

    private func loadDirectUserActivity(userID: String) async {
        do {
            directUserActivity = try await model.userActivity(userID: userID)
        } catch {
            directUserActivity = .unknown
        }
    }

    private func loadCommonRooms(with userID: String, excluding roomID: String) async {
        isLoadingCommonRooms = true
        defer {
            isLoadingCommonRooms = false
        }

        var matches: [TrixRoomSummary] = []
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

    private func inviteUser(to room: TrixRoomSummary) async {
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
            membershipErrorMessage = error.trixUserFacingMessage
        }
    }

    private func removeUser(_ userID: String, from room: TrixRoomSummary) async {
        isUpdatingMembership = true
        membershipErrorMessage = nil
        defer {
            isUpdatingMembership = false
        }

        do {
            try await model.removeUser(userID, from: room.id)
            await loadInspector(room: room)
        } catch {
            membershipErrorMessage = error.trixUserFacingMessage
        }
    }

    private func openRoom(_ room: TrixRoomSummary) {
        model.prepareRoomSelection(room)
        Task {
            await model.selectRoom(room)
        }
    }

    private func conversationSubtitle(for room: TrixRoomSummary) -> String {
        if room.kind == .direct,
           let participant = counterparty(for: room) {
            return participant.subtitle
        }

        if membersRoomID == room.id, !members.isEmpty {
            let count = members.filter(\.membership.isActive).count
            return "\(count) people"
        }

        return room.kind == .direct ? "Direct message" : "Group chat"
    }

    private func memberUserIDs(for room: TrixRoomSummary) -> Set<String> {
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

    private func participants(for room: TrixRoomSummary) -> [TrixMacParticipant] {
        let currentUserID = model.account?.userID ?? model.session?.userID
        let activeMembers = membersRoomID == room.id ? members.filter(\.membership.isActive) : []
        if !activeMembers.isEmpty {
            return activeMembers.map { member in
                TrixMacParticipant(
                    userID: member.userID,
                    displayName: member.displayName,
                    avatarURL: avatarURL(for: member, currentUserID: currentUserID),
                    membership: member.membership,
                    isCurrentUser: member.userID.caseInsensitiveCompare(currentUserID ?? "") == .orderedSame
                )
            }
        }

        var participants: [TrixMacParticipant] = []
        if let currentUserID {
            participants.append(
                TrixMacParticipant(
                    userID: currentUserID,
                    displayName: model.account?.displayName,
                    avatarURL: model.ownProfile?.avatarURL,
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
                TrixMacParticipant(
                    userID: item.sender,
                    displayName: nil,
                    avatarURL: nil,
                    membership: nil,
                    isCurrentUser: false
                )
            )
        }

        return participants
    }

    private func avatarURL(for member: TrixRoomMember, currentUserID: String?) -> String? {
        if member.userID.caseInsensitiveCompare(currentUserID ?? "") == .orderedSame,
           let avatarURL = model.ownProfile?.avatarURL {
            return avatarURL
        }

        return member.avatarURL
    }

    private func counterparty(
        for room: TrixRoomSummary,
        members loadedMembers: [TrixRoomMember]? = nil
    ) -> TrixMacParticipant? {
        let currentUserID = model.account?.userID ?? model.session?.userID
        let sourceMembers = loadedMembers ?? (membersRoomID == room.id ? members : [])

        if let member = sourceMembers.first(where: { member in
            member.membership.isActive && member.userID.caseInsensitiveCompare(currentUserID ?? "") != .orderedSame
        }) {
            return TrixMacParticipant(
                userID: member.userID,
                displayName: member.displayName,
                avatarURL: avatarURL(for: member, currentUserID: currentUserID),
                membership: member.membership,
                isCurrentUser: false
            )
        }

        if let item = timelineItems(for: room).first(where: { item in
            item.sender.caseInsensitiveCompare(currentUserID ?? "") != .orderedSame
        }) {
            return TrixMacParticipant(
                userID: item.sender,
                displayName: nil,
                avatarURL: nil,
                membership: nil,
                isCurrentUser: false
            )
        }

        if room.kind == .direct {
            return TrixMacParticipant(
                userID: room.id,
                displayName: room.name,
                avatarURL: nil,
                membership: nil,
                isCurrentUser: false
            )
        }

        return nil
    }

    private func sharedMediaItems(for room: TrixRoomSummary) -> [TrixTimelineItem] {
        timelineItems(for: room).filter { $0.attachment != nil }
    }

    private func timelineItems(for room: TrixRoomSummary) -> [TrixTimelineItem] {
        guard timelineViewModel.roomID == room.id else {
            return []
        }

        return timelineViewModel.items
    }
}

private struct TrixMacParticipant: Identifiable {
    let userID: String
    let displayName: String?
    let avatarURL: String?
    let membership: TrixRoomMembership?
    let isCurrentUser: Bool

    var id: String {
        userID.lowercased()
    }

    var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }

        return TrixUserIdentity.displayName(from: userID)
    }

    var subtitle: String {
        if isCurrentUser {
            return "You"
        }

        return TrixUserIdentity.handle(from: userID)
    }

    var canRemove: Bool {
        !isCurrentUser && membership != .left && membership != .banned
    }
}

private struct TrixMacParticipantRow<Action: View>: View {
    let participant: TrixMacParticipant
    @ViewBuilder let action: () -> Action

    init(
        participant: TrixMacParticipant,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.participant = participant
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            TrixAvatarView(
                title: participant.title,
                systemImage: "person.fill",
                size: 34,
                avatarURL: participant.avatarURL,
                tint: participant.isCurrentUser ? .secondary : TrixDesign.accent
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

private struct TrixMacCommonRoomRow: View {
    let room: TrixRoomSummary

    var body: some View {
        HStack(spacing: 10) {
            TrixRoomKindMark(kind: room.kind, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(room.lastMessagePreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct TrixMacSharedMediaRow: View {
    let item: TrixTimelineItem
    let attachment: TrixTimelineAttachment
    let preview: TrixAttachmentDownload?
    let isDownloading: Bool
    let isLoadingPreview: Bool
    let previewFailure: String?
    let open: () -> Void
    let loadPreview: () -> Void

    var body: some View {
        Button {
            guard attachment.isDownloadable, !isDownloading else {
                return
            }

            open()
        } label: {
            HStack(spacing: 10) {
                TrixMacSharedMediaThumbnail(
                    attachment: attachment,
                    preview: preview,
                    isLoading: isLoadingPreview
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachmentTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Text(mediaSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if previewFailure != nil {
                        Text("Preview unavailable")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: attachment.isDownloadable ? "eye.circle" : "lock.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(attachment.isDownloadable ? .secondary : .tertiary)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDownloading || !attachment.isDownloadable)
        .help(attachment.isDownloadable ? "Open \(attachment.filename)" : "Attachment is not available for download")
        .accessibilityLabel("Open \(attachment.filename)")
        .task(id: item.id) {
            guard preview == nil,
                  !isLoadingPreview,
                  previewFailure == nil,
                  TrixInlineMediaPreviewSupport.canAttemptInlinePreview(attachment) else {
                return
            }

            loadPreview()
        }
    }

    private var attachmentTitle: String {
        attachment.isSticker ? (attachment.stickerMetadata?.packTitle ?? "Sticker") : attachment.filename
    }

    private var mediaSubtitle: String {
        let sender = TrixMacParticipant(
            userID: item.sender,
            displayName: nil,
            avatarURL: nil,
            membership: nil,
            isCurrentUser: item.isLocalEcho
        ).title
        let details = attachment.subtitle.isEmpty ? sender : "\(sender) - \(attachment.subtitle)"
        return "\(details) - \(item.timestamp.formatted(date: .omitted, time: .shortened))"
    }
}

private struct TrixMacSharedMediaThumbnail: View {
    let attachment: TrixTimelineAttachment
    let preview: TrixAttachmentDownload?
    let isLoading: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TrixDesign.accent.opacity(0.12))

            if let preview, let image = platformImage(from: preview.data) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TrixDesign.accent)
            }
        }
        .frame(width: 36, height: 36)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }

    private var placeholderSystemImage: String {
        if attachment.isSticker {
            return "face.smiling"
        }

        return attachment.isImage ? "photo" : "doc"
    }

    private func platformImage(from data: Data) -> Image? {
        guard let image = NSImage(data: data) else {
            return nil
        }

        return Image(nsImage: image)
    }
}

private struct TrixMacMetadataRow: View {
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

private struct TrixMacRoomRow: View {
    let room: TrixRoomSummary
    let notificationProfile: TrixRoomNotificationProfile
    let callIndicator: TrixRoomCallIndicator?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 34,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.headline)
                        .lineLimit(1)
                    TrixRoomSecurityMark(isEncrypted: room.isEncrypted, size: 20)
                    TrixRoomNotificationProfileMark(profile: notificationProfile, size: 18)
                    if let callIndicator {
                        TrixRoomCallIndicatorMark(indicator: callIndicator)
                    }
                }

                Text(room.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .trailing) {
                    Text(room.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask {
                            TrixTrailingFadeMask(width: previewFadeWidth)
                        }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TrixRelativeLastActivityText(
                            date: room.lastActivityAt,
                            font: .caption2.weight(room.unreadCount > 0 ? .semibold : .regular),
                            foregroundStyle: room.unreadCount > 0 ? Color.primary : Color.secondary
                        )

                        if room.unreadCount > 0 {
                            unreadBadge
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var unreadBadge: some View {
        Text(room.unreadCount > 99 ? "99+" : "\(room.unreadCount)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(TrixDesign.accent, in: Capsule())
            .foregroundStyle(.white)
    }

    private var previewFadeWidth: CGFloat {
        room.unreadCount > 0 ? 108 : 72
    }
}

private struct TrixMacInviteRow: View {
    let invitation: TrixRoomInvite
    let isWorking: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TrixAvatarView(
                    title: invitation.kind == .direct ? invitation.inviterLabel : invitation.title,
                    systemImage: invitation.kind.systemImage,
                    size: 34,
                    tint: invitation.kind.tint
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
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

struct TrixMacSettingsView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel
    @ObservedObject private var deviceVerificationViewModel: DeviceVerificationViewModel
    @State private var activeTab: TrixMacSettingsTab = .account

    init(model: TrixAppModel) {
        self.model = model
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
        self._deviceVerificationViewModel = ObservedObject(wrappedValue: model.deviceVerificationViewModel)
    }

    var body: some View {
        NavigationSplitView {
            List(TrixMacSettingsTab.allCases, selection: $activeTab) { tab in
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
            passwordSettings
        case .invites:
            inviteSettings
        case .security:
            securitySettings
        case .diagnostics:
            diagnosticsSettings
        case .mvp:
            TrixLimitationsView()
        }
    }

    private var accountSettings: some View {
        GroupBox("Account") {
            VStack(alignment: .leading, spacing: 12) {
                if let account = model.account {
                    LabeledContent("User", value: TrixUserIdentity.handle(from: account.userID))
                    LabeledContent("Device", value: account.deviceID)
                } else {
                    ContentUnavailableView(
                        "Not Signed In",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Sign in from the main window before managing account settings.")
                    )
                }

                LabeledContent("Connection", value: model.isAuthenticated ? "Session restored" : "Signed out")
                LabeledContent("Last checked", value: lastCheckedLabel)

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

                if let sessionCleanupMessage = model.sessionCleanupMessage {
                    Text(sessionCleanupMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var profileSettings: some View {
        GroupBox("Profile") {
            TrixProfileSettingsView(model: model)
                .padding(.vertical, 4)
        }
    }

    private var passwordSettings: some View {
        GroupBox("Password") {
            TrixPasswordChangeView(model: model)
                .padding(.vertical, 4)
        }
    }

    private var inviteSettings: some View {
        GroupBox("Invite Codes") {
            TrixInviteIssueView(model: model)
                .padding(.vertical, 4)
        }
    }

    private var securitySettings: some View {
        GroupBox("Device Verification And Recovery") {
            VStack(alignment: .leading, spacing: 12) {
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
                    revokeOwnDevice: { device in
                        Task {
                            await model.revokeOwnDevice(device)
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

    private var diagnosticsSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Server", value: "Trix private server")
                    LabeledContent("State", value: model.isAuthenticated ? "Session restored" : "Signed out")
                    LabeledContent("Last checked", value: lastCheckedLabel)

                    Button {
                        Task {
                            await model.reloadRooms()
                        }
                    } label: {
                        Label("Refresh Connection", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isAuthenticated)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Push") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Status", value: pushRegistrationStatus)
                    if let registration = model.pushRegistration {
                        LabeledContent("Environment", value: registration.environment.rawValue)
                        LabeledContent("Provider", value: registration.provider)
                        LabeledContent("Gateway", value: "Configured")
                    } else if let blocker = model.pushRegistrationBlocker {
                        Text(blockerExplanation(blocker))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Redacted Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(diagnosticRows, id: \.0) { title, value in
                        LabeledContent(title, value: value)
                    }

                    Text("Diagnostics are local and redacted: no passwords, APNs tokens, OMEMO secrets, private keys, or decrypted message bodies are shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var pushRegistrationStatus: String {
        if model.pushRegistration != nil {
            return "Registered"
        }

        return model.pushRegistrationBlocker?.label ?? "Unknown"
    }

    private var lastCheckedLabel: String {
        guard let lastRoomRefreshAt = model.lastRoomRefreshAt else {
            return "Not checked"
        }

        return lastRoomRefreshAt.formatted(date: .abbreviated, time: .standard)
    }

    private var diagnosticRows: [(String, String)] {
        [
            ("Account", model.account.map { TrixUserIdentity.handle(from: $0.userID) } ?? "Signed out"),
            ("Server", "Trix private server"),
            ("Rooms", "\(roomListViewModel.rooms.count)"),
            ("Invites", "\(roomListViewModel.invitations.count)"),
            ("Unread", "\(totalUnreadCount)"),
            ("Push", pushRegistrationStatus),
            ("Device trust", deviceVerificationViewModel.status?.state.label ?? "Unknown"),
        ]
    }

    private var totalUnreadCount: Int {
        roomListViewModel.rooms.reduce(0) { partialResult, room in
            partialResult + max(room.unreadCount, 0)
        }
    }

    private func blockerExplanation(_ blocker: TrixPushRegistrationBlocker) -> String {
        switch blocker {
        case .waitingForAPNsToken:
            return "The app has not received an APNs device token in this run."
        case .waitingForSession:
            return "Sign in before registering this device for push notifications."
        case .pushGatewayUnavailable:
            return "The XMPP push gateway could not be reached from this client."
        case .registrationFailed:
            return "XMPP push registration failed. Refresh after the gateway and account are available."
        }
    }
}

private enum TrixMacSettingsTab: String, CaseIterable, Identifiable {
    case account
    case invites
    case security
    case diagnostics
    case mvp

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .account:
            return "Account"
        case .invites:
            return "Invites"
        case .security:
            return "Security"
        case .diagnostics:
            return "Diagnostics"
        case .mvp:
            return "MVP Limits"
        }
    }

    var systemImage: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .invites:
            return "envelope.badge"
        case .security:
            return "checkmark.shield"
        case .diagnostics:
            return "waveform.path.ecg"
        case .mvp:
            return "exclamationmark.triangle"
        }
    }
}
