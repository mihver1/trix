import SwiftUI
import UniformTypeIdentifiers

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

    private var presentedTimelineMessages: [PresentedTimelineMessage] {
        var receiptStatusByMessageID: [UUID: WorkspaceMessageReceiptStatus] = [:]
        let visibleMessages = model.selectedChatTimelineItems.compactMap { message -> LocalTimelineItem? in
            guard !isReceiptTimelineMessage(message) else {
                if let targetMessageID = message.body?.targetMessageId {
                    receiptStatusByMessageID[targetMessageID] = mergeReceiptStatus(
                        receiptStatusByMessageID[targetMessageID],
                        with: receiptStatus(for: message) ?? .delivered
                    )
                }
                return nil
            }

            return message
        }

        return visibleMessages.map { message in
            PresentedTimelineMessage(
                message: message,
                receiptStatus: message.isOutgoing ? receiptStatusByMessageID[message.messageId] : nil
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
            .sheet(isPresented: $isPresentingSettings) {
                settingsSheet
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
                    model.lastErrorMessage = error.localizedDescription
                }
            }
            .onChange(of: model.selectedChatID, initial: false) { _, _ in
                composerDraft = ""
                memberSearchQuery = ""
                memberSearchResults = []
            }
            .task(id: model.visibleLocalChatListItems.first?.chatId) {
                guard model.selectedChatID == nil, let firstChat = model.visibleLocalChatListItems.first else {
                    return
                }
                await model.selectChat(firstChat.chatId)
            }
        } else {
            TrixPanel(
                title: "Restore Session",
                subtitle: "A local device profile exists, but the app still needs to re-authenticate against the server."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reconnect to reload account metadata, device state and encrypted chat history.")
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
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .frame(maxWidth: 220)
                    .disabled(model.isRestoringSession)
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
        HStack(alignment: .center, spacing: 16) {
            ConversationAvatar(
                title: selectedChatTitle,
                chatType: selectedChatType
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(selectedChatTitle)
                    .font(.system(size: availableSize.height < 760 ? 23 : 26, weight: .bold, design: .serif))
                    .foregroundStyle(colors.ink)

                Text(toolbarSubtitle)
                    .font(.callout)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                Button {
                    model.resetCreateChatComposer()
                    isPresentingCreateChat = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.headline.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(MessengerToolbarIconButtonStyle())

                Button {
                    activeSettingsTab = .profile
                    isPresentingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.headline.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(MessengerToolbarIconButtonStyle())
            }
        }
        .padding(.horizontal, 4)
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
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(colors.accent)

            Text("Choose a conversation")
                .font(.title3.weight(.bold))
                .foregroundStyle(colors.ink)

            Text("Pick a chat from the left or start a new one.")
                .font(.subheadline)
                .foregroundStyle(colors.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.resetCreateChatComposer()
                isPresentingCreateChat = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(colors.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private var settingsSheet: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(colors.ink)

                    Text("Profile, devices, notifications and advanced tooling live here.")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SettingsTab.allCases) { tab in
                        SettingsTabButton(
                            tab: tab,
                            isSelected: activeSettingsTab == tab
                        ) {
                            activeSettingsTab = tab
                        }
                    }
                }

                Spacer()

                Button("Done") {
                    isPresentingSettings = false
                }
                .buttonStyle(TrixActionButtonStyle(tone: .primary))
            }
            .frame(width: 260, alignment: .topLeading)
            .padding(24)
            .background(colors.panelStrong)

            Rectangle()
                .fill(colors.outline)
                .frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsContent
                }
                .padding(24)
            }
            .background(colors.panel)
        }
        .frame(minWidth: 1080, minHeight: 760)
        .background(colors.panel)
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
                            .textFieldStyle(.plain)
                            .trixInputChrome()
                    }

                    TrixInputBlock("Handle", hint: "Optional public handle.") {
                        TextField("mihver", text: $model.editProfileDraft.handle)
                            .textFieldStyle(.plain)
                            .trixInputChrome()
                    }

                    TrixInputBlock("Bio", hint: "Optional short profile bio.") {
                        TextEditor(text: $model.editProfileDraft.profileBio)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120)
                            .font(.body)
                            .trixInputChrome()
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
                        .buttonStyle(TrixActionButtonStyle(tone: .primary))
                        .disabled(!model.canUpdateProfile)

                        Button(role: .destructive) {
                            model.signOut()
                            isPresentingSettings = false
                        } label: {
                            Label("Forget This Device", systemImage: "trash")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .ghost))
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
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
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
                            .buttonStyle(TrixActionButtonStyle(tone: .secondary))

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
                        }
                    }

                    Divider()
                        .overlay(colors.outline)

                    chatMembersInspector(detail: detail, currentAccount: currentAccount)

                    Divider()
                        .overlay(colors.outline)

                    chatDevicesInspector(detail: detail, currentAccount: currentAccount)
                }
                .padding(20)
            }
            .background(colors.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(colors.ink)
                Text("Choose a conversation to see people and devices.")
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colors.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
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
                    canRemove: canManageSelectedChatMembers && member.accountId != currentAccount.accountId,
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
                            .textFieldStyle(.plain)
                            .trixInputChrome()
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
                        .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                    canRemove: canManageSelectedChatDevices && device.deviceId != model.currentDeviceID,
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
                                isOutgoing: message.isOutgoing
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
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private func composerPanel(chatTitle: String) -> some View {
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
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 88, maxHeight: 140)
                    .font(.body)
                    .trixInputChrome()
            }

            HStack(spacing: 12) {
                Button {
                    isImportingAttachment = true
                } label: {
                    Label(model.composerAttachmentDraft == nil ? "Attach" : "Replace", systemImage: "paperclip")
                }
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                .disabled(model.isSendingMessage)

                Button {
                    composerDraft = ""
                } label: {
                    Label("Clear Draft", systemImage: "xmark.circle")
                }
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
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
                .buttonStyle(TrixActionButtonStyle(tone: .primary))
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
        .background(colors.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private var timelineScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(presentedTimelineMessages) { entry in
                    LocalTimelineMessageRow(
                        message: entry.message,
                        isOutgoing: entry.message.isOutgoing,
                        receiptStatus: entry.receiptStatus,
                        isDownloadingAttachment: model.downloadingAttachmentMessageIDs.contains(entry.message.messageId),
                        openAttachment: entry.message.body?.kind == .attachment ? {
                            Task {
                                await model.openAttachment(for: entry.message)
                            }
                        } : nil
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

    private func isReceiptTimelineMessage(_ message: LocalTimelineItem) -> Bool {
        message.contentType == .receipt || message.body?.kind == .receipt
    }

    private func receiptStatus(for message: LocalTimelineItem) -> WorkspaceMessageReceiptStatus? {
        guard isReceiptTimelineMessage(message) else {
            return nil
        }

        return message.body?.receiptType == .read ? .read : .delivered
    }

    private func mergeReceiptStatus(
        _ current: WorkspaceMessageReceiptStatus?,
        with next: WorkspaceMessageReceiptStatus
    ) -> WorkspaceMessageReceiptStatus {
        current.map { max($0, next) } ?? next
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

    private static let linkExpiryFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct SettingsTabButton: View {
    @Environment(\.trixColors) private var colors
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: tab.iconName)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? colors.accentSoft.opacity(0.8) : colors.tileFill,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? colors.accent.opacity(0.24) : colors.outline, lineWidth: 1)
            }
            .foregroundStyle(isSelected ? colors.ink : colors.inkMuted)
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationAvatar: View {
    @Environment(\.trixColors) private var colors
    let title: String
    let chatType: ChatType?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colors.panel)
                .frame(width: 48, height: 48)

            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(colors.accent)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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

private struct MessengerToolbarIconButtonStyle: ButtonStyle {
    @Environment(\.trixColors) private var colors

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(10)
            .background(
                colors.tileFill.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
            .foregroundStyle(colors.ink)
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
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
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
                        .textFieldStyle(.plain)
                        .trixInputChrome()
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
                        .textFieldStyle(.plain)
                        .trixInputChrome()
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
                    .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))

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
                .buttonStyle(TrixActionButtonStyle(tone: .primary))
                .disabled(!model.canCreateChat)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(colors.panelStrong, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
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
    let isCompleting: Bool
    let complete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.jobType.label)
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text("job \(shortID(job.jobId)) • target \(shortID(job.targetDeviceId))")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }
                Spacer()
                TrixToneBadge(label: job.jobStatus.label, tint: statusTint)
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

            if job.isCompletable {
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

private struct InboxItemRow: View {
    @Environment(\.trixColors) private var colors
    let item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("inbox \(item.inboxId) • seq \(item.message.serverSeq)")
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text("chat \(shortID(item.message.chatId)) • sender \(item.message.senderShortID)")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: item.message.createdAt, relativeTo: .now))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.inkMuted)
            }

            HStack(spacing: 10) {
                InlineMeta(label: item.message.messageKind.label)
                InlineMeta(label: item.message.contentType.label)
                InlineMeta(label: "\(item.message.ciphertextSizeBytes) bytes")
                InlineMeta(label: "epoch \(item.message.epoch)")
            }
        }
        .padding(16)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
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

    init(message: MessageEnvelope, isOutgoing: Bool = false) {
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
                    Text(userFacingError(errorMessage))
                        .font(.footnote)
                        .foregroundStyle(colors.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if message.status == .failed {
                    HStack(spacing: 10) {
                        Button(action: retry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .secondary))

                        Button(role: .destructive, action: discard) {
                            Label("Dismiss", systemImage: "trash")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .ghost))
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

    private func userFacingError(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        if normalized.contains("epoch") || normalized.contains("mls") || normalized.contains("conversation") {
            return "Couldn't send this message right now. Try again in a moment."
        }
        return rawValue
    }
}

private struct LocalTimelineMessageRow: View {
    @Environment(\.trixColors) private var colors
    let message: LocalTimelineItem
    let isOutgoing: Bool
    let receiptStatus: WorkspaceMessageReceiptStatus?
    let isDownloadingAttachment: Bool
    let openAttachment: (() -> Void)?

    init(
        message: LocalTimelineItem,
        isOutgoing: Bool = false,
        receiptStatus: WorkspaceMessageReceiptStatus? = nil,
        isDownloadingAttachment: Bool = false,
        openAttachment: (() -> Void)? = nil
    ) {
        self.message = message
        self.isOutgoing = isOutgoing
        self.receiptStatus = receiptStatus
        self.isDownloadingAttachment = isDownloadingAttachment
        self.openAttachment = openAttachment
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 64)
            }

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
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: body.mimeType?.hasPrefix("image/") == true ? "photo" : "paperclip")
                            .font(.headline)
                            .foregroundStyle(colors.accent)

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

            if !isOutgoing {
                Spacer(minLength: 64)
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
