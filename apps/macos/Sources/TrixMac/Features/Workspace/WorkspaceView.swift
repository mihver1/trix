import SwiftUI

struct WorkspaceView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let availableSize: CGSize

    private var prefersSingleColumn: Bool {
        availableSize.width < 1380 || availableSize.height < 860
    }

    var body: some View {
        if let currentAccount = model.currentAccount {
            VStack(alignment: .leading, spacing: 20) {
                TrixPanel(
                    title: currentAccount.profileName,
                    subtitle: currentAccount.handle ?? "No public handle yet.",
                    tone: .strong
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let profileBio = currentAccount.profileBio, !profileBio.isEmpty {
                            Text(profileBio)
                                .font(.body)
                                .foregroundStyle(colors.inkMuted)
                        }

                        HStack(spacing: 16) {
                            TrixMetricTile(
                                label: "Account",
                                value: shortID(currentAccount.accountId),
                                footnote: "Authenticated via challenge/session"
                            )
                            TrixMetricTile(
                                label: "Devices",
                                value: "\(model.devices.count)",
                                footnote: model.hasAccountRootKey ? "This Mac can sign root-level device actions" : "This Mac cannot sign root-level device actions"
                            )
                            TrixMetricTile(
                                label: "Chats",
                                value: "\(model.chats.count)",
                                footnote: "Sorted from live server metadata"
                            )
                            TrixMetricTile(
                                label: "Sync Jobs",
                                value: "\(model.historySyncJobs.count)",
                                footnote: "Visible for this source device"
                            )
                        }
                    }
                }

                if prefersSingleColumn {
                    VStack(alignment: .leading, spacing: 20) {
                        operationsColumn
                        inspectorColumn
                    }
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        operationsColumn
                            .frame(width: 360)

                        inspectorColumn
                    }
                }
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
                subtitle: "Choose a chat to inspect current members and encrypted history metadata."
            ) {
                if model.chats.isEmpty {
                    EmptyWorkspaceLabel("No chats are visible yet. Create another account or use the API to open the first DM or group.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.chats) { chat in
                            ChatRow(
                                chat: chat,
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

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary = model.selectedChatSummary {
                TrixPanel(
                    title: summary.displayTitle,
                    subtitle: "\(summary.chatType.rawValue.replacingOccurrences(of: "_", with: " ")) conversation"
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            TrixToneBadge(label: summary.chatType.rawValue.replacingOccurrences(of: "_", with: " "), tint: colors.accent)
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
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Members")
                                    .font(.headline)
                                    .foregroundStyle(colors.ink)

                                ForEach(detail.members) { member in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(shortID(member.accountId))
                                                .font(.system(.subheadline, design: .monospaced))
                                                .foregroundStyle(colors.ink)
                                            Text(member.role)
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
                    title: "Encrypted History",
                    subtitle: "Raw metadata only for now. Message decryption and compose flow come next."
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
                    subtitle: "The right-hand inspector still focuses on encrypted history and membership metadata."
                ) {
                    EmptyWorkspaceLabel("Select a chat from the operations rail or create one through the API to continue.")
                }
            }
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    private func cursorBinding(for jobID: UUID) -> Binding<String> {
        Binding(
            get: { model.historySyncCursorDrafts[jobID] ?? "" },
            set: { model.historySyncCursorDrafts[jobID] = $0 }
        )
    }

    private static let linkExpiryFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
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
                    Text(chat.displayTitle)
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(chat.chatType.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
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

private struct MessageHistoryRow: View {
    @Environment(\.trixColors) private var colors
    let message: MessageEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("seq \(message.serverSeq) • \(message.messageKind.label)")
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text("sender \(message.senderShortID) • epoch \(message.epoch)")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: .now))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.inkMuted)
            }

            HStack(spacing: 10) {
                InlineMeta(label: message.contentType.label)
                InlineMeta(label: "\(message.ciphertextSizeBytes) bytes")
                InlineMeta(label: message.aadSummary)
            }
        }
        .padding(16)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
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
