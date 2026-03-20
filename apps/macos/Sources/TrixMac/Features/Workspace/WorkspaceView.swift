import SwiftUI

private enum WorkspaceSurface: String, CaseIterable, Identifiable {
    case messages
    case control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages:
            return "Messages"
        case .control:
            return "Control"
        }
    }

    var subtitle: String {
        switch self {
        case .messages:
            return "Chats and timeline stay on the primary surface."
        case .control:
            return "Linking, sync and diagnostics live behind the scenes."
        }
    }

    var iconName: String {
        switch self {
        case .messages:
            return "bubble.left.and.bubble.right.fill"
        case .control:
            return "switch.2"
        }
    }
}

struct WorkspaceView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let availableSize: CGSize
    @State private var activeSurface: WorkspaceSurface = .messages
    @State private var composerDraft = ""
    @State private var isPresentingCreateChat = false

    private var prefersSingleColumn: Bool {
        availableSize.width < 1380 || availableSize.height < 860
    }

    private var timelineUsesLocalData: Bool {
        !model.selectedChatTimelineItems.isEmpty
    }

    private var timelineUsesEncryptedFallback: Bool {
        model.selectedChatTimelineItems.isEmpty && !model.selectedChatHistory.isEmpty
    }

    private var presentationAccountID: UUID? {
        model.chatPresentationAccountID
    }

    var body: some View {
        if let currentAccount = model.currentAccount {
            VStack(alignment: .leading, spacing: 20) {
                workspaceToolbar

                if activeSurface == .messages {
                    conversationPanel(currentAccount)
                } else {
                    controlSurface
                }
            }
            .sheet(isPresented: $isPresentingCreateChat) {
                CreateChatSheet(
                    model: model,
                    isPresented: $isPresentingCreateChat
                ) {
                    activeSurface = .messages
                }
            }
            .onChange(of: model.selectedChatID, initial: false) { _, _ in
                composerDraft = ""
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

    private var workspaceToolbar: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(activeSurface == .messages ? "Messages" : "Control")
                    .font(.system(size: availableSize.height < 760 ? 32 : 38, weight: .bold, design: .serif))
                    .foregroundStyle(colors.ink)

                Text(toolbarSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 12) {
                    if activeSurface == .messages {
                        Button {
                            model.resetCreateChatComposer()
                            isPresentingCreateChat = true
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    }

                    HStack(spacing: 8) {
                        ForEach(WorkspaceSurface.allCases) { surface in
                            WorkspaceSurfaceButton(
                                surface: surface,
                                isSelected: activeSurface == surface
                            ) {
                                activeSurface = surface
                            }
                        }
                    }
                }
            }
        }
    }

    private var toolbarSubtitle: String {
        if activeSurface == .control {
            return "Linking, sync and diagnostics stay secondary."
        }

        if let selectedChatListItem = model.selectedChatListItem {
            return selectedChatListItem.participantSubtitle(for: presentationAccountID)
        }

        if let selectedChatSummary = model.selectedChatSummary {
            return selectedChatSummary.subtitle(for: presentationAccountID)
        }

        return "Choose a conversation from the sidebar."
    }

    private var controlSurface: some View {
        Group {
            if prefersSingleColumn {
                VStack(alignment: .leading, spacing: 20) {
                    controlSummaryPanel
                    operationsColumn
                    controlInspectorColumn
                }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 20) {
                        controlSummaryPanel
                        operationsColumn
                    }
                    .frame(width: 380)

                    controlInspectorColumn
                }
            }
        }
    }

    @ViewBuilder
    private func conversationPanel(_ currentAccount: AccountProfileResponse) -> some View {
        if let selectedChatListItem = model.selectedChatListItem ?? fallbackSelectedChatListItem(currentAccountID: currentAccount.accountId) {
            TrixPanel(
                title: selectedChatListItem.displayTitle,
                subtitle: selectedChatListItem.participantSubtitle(for: currentAccount.accountId)
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        TrixToneBadge(
                            label: selectedChatListItem.chatType.label,
                            tint: colors.accent
                        )

                        if timelineUsesLocalData {
                            TrixToneBadge(label: "Local timeline", tint: colors.success)
                        } else if timelineUsesEncryptedFallback {
                            TrixToneBadge(label: "Encrypted fallback", tint: colors.warning)
                        } else {
                            TrixToneBadge(label: "No local timeline yet", tint: colors.inkMuted)
                        }

                        if model.isLoadingSelectedChat {
                            TrixToneBadge(label: "Refreshing", tint: colors.rust)
                        }
                    }

                    if let detail = model.selectedChatDetail {
                        conversationMetadata(detail)
                    }

                    conversationTimeline()
                    composerPanel(chatTitle: selectedChatListItem.displayTitle)
                }
            }
        } else {
            TrixPanel(
                title: "Choose A Conversation",
                subtitle: "This space should be your timeline, not a dashboard."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    EmptyWorkspaceLabel("Pick a chat from the left rail or start a new one. The conversation canvas will take over this area once a chat exists.")

                    Button {
                        model.resetCreateChatComposer()
                        isPresentingCreateChat = true
                    } label: {
                        Label("Start New Chat", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private var controlSummaryPanel: some View {
        TrixPanel(
            title: "Control Room",
            subtitle: "Operational tooling stays here so the primary workspace can behave like a messenger."
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: availableSize.width < 1160 ? 180 : 220), spacing: 12)], alignment: .leading, spacing: 12) {
                WorkspaceSummaryChip(
                    iconName: "person.crop.circle.badge.checkmark",
                    label: "\(model.devices.count) device record\(model.devices.count == 1 ? "" : "s")",
                    tone: .surface
                )
                WorkspaceSummaryChip(
                    iconName: "tray.and.arrow.down.fill",
                    label: "\(model.inboxItems.count) inbox item\(model.inboxItems.count == 1 ? "" : "s") loaded",
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
                title: "Inbox Polling",
                subtitle: "Incremental inbox inspection with local cache ingest and persisted sync cursors for this device."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        if let lease = model.activeInboxLease {
                            TrixToneBadge(
                                label: lease.isExpired ? "Lease expired" : "Lease active",
                                tint: lease.isExpired ? colors.warning : colors.success
                            )

                            Text("\(lease.owner) until \(Self.linkExpiryFormatter.localizedString(for: lease.expiresAt, relativeTo: .now))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(colors.inkMuted)
                        } else {
                            TrixToneBadge(label: "No active lease", tint: colors.inkMuted)
                        }
                    }

                    if let lastInboxCursor = model.lastInboxCursor {
                        Text("Last seen inbox id \(lastInboxCursor)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(colors.inkMuted)
                    }

                    TrixInputBlock(
                        "After Inbox ID",
                        hint: "Leave empty for the earliest visible pending items. Successful poll and lease actions advance this cursor automatically."
                    ) {
                        TextField("0", text: $model.inboxLeaseDraft.afterInboxID)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .trixInputChrome()
                    }

                    if prefersSingleColumn {
                        VStack(alignment: .leading, spacing: 16) {
                            inboxLimitField
                            inboxLeaseTTLField
                            inboxLeaseOwnerField
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 16) {
                                inboxLimitField
                                inboxLeaseTTLField
                            }
                            inboxLeaseOwnerField
                        }
                    }

                    if prefersSingleColumn {
                        VStack(spacing: 12) {
                            inboxPrimaryActions
                            inboxSecondaryActions
                        }
                    } else {
                        inboxPrimaryActions
                        inboxSecondaryActions
                    }

                    if !model.lastAckedInboxIDs.isEmpty {
                        Text("last acked \(model.lastAckedInboxIDs.count) item(s) through inbox \(model.lastAckedInboxIDs.max() ?? 0)")
                            .font(.footnote)
                            .foregroundStyle(colors.inkMuted)
                    }

                    if model.inboxItems.isEmpty {
                        EmptyWorkspaceLabel("No inbox items are loaded into this shell yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.inboxItems) { item in
                                InboxItemRow(item: item)
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
                                    isCompleting: model.completingHistorySyncJobIDs.contains(job.jobId)
                                ) {
                                    Task {
                                        await model.completeHistorySyncJob(job.jobId)
                                    }
                                }
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
                    } else if model.selectedChatHistory.isEmpty {
                        EmptyWorkspaceLabel("This chat has no server-stored messages yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.selectedChatHistory) { message in
                                MessageHistoryRow(message: message)
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
                ConversationMetaChip(label: "Epoch", value: "\(detail.epoch)")
                ConversationMetaChip(label: "Server", value: "seq \(detail.lastServerSeq)")
                ConversationMetaChip(label: "Unread", value: "\(model.selectedChatReadState?.unreadCount ?? 0)")
                ConversationMetaChip(
                    label: "Timeline",
                    value: timelineUsesLocalData ? "local" : (timelineUsesEncryptedFallback ? "encrypted fallback" : "empty")
                )
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Timeline")
                    .font(.headline)
                    .foregroundStyle(colors.ink)

                Spacer()

                TrixToneBadge(
                    label: timelineBadgeLabel,
                    tint: timelineUsesLocalData ? colors.success : (timelineUsesEncryptedFallback ? colors.warning : colors.inkMuted)
                )
            }

            if model.isLoadingSelectedChat && model.selectedChatTimelineItems.isEmpty && model.selectedChatHistory.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading conversation…")
                        .foregroundStyle(colors.inkMuted)
                }
            } else if timelineUsesLocalData {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.selectedChatTimelineItems) { message in
                        LocalTimelineMessageRow(
                            message: message,
                            isOutgoing: message.isOutgoing
                        )
                    }
                }
            } else if timelineUsesEncryptedFallback {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Encrypted envelopes are stored locally, but this conversation still needs a projected local timeline on this Mac.")
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.selectedChatHistory) { message in
                        MessageHistoryRow(
                            message: message,
                            isOutgoing: presentationAccountID.map { $0 == message.senderAccountId } ?? false
                        )
                    }
                }
            } else {
                EmptyWorkspaceLabel("No local messages are stored for this conversation yet.")
            }
        }
        .padding(20)
        .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private func composerPanel(chatTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Composer")
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text("Messages send through the local MLS state for this conversation.")
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                TrixToneBadge(
                    label: model.isSendingMessage ? "Sending…" : "Ready to send",
                    tint: model.isSendingMessage ? colors.warning : colors.success
                )
            }

            ZStack(alignment: .topLeading) {
                if composerDraft.isEmpty {
                    Text("Write a reply to \(chatTitle)…")
                        .font(.body)
                        .foregroundStyle(colors.inkMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                }

                TextEditor(text: $composerDraft)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .font(.body)
                    .trixInputChrome()
            }

            HStack(spacing: 12) {
                Button {
                    composerDraft = ""
                } label: {
                    Label("Clear Draft", systemImage: "xmark.circle")
                }
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                .disabled(composerDraft.isEmpty)

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
                    composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        model.isSendingMessage
                )
            }
        }
        .padding(20)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private var timelineBadgeLabel: String {
        if timelineUsesLocalData {
            return "\(model.selectedChatTimelineItems.count) messages"
        }
        if timelineUsesEncryptedFallback {
            return "\(model.selectedChatHistory.count) encrypted"
        }
        return "No messages yet"
    }

    private func fallbackSelectedChatListItem(currentAccountID: UUID) -> LocalChatListItem? {
        guard let summary = model.selectedChatSummary else {
            return nil
        }

        return LocalChatListItem(
            chatId: summary.chatId,
            chatType: summary.chatType,
            title: summary.title,
            displayTitle: summary.displayTitle(for: currentAccountID),
            lastServerSeq: summary.lastServerSeq,
            pendingMessageCount: 0,
            unreadCount: model.selectedChatReadState?.unreadCount ?? 0,
            previewText: model.selectedChatTimelineItems.last?.previewText,
            previewSenderAccountId: model.selectedChatTimelineItems.last?.senderAccountId,
            previewSenderDisplayName: model.selectedChatTimelineItems.last?.senderDisplayName,
            previewIsOutgoing: model.selectedChatTimelineItems.last?.isOutgoing,
            previewServerSeq: model.selectedChatTimelineItems.last?.serverSeq,
            previewCreatedAtUnix: model.selectedChatTimelineItems.last?.createdAtUnix,
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

    private var inboxPrimaryActions: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await model.refreshInbox()
                }
            } label: {
                Label(
                    model.isRefreshingInbox ? "Polling Inbox…" : "Poll Inbox",
                    systemImage: "tray.and.arrow.down"
                )
            }
            .buttonStyle(TrixActionButtonStyle(tone: .secondary))
            .disabled(model.isRefreshingInbox || model.isLeasingInbox || model.isAckingInbox)

            Button {
                Task {
                    await model.leaseInbox()
                }
            } label: {
                Label(
                    model.isLeasingInbox ? "Leasing Inbox…" : "Lease Inbox",
                    systemImage: "lock.open.display"
                )
            }
            .buttonStyle(TrixActionButtonStyle(tone: .primary))
            .disabled(model.isRefreshingInbox || model.isLeasingInbox || model.isAckingInbox)
        }
    }

    private var inboxSecondaryActions: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await model.ackLoadedInboxItems()
                }
            } label: {
                Label(
                    model.isAckingInbox ? "Acking Loaded…" : "Ack Loaded",
                    systemImage: "checkmark.circle"
                )
            }
            .buttonStyle(TrixActionButtonStyle(tone: .ghost))
            .disabled(!model.canAckLoadedInboxItems || model.isRefreshingInbox || model.isLeasingInbox)

            Button {
                model.useLastInboxCursor()
            } label: {
                Label("Use Last Cursor", systemImage: "arrow.turn.down.right")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .ghost))
            .disabled(model.lastInboxCursor == nil)

            Button {
                model.resetInboxCursor()
            } label: {
                Label("Reset Cursor", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .ghost))

            Button {
                model.clearLoadedInboxItems()
            } label: {
                Label("Clear Loaded", systemImage: "trash")
            }
            .buttonStyle(TrixActionButtonStyle(tone: .ghost))
            .disabled(model.inboxItems.isEmpty)
        }
    }

    private var inboxLimitField: some View {
        TrixInputBlock("Limit", hint: "1...500 items per poll.") {
            TextField("50", text: $model.inboxLeaseDraft.limit)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .trixInputChrome()
        }
    }

    private var inboxLeaseTTLField: some View {
        TrixInputBlock("Lease TTL", hint: "1...300 seconds for `/v0/inbox/lease`.") {
            TextField("30", text: $model.inboxLeaseDraft.leaseTTLSeconds)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .trixInputChrome()
        }
    }

    private var inboxLeaseOwnerField: some View {
        TrixInputBlock("Lease Owner", hint: "Optional diagnostic owner label. Leave blank to let the server generate one.") {
            TextField("macos-alpha:device", text: $model.inboxLeaseDraft.leaseOwner)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .trixInputChrome()
        }
    }

    private static let linkExpiryFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct WorkspaceSurfaceButton: View {
    @Environment(\.trixColors) private var colors
    let surface: WorkspaceSurface
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: surface.iconName)
                    .font(.subheadline.weight(.semibold))
                Text(surface.title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? colors.accentSoft.opacity(0.8) : colors.panel,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? colors.accent.opacity(0.24) : colors.outline, lineWidth: 1)
            }
            .foregroundStyle(isSelected ? colors.ink : colors.inkMuted)
        }
        .buttonStyle(.plain)
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

private func trimmedValue(_ rawValue: String?) -> String? {
    guard let rawValue else {
        return nil
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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

                Text("MLS payload is stored locally, but the projected body is not available for this row yet.")
                    .font(.subheadline)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    InlineMeta(label: "seq \(message.serverSeq)")
                    InlineMeta(label: message.contentType.label)
                    InlineMeta(label: "\(message.ciphertextSizeBytes) bytes")
                    InlineMeta(label: "epoch \(message.epoch)")
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

private struct LocalTimelineMessageRow: View {
    @Environment(\.trixColors) private var colors
    let message: LocalTimelineItem
    let isOutgoing: Bool

    init(message: LocalTimelineItem, isOutgoing: Bool = false) {
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
                    Text(senderLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.ink)

                    Spacer()

                    Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: .now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.inkMuted)
                }

                Text(message.bodySummary)
                    .font(.body)
                    .foregroundStyle(message.bodyParseError == nil ? colors.ink : colors.warning)
                    .fixedSize(horizontal: false, vertical: true)

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
