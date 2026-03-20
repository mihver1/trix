import SwiftUI
import UIKit

private let dashboardAccent = Color(red: 0.14, green: 0.55, blue: 0.98)

private struct DashboardCreateChatDraft {
    var chatType: ChatType = .dm
    var title = ""
    var participantAccountIds = ""

    var canSubmit: Bool {
        !dashboardParsedIdentifiers(participantAccountIds).isEmpty
    }
}

private struct ChatListSnapshot {
    let previewText: String
    let previewDate: Date?
    let unreadCount: Int
}

struct DashboardView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var isShowingForgetAlert = false
    @State private var revokeCandidate: DeviceSummary?
    @State private var revokeReason = ""
    @State private var isPresentingCreateChat = false
    @State private var createChatDraft = DashboardCreateChatDraft()

    var body: some View {
        TabView {
            NavigationStack {
                ChatsHomeView(
                    serverBaseURL: $serverBaseURL,
                    model: model,
                    onReload: reload,
                    onCompose: {
                        createChatDraft = DashboardCreateChatDraft()
                        isPresentingCreateChat = true
                    }
                )
            }
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
            }

            NavigationStack {
                SettingsHomeView(
                    serverBaseURL: $serverBaseURL,
                    model: model,
                    onReload: reload,
                    onForgetLocalDevice: {
                        isShowingForgetAlert = true
                    },
                    onCreateLinkIntent: createLinkIntent,
                    onApprovePendingDevice: approvePendingDevice(deviceId:),
                    onRevokeDevice: { device in
                        revokeCandidate = device
                        revokeReason = ""
                    },
                    onCompleteHistorySyncJob: completeHistorySyncJob(jobId:)
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(dashboardAccent)
        .alert("Forget this device?", isPresented: $isShowingForgetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                model.forgetLocalDevice()
            }
        } message: {
            Text("This removes local keys and session state from the iPhone. The server-side account and device record stay unchanged.")
        }
        .sheet(isPresented: $isPresentingCreateChat) {
            CreateChatSheet(
                draft: $createChatDraft,
                isSubmitting: model.isLoading,
                onCancel: {
                    isPresentingCreateChat = false
                },
                onCreate: createChat
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $revokeCandidate) { device in
            RevokeDeviceSheet(
                device: device,
                revokeReason: $revokeReason,
                isSubmitting: model.isLoading,
                onCancel: {
                    revokeCandidate = nil
                },
                onConfirm: {
                    let deviceId = device.deviceId
                    let reason = revokeReason
                    revokeCandidate = nil
                    revokeReason = ""
                    Task {
                        await model.revokeDevice(
                            baseURLString: serverBaseURL,
                            deviceId: deviceId,
                            reason: reason
                        )
                    }
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(item: linkIntentBinding) { linkIntent in
            LinkIntentSheet(
                linkIntent: linkIntent,
                onClose: model.dismissActiveLinkIntent
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }

    private func createChat() {
        let participantAccountIds = dashboardParsedIdentifiers(createChatDraft.participantAccountIds)

        Task {
            if await model.createChat(
                baseURLString: serverBaseURL,
                chatType: createChatDraft.chatType,
                title: createChatDraft.title,
                participantAccountIds: participantAccountIds
            ) != nil {
                isPresentingCreateChat = false
                createChatDraft = DashboardCreateChatDraft()
            }
        }
    }

    private func completeHistorySyncJob(jobId: String) {
        Task {
            await model.completeHistorySyncJob(
                baseURLString: serverBaseURL,
                jobId: jobId
            )
        }
    }

    private func createLinkIntent() {
        Task {
            await model.createLinkIntent(baseURLString: serverBaseURL)
        }
    }

    private func approvePendingDevice(deviceId: String) {
        Task {
            _ = await model.approvePendingDevice(
                baseURLString: serverBaseURL,
                deviceId: deviceId
            )
        }
    }

    private var linkIntentBinding: Binding<CreateLinkIntentResponse?> {
        Binding(
            get: { model.activeLinkIntent },
            set: { value in
                if value == nil {
                    model.dismissActiveLinkIntent()
                }
            }
        )
    }
}

private struct ChatsHomeView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel
    let onReload: () -> Void
    let onCompose: () -> Void

    var body: some View {
        Group {
            if let dashboard = model.dashboard {
                List {
                    if let errorMessage = model.errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        HStack(spacing: 14) {
                            AccountAvatarView(title: dashboard.profile.profileName, size: 50)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(dashboard.profile.profileName)
                                    .font(.headline)

                                Text(dashboard.profile.handle.map { "@\($0)" } ?? dashboard.currentDevice?.displayName ?? "Encrypted messaging")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                DeviceStatusBadge(status: dashboard.session.deviceStatus)

                                if let lastUpdatedAt = model.lastUpdatedAt {
                                    Text(lastUpdatedAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Section {
                        if dashboard.chats.isEmpty {
                            EmptyChatsView(onCompose: onCompose)
                                .listRowInsets(EdgeInsets(top: 28, leading: 20, bottom: 28, trailing: 20))
                        } else {
                            ForEach(dashboard.chats) { chat in
                                NavigationLink {
                                    ConsumerChatDetailView(
                                        chatSummary: chat,
                                        serverBaseURL: $serverBaseURL,
                                        model: model
                                    )
                                } label: {
                                    ChatListRow(
                                        chat: chat,
                                        snapshot: dashboard.chatListSnapshot(for: chat)
                                    )
                                }
                            }
                        }
                    } header: {
                        Text("Recent")
                    }
                }
                .listStyle(.plain)
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Refresh", action: onReload)
                            .disabled(model.isLoading)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onCompose) {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(model.isLoading)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onCompose) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(dashboardAccent)
                            .clipShape(Circle())
                            .shadow(color: dashboardAccent.opacity(0.28), radius: 18, y: 10)
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                    .disabled(model.isLoading)
                }
            } else {
                ContentUnavailableView {
                    Label("Connecting", systemImage: "bolt.horizontal.circle")
                } description: {
                    if model.isLoading {
                        Text("Authenticating this device and loading chats.")
                    } else {
                        Text(model.errorMessage ?? "No authenticated session yet.")
                    }
                } actions: {
                    Button("Retry", action: onReload)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct SettingsHomeView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel
    let onReload: () -> Void
    let onForgetLocalDevice: () -> Void
    let onCreateLinkIntent: () -> Void
    let onApprovePendingDevice: (String) -> Void
    let onRevokeDevice: (DeviceSummary) -> Void
    let onCompleteHistorySyncJob: (String) -> Void

    var body: some View {
        List {
            ServerConnectionSection(
                serverBaseURL: $serverBaseURL,
                snapshot: model.systemSnapshot,
                lastUpdatedAt: model.lastUpdatedAt,
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                reloadTitle: "Refresh",
                onReload: onReload
            )

            if let dashboard = model.dashboard {
                Section {
                    HStack(spacing: 14) {
                        AccountAvatarView(title: dashboard.profile.profileName, size: 58)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(dashboard.profile.profileName)
                                .font(.headline)

                            if let handle = dashboard.profile.handle {
                                Text("@\(handle)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let bio = dashboard.profile.profileBio, !bio.isEmpty {
                                Text(bio)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("Devices") {
                    Button(action: onCreateLinkIntent) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Link New Device")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)

                    ForEach(dashboard.devices) { device in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(device.displayName)
                                    .font(.body.weight(.medium))

                                Spacer()

                                DeviceStatusBadge(status: device.deviceStatus)
                            }

                            Text(device.platform.capitalized)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if device.deviceId == dashboard.profile.deviceId {
                                Text("This iPhone")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(dashboardAccent)
                            } else if model.canManageAccountDevices {
                                if device.deviceStatus == .pending {
                                    Button("Approve Device") {
                                        onApprovePendingDevice(device.deviceId)
                                    }
                                    .disabled(model.isLoading)
                                }

                                if device.deviceStatus == .active {
                                    Button("Remove Device", role: .destructive) {
                                        onRevokeDevice(device)
                                    }
                                    .disabled(model.isLoading)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Sync") {
                    if dashboard.historySyncJobs.isEmpty {
                        Text("No active sync jobs.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dashboard.historySyncJobs) { job in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(job.jobType.label)
                                        .font(.body.weight(.medium))

                                    Spacer()

                                    HistorySyncStatusBadge(status: job.jobStatus)
                                }

                                Text(Date(timeIntervalSince1970: TimeInterval(job.updatedAtUnix)).formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                if job.jobStatus.canComplete {
                                    Button("Mark Completed") {
                                        onCompleteHistorySyncJob(job.jobId)
                                    }
                                    .disabled(model.isLoading)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Developer Tools") {
                    NavigationLink {
                        MessagingLabView(
                            serverBaseURL: $serverBaseURL,
                            model: model
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MLS Lab")
                            Text("Chats, inbox, key packages, device flows")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let localIdentity = model.localIdentity {
                Section("Local Storage") {
                    LabeledContent("Account") {
                        Text(localIdentity.accountId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }

                    if let accountSyncChatId = localIdentity.accountSyncChatId {
                        LabeledContent("Sync Chat") {
                            Text(accountSyncChatId)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    if let localCoreState = model.localCoreState {
                        LabeledContent("Cached Chats") {
                            Text("\(localCoreState.localChats.count)")
                        }

                        LabeledContent("Inbox Cursor") {
                            Text(localCoreState.lastAckedInboxId.map(String.init) ?? "None")
                        }
                    }

                    Button("Forget This Device", role: .destructive, action: onForgetLocalDevice)
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
    }
}

private struct ChatListRow: View {
    let chat: ChatSummary
    let snapshot: ChatListSnapshot

    var body: some View {
        HStack(spacing: 14) {
            AccountAvatarView(title: chat.title ?? chat.chatType.label, size: 54)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(chat.title ?? chat.chatType.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    if let previewDate = snapshot.previewDate {
                        Text(previewDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    if snapshot.unreadCount > 0 {
                        Text(String(snapshot.unreadCount))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(dashboardAccent)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct EmptyChatsView: View {
    let onCompose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(dashboardAccent)

            Text("No conversations yet")
                .font(.headline)

            Text("Start with a direct message or create a group. MLS and device tooling stay available in Settings, not on the main screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("New Chat", action: onCompose)
                .buttonStyle(.borderedProminent)
                .tint(dashboardAccent)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CreateChatSheet: View {
    @Binding var draft: DashboardCreateChatDraft
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    Picker("Type", selection: $draft.chatType) {
                        Text(ChatType.dm.label).tag(ChatType.dm)
                        Text(ChatType.group.label).tag(ChatType.group)
                    }
                    .pickerStyle(.segmented)

                    if draft.chatType == .group {
                        TextField("Group name", text: $draft.title)
                    }
                }

                Section {
                    TextField("Account IDs", text: $draft.participantAccountIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))
                } header: {
                    Text("Participants")
                } footer: {
                    Text("For a DM, add one peer account ID. For a group, add multiple account IDs separated by commas or new lines.")
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onCreate)
                        .disabled(isSubmitting || !draft.canSubmit)
                }
            }
        }
    }
}

private struct AccountAvatarView: View {
    let title: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(avatarTint)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }

    private var initials: String {
        let tokens = title
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }

        if let first = tokens.first, !first.isEmpty {
            return tokens.joined()
        }

        return String(title.prefix(1)).uppercased()
    }

    private var avatarTint: Color {
        let scalarSum = title.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
        let palette: [Color] = [
            Color(red: 0.12, green: 0.55, blue: 0.98),
            Color(red: 0.11, green: 0.72, blue: 0.61),
            Color(red: 0.96, green: 0.58, blue: 0.25),
            Color(red: 0.91, green: 0.38, blue: 0.46),
            Color(red: 0.45, green: 0.50, blue: 0.94),
        ]
        return palette[scalarSum % palette.count]
    }
}

private extension DashboardData {
    func chatListSnapshot(for chat: ChatSummary) -> ChatListSnapshot {
        let matchingItems = inboxItems
            .filter { $0.message.chatId == chat.chatId }
            .sorted { $0.message.createdAtUnix > $1.message.createdAtUnix }

        let latestItem = matchingItems.first
        let previewText: String
        if let latestItem {
            previewText = latestItem.message.debugPreview
        } else if chat.lastServerSeq == 0 {
            previewText = "No messages yet"
        } else {
            previewText = "\(chat.chatType.label) conversation"
        }

        return ChatListSnapshot(
            previewText: previewText,
            previewDate: latestItem?.message.createdAtDate,
            unreadCount: matchingItems.count
        )
    }
}

private struct DeviceStatusBadge: View {
    let status: DeviceStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

private extension DeviceStatus {
    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .active:
            return "Active"
        case .revoked:
            return "Revoked"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            return .orange
        case .active:
            return .green
        case .revoked:
            return .red
        }
    }
}

private struct HistorySyncStatusBadge: View {
    let status: HistorySyncJobStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

private extension HistorySyncJobType {
    var label: String {
        switch self {
        case .initialSync:
            return "Initial Sync"
        case .chatBackfill:
            return "Chat Backfill"
        case .deviceRekey:
            return "Device Rekey"
        }
    }
}

private extension HistorySyncJobStatus {
    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            return .orange
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .gray
        }
    }

    var canComplete: Bool {
        switch self {
        case .pending, .running:
            return true
        case .completed, .failed, .canceled:
            return false
        }
    }
}

private struct RevokeDeviceSheet: View {
    let device: DeviceSummary
    @Binding var revokeReason: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Name") {
                        Text(device.displayName)
                    }

                    LabeledContent("Platform") {
                        Text(device.platform)
                    }

                    LabeledContent("Device ID") {
                        Text(device.deviceId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    TextField("Compromised, lost, replaced...", text: $revokeReason, axis: .vertical)
                        .lineLimit(3, reservesSpace: false)
                } header: {
                    Text("Reason")
                } footer: {
                    Text("The server requires a signed revoke reason. This device will lose future access immediately.")
                }
            }
            .navigationTitle("Remove Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove", role: .destructive, action: onConfirm)
                        .disabled(isSubmitting || revokeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LinkIntentSheet: View {
    let linkIntent: CreateLinkIntentResponse
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Expires") {
                    Text(linkIntent.expirationDate.formatted(date: .abbreviated, time: .standard))
                }

                Section {
                    Text(linkIntent.qrPayload)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Payload")
                } footer: {
                    Text("For now the iOS PoC exposes the link payload as JSON so it can be copied into another device manually.")
                }

                Section {
                    Button("Copy Payload") {
                        UIPasteboard.general.string = linkIntent.qrPayload
                    }
                }
            }
            .navigationTitle("Link Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}

private func dashboardParsedIdentifiers(_ rawValue: String) -> [String] {
    rawValue
        .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

#Preview {
    DashboardView(
        serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
        model: AppModel()
    )
}
