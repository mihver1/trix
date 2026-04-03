import SwiftUI
import UniformTypeIdentifiers

private let workspaceQuickReactionEmojis: [String] = {
    let emojis = ffiDefaultQuickReactionEmojis()
    return emojis.isEmpty ? ["👍", "❤️", "🔥", "👎", "💔", "🤔", "😕", "🤨", "😡", "🤡", "💩", "🗿"] : emojis
}()

private enum SettingsTab: String, CaseIterable, Identifiable {
    case profile
    case devices
    case notifications
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile:
            return "Profile"
        case .devices:
            return "Devices"
        case .notifications:
            return "Notifications"
        case .advanced:
            return "Advanced"
        }
    }

    var iconName: String {
        switch self {
        case .profile:
            return "person.crop.circle"
        case .devices:
            return "laptopcomputer.and.iphone"
        case .notifications:
            return "bell"
        case .advanced:
            return "gearshape.2"
        }
    }
}

struct WorkspaceView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let availableSize: CGSize
    @State private var composerDraft = ""
    @State private var isPresentingCreateChat = false
    @State private var isPresentingSettings = false
    @State private var activeSettingsTab: SettingsTab = .profile
    @State private var isImportingAttachment = false
    @State private var memberSearchQuery = ""
    @State private var memberSearchResults: [DirectoryAccountSummary] = []

    private var prefersSingleColumn: Bool {
        availableSize.width < 1380 || availableSize.height < 860
    }

    private var timelineUsesLocalData: Bool {
        !presentedTimelineMessages.isEmpty
    }

    private var timelineUsesEncryptedFallback: Bool {
        presentedTimelineMessages.isEmpty && !presentedHistoryMessages.isEmpty
    }

    private var presentationAccountID: UUID? {
        model.chatPresentationAccountID
    }

    private var canManageSelectedChatMembers: Bool {
        model.selectedChatDetail?.chatType == .group
    }

    private var canManageSelectedChatDevices: Bool {
        model.selectedChatDetail?.chatType == .group
    }

    private var detailPaneWidth: CGFloat {
        min(max(286, availableSize.width * 0.24), 340)
    }

    private var selectedChatType: ChatType? {
        model.selectedChatListItem?.chatType ?? model.selectedChatSummary?.chatType
    }

    private var previewedAttachmentBinding: Binding<PreviewedAttachmentFile?> {
        Binding(
            get: { model.previewedAttachment },
            set: { model.previewedAttachment = $0 }
        )
    }

    private var presentedTimelineMessages: [PresentedTimelineMessage] {
        model.selectedChatTimelineItems
            .filter(\.isVisibleInTimeline)
            .map { message in
            PresentedTimelineMessage(
                message: message,
                receiptStatus: message.isOutgoing
                    ? message.receiptStatus.flatMap(WorkspaceMessageReceiptStatus.init)
                    : nil
            )
        }
    }

    private var presentedHistoryMessages: [PresentedHistoryMessage] {
        model.selectedChatHistory.compactMap { message in
            guard message.contentType != .receipt else {
                return nil
            }

            return PresentedHistoryMessage(
                message: message,
                isOutgoing: presentationAccountID.map { $0 == message.senderAccountId } ?? false
            )
        }
    }

    var body: some View {
        if let currentAccount = model.currentAccount {
            HStack(alignment: .top, spacing: 18) {
                messengerColumn(currentAccount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                chatInfoInspector(currentAccount)
                    .frame(width: detailPaneWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(isPresented: $isPresentingCreateChat) {
                CreateChatSheet(
                    model: model,
                    isPresented: $isPresentingCreateChat
                ) {}
            }
            .sheet(item: previewedAttachmentBinding) { attachment in
                AttachmentPreviewSheet(attachment: attachment)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        model.resetCreateChatComposer()
                        isPresentingCreateChat = true
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }

                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImportingAttachment,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    if let fileURL = urls.first {
                        model.importComposerAttachment(from: fileURL)
                    }
                case let .failure(error):
                    model.lastErrorMessage = error.trixUserFacingMessage
                }
            }
            .onChange(of: model.selectedChatID, initial: false) { _, _ in
                model.updateTypingState(for: nil, draftText: "")
                composerDraft = ""
                memberSearchQuery = ""
                memberSearchResults = []
            }
            .onChange(of: composerDraft, initial: false) { _, newValue in
                model.updateTypingState(for: model.selectedChatID, draftText: newValue)
            }
            .task(id: model.visibleLocalChatListItems.first?.chatId) {
                guard model.selectedChatID == nil, let firstChat = model.visibleLocalChatListItems.first else {
                    return
                }
                await model.selectChat(firstChat.chatId)
            }
        } else {
            TrixPanel(
                title: restoreSessionPanelTitle,
                subtitle: restoreSessionPanelSubtitle
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if model.storedSessionRecoveryMode != .reconnect {
                        Text(restoreSessionPanelDescription)
                            .foregroundStyle(colors.inkMuted)

                        Button(role: .destructive) {
                            model.signOut()
                        } label: {
                            Label("Forget This Device", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: 220)
                    } else {
                        Text(restoreSessionPanelDescription)
                            .foregroundStyle(colors.inkMuted)

                        Button {
                            Task {
                                await model.restoreSession()
                            }
                        } label: {
                            Label(
                                model.isRestoringSession ? "Reconnecting…" : "Reconnect",
                                systemImage: "arrow.clockwise.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: 220)
                        .disabled(model.isRestoringSession)
                        .accessibilityIdentifier(TrixMacAccessibilityID.Restore.reconnectButton)
                    }
                }
            }
        }
    }

    private func messengerColumn(_ currentAccount: AccountProfileResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            conversationHeader

            if let selectedChatListItem = model.selectedChatListItem ?? fallbackSelectedChatListItem(currentAccountID: currentAccount.accountId) {
                VStack(alignment: .leading, spacing: 16) {
                    conversationTimeline()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    composerPanel(chatTitle: selectedChatListItem.displayTitle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyConversationState
            }
        }
    }

    private var conversationHeader: some View {
        TrixSurface(emphasized: true, cornerRadius: 26) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    ConversationAvatar(
                        title: selectedChatTitle,
                        chatType: selectedChatType
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedChatTitle)
                            .font(availableSize.height < 760 ? .title3.weight(.semibold) : .title2.weight(.semibold))
                            .foregroundStyle(colors.ink)

                        Text(toolbarSubtitle)
                            .font(.callout)
                            .foregroundStyle(colors.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 20)

                    if model.isLoadingSelectedChat {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    if let selectedChatTypeLabel {
                        InlineMeta(label: selectedChatTypeLabel)
                    }

                    if let detail = model.selectedChatDetail {
                        InlineMeta(label: "\(detail.members.count) people")
                        InlineMeta(label: "\(detail.deviceMembers.count) devices")
                    } else if timelineUsesEncryptedFallback {
                        InlineMeta(label: "Encrypted history")
                    }

                    if model.isRefreshingWorkspace {
                        InlineMeta(label: "Syncing workspace")
                    }
                }
            }
            .padding(20)
        }
    }

    private var selectedChatTitle: String {
        if let selectedChatListItem = model.selectedChatListItem {
            return selectedChatListItem.displayTitle
        }

        if let selectedChatSummary = model.selectedChatSummary {
            return selectedChatSummary.displayTitle(for: presentationAccountID)
        }

        return "Messages"
    }

    private var selectedChatTypeLabel: String? {
        switch selectedChatType {
        case .dm:
            return "Direct Message"
        case .group:
            return "Group Chat"
        case .accountSync:
            return "Account Sync"
        case .none:
            return nil
        }
    }

    private var toolbarSubtitle: String {
        if let selectedChatListItem = model.selectedChatListItem {
            return selectedChatListItem.participantSubtitle(for: presentationAccountID)
        }

        if let selectedChatSummary = model.selectedChatSummary {
            return selectedChatSummary.subtitle(for: presentationAccountID)
        }

        return "Choose a conversation from the chat list."
    }

    private var emptyConversationState: some View {
        TrixSurface(emphasized: true, cornerRadius: 28) {
            ContentUnavailableView {
                Label("Choose a Conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Pick a chat from the sidebar or start a new one from the toolbar.")
            } actions: {
                Button {
                    model.resetCreateChatComposer()
                    isPresentingCreateChat = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var restoreSessionPanelTitle: String {
        switch model.storedSessionRecoveryMode {
        case .reconnect:
            "Restore Session"
        case .relinkRequired, .localKeysMissing:
            "Relink This Mac"
        }
    }

    private var restoreSessionPanelSubtitle: String {
        switch model.storedSessionRecoveryMode {
        case .reconnect:
            "A local device profile exists, but the app still needs to re-authenticate against the server."
        case .relinkRequired:
            "The local device profile is still on this Mac, but the server no longer recognizes it as an active device."
        case .localKeysMissing:
            "The saved session is still present, but this Mac no longer has the device keys required to decrypt history or re-authenticate."
        }
    }

    private var restoreSessionPanelDescription: String {
        switch model.storedSessionRecoveryMode {
        case .reconnect:
            "Reconnect to reload account metadata, device state and encrypted chat history."
        case .relinkRequired:
            "Reconnect cannot succeed anymore. Forget this broken device session, then link this Mac again from another trusted device."
        case .localKeysMissing:
            "Reconnect cannot succeed because the local device keys are missing. Forget this broken device session, then link this Mac again from another trusted device."
        }
    }

    private var settingsSheet: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $activeSettingsTab) { tab in
                Label(tab.title, systemImage: tab.iconName)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresentingSettings = false
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .frame(minWidth: 960, minHeight: 720)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch activeSettingsTab {
        case .profile:
            profileSettingsPanel
        case .devices:
            devicesSettingsPanel
        case .notifications:
            notificationsSettingsPanel
        case .advanced:
            advancedSettingsPanel
        }
    }

    private var profileSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Profile",
                subtitle: "This is how your account appears in directory search and conversations."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    TrixInputBlock("Display Name", hint: "Visible account name.") {
                        TextField("Maksym", text: $model.editProfileDraft.profileName)
                            .textFieldStyle(.roundedBorder)
                    }

                    TrixInputBlock("Handle", hint: "Optional public handle.") {
                        TextField("mihver", text: $model.editProfileDraft.handle)
                            .textFieldStyle(.roundedBorder)
                    }

                    TrixInputBlock("Bio", hint: "Optional short profile bio.") {
                        TextEditor(text: $model.editProfileDraft.profileBio)
                            .frame(minHeight: 120)
                            .font(.body)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await model.updateProfile()
                            }
                        } label: {
                            Label(
                                model.isUpdatingProfile ? "Saving…" : "Save Profile",
                                systemImage: "checkmark.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canUpdateProfile)

                        Button(role: .destructive) {
                            model.signOut()
                            isPresentingSettings = false
                        } label: {
                            Label("Forget This Device", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let account = model.currentAccount {
                TrixPanel(
                    title: "Account",
                    subtitle: "Reference details for this signed-in identity."
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                        ConversationMetaChip(label: "Account", value: shortID(account.accountId))
                        ConversationMetaChip(label: "Handle", value: trimmedValue(account.handle) ?? "not set")
                        ConversationMetaChip(label: "Device", value: shortID(account.deviceId))
                        ConversationMetaChip(label: "Status", value: account.deviceStatus.label)
                    }
                }
            }
        }
    }

    private var devicesSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Link A New Device",
                subtitle: model.hasAccountRootKey
                    ? "Create a link payload here, then approve the new Mac from your trusted device list."
                    : "This Mac can create a link payload, but approval still needs a root-capable device."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task {
                            await model.createLinkIntent()
                        }
                    } label: {
                        Label(
                            model.isCreatingLinkIntent ? "Creating Link…" : "Create Link Intent",
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCreatingLinkIntent)

                    if let linkIntent = model.outgoingLinkIntent {
                        TrixInputBlock("Link Payload", hint: "Move this payload to the Mac you want to add.") {
                            TrixPayloadBox(payload: linkIntent.payload, minHeight: 150)
                        }

                        HStack(spacing: 12) {
                            Button {
                                copyStringToPasteboard(linkIntent.payload)
                            } label: {
                                Label("Copy Payload", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Text("expires \(Self.linkExpiryFormatter.localizedString(for: linkIntent.expiresAt, relativeTo: .now))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        }
                    }
                }
            }

            TrixPanel(
                title: "Trusted Devices",
                subtitle: "Approve pending devices, revoke old ones and keep your account inventory clean."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Button {
                            Task {
                                await model.refreshDevices()
                            }
                        } label: {
                            Label(
                                model.isRefreshingDevices || model.isRefreshingWorkspace ? "Refreshing Devices…" : "Refresh Devices",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRefreshingDevices || model.isRefreshingWorkspace)

                        if model.devices.contains(where: { $0.deviceStatus == .pending }) {
                            Text("Pending devices are shown first.")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.warning)
                        }
                    }

                    if model.devices.isEmpty {
                        EmptyWorkspaceLabel("No devices are visible for this account yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.devices) { device in
                                DeviceRow(
                                    device: device,
                                    isCurrentDevice: device.deviceId == model.currentDeviceID,
                                    canApprove: model.hasAccountRootKey &&
                                        device.deviceStatus == .pending &&
                                        device.deviceId != model.currentDeviceID,
                                    isApproving: model.approvingDeviceIDs.contains(device.deviceId),
                                    canRevoke: model.hasAccountRootKey && device.deviceId != model.currentDeviceID,
                                    isRevoking: model.revokingDeviceIDs.contains(device.deviceId),
                                    approve: {
                                        Task {
                                            await model.approvePendingDevice(device)
                                        }
                                    },
                                    revoke: {
                                        Task {
                                            await model.revokeDevice(device)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var notificationsSettingsPanel: some View {
        let intervalOptions: [TimeInterval] = [15, 30, 60, 120, 300]

        return VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Notifications",
                subtitle: "Background polling keeps unread counts fresh and surfaces incoming messages while the app is in the background."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        TrixToneBadge(
                            label: model.notificationPreferences.permissionState.label,
                            tint: notificationPermissionTint
                        )
                        TrixToneBadge(
                            label: model.notificationPreferences.isEnabled ? "Enabled" : "Disabled",
                            tint: model.notificationPreferences.isEnabled ? colors.success : colors.inkMuted
                        )
                    }

                    Toggle(
                        "Allow background polling and message notifications",
                        isOn: Binding(
                            get: { model.notificationPreferences.isEnabled },
                            set: { model.setNotificationsEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await model.requestNotificationPermission()
                            }
                        } label: {
                            Label("Request Permission", systemImage: "bell.badge")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .secondary))

                        Picker(
                            "Polling Interval",
                            selection: Binding(
                                get: { model.notificationPreferences.backgroundPollingIntervalSeconds },
                                set: { model.setNotificationPollingInterval($0) }
                            )
                        ) {
                            ForEach(intervalOptions, id: \.self) { seconds in
                                Text(seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) sec")
                                    .tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Text("When the app is open, sync stays live in the foreground. When it is in the background, polling continues only if notifications are enabled.")
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var advancedSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Device Linking",
                subtitle: model.hasAccountRootKey
                    ? "Create a link intent here, then approve the pending Mac directly from the device directory once it registers."
                    : "This device can create link intents, but approval must happen on another root-capable trusted device."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task {
                            await model.createLinkIntent()
                        }
                    } label: {
                        Label(
                            model.isCreatingLinkIntent ? "Creating Link Intent…" : "Create Link Intent",
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .disabled(model.isCreatingLinkIntent)

                    if let linkIntent = model.outgoingLinkIntent {
                        TrixInputBlock(
                            "Link Payload",
                            hint: "Move this JSON to the Mac that should join the account."
                        ) {
                            TrixPayloadBox(payload: linkIntent.payload, minHeight: 160)
                        }

                        HStack(spacing: 12) {
                            Button {
                                copyStringToPasteboard(linkIntent.payload)
                            } label: {
                                Label("Copy Payload", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(TrixActionButtonStyle(tone: .secondary))

                            Text("expires \(Self.linkExpiryFormatter.localizedString(for: linkIntent.expiresAt, relativeTo: .now))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatInfoInspector(_ currentAccount: AccountProfileResponse) -> some View {
        if let detail = model.selectedChatDetail {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    inspectorHeroCard(detail: detail, currentAccount: currentAccount)

                    TrixSurface {
                        chatMembersInspector(detail: detail, currentAccount: currentAccount)
                            .padding(20)
                    }

                    TrixSurface {
                        chatDevicesInspector(detail: detail, currentAccount: currentAccount)
                            .padding(20)
                    }
                }
                .padding(.vertical, 2)
            }
        } else {
            TrixSurface(cornerRadius: 26) {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "person.2.slash",
                    description: Text("Choose a conversation to inspect members and devices.")
                )
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inspectorHeroCard(
        detail: ChatDetailResponse,
        currentAccount: AccountProfileResponse
    ) -> some View {
        TrixSurface(emphasized: true, cornerRadius: 26) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.displayTitle(for: currentAccount.accountId))
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(colors.ink)

                    Text(detail.subtitle(for: currentAccount.accountId))
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        InlineMeta(label: "\(detail.members.count) people")
                        InlineMeta(label: "\(detail.deviceMembers.count) devices")
                        InlineMeta(label: chatTypeSummary(detail.chatType))
                    }
                }

                conversationMetadata(detail)
            }
            .padding(20)
        }
    }

    private func chatMembersInspector(
        detail: ChatDetailResponse,
        currentAccount: AccountProfileResponse
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            detailsSectionHeader(
                title: "People",
                subtitle: canManageSelectedChatMembers
                    ? "Manage who is in this conversation."
                    : "People in this conversation."
            )

            ForEach(detail.members) { member in
                ChatMemberInspectorRow(
                    profile: participantProfile(detail: detail, accountId: member.accountId),
                    member: member,
                    isCurrentAccount: member.accountId == currentAccount.accountId,
                    canRemove: canManageSelectedChatMembers &&
                        model.supportsSafeConversationMemberRemoval &&
                        member.accountId != currentAccount.accountId,
                    isRemoving: model.removingChatMemberAccountIDs.contains(member.accountId)
                ) {
                    Task {
                        await model.removeMemberFromSelectedChat(member.accountId)
                    }
                }
            }

            if canManageSelectedChatMembers {
                TrixInputBlock("Add People", hint: "Search by name or handle.") {
                    HStack(spacing: 12) {
                        TextField("Find people", text: $memberSearchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                searchSelectedChatMembers()
                            }

                        Button {
                            searchSelectedChatMembers()
                        } label: {
                            Label(
                                model.isSearchingAccountDirectory ? "Searching…" : "Search",
                                systemImage: "magnifyingglass"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isSearchingAccountDirectory || model.isAddingChatMembers)
                    }
                }

                if !memberSearchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(memberSearchResults.filter { account in
                            !detail.members.contains(where: { $0.accountId == account.accountId })
                        }) { account in
                            DirectoryAccountActionRow(
                                account: account,
                                actionTitle: "Add",
                                isBusy: model.isAddingChatMembers
                            ) {
                                Task {
                                    await model.addMembersToSelectedChat([account.accountId])
                                }
                            }
                        }
                    }
                } else if trimmedValue(memberSearchQuery) != nil, !model.isSearchingAccountDirectory {
                    Text("No matching people found.")
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                }
            }
        }
    }

    private func chatDevicesInspector(
        detail: ChatDetailResponse,
        currentAccount: AccountProfileResponse
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            detailsSectionHeader(
                title: "Devices",
                subtitle: canManageSelectedChatDevices
                    ? "Manage which of your devices are in this conversation."
                    : "Devices currently present in this chat."
            )

            ForEach(detail.deviceMembers) { device in
                ChatDeviceInspectorRow(
                    device: device,
                    ownerProfile: participantProfile(detail: detail, accountId: device.accountId),
                    isCurrentDevice: device.deviceId == model.currentDeviceID,
                    canRemove: canManageSelectedChatDevices &&
                        model.supportsSafeConversationDeviceRemoval &&
                        device.deviceId != model.currentDeviceID,
                    isRemoving: model.removingChatDeviceIDs.contains(device.deviceId)
                ) {
                    Task {
                        await model.removeDeviceFromSelectedChat(device.deviceId)
                    }
                }
            }

            if canManageSelectedChatDevices && !model.addableCurrentAccountDevicesForSelectedChat.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Your Other Devices")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.ink)

                    ForEach(model.addableCurrentAccountDevicesForSelectedChat) { device in
                        AvailableChatDeviceRow(
                            device: device,
                            isBusy: model.isAddingChatDevices
                        ) {
                            Task {
                                await model.addDevicesToSelectedChat([device.deviceId])
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func searchSelectedChatMembers() {
        Task {
            memberSearchResults = await model.searchAccounts(query: memberSearchQuery)
        }
    }

    private func detailsSectionHeader(title: String, subtitle: String) -> some View {
        DetailsSectionHeader(title: title, subtitle: subtitle)
    }

    private func chatTypeSummary(_ chatType: ChatType) -> String {
        switch chatType {
        case .dm:
            return "Direct"
        case .group:
            return "Group"
        case .accountSync:
            return "Sync"
        }
    }

    private var notificationPermissionTint: Color {
        switch model.notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            return colors.success
        case .denied:
            return colors.rust
        case .notDetermined:
            return colors.warning
        }
    }

    private var controlSummaryPanel: some View {
        TrixPanel(
            title: "Advanced",
            subtitle: "Operational tooling stays here so the main conversation view can behave like a messenger."
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: availableSize.width < 1160 ? 180 : 220), spacing: 12)], alignment: .leading, spacing: 12) {
                WorkspaceSummaryChip(
                    iconName: "person.crop.circle.badge.checkmark",
                    label: "\(model.devices.count) device record\(model.devices.count == 1 ? "" : "s")",
                    tone: .surface
                )
                WorkspaceSummaryChip(
                    iconName: "bubble.left.and.bubble.right.fill",
                    label: "\(model.localChatListItems.count) local chat projection\(model.localChatListItems.count == 1 ? "" : "s")",
                    tone: .surface
                )
                WorkspaceSummaryChip(
                    iconName: "arrow.triangle.2.circlepath",
                    label: "\(model.syncStateSnapshot?.chatCursors.count ?? 0) persisted sync cursor\(model.syncStateSnapshot?.chatCursors.count == 1 ? "" : "s")",
                    tone: .surface
                )
                WorkspaceSummaryChip(
                    iconName: "clock.badge.checkmark",
                    label: "\(model.historySyncJobs.count) history sync job\(model.historySyncJobs.count == 1 ? "" : "s")",
                    tone: .surface
                )
            }
        }
    }

    private var operationsColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Device Linking",
                subtitle: model.hasAccountRootKey
                    ? "Create a link intent here, then approve the pending Mac directly from the device directory once it registers."
                    : "This device can create link intents, but approval must happen on another root-capable trusted device."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task {
                            await model.createLinkIntent()
                        }
                    } label: {
                        Label(
                            model.isCreatingLinkIntent ? "Creating Link Intent…" : "Create Link Intent",
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .disabled(model.isCreatingLinkIntent)

                    if let linkIntent = model.outgoingLinkIntent {
                        TrixInputBlock(
                            "Link Payload",
                            hint: "Move this JSON to the Mac that should join the account."
                        ) {
                            TrixPayloadBox(payload: linkIntent.payload, minHeight: 160)
                        }

                        HStack(spacing: 12) {
                            Button {
                                copyStringToPasteboard(linkIntent.payload)
                            } label: {
                                Label("Copy Payload", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(TrixActionButtonStyle(tone: .secondary))

                            Text("expires \(Self.linkExpiryFormatter.localizedString(for: linkIntent.expiresAt, relativeTo: .now))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        }
                    }
                }
            }

            TrixPanel(
                title: "Key Packages",
                subtitle: "Manual publish and reserve tooling until native MLS package generation lands in the Mac client."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    if let signatureFingerprint = model.mlsSignaturePublicKeyFingerprint {
                        InlineMeta(label: "MLS signer \(signatureFingerprint)")
                    }

                    OperationalSectionLabel("Publish For Current Device")

                    TrixInputBlock(
                        "Packages JSON",
                        hint: "Paste a JSON array of `{ cipher_suite, key_package_b64 }` objects."
                    ) {
                        TextEditor(text: $model.keyPackagePublishDraft.packagesJSON)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 138)
                            .font(.system(.footnote, design: .monospaced))
                            .trixInputChrome()
                    }

                    Button {
                        Task {
                            await model.publishKeyPackages()
                        }
                    } label: {
                        Label(
                            model.isPublishingKeyPackages ? "Publishing Packages…" : "Publish Packages",
                            systemImage: "arrow.up.circle"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .disabled(!model.canPublishKeyPackages)

                    if !model.publishedKeyPackages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.publishedKeyPackages) { package in
                                PublishedKeyPackageRow(package: package)
                            }
                        }
                    }

                    Divider()

                    OperationalSectionLabel("Reserve For Account")

                    HStack(spacing: 10) {
                        KeyPackageReserveModeButton(
                            title: KeyPackageReserveMode.allActiveDevices.title,
                            isSelected: model.keyPackageReserveDraft.mode == .allActiveDevices
                        ) {
                            model.keyPackageReserveDraft.mode = .allActiveDevices
                        }

                        KeyPackageReserveModeButton(
                            title: KeyPackageReserveMode.selectedDevices.title,
                            isSelected: model.keyPackageReserveDraft.mode == .selectedDevices
                        ) {
                            model.keyPackageReserveDraft.mode = .selectedDevices
                        }
                    }

                    TrixInputBlock(
                        "Account ID",
                        hint: "Target account whose active devices should contribute reserved key packages."
                    ) {
                        TextField("account uuid", text: $model.keyPackageReserveDraft.accountID)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .trixInputChrome()
                    }

                    if model.keyPackageReserveDraft.mode == .selectedDevices {
                        TrixInputBlock(
                            "Device IDs",
                            hint: "One UUID per line, or comma-separated."
                        ) {
                            TextEditor(text: $model.keyPackageReserveDraft.selectedDeviceIDs)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 110)
                                .font(.system(.footnote, design: .monospaced))
                                .trixInputChrome()
                        }

                        Button {
                            model.useVisibleActiveDeviceIDsForReserve()
                        } label: {
                            Label("Use Visible Active Devices", systemImage: "list.bullet.rectangle")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .secondary))
                    }

                    Button {
                        Task {
                            await model.reserveKeyPackages()
                        }
                    } label: {
                        Label(
                            model.isReservingKeyPackages ? "Reserving Packages…" : "Reserve Packages",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .disabled(!model.canReserveKeyPackages)

                    if !model.reservedKeyPackages.isEmpty {
                        if let accountID = model.reservedKeyPackagesAccountID {
                            Text("reserved for \(shortID(accountID))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.reservedKeyPackages) { package in
                                ReservedKeyPackageRow(package: package)
                            }
                        }
                    }
                }
            }

            TrixPanel(
                title: "History Sync Jobs",
                subtitle: "Server-side jobs targeted from this device. Useful after device approval, revoke and future chat backfills."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task {
                            await model.refreshHistorySyncJobs()
                        }
                    } label: {
                        Label(
                            model.isRefreshingHistorySyncJobs ? "Refreshing Jobs…" : "Refresh Jobs",
                            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .secondary))
                    .disabled(model.isRefreshingHistorySyncJobs)

                    if model.historySyncJobs.isEmpty {
                        EmptyWorkspaceLabel("No history sync jobs are visible for this device yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.historySyncJobs) { job in
                                HistorySyncJobRow(
                                    job: job,
                                    cursorText: cursorBinding(for: job.jobId),
                                    chunkDraft: historySyncChunkDraftBinding(for: job.jobId),
                                    chunks: model.historySyncChunksByJobID[job.jobId] ?? [],
                                    isCompleting: model.completingHistorySyncJobIDs.contains(job.jobId),
                                    isLoadingChunks: model.loadingHistorySyncChunkJobIDs.contains(job.jobId),
                                    isAppendingChunk: model.appendingHistorySyncChunkJobIDs.contains(job.jobId),
                                    loadChunks: {
                                        Task {
                                            await model.refreshHistorySyncChunks(for: job.jobId)
                                        }
                                    },
                                    complete: {
                                        Task {
                                            await model.completeHistorySyncJob(job.jobId)
                                        }
                                    },
                                    appendChunk: {
                                        Task {
                                            await model.appendHistorySyncChunk(job.jobId)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }

            TrixPanel(
                title: "Devices",
                subtitle: "Current account device directory."
            ) {
                if model.devices.isEmpty {
                    EmptyWorkspaceLabel("No devices returned by the server.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.devices) { device in
                            DeviceRow(
                                device: device,
                                isCurrentDevice: device.deviceId == model.currentDeviceID,
                                canApprove: model.hasAccountRootKey &&
                                    device.deviceStatus == .pending &&
                                    device.deviceId != model.currentDeviceID,
                                isApproving: model.approvingDeviceIDs.contains(device.deviceId),
                                canRevoke: model.hasAccountRootKey && device.deviceId != model.currentDeviceID,
                                isRevoking: model.revokingDeviceIDs.contains(device.deviceId),
                                approve: {
                                    Task {
                                        await model.approvePendingDevice(device)
                                    }
                                },
                                revoke: {
                                    Task {
                                        await model.revokeDevice(device)
                                    }
                                }
                            )
                        }
                    }
                }
            }

            TrixPanel(
                title: "Chats",
                subtitle: "Secondary chat picker for the control inspector."
            ) {
                if model.chats.isEmpty {
                    EmptyWorkspaceLabel("No chats are visible yet. Create another account or use the API to open the first DM or group.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.chats) { chat in
                            ChatRow(
                                chat: chat,
                                currentAccountID: presentationAccountID,
                                isSelected: chat.chatId == model.selectedChatID,
                                isLoading: chat.chatId == model.selectedChatID && model.isLoadingSelectedChat
                            ) {
                                Task {
                                    await model.selectChat(chat.chatId)
                                }
                            }
                            .optionalAccessibilityIdentifier(
                                MacUITestFixtureViewHints.sidebarChatRowIdentifier(
                                    chatId: chat.chatId,
                                    chatTypeRawValue: chat.chatType.rawValue
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    private var controlInspectorColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary = model.selectedChatSummary {
                TrixPanel(
                    title: "Selected Chat Diagnostics",
                    subtitle: "\(summary.displayTitle(for: presentationAccountID)) • \(summary.subtitle(for: presentationAccountID))"
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            TrixToneBadge(label: summary.chatType.label, tint: colors.accent)
                            if model.isLoadingSelectedChat {
                                TrixToneBadge(label: "Refreshing detail", tint: colors.rust)
                            }
                        }

                        if let detail = model.selectedChatDetail {
                            HStack(spacing: 16) {
                                TrixMetricTile(label: "Epoch", value: "\(detail.epoch)")
                                TrixMetricTile(label: "Server seq", value: "\(detail.lastServerSeq)")
                                TrixMetricTile(
                                    label: "Members",
                                    value: "\(detail.members.count)",
                                    footnote: detail.lastCommitMessageId.map { "commit \(shortID($0))" }
                                )
                                TrixMetricTile(
                                    label: "Projected",
                                    value: model.selectedChatProjectedCursor.map(String.init) ?? "none",
                                    footnote: model.hasProjectedTimelineData
                                        ? "\(model.selectedChatProjectedMessages.count) projected item(s)"
                                        : "MLS restore path still missing"
                                )
                            }

                            HStack(spacing: 16) {
                                TrixMetricTile(
                                    label: "Read cursor",
                                    value: model.selectedChatReadCursor.map(String.init) ?? "none"
                                )
                                TrixMetricTile(
                                    label: "Unread",
                                    value: model.selectedChatUnreadCount.map(String.init) ?? "none"
                                )
                                TrixMetricTile(
                                    label: "Sync cursor",
                                    value: model.selectedChatSyncCursor.map(String.init) ?? "none"
                                )
                                TrixMetricTile(
                                    label: "MLS leaves",
                                    value: model.selectedChatMlsDiagnostics.map { "\($0.memberCount)" } ?? "n/a",
                                    footnote: model.selectedChatMlsDiagnostics.map {
                                        "\($0.ratchetTreeBytes) ratchet-tree bytes"
                                    }
                                )
                            }

                            if model.selectedChatProjectedCursor != nil || detail.lastServerSeq > 0 {
                                Button {
                                    Task {
                                        await model.setSelectedChatReadCursor(
                                            model.selectedChatProjectedCursor ?? detail.lastServerSeq
                                        )
                                    }
                                } label: {
                                    Label("Set Local Read Cursor", systemImage: "checkmark.circle")
                                }
                                .buttonStyle(TrixActionButtonStyle(tone: .secondary))
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Members")
                                    .font(.headline)
                                    .foregroundStyle(colors.ink)

                                ForEach(detail.members) { member in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(memberDisplayName(detail: detail, accountId: member.accountId))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(colors.ink)
                                            Text(memberSecondaryLine(detail: detail, accountId: member.accountId) ?? member.role)
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(colors.inkMuted)
                                        }
                                        Spacer()
                                        Text(member.membershipStatus)
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(colors.tileFill, in: Capsule())
                                            .foregroundStyle(colors.inkMuted)
                                    }
                                    .padding(.bottom, 2)
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading chat detail…")
                                    .foregroundStyle(colors.inkMuted)
                            }
                        }
                    }
                }

                TrixPanel(
                    title: "Projected Timeline",
                    subtitle: "Typed local timeline projection is wired in, but application payloads still depend on restored MLS conversation state."
                ) {
                    if model.isLoadingSelectedChat && model.selectedChatProjectedMessages.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Checking projected timeline…")
                                .foregroundStyle(colors.inkMuted)
                        }
                    } else if model.selectedChatProjectedMessages.isEmpty {
                        EmptyWorkspaceLabel(
                            model.selectedChatHistory.isEmpty
                                ? "No projected items are stored for this chat yet."
                                : "Projected timeline is empty. The local store has encrypted history, but macOS still cannot restore the MLS conversation for this chat."
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.selectedChatProjectedMessages) { message in
                                ProjectedMessageRow(message: message)
                            }
                        }
                    }
                }

                TrixPanel(
                    title: "Encrypted History",
                    subtitle: "Raw encrypted metadata persisted through the local history store. This remains the fallback until MLS restore lands."
                ) {
                    if model.isLoadingSelectedChat && model.selectedChatHistory.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading history…")
                                .foregroundStyle(colors.inkMuted)
                        }
                    } else if presentedHistoryMessages.isEmpty {
                        EmptyWorkspaceLabel("This chat has no server-stored messages yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(presentedHistoryMessages) { message in
                                MessageHistoryRow(
                                    message: message.message,
                                    isOutgoing: message.isOutgoing,
                                    fixtureAccessibilityIdentifier: MacUITestFixtureViewHints.timelineMessageIdentifier(
                                        messageId: message.message.messageId,
                                        selectedChatId: message.message.chatId
                                    )
                                )
                            }
                        }
                    }
                }
            } else {
                TrixPanel(
                    title: "No Chat Selected",
                    subtitle: "Select a chat if you want the control inspector to show membership and timeline diagnostics."
                ) {
                    EmptyWorkspaceLabel("Select a chat from Messages or from the secondary picker in Control to inspect server and local state.")
                }
            }
        }
    }
    private func conversationMetadata(_ detail: ChatDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: availableSize.width < 1160 ? 180 : 220), spacing: 12)], alignment: .leading, spacing: 12) {
                ConversationMetaChip(label: "Members", value: "\(detail.members.count)")
                ConversationMetaChip(label: "Devices", value: "\(detail.deviceMembers.count)")
                ConversationMetaChip(label: "Unread", value: "\(model.selectedChatReadState?.unreadCount ?? 0)")
                ConversationMetaChip(label: "Pending", value: "\(detail.pendingMessageCount)")
            }

            if !detail.participantProfiles.isEmpty {
                Text(detail.participantProfiles.prefix(6).map(\.displayName).joined(separator: " · "))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.inkMuted)
                    .textSelection(.enabled)
            }
        }
    }

    private func conversationTimeline() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoadingSelectedChat && model.selectedChatTimelineItems.isEmpty && model.selectedChatHistory.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading conversation…")
                        .foregroundStyle(colors.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if timelineUsesLocalData {
                timelineScrollContent
            } else if timelineUsesEncryptedFallback {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Loading messages…")
                            .font(.footnote)
                            .foregroundStyle(colors.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(presentedHistoryMessages) { message in
                            MessageHistoryRow(
                                message: message.message,
                                isOutgoing: message.isOutgoing,
                                fixtureAccessibilityIdentifier: MacUITestFixtureViewHints.timelineMessageIdentifier(
                                    messageId: message.message.messageId,
                                    selectedChatId: message.message.chatId
                                )
                            )
                        }

                        pendingOutgoingList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if !model.selectedPendingOutgoingMessages.isEmpty {
                timelineScrollContent
            } else {
                EmptyWorkspaceLabel("No messages yet.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private func composerPanel(chatTitle: String) -> some View {
        TrixSurface(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                if let attachmentDraft = model.composerAttachmentDraft {
                    ComposerAttachmentRow(
                        attachment: attachmentDraft,
                        clear: {
                            model.clearComposerAttachment()
                        }
                    )
                }

                ZStack(alignment: .topLeading) {
                    if composerDraft.isEmpty {
                        Text("Write a reply to \(chatTitle)…")
                            .font(.body)
                            .foregroundStyle(colors.inkMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    }

                    TextEditor(text: $composerDraft)
                        .frame(minHeight: 88, maxHeight: 140)
                        .font(.body)
                        .padding(6)
                        .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack(spacing: 12) {
                    Button {
                        isImportingAttachment = true
                    } label: {
                        Label(model.composerAttachmentDraft == nil ? "Attach" : "Replace", systemImage: "paperclip")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSendingMessage)

                    Button {
                        composerDraft = ""
                    } label: {
                        Label("Clear Draft", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        composerDraft.isEmpty &&
                            model.composerAttachmentDraft == nil
                    )

                    Spacer()

                    Button {
                        Task {
                            let sent = await model.sendMessage(draftText: composerDraft)
                            if sent {
                                composerDraft = ""
                            }
                        }
                    } label: {
                        Label(model.isSendingMessage ? "Sending…" : "Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        (
                            composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                model.composerAttachmentDraft == nil
                        ) ||
                            model.isSendingMessage
                    )
                }
            }
            .padding(16)
        }
    }

    private var timelineScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(presentedTimelineMessages) { entry in
                    let reactionHandler: ((LocalTimelineItem, String) -> Void)? = model.isSendingMessage ? nil : { message, emoji in
                        Task {
                            let removeExisting = message.reactions.contains {
                                $0.emoji == emoji && $0.includesSelf
                            }
                            _ = await model.sendReaction(
                                targetMessageID: message.messageId,
                                emoji: emoji,
                                removeExisting: removeExisting
                            )
                        }
                    }

                    LocalTimelineMessageRow(
                        model: model,
                        message: entry.message,
                        isOutgoing: entry.message.isOutgoing,
                        receiptStatus: entry.receiptStatus,
                        isDownloadingAttachment: model.downloadingAttachmentMessageIDs.contains(entry.message.messageId),
                        openAttachment: entry.message.body?.kind == .attachment ? {
                            Task {
                                await model.openAttachment(for: entry.message)
                            }
                        } : nil,
                        onSelectReaction: reactionHandler,
                        fixtureAccessibilityIdentifier: MacUITestFixtureViewHints.timelineMessageIdentifier(
                            messageId: entry.message.messageId,
                            selectedChatId: model.selectedChatID
                        )
                    )
                }

                pendingOutgoingList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var pendingOutgoingList: some View {
        Group {
            if !model.selectedPendingOutgoingMessages.isEmpty {
                ForEach(model.selectedPendingOutgoingMessages) { pendingMessage in
                    PendingOutgoingMessageRow(
                        message: pendingMessage,
                        retry: {
                            Task {
                                await model.retryPendingOutgoingMessage(pendingMessage.id)
                            }
                        },
                        discard: {
                            model.discardPendingOutgoingMessage(pendingMessage.id)
                        }
                    )
                }
            }
        }
    }

    private var timelineBadgeLabel: String {
        if timelineUsesLocalData {
            let total = presentedTimelineMessages.count + model.selectedPendingOutgoingMessages.count
            return "\(total) message\(total == 1 ? "" : "s")"
        }
        if timelineUsesEncryptedFallback {
            return "\(presentedHistoryMessages.count) encrypted"
        }
        if !model.selectedPendingOutgoingMessages.isEmpty {
            return "\(model.selectedPendingOutgoingMessages.count) sending"
        }
        return "No messages yet"
    }

    private func fallbackSelectedChatListItem(currentAccountID: UUID) -> LocalChatListItem? {
        guard let summary = model.selectedChatSummary else {
            return nil
        }
        let latestPresentedMessage = presentedTimelineMessages.last?.message

        return LocalChatListItem(
            chatId: summary.chatId,
            chatType: summary.chatType,
            title: summary.title,
            displayTitle: summary.displayTitle(for: currentAccountID),
            lastServerSeq: summary.lastServerSeq,
            epoch: summary.epoch,
            pendingMessageCount: 0,
            unreadCount: model.selectedChatReadState?.unreadCount ?? 0,
            previewText: latestPresentedMessage?.previewText,
            previewSenderAccountId: latestPresentedMessage?.senderAccountId,
            previewSenderDisplayName: latestPresentedMessage?.senderDisplayName,
            previewIsOutgoing: latestPresentedMessage?.isOutgoing,
            previewServerSeq: latestPresentedMessage?.serverSeq,
            previewCreatedAtUnix: latestPresentedMessage?.createdAtUnix,
            participantProfiles: summary.participantProfiles
        )
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    private func participantProfile(
        detail: ChatDetailResponse,
        accountId: UUID
    ) -> ChatParticipantProfileSummary? {
        detail.participantProfiles.first { $0.accountId == accountId }
    }

    private func memberDisplayName(detail: ChatDetailResponse, accountId: UUID) -> String {
        participantProfile(detail: detail, accountId: accountId)?.displayName ?? shortID(accountId)
    }

    private func memberSecondaryLine(detail: ChatDetailResponse, accountId: UUID) -> String? {
        let profile = participantProfile(detail: detail, accountId: accountId)
        let role = detail.members.first(where: { $0.accountId == accountId })?.role
        let segments = [profile?.handleLabel, role].compactMap { $0 }
        return segments.isEmpty ? profile?.detailLine : segments.joined(separator: " • ")
    }

    private func cursorBinding(for jobID: UUID) -> Binding<String> {
        Binding(
            get: { model.historySyncCursorDrafts[jobID] ?? "" },
            set: { model.historySyncCursorDrafts[jobID] = $0 }
        )
    }

    private func historySyncChunkDraftBinding(for jobID: UUID) -> Binding<HistorySyncChunkDraft> {
        Binding(
            get: { model.historySyncChunkDrafts[jobID] ?? HistorySyncChunkDraft() },
            set: { model.historySyncChunkDrafts[jobID] = $0 }
        )
    }

    private static let linkExpiryFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

struct WorkspaceSettingsView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    @State private var activeSettingsTab: SettingsTab = .profile

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $activeSettingsTab) { tab in
                Label(tab.title, systemImage: tab.iconName)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Settings")
        }
        .frame(minWidth: 960, minHeight: 720)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch activeSettingsTab {
        case .profile:
            profileSettingsPanel
        case .devices:
            devicesSettingsPanel
        case .notifications:
            notificationsSettingsPanel
        case .advanced:
            advancedSettingsPanel
        }
    }

    private var profileSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Profile",
                subtitle: "This is how your account appears in directory search and conversations."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    TrixInputBlock("Display Name", hint: "Visible account name.") {
                        TextField("Maksym", text: $model.editProfileDraft.profileName)
                            .textFieldStyle(.roundedBorder)
                    }

                    TrixInputBlock("Handle", hint: "Optional public handle.") {
                        TextField("mihver", text: $model.editProfileDraft.handle)
                            .textFieldStyle(.roundedBorder)
                    }

                    TrixInputBlock("Bio", hint: "Optional short profile bio.") {
                        TextEditor(text: $model.editProfileDraft.profileBio)
                            .frame(minHeight: 120)
                            .font(.body)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await model.updateProfile()
                            }
                        } label: {
                            Label(
                                model.isUpdatingProfile ? "Saving…" : "Save Profile",
                                systemImage: "checkmark.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canUpdateProfile)

                        Button(role: .destructive) {
                            model.signOut()
                        } label: {
                            Label("Forget This Device", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let account = model.currentAccount {
                TrixPanel(
                    title: "Account",
                    subtitle: "Reference details for this signed-in identity."
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                        ConversationMetaChip(label: "Account", value: shortID(account.accountId))
                        ConversationMetaChip(label: "Handle", value: trimmedValue(account.handle) ?? "not set")
                        ConversationMetaChip(label: "Device", value: shortID(account.deviceId))
                        ConversationMetaChip(label: "Status", value: account.deviceStatus.label)
                    }
                }
            }
        }
    }

    private var devicesSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Link A New Device",
                subtitle: model.hasAccountRootKey
                    ? "Create a link payload here, then approve the new Mac from your trusted device list."
                    : "This Mac can create a link payload, but approval still needs a root-capable device."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task {
                            await model.createLinkIntent()
                        }
                    } label: {
                        Label(
                            model.isCreatingLinkIntent ? "Creating Link…" : "Create Link Intent",
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCreatingLinkIntent)

                    if let linkIntent = model.outgoingLinkIntent {
                        TrixInputBlock("Link Payload", hint: "Move this payload to the Mac you want to add.") {
                            TrixPayloadBox(payload: linkIntent.payload, minHeight: 150)
                        }

                        HStack(spacing: 12) {
                            Button {
                                copyStringToPasteboard(linkIntent.payload)
                            } label: {
                                Label("Copy Payload", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Text("expires \(Self.linkExpiryFormatter.localizedString(for: linkIntent.expiresAt, relativeTo: .now))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        }
                    }
                }
            }

            TrixPanel(
                title: "Trusted Devices",
                subtitle: "Approve pending devices, revoke old ones and keep your account inventory clean."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Button {
                            Task {
                                await model.refreshDevices()
                            }
                        } label: {
                            Label(
                                model.isRefreshingDevices || model.isRefreshingWorkspace ? "Refreshing Devices…" : "Refresh Devices",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRefreshingDevices || model.isRefreshingWorkspace)

                        if model.devices.contains(where: { $0.deviceStatus == .pending }) {
                            Text("Pending devices are shown first.")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.warning)
                        }
                    }

                    if model.devices.isEmpty {
                        EmptyWorkspaceLabel("No devices are visible for this account yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.devices) { device in
                                DeviceRow(
                                    device: device,
                                    isCurrentDevice: device.deviceId == model.currentDeviceID,
                                    canApprove: model.hasAccountRootKey &&
                                        device.deviceStatus == .pending &&
                                        device.deviceId != model.currentDeviceID,
                                    isApproving: model.approvingDeviceIDs.contains(device.deviceId),
                                    canRevoke: model.hasAccountRootKey && device.deviceId != model.currentDeviceID,
                                    isRevoking: model.revokingDeviceIDs.contains(device.deviceId),
                                    approve: {
                                        Task {
                                            await model.approvePendingDevice(device)
                                        }
                                    },
                                    revoke: {
                                        Task {
                                            await model.revokeDevice(device)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var notificationsSettingsPanel: some View {
        let intervalOptions: [TimeInterval] = [15, 30, 60, 120, 300]

        return VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Notifications",
                subtitle: "Background polling keeps unread counts fresh and surfaces incoming messages while the app is in the background."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        TrixToneBadge(
                            label: model.notificationPreferences.permissionState.label,
                            tint: notificationPermissionTint
                        )
                        TrixToneBadge(
                            label: model.notificationPreferences.isEnabled ? "Enabled" : "Disabled",
                            tint: model.notificationPreferences.isEnabled ? colors.success : colors.inkMuted
                        )
                    }

                    Toggle(
                        "Allow background polling and message notifications",
                        isOn: Binding(
                            get: { model.notificationPreferences.isEnabled },
                            set: { model.setNotificationsEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await model.requestNotificationPermission()
                            }
                        } label: {
                            Label("Request Permission", systemImage: "bell.badge")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .secondary))

                        Picker(
                            "Polling Interval",
                            selection: Binding(
                                get: { model.notificationPreferences.backgroundPollingIntervalSeconds },
                                set: { model.setNotificationPollingInterval($0) }
                            )
                        ) {
                            ForEach(intervalOptions, id: \.self) { seconds in
                                Text(seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) sec")
                                    .tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Text("When the app is open, sync stays live in the foreground. When it is in the background, polling continues only if notifications are enabled.")
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var advancedSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Device Linking",
                subtitle: model.hasAccountRootKey
                    ? "Create a link intent here, then approve the pending Mac directly from the device directory once it registers."
                    : "This device can create link intents, but approval must happen on another root-capable trusted device."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task {
                            await model.createLinkIntent()
                        }
                    } label: {
                        Label(
                            model.isCreatingLinkIntent ? "Creating Link Intent…" : "Create Link Intent",
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .disabled(model.isCreatingLinkIntent)

                    if let linkIntent = model.outgoingLinkIntent {
                        TrixInputBlock(
                            "Link Payload",
                            hint: "Move this JSON to the Mac that should join the account."
                        ) {
                            TrixPayloadBox(payload: linkIntent.payload, minHeight: 160)
                        }

                        HStack(spacing: 12) {
                            Button {
                                copyStringToPasteboard(linkIntent.payload)
                            } label: {
                                Label("Copy Payload", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(TrixActionButtonStyle(tone: .secondary))

                            Text("expires \(Self.linkExpiryFormatter.localizedString(for: linkIntent.expiresAt, relativeTo: .now))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        }
                    }
                }
            }
        }
    }

    private var notificationPermissionTint: Color {
        switch model.notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            return colors.success
        case .denied:
            return colors.rust
        case .notDetermined:
            return colors.warning
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    private static let linkExpiryFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct ConversationAvatar: View {
    @Environment(\.trixColors) private var colors
    let title: String
    let chatType: ChatType?

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [colors.accent.opacity(0.16), colors.panelStrong],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 54, height: 54)

            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(colors.accent)
        }
        .overlay {
            Circle()
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private var iconName: String {
        switch chatType {
        case .group:
            return "person.3.fill"
        case .accountSync:
            return "arrow.triangle.2.circlepath"
        case .dm:
            return "person.crop.circle.fill"
        case .none:
            return title == "Messages" ? "bubble.left.and.bubble.right.fill" : "bubble.left.fill"
        }
    }
}

private struct DetailsSectionHeader: View {
    @Environment(\.trixColors) private var colors
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(colors.ink)

            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(colors.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum WorkspaceSummaryChipTone {
    case surface
    case inverted
}

private struct WorkspaceSummaryChip: View {
    @Environment(\.trixColors) private var colors
    let iconName: String
    let label: String
    let tone: WorkspaceSummaryChipTone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var foregroundColor: Color {
        tone == .inverted ? colors.inverseInk : colors.ink
    }

    private var backgroundColor: Color {
        tone == .inverted ? colors.inverseInk.opacity(0.08) : colors.tileFill
    }

    private var borderColor: Color {
        tone == .inverted ? colors.inverseInk.opacity(0.08) : colors.outline
    }
}

private struct ConversationMetaChip: View {
    @Environment(\.trixColors) private var colors
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(colors.inkMuted)
            Text(value)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(colors.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct CreateChatSheet: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    let didCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Chat")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(colors.ink)
                    Text("Find people from the account directory, choose participants, then land directly in the conversation.")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.borderless)
            }

            Picker(
                "Chat Type",
                selection: Binding(
                    get: { model.createChatDraft.chatType },
                    set: { model.setCreateChatType($0) }
                )
            ) {
                Text("Direct Message").tag(ChatType.dm)
                Text("Group").tag(ChatType.group)
            }
            .pickerStyle(.segmented)

            if model.createChatDraft.chatType == .group {
                TrixInputBlock(
                    "Title",
                    hint: "Optional group name."
                ) {
                    TextField("Design review", text: $model.createChatDraft.title)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if !model.createChatDraft.selectedParticipants.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Selected")
                        .font(.caption.weight(.bold))
                        .tracking(0.9)
                        .foregroundStyle(colors.inkMuted)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.createChatDraft.selectedParticipants) { participant in
                                SelectedParticipantChip(
                                    participant: participant,
                                    remove: { model.removeCreateChatParticipant(participant.accountId) }
                                )
                            }
                        }
                    }
                }
            }

            TrixInputBlock(
                "Find People",
                hint: participantHint
            ) {
                HStack(spacing: 12) {
                    TextField("Search by handle or profile name", text: $model.createChatDraft.directoryQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task {
                                await model.searchAccountDirectory()
                            }
                        }

                    Button {
                        Task {
                            await model.searchAccountDirectory()
                        }
                    } label: {
                        Label(
                            model.isSearchingAccountDirectory ? "Searching…" : "Search",
                            systemImage: "magnifyingglass"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSearchingAccountDirectory)
                }
            }

            directoryResults

            HStack(alignment: .center, spacing: 12) {
                Text(footerHint)
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.borderless)

                Button {
                    Task {
                        let created = await model.createChat()
                        if created {
                            didCreate()
                            isPresented = false
                        }
                    }
                } label: {
                    Label(
                        model.isCreatingChat ? "Creating…" : "Create Chat",
                        systemImage: "plus.bubble.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCreateChat)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task {
            await model.prepareCreateChatSheet()
        }
    }

    private var participantHint: String {
        switch model.createChatDraft.chatType {
        case .dm:
            return "Pick exactly one account for the direct message."
        case .group:
            return "Pick one or more accounts for the group."
        case .accountSync:
            return "Account sync chats are created by the server."
        }
    }

    private var footerHint: String {
        switch model.createChatDraft.chatType {
        case .dm:
            return "Your own account is excluded from search and is added automatically."
        case .group:
            return "Your own account is excluded from search and will be added automatically to the group."
        case .accountSync:
            return "Account sync chats are created by the server."
        }
    }

    @ViewBuilder
    private var directoryResults: some View {
        if model.isSearchingAccountDirectory && model.accountDirectoryResults.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching directory…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.inkMuted)
            }
            .padding(.vertical, 8)
        } else if model.isCreateChatDirectoryEmpty {
            EmptyWorkspaceLabel(emptyDirectoryMessage)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.accountDirectoryResults) { account in
                        DirectoryAccountRow(
                            account: account,
                            isSelected: model.createChatParticipantAccountIDs.contains(account.accountId),
                            selectionMode: model.createChatDraft.chatType
                        ) {
                            model.toggleCreateChatParticipant(account)
                        }
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 280)
        }
    }

    private var emptyDirectoryMessage: String {
        if trimmedValue(model.createChatDraft.directoryQuery) != nil {
            return "No accounts matched the current search."
        }

        return "No other accounts are visible in the directory yet."
    }
}

private struct DirectoryAccountRow: View {
    @Environment(\.trixColors) private var colors
    let account: DirectoryAccountSummary
    let isSelected: Bool
    let selectionMode: ChatType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(account.profileName)
                            .font(.headline)
                            .foregroundStyle(colors.ink)

                        if let handle = trimmedValue(account.handle) {
                            Text("@\(handle)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(colors.accent)
                        }
                    }

                    if let profileBio = trimmedValue(account.profileBio) {
                        Text(profileBio)
                            .font(.subheadline)
                            .foregroundStyle(colors.inkMuted)
                            .lineLimit(2)
                    }

                    Text(String(account.accountId.uuidString.prefix(8)).lowercased())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(colors.inkMuted)
                }

                Spacer(minLength: 12)

                Text(isSelected ? "Selected" : selectionLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? colors.accent : colors.inkMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? colors.accentSoft.opacity(0.16) : colors.tileFill,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? colors.accent.opacity(0.4) : colors.outline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var selectionLabel: String {
        selectionMode == .dm ? "Choose" : "Add"
    }
}

private struct SelectedParticipantChip: View {
    @Environment(\.trixColors) private var colors
    let participant: DirectoryAccountSummary
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(participant.profileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.ink)

                if let handle = trimmedValue(participant.handle) {
                    Text("@\(handle)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.inkMuted)
                }
            }

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colors.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(colors.tileFill, in: Capsule())
        .overlay {
            Capsule()
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct DirectoryAccountActionRow: View {
    @Environment(\.trixColors) private var colors
    let account: DirectoryAccountSummary
    let actionTitle: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.profileName)
                    .font(.headline)
                    .foregroundStyle(colors.ink)

                HStack(spacing: 8) {
                    if let handle = trimmedValue(account.handle) {
                        Text("@\(handle)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.accent)
                    }

                    Text(String(account.accountId.uuidString.prefix(8)).lowercased())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(colors.inkMuted)
                }

                if let profileBio = trimmedValue(account.profileBio) {
                    Text(profileBio)
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Button(action: action) {
                Label(isBusy ? "Adding…" : actionTitle, systemImage: "plus")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .secondary))
            .disabled(isBusy)
        }
        .padding(14)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private func trimmedValue(_ rawValue: String?) -> String? {
    guard let rawValue else {
        return nil
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func formattedByteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
}

private struct PublishedKeyPackageRow: View {
    @Environment(\.trixColors) private var colors
    let package: PublishedKeyPackage

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.cipherSuite)
                    .font(.headline)
                    .foregroundStyle(colors.ink)
                Text(package.keyPackageId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(colors.inkMuted)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                copyStringToPasteboard(package.keyPackageId)
            } label: {
                Label("Copy ID", systemImage: "doc.on.doc")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .ghost))
            .frame(maxWidth: 140)
        }
        .padding(14)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct ReservedKeyPackageRow: View {
    @Environment(\.trixColors) private var colors
    let package: ReservedKeyPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.cipherSuite)
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text("device \(shortID(package.deviceId)) • package \(package.keyPackageId)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(colors.inkMuted)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    copyStringToPasteboard(package.keyPackageB64)
                } label: {
                    Label("Copy B64", systemImage: "doc.on.doc")
                }
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                .frame(maxWidth: 148)
            }

            TrixPayloadBox(payload: package.keyPackageB64, minHeight: 74)
        }
        .padding(14)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }
}

private struct KeyPackageReserveModeButton: View {
    @Environment(\.trixColors) private var colors
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    isSelected ? colors.accent.opacity(0.92) : colors.tileFill,
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : colors.ink)
                .overlay {
                    Capsule()
                        .stroke(isSelected ? colors.accent.opacity(0.16) : colors.outline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct OperationalSectionLabel: View {
    @Environment(\.trixColors) private var colors
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(colors.inkMuted)
    }
}

private struct HistorySyncJobRow: View {
    @Environment(\.trixColors) private var colors
    let job: HistorySyncJobSummary
    @Binding var cursorText: String
    @Binding var chunkDraft: HistorySyncChunkDraft
    let chunks: [HistorySyncChunkSummary]
    let isCompleting: Bool
    let isLoadingChunks: Bool
    let isAppendingChunk: Bool
    let loadChunks: () -> Void
    let complete: () -> Void
    let appendChunk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.jobType.label)
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text(jobSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    TrixToneBadge(label: job.role.label, tint: roleTint)
                    TrixToneBadge(label: job.jobStatus.label, tint: statusTint)
                }
            }

            HStack(spacing: 10) {
                InlineMeta(label: "updated \(Self.relativeFormatter.localizedString(for: job.updatedAt, relativeTo: .now))")
                if let chatID = job.chatId {
                    InlineMeta(label: "chat \(shortID(chatID))")
                }
            }

            if let cursor = job.cursorJson {
                TrixInputBlock("Server Cursor", hint: "Last cursor JSON already stored on the server for this job.") {
                    TrixPayloadBox(payload: prettyCursor(cursor), minHeight: 90)
                }
            }

            if job.role == .target {
                Button(action: loadChunks) {
                    Label(
                        isLoadingChunks ? "Loading Chunks…" : "Load Chunks",
                        systemImage: "square.stack.3d.down.right"
                    )
                }
                .buttonStyle(TrixActionButtonStyle(tone: .secondary))
                .disabled(isLoadingChunks)

                if !chunks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(chunks) { chunk in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    InlineMeta(label: "chunk \(chunk.chunkId)")
                                    InlineMeta(label: "seq \(chunk.sequenceNo)")
                                    if chunk.isFinal {
                                        InlineMeta(label: "final")
                                    }
                                }
                                Text(chunk.payloadB64)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(colors.inkMuted)
                                    .textSelection(.enabled)
                                if let cursorJson = chunk.cursorJson {
                                    TrixPayloadBox(payload: prettyCursor(cursorJson), minHeight: 72)
                                }
                            }
                            .padding(12)
                            .background(colors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
            }

            if job.role == .source {
                TrixInputBlock(
                    "Append Chunk",
                    hint: "Paste the opaque chunk payload as base64 and choose the monotonic source sequence number."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Sequence No", text: $chunkDraft.sequenceNo)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .trixInputChrome()

                        TextEditor(text: $chunkDraft.payloadB64)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 96)
                            .font(.system(.footnote, design: .monospaced))
                            .trixInputChrome()

                        TextEditor(text: $chunkDraft.cursorJSON)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 92)
                            .font(.system(.footnote, design: .monospaced))
                            .trixInputChrome()

                        Toggle("Mark Final Chunk", isOn: $chunkDraft.isFinal)
                            .toggleStyle(.switch)
                    }
                }

                Button(action: appendChunk) {
                    Label(
                        isAppendingChunk ? "Appending Chunk…" : "Append Chunk",
                        systemImage: "arrow.up.to.line"
                    )
                }
                .buttonStyle(TrixActionButtonStyle(tone: .secondary))
                .disabled(isAppendingChunk)
            }

            if job.role == .source && job.isCompletable {
                TrixInputBlock(
                    "Complete Cursor JSON",
                    hint: "Optional JSON persisted while marking the job completed. Leave empty to send `null`."
                ) {
                    TextEditor(text: $cursorText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 92)
                        .font(.system(.footnote, design: .monospaced))
                        .trixInputChrome()
                }

                Button(action: complete) {
                    Label(
                        isCompleting ? "Completing Job…" : "Mark Completed",
                        systemImage: "checkmark.circle"
                    )
                }
                .buttonStyle(TrixActionButtonStyle(tone: .primary))
                .disabled(isCompleting)
            }
        }
        .padding(16)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private var statusTint: Color {
        switch job.jobStatus {
        case .pending:
            return colors.warning
        case .running:
            return colors.accent
        case .completed:
            return colors.success
        case .failed, .canceled:
            return colors.rust
        }
    }

    private var roleTint: Color {
        switch job.role {
        case .source:
            return colors.accent
        case .target:
            return colors.success
        }
    }

    private var jobSubtitle: String {
        switch job.role {
        case .source:
            return "job \(shortID(job.jobId)) • target \(shortID(job.targetDeviceId))"
        case .target:
            return "job \(shortID(job.jobId)) • source \(shortID(job.sourceDeviceId))"
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    private func prettyCursor(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard
            let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "cursor unavailable"
        }

        return string
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct DeviceRow: View {
    @Environment(\.trixColors) private var colors
    let device: DeviceSummary
    let isCurrentDevice: Bool
    let canApprove: Bool
    let isApproving: Bool
    let canRevoke: Bool
    let isRevoking: Bool
    let approve: () -> Void
    let revoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text(device.platform)
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if isCurrentDevice {
                        Text("current")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(colors.accent)
                    }
                    TrixToneBadge(
                        label: device.deviceStatus.label,
                        tint: device.deviceStatus == .active ? colors.success : (device.deviceStatus == .pending ? colors.warning : colors.rust)
                    )
                }
            }

            if canApprove || canRevoke {
                HStack(spacing: 10) {
                    if canApprove {
                        Button(action: approve) {
                            Label(
                                isApproving ? "Approving…" : "Approve Device",
                                systemImage: "checkmark.seal.fill"
                            )
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .primary))
                        .disabled(isApproving || isRevoking)
                    }

                    if canRevoke {
                        Button(role: .destructive, action: revoke) {
                            Label(
                                isRevoking ? (device.deviceStatus == .pending ? "Rejecting…" : "Revoking…") : (device.deviceStatus == .pending ? "Reject Pending Device" : "Revoke Device"),
                                systemImage: "xmark.shield"
                            )
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                        .disabled(isApproving || isRevoking)
                    }
                }
            }
        }
        .padding(16)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct ChatMemberInspectorRow: View {
    @Environment(\.trixColors) private var colors
    let profile: ChatParticipantProfileSummary?
    let member: ChatMemberSummary
    let isCurrentAccount: Bool
    let canRemove: Bool
    let isRemoving: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(profile?.displayName ?? shortID(member.accountId))
                        .font(.headline)
                        .foregroundStyle(colors.ink)

                    if isCurrentAccount {
                        TrixToneBadge(label: "You", tint: colors.accent)
                    }
                }

                Text([profile?.handleLabel, member.role].compactMap { $0 }.joined(separator: " • "))
                    .font(.subheadline)
                    .foregroundStyle(colors.inkMuted)

                if let profileBio = trimmedValue(profile?.profileBio) {
                    Text(profileBio)
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 10) {
                Text(member.membershipStatus)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colors.inkMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(colors.inputFill, in: Capsule())

                if canRemove {
                    Button(role: .destructive, action: remove) {
                        Label(isRemoving ? "Removing…" : "Remove", systemImage: "person.badge.minus")
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                    .disabled(isRemoving)
                }
            }
        }
        .padding(14)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }
}

private struct ChatDeviceInspectorRow: View {
    @Environment(\.trixColors) private var colors
    let device: ChatDeviceSummary
    let ownerProfile: ChatParticipantProfileSummary?
    let isCurrentDevice: Bool
    let canRemove: Bool
    let isRemoving: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundStyle(colors.ink)

                    if isCurrentDevice {
                        TrixToneBadge(label: "This Mac", tint: colors.accent)
                    }
                }

                Text([ownerProfile?.displayName, device.platform].compactMap { $0 }.joined(separator: " • "))
                    .font(.subheadline)
                    .foregroundStyle(colors.inkMuted)

                Text("device \(String(device.deviceId.uuidString.prefix(8)).lowercased())")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(colors.inkMuted)
            }

            Spacer(minLength: 12)

            if canRemove {
                Button(role: .destructive, action: remove) {
                    Label(isRemoving ? "Removing…" : "Remove", systemImage: "iphone.gen3.slash")
                }
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                .disabled(isRemoving)
            }
        }
        .padding(14)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct AvailableChatDeviceRow: View {
    @Environment(\.trixColors) private var colors
    let device: DeviceSummary
    let isBusy: Bool
    let add: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(device.displayName)
                    .font(.headline)
                    .foregroundStyle(colors.ink)
                Text(device.platform)
                    .font(.subheadline)
                    .foregroundStyle(colors.inkMuted)
            }

            Spacer(minLength: 12)

            Button(action: add) {
                Label(isBusy ? "Adding…" : "Add Device", systemImage: "plus.circle")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .secondary))
            .disabled(isBusy)
        }
        .padding(14)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct ChatRow: View {
    @Environment(\.trixColors) private var colors
    let chat: ChatSummary
    let currentAccountID: UUID?
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isSelected ? colors.accent.opacity(0.18) : colors.tileFill)
                        .frame(width: 48, height: 48)

                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? colors.accent : colors.inkMuted)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.displayTitle(for: currentAccountID))
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(chat.subtitle(for: currentAccountID))
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                        .lineLimit(2)
                }

                VStack(alignment: .trailing, spacing: 6) {
                    Text("seq \(chat.lastServerSeq)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colors.inkMuted)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .background(
                isSelected ? colors.accentSoft.opacity(0.66) : colors.panel,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? colors.accent.opacity(0.26) : colors.outline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch chat.chatType {
        case .dm:
            return "person.2.fill"
        case .group:
            return "person.3.fill"
        case .accountSync:
            return "arrow.triangle.2.circlepath"
        }
    }
}

private enum WorkspaceMessageReceiptStatus: Int, Comparable {
    case delivered = 0
    case read = 1

    static func < (lhs: WorkspaceMessageReceiptStatus, rhs: WorkspaceMessageReceiptStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var systemImageName: String {
        switch self {
        case .delivered:
            return "checkmark"
        case .read:
            return "checkmark.double"
        }
    }
}

private extension WorkspaceMessageReceiptStatus {
    init?(_ value: ReceiptType) {
        switch value {
        case .delivered:
            self = .delivered
        case .read:
            self = .read
        }
    }
}

private struct PresentedTimelineMessage: Identifiable {
    let message: LocalTimelineItem
    let receiptStatus: WorkspaceMessageReceiptStatus?

    var id: UUID { message.messageId }
}

private struct PresentedHistoryMessage: Identifiable {
    let message: MessageEnvelope
    let isOutgoing: Bool

    var id: UUID { message.messageId }
}

private struct MessageHistoryRow: View {
    @Environment(\.trixColors) private var colors
    let message: MessageEnvelope
    let isOutgoing: Bool
    let fixtureAccessibilityIdentifier: String?

    init(message: MessageEnvelope, isOutgoing: Bool = false, fixtureAccessibilityIdentifier: String? = nil) {
        self.message = message
        self.isOutgoing = isOutgoing
        self.fixtureAccessibilityIdentifier = fixtureAccessibilityIdentifier
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 64)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isOutgoing ? "You" : message.senderShortID)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.ink)

                    Spacer()

                    Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: .now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.inkMuted)
                }

                Text("Encrypted \(message.messageKind.label.lowercased())")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(colors.ink)

                Text("This message is still syncing on this Mac and will appear normally once local history catches up.")
                    .font(.subheadline)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .background(bubbleFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(bubbleBorder, lineWidth: 1)
            }

            if !isOutgoing {
                Spacer(minLength: 64)
            }
        }
        .optionalAccessibilityIdentifier(fixtureAccessibilityIdentifier)
    }

    private var bubbleFill: Color {
        isOutgoing ? colors.accent.opacity(0.12) : colors.tileFill
    }

    private var bubbleBorder: Color {
        isOutgoing ? colors.accent.opacity(0.26) : colors.outline
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct ProjectedMessageRow: View {
    @Environment(\.trixColors) private var colors
    let message: LocalProjectedMessage
    let isOutgoing: Bool

    init(message: LocalProjectedMessage, isOutgoing: Bool = false) {
        self.message = message
        self.isOutgoing = isOutgoing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 64)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isOutgoing ? "You" : message.senderShortID)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.ink)

                    Spacer()

                    Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: .now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.inkMuted)
                }

                if let body = message.body {
                    Text(body.summary)
                        .font(.body)
                        .foregroundStyle(colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let parseError = message.bodyParseError {
                    Text(parseError)
                        .font(.subheadline)
                        .foregroundStyle(colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Projected metadata is available, but this entry has no decoded body.")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    InlineMeta(label: message.projectionKind.label)
                    InlineMeta(label: message.contentType.label)
                    if let body = message.body {
                        InlineMeta(label: body.kind.label)
                    }
                    if let mergedEpoch = message.mergedEpoch {
                        InlineMeta(label: "merged \(mergedEpoch)")
                    }
                    InlineMeta(label: "seq \(message.serverSeq)")
                    if message.payloadSizeBytes > 0 {
                        InlineMeta(label: "\(message.payloadSizeBytes) bytes")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .background(bubbleFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(bubbleBorder, lineWidth: 1)
            }

            if !isOutgoing {
                Spacer(minLength: 64)
            }
        }
    }

    private var bubbleFill: Color {
        isOutgoing ? colors.accent.opacity(0.14) : colors.tileFill
    }

    private var bubbleBorder: Color {
        isOutgoing ? colors.accent.opacity(0.28) : colors.outline
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct ComposerAttachmentRow: View {
    @Environment(\.trixColors) private var colors
    let attachment: AttachmentDraft
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: attachment.isImage ? "photo" : "paperclip")
                .font(.headline)
                .foregroundStyle(colors.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.fileName)
                    .font(.headline)
                    .foregroundStyle(colors.ink)
                Text([attachment.mimeType, formattedByteCount(attachment.fileSizeBytes)].joined(separator: " • "))
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
            }

            Spacer(minLength: 12)

            Button(role: .destructive, action: clear) {
                Label("Remove", systemImage: "xmark.circle")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .ghost))
        }
        .padding(14)
        .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

private struct PendingOutgoingMessageRow: View {
    @Environment(\.trixColors) private var colors
    let message: PendingOutgoingMessage
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 64)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("You")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.ink)

                    Spacer()

                    TrixToneBadge(
                        label: message.status == .sending ? "Sending…" : "Failed",
                        tint: message.status == .sending ? colors.warning : colors.rust
                    )
                }

                switch message.payload {
                case let .text(text):
                    Text(text)
                        .font(.body)
                        .foregroundStyle(colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                case let .attachment(attachment):
                    HStack(spacing: 10) {
                        Image(systemName: attachment.isImage ? "photo" : "paperclip")
                            .foregroundStyle(colors.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(attachment.fileName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(colors.ink)
                            Text([attachment.mimeType, formattedByteCount(attachment.fileSizeBytes)].joined(separator: " • "))
                                .font(.footnote)
                                .foregroundStyle(colors.inkMuted)
                        }
                    }
                }

                if let errorMessage = trimmedValue(message.errorMessage) {
                    Text(localizedPendingOutgoingError(errorMessage))
                        .font(.footnote)
                        .foregroundStyle(colors.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if message.status == .failed {
                    HStack(spacing: 10) {
                        Button(action: retry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive, action: discard) {
                            Label("Dismiss", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
            .background(colors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        message.status == .sending ? colors.accent.opacity(0.24) : colors.rust.opacity(0.28),
                        lineWidth: 1
                    )
            }
        }
    }

}

private struct LocalTimelineMessageRow: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let message: LocalTimelineItem
    let isOutgoing: Bool
    let receiptStatus: WorkspaceMessageReceiptStatus?
    let isDownloadingAttachment: Bool
    let openAttachment: (() -> Void)?
    let onSelectReaction: ((LocalTimelineItem, String) -> Void)?
    let fixtureAccessibilityIdentifier: String?

    init(
        model: AppModel,
        message: LocalTimelineItem,
        isOutgoing: Bool = false,
        receiptStatus: WorkspaceMessageReceiptStatus? = nil,
        isDownloadingAttachment: Bool = false,
        openAttachment: (() -> Void)? = nil,
        onSelectReaction: ((LocalTimelineItem, String) -> Void)? = nil,
        fixtureAccessibilityIdentifier: String? = nil
    ) {
        self.model = model
        self.message = message
        self.isOutgoing = isOutgoing
        self.receiptStatus = receiptStatus
        self.isDownloadingAttachment = isDownloadingAttachment
        self.openAttachment = openAttachment
        self.onSelectReaction = onSelectReaction
        self.fixtureAccessibilityIdentifier = fixtureAccessibilityIdentifier
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 64)
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(senderLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.ink)

                        Spacer()

                        HStack(spacing: 6) {
                            if isOutgoing, let receiptStatus {
                                Image(systemName: receiptStatus.systemImageName)
                                    .font(.caption.weight(.semibold))
                            }

                            Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: .now))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(colors.inkMuted)
                    }

                    if let body = message.body, body.kind == .attachment {
                        VStack(alignment: .leading, spacing: 12) {
                            if LocalImageAttachmentSupport.supports(
                                mimeType: body.mimeType,
                                fileName: body.fileName
                            ) {
                                WorkspaceInlineAttachmentPreview(
                                    model: model,
                                    message: message,
                                    attachmentBody: body,
                                    openAttachment: openAttachment
                                )
                            }

                            HStack(alignment: .center, spacing: 12) {
                                if !LocalImageAttachmentSupport.supports(
                                    mimeType: body.mimeType,
                                    fileName: body.fileName
                                ) {
                                    Image(systemName: body.mimeType?.hasPrefix("image/") == true ? "photo" : "paperclip")
                                        .font(.headline)
                                        .foregroundStyle(colors.accent)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(body.fileName ?? "Attachment")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(colors.ink)
                                    Text(attachmentMeta(body))
                                        .font(.footnote)
                                        .foregroundStyle(colors.inkMuted)
                                }

                                Spacer(minLength: 12)

                                if let openAttachment {
                                    Button(action: openAttachment) {
                                        Label(isDownloadingAttachment ? "Opening…" : "Open", systemImage: "arrow.down.circle")
                                    }
                                    .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                                    .disabled(isDownloadingAttachment)
                                }
                            }
                        }
                    } else {
                        Text(message.bodySummary)
                            .font(.body)
                            .foregroundStyle(message.bodyParseError == nil ? colors.ink : colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if message.contentType != .text || message.bodyParseError != nil {
                        HStack(spacing: 10) {
                            InlineMeta(label: message.contentType.label)
                            if let body = message.body {
                                InlineMeta(label: body.kind.label)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
                .background(bubbleFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(bubbleBorder, lineWidth: 1)
                }

                if !message.reactions.isEmpty {
                    ReactionMetaChipRow(
                        reactions: message.reactions,
                        isOutgoing: isOutgoing
                    )
                }
            }

            if !isOutgoing {
                Spacer(minLength: 64)
            }
        }
        .optionalAccessibilityIdentifier(fixtureAccessibilityIdentifier)
        .contextMenu {
            if let onSelectReaction {
                ForEach(workspaceQuickReactionEmojis, id: \.self) { emoji in
                    let removeExisting = message.reactions.contains {
                        $0.emoji == emoji && $0.includesSelf
                    }
                    Button(removeExisting ? "\(emoji) Remove" : emoji) {
                        onSelectReaction(message, emoji)
                    }
                }
            }
        }
    }

    private var senderLabel: String {
        if isOutgoing {
            return "You"
        }

        let trimmed = message.senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? shortID(message.senderAccountId) : trimmed
    }

    private var bubbleFill: Color {
        isOutgoing ? colors.accent.opacity(0.14) : colors.tileFill
    }

    private var bubbleBorder: Color {
        isOutgoing ? colors.accent.opacity(0.28) : colors.outline
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    private func attachmentMeta(_ body: TypedMessageBody) -> String {
        [
            body.mimeType,
            body.sizeBytes.map(formattedByteCount)
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct ReactionMetaChipRow: View {
    let reactions: [MessageReactionSummary]
    let isOutgoing: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(reactions, id: \.emoji) { reaction in
                    ReactionMetaChip(reaction: reaction)
                }
            }
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        }
        .frame(maxWidth: 620, alignment: isOutgoing ? .trailing : .leading)
    }
}

private struct ReactionMetaChip: View {
    @Environment(\.trixColors) private var colors
    let reaction: MessageReactionSummary

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(reaction.includesSelf ? colors.accent : colors.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                reaction.includesSelf ? colors.accent.opacity(0.12) : colors.inputFill,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        reaction.includesSelf ? colors.accent.opacity(0.18) : colors.outline,
                        lineWidth: 1
                    )
            }
    }

    private var label: String {
        reaction.count > 1 ? "\(reaction.emoji) \(reaction.count)" : reaction.emoji
    }
}

private struct InlineMeta: View {
    @Environment(\.trixColors) private var colors
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colors.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(colors.inputFill, in: Capsule())
    }
}

private struct EmptyWorkspaceLabel: View {
    @Environment(\.trixColors) private var colors
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(colors.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
