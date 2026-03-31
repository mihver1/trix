import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

private let dashboardAccent = Color(red: 0.14, green: 0.55, blue: 0.98)

private struct DashboardCreateChatDraft {
    var chatType: ChatType = .dm
    var title = ""
    var searchQuery = ""
    var selectedAccounts: [DirectoryAccountSummary] = []

    var canSubmit: Bool {
        switch chatType {
        case .dm:
            return selectedAccounts.count == 1
        case .group:
            return !selectedAccounts.isEmpty
        case .accountSync:
            return false
        }
    }

    var selectedAccountIds: [String] {
        selectedAccounts.map(\.accountId)
    }

    mutating func toggleSelection(_ account: DirectoryAccountSummary) {
        if let existingIndex = selectedAccounts.firstIndex(of: account) {
            selectedAccounts.remove(at: existingIndex)
            return
        }

        if chatType == .dm {
            selectedAccounts = [account]
        } else {
            selectedAccounts.append(account)
        }
    }

    mutating func removeSelection(accountId: String) {
        selectedAccounts.removeAll { $0.accountId == accountId }
    }

    mutating func normalizeSelectionForCurrentChatType() {
        if chatType == .dm, selectedAccounts.count > 1 {
            selectedAccounts = Array(selectedAccounts.prefix(1))
        }
    }
}

private struct ChatListSnapshot {
    let title: String
    let avatarSeedTitle: String
    let previewText: String
    let previewDate: Date?
    let unreadCount: Int
}

private struct DashboardChatListRowModel: Identifiable {
    let chat: ChatSummary
    let snapshot: ChatListSnapshot
    let fixtureKind: UITestFixtureChatKind?

    var id: String { chat.chatId }
}

private enum DashboardSheet: Identifiable {
    case createChat
    case editProfile
    case revokeDevice(DeviceSummary)
    case linkIntent(CreateLinkIntentResponse)

    var id: String {
        switch self {
        case .createChat:
            return "create-chat"
        case .editProfile:
            return "edit-profile"
        case let .revokeDevice(device):
            return "revoke-\(device.deviceId)"
        case let .linkIntent(linkIntent):
            return "link-intent-\(linkIntent.linkIntentId)"
        }
    }
}

struct DashboardView: View {
    @Binding var serverBaseURL: String
    var model: AppModel

    @State private var isShowingForgetAlert = false
    @State private var activeSheet: DashboardSheet?
    @State private var revokeReason = ""
    @State private var createChatDraft = DashboardCreateChatDraft()
    @State private var editProfileDraft = EditProfileForm()

    var body: some View {
        TabView {
            NavigationStack {
                ChatsHomeView(
                    serverBaseURL: $serverBaseURL,
                    model: model,
                    onReload: reload,
                    onCompose: {
                        createChatDraft = DashboardCreateChatDraft()
                        activeSheet = .createChat
                    }
                )
            }
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                    .accessibilityIdentifier(TrixAccessibilityID.Dashboard.chatsTab)
            }

            NavigationStack {
                SettingsHomeView(
                    serverBaseURL: $serverBaseURL,
                    model: model,
                    onReload: reload,
                    onEditProfile: {
                        if let profile = model.dashboard?.profile {
                            editProfileDraft = EditProfileForm(profile: profile)
                        } else {
                            editProfileDraft = EditProfileForm()
                        }
                        activeSheet = .editProfile
                    },
                    onForgetLocalDevice: {
                        isShowingForgetAlert = true
                    },
                    onCreateLinkIntent: createLinkIntent,
                    onApprovePendingDevice: approvePendingDevice(deviceId:),
                    onRevokeDevice: { device in
                        revokeReason = ""
                        activeSheet = .revokeDevice(device)
                    },
                    onCompleteHistorySyncJob: completeHistorySyncJob(jobId:)
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
                    .accessibilityIdentifier(TrixAccessibilityID.Dashboard.settingsTab)
            }
        }
        .accessibilityIdentifier(TrixAccessibilityID.Root.dashboardScreen)
        .tint(dashboardAccent)
        .alert("Forget this device?", isPresented: $isShowingForgetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                model.forgetLocalDevice()
            }
        } message: {
            Text("This removes local keys and session state from the iPhone. The server-side account and device record stay unchanged.")
        }
        .sheet(item: presentedSheetBinding) { sheet in
            switch sheet {
            case .createChat:
                CreateChatSheet(
                    serverBaseURL: serverBaseURL,
                    model: model,
                    draft: $createChatDraft,
                    isSubmitting: model.isLoading,
                    createAction: createChat
                )
                .presentationDetents([.medium, .large])
            case .editProfile:
                EditProfileSheet(
                    draft: $editProfileDraft,
                    errorMessage: model.errorMessage,
                    isSubmitting: model.isLoading,
                    saveAction: saveProfile
                )
                .presentationDetents([.medium, .large])
            case let .revokeDevice(device):
                RevokeDeviceSheet(
                    device: device,
                    revokeReason: $revokeReason,
                    errorMessage: model.errorMessage,
                    isSubmitting: model.isLoading,
                    confirmAction: {
                        await revokeDevice(deviceId: device.deviceId, reason: revokeReason)
                    }
                )
                .presentationDetents([.medium])
            case let .linkIntent(linkIntent):
                LinkIntentSheet(linkIntent: linkIntent)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }

    private func createChat() async -> Bool {
        if await model.createChat(
            baseURLString: serverBaseURL,
            chatType: createChatDraft.chatType,
            title: createChatDraft.title,
            participantAccountIds: createChatDraft.selectedAccountIds
        ) != nil {
            createChatDraft = DashboardCreateChatDraft()
            return true
        }

        return false
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

    private func saveProfile() async -> Bool {
        if await model.updateAccountProfile(
            baseURLString: serverBaseURL,
            form: editProfileDraft
        ) != nil {
            return true
        }

        return false
    }

    private func approvePendingDevice(deviceId: String) {
        Task {
            _ = await model.approvePendingDevice(
                baseURLString: serverBaseURL,
                deviceId: deviceId
            )
        }
    }

    private func revokeDevice(deviceId: String, reason: String) async -> Bool {
        let didRevoke = await model.revokeDevice(
            baseURLString: serverBaseURL,
            deviceId: deviceId,
            reason: reason
        )
        if didRevoke {
            revokeReason = ""
        }
        return didRevoke
    }

    private var presentedSheet: DashboardSheet? {
        activeSheet ?? model.activeLinkIntent.map(DashboardSheet.linkIntent)
    }

    private var presentedSheetBinding: Binding<DashboardSheet?> {
        Binding(
            get: { presentedSheet },
            set: { value in
                if value == nil {
                    if case .linkIntent? = presentedSheet {
                        model.dismissActiveLinkIntent()
                    }
                    activeSheet = nil
                }
            }
        )
    }
}

private struct ChatsHomeView: View {
    @Binding var serverBaseURL: String
    var model: AppModel
    let onReload: () -> Void
    let onCompose: () -> Void

    var body: some View {
        Group {
            if let dashboard = model.dashboard {
                let chatRows = chatListRows(for: dashboard)

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
                        if chatRows.isEmpty {
                            EmptyChatsView(onCompose: onCompose)
                                .listRowInsets(EdgeInsets(top: 28, leading: 20, bottom: 28, trailing: 20))
                        } else {
                            ForEach(chatRows) { row in
                                let link = NavigationLink {
                                    ConsumerChatDetailView(
                                        chatSummary: row.chat,
                                        serverBaseURL: $serverBaseURL,
                                        model: model
                                    )
                                } label: {
                                    ChatListRow(
                                        snapshot: row.snapshot,
                                        fixtureKind: row.fixtureKind
                                    )
                                }

                                if let fixtureKind = row.fixtureKind {
                                    link.accessibilityIdentifier(TrixAccessibilityID.Dashboard.chatRow(fixtureKind))
                                } else {
                                    link
                                }
                            }
                        }
                    } header: {
                        Text("Recent")
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier(TrixAccessibilityID.Dashboard.chatsList)
                .refreshable {
                    onReload()
                }
                .navigationTitle("Chats")
                .overlay(alignment: .bottomTrailing) {
                    if !chatRows.isEmpty {
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
                        .accessibilityIdentifier(TrixAccessibilityID.Dashboard.composeButton)
                    }
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

    private func chatListRows(for dashboard: DashboardData) -> [DashboardChatListRowModel] {
        dashboard.chatListRows(
            localCoreState: model.localCoreState,
            fixtureManifest: UITestLaunchConfiguration.current.isEnabled ? UITestFixtureManifestStore.load() : nil
        )
    }
}

private struct SettingsHomeView: View {
    @Binding var serverBaseURL: String
    var model: AppModel
    let onReload: () -> Void
    let onEditProfile: () -> Void
    let onForgetLocalDevice: () -> Void
    let onCreateLinkIntent: () -> Void
    let onApprovePendingDevice: (String) -> Void
    let onRevokeDevice: (DeviceSummary) -> Void
    let onCompleteHistorySyncJob: (String) -> Void
    @State private var isShowingAdvanced = false

    var body: some View {
        List {
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

                    Button("Edit Profile", action: onEditProfile)
                        .disabled(model.isLoading)
                }

                Section("Linked Devices") {
                    NavigationLink {
                        LinkedDevicesView(
                            dashboard: dashboard,
                            canManageDevices: model.canManageAccountDevices,
                            capabilitySummary: model.deviceCapabilitySummary,
                            isLoading: model.isLoading,
                            onReload: onReload,
                            onCreateLinkIntent: onCreateLinkIntent,
                            onApprovePendingDevice: onApprovePendingDevice,
                            onRevokeDevice: onRevokeDevice
                        )
                    } label: {
                        SettingsNavigationRow(
                            icon: "iphone.gen3.badge.plus",
                            tint: dashboardAccent,
                            title: "Linked Devices",
                            subtitle: linkedDevicesSummaryText(for: dashboard),
                            trailingText: "\(dashboard.devices.count)"
                        )
                    }
                }

                if model.localIdentity != nil {
                    Section("App") {
                        Button("Forget This Device", role: .destructive, action: onForgetLocalDevice)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Loading Settings",
                        systemImage: "gearshape.2.fill",
                        description: Text(model.errorMessage ?? "Profile and device details will appear here once the session finishes loading.")
                    )
                }
            }

            Section {
                DisclosureGroup(isExpanded: $isShowingAdvanced) {
                    VStack(alignment: .leading, spacing: 18) {
                        AdvancedSettingsConnectionCard(
                            serverBaseURL: $serverBaseURL,
                            snapshot: model.systemSnapshot,
                            lastUpdatedAt: model.lastUpdatedAt,
                            isLoading: model.isLoading,
                            errorMessage: model.errorMessage,
                            onReload: onReload
                        )

                        if let dashboard = model.dashboard {
                            if dashboard.historySyncJobs.isEmpty {
                                AdvancedInfoRow(
                                    title: "History Sync",
                                    text: "No background sync jobs are active right now."
                                )
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("History Sync")
                                        .font(.headline)

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
                        }

                        NavigationLink {
                            MessagingLabView(
                                serverBaseURL: $serverBaseURL,
                                model: model
                            )
                        } label: {
                            AdvancedInfoRow(
                                title: "Developer Tools",
                                text: "Open the MLS lab, inbox inspector, and low-level device tooling."
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            DiagnosticsLogView(logStore: SafeDiagnosticLogStore.shared)
                        } label: {
                            AdvancedInfoRow(
                                title: "Client Logs",
                                text: "Review safe diagnostics for sync, device actions, memberships, and failures without exposing decrypted content."
                            )
                        }
                        .buttonStyle(.plain)

                        if let localIdentity = model.localIdentity {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Local State")
                                    .font(.headline)

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
                            }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .accessibilityIdentifier(TrixAccessibilityID.Dashboard.settingsList)
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

    private func linkedDevicesSummaryText(for dashboard: DashboardData) -> String {
        let pendingCount = dashboard.devices.filter { $0.deviceStatus == .pending }.count
        if pendingCount > 0 {
            return pendingCount == 1 ? "1 device is waiting for approval" : "\(pendingCount) devices are waiting for approval"
        }

        let activeCount = dashboard.devices.filter { $0.deviceStatus == .active }.count
        if activeCount <= 1 {
            return "This is your only active device"
        }

        return "\(activeCount) active devices on this account"
    }
}

private struct AdvancedSettingsConnectionCard: View {
    @Binding var serverBaseURL: String
    let snapshot: ServerSnapshot?
    let lastUpdatedAt: Date?
    let isLoading: Bool
    let errorMessage: String?
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection")
                        .font(.headline)

                    Text(connectionSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AdvancedConnectionBadge(snapshot: snapshot)
            }

            Text(serverBaseURL)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let lastUpdatedAt {
                Text("Last checked \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(action: onReload) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Refresh Connection")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
    }

    private var connectionSummary: String {
        if let host = URL(string: serverBaseURL)?.host {
            return "Connected through \(host)"
        }

        return "Custom server connection"
    }
}

private struct AdvancedConnectionBadge: View {
    let snapshot: ServerSnapshot?

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        guard let snapshot else {
            return "Unchecked"
        }

        return snapshot.health.status == .ok ? "Connected" : "Degraded"
    }

    private var tint: Color {
        guard let snapshot else {
            return .secondary
        }

        return snapshot.health.status == .ok ? .green : .orange
    }
}

private struct LinkedDevicesView: View {
    let dashboard: DashboardData
    let canManageDevices: Bool
    let capabilitySummary: String
    let isLoading: Bool
    let onReload: () -> Void
    let onCreateLinkIntent: () -> Void
    let onApprovePendingDevice: (String) -> Void
    let onRevokeDevice: (DeviceSummary) -> Void

    private var currentDevice: DeviceSummary? {
        dashboard.currentDevice
    }

    private var pendingDevices: [DeviceSummary] {
        dashboard.devices.filter { $0.deviceStatus == .pending }
    }

    private var otherActiveDevices: [DeviceSummary] {
        dashboard.devices.filter { device in
            device.deviceId != dashboard.profile.deviceId && device.deviceStatus == .active
        }
    }

    private var revokedDevices: [DeviceSummary] {
        dashboard.devices.filter { $0.deviceStatus == .revoked }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Bring another phone, tablet, or desktop onto this account without signing out here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(action: onCreateLinkIntent) {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Link New Device", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(dashboardAccent)
                    .disabled(isLoading)
                }
                .padding(.vertical, 6)
            }

            if let currentDevice {
                Section("This iPhone") {
                    LinkedDeviceCard(
                        device: currentDevice,
                        subtitle: "Signed in and ready for daily use.",
                        showApproveAction: false,
                        showRevokeAction: false,
                        isLoading: isLoading,
                        onApprove: {},
                        onRevoke: {}
                    )
                }
            }

            if !pendingDevices.isEmpty {
                Section("Waiting for Approval") {
                    ForEach(pendingDevices) { device in
                        LinkedDeviceCard(
                            device: device,
                            subtitle: "Approve this device from a trusted phone or desktop to finish setup.",
                            showApproveAction: canManageDevices,
                            showRevokeAction: false,
                            isLoading: isLoading,
                            onApprove: {
                                onApprovePendingDevice(device.deviceId)
                            },
                            onRevoke: {}
                        )
                    }
                }
            }

            if !otherActiveDevices.isEmpty {
                Section("Other Devices") {
                    ForEach(otherActiveDevices) { device in
                        LinkedDeviceCard(
                            device: device,
                            subtitle: "This device can read and send messages on your behalf.",
                            showApproveAction: false,
                            showRevokeAction: canManageDevices,
                            isLoading: isLoading,
                            onApprove: {},
                            onRevoke: {
                                onRevokeDevice(device)
                            }
                        )
                    }
                }
            }

            if !revokedDevices.isEmpty {
                Section("Removed Devices") {
                    ForEach(revokedDevices) { device in
                        LinkedDeviceCard(
                            device: device,
                            subtitle: "Access has already been revoked.",
                            showApproveAction: false,
                            showRevokeAction: false,
                            isLoading: isLoading,
                            onApprove: {},
                            onRevoke: {}
                        )
                    }
                }
            }

            if !capabilitySummary.isEmpty {
                Section {
                    Label(
                        capabilitySummary,
                        systemImage: canManageDevices ? "checkmark.shield" : "lock.shield"
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            onReload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct LinkedDeviceCard: View {
    let device: DeviceSummary
    let subtitle: String
    let showApproveAction: Bool
    let showRevokeAction: Bool
    let isLoading: Bool
    let onApprove: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: device.platform.trix_deviceIconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(dashboardAccent)
                    .frame(width: 42, height: 42)
                    .background(dashboardAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName)
                        .font(.body.weight(.semibold))

                    Text(device.platform.trix_platformLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                DeviceStatusBadge(status: device.deviceStatus)
            }

            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if showApproveAction || showRevokeAction {
                HStack(spacing: 10) {
                    if showApproveAction {
                        Button("Approve", action: onApprove)
                            .buttonStyle(.borderedProminent)
                            .tint(dashboardAccent)
                    }

                    if showRevokeAction {
                        Button("Remove", role: .destructive, action: onRevoke)
                            .buttonStyle(.bordered)
                    }
                }
                .disabled(isLoading)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailingText: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let trailingText {
                Text(trailingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChatListRow: View {
    let snapshot: ChatListSnapshot
    let fixtureKind: UITestFixtureChatKind?

    var body: some View {
        if let fixtureKind {
            rowBody
                .accessibilityIdentifier(TrixAccessibilityID.Dashboard.chatRow(fixtureKind))
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: 14) {
            AccountAvatarView(title: snapshot.avatarSeedTitle, size: 54)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(snapshot.title)
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
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if snapshot.unreadCount > 0 {
                        Text(snapshot.unreadCount > 99 ? "99+" : String(snapshot.unreadCount))
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

            Text("Start a direct message or create a group. Your conversations will show up here as soon as the first message is sent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("New Chat", action: onCompose)
                .buttonStyle(.borderedProminent)
                .tint(dashboardAccent)
                .accessibilityIdentifier(TrixAccessibilityID.Dashboard.composeButton)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.vertical, 12)
    }
}

private struct CreateChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    let serverBaseURL: String
    var model: AppModel
    @Binding var draft: DashboardCreateChatDraft
    let isSubmitting: Bool
    let createAction: () async -> Bool

    @State private var directoryResults: [DirectoryAccountSummary] = []
    @State private var isSearching = false
    @State private var searchErrorMessage: String?

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
                    TextField("Search by name or @handle", text: $draft.searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("People")
                } footer: {
                    Text(draft.chatType == .dm ? "Choose one person for a direct message." : "Choose one or more people for this group.")
                }

                if !draft.selectedAccounts.isEmpty {
                    Section(draft.chatType == .dm ? "Selected Person" : "Selected People") {
                        ForEach(draft.selectedAccounts) { account in
                            SelectedDirectoryAccountRow(account: account) {
                                draft.removeSelection(accountId: account.accountId)
                            }
                        }
                    }
                }

                Section {
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if let searchErrorMessage {
                        Label(searchErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if directoryResults.isEmpty {
                        ContentUnavailableView(
                            draft.searchQuery.trix_trimmed().isEmpty ? "No People Yet" : "No Matches",
                            systemImage: draft.searchQuery.trix_trimmed().isEmpty ? "person.2.slash" : "magnifyingglass",
                            description: Text(draft.searchQuery.trix_trimmed().isEmpty ? "No active accounts are available in the directory right now." : "Try a different name or handle.")
                        )
                    } else {
                        ForEach(directoryResults) { account in
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    draft.toggleSelection(account)
                                }
                            } label: {
                                DirectoryAccountPickerRow(
                                    account: account,
                                    isSelected: draft.selectedAccounts.contains(account)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(draft.searchQuery.trix_trimmed().isEmpty ? "Suggested" : "Results")
                } footer: {
                    Text("The account directory only returns people who currently have at least one active device.")
                }
            }
            .accessibilityIdentifier(TrixAccessibilityID.Dashboard.createChatSheet)
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: searchTaskID) {
                await loadDirectoryResults()
            }
            .onChange(of: draft.chatType) { _, _ in
                draft.normalizeSelectionForCurrentChatType()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                        .accessibilityIdentifier(TrixAccessibilityID.Dashboard.createChatCancelButton)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if await createAction() {
                                dismiss()
                            }
                        }
                    }
                        .disabled(isSubmitting || !draft.canSubmit)
                }
            }
        }
    }

    private var searchTaskID: String {
        "\(draft.chatType.rawValue)|\(draft.searchQuery.trix_trimmed())"
    }

    private func loadDirectoryResults() async {
        let trimmedQuery = draft.searchQuery.trix_trimmedOrNil()

        if trimmedQuery != nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if Task.isCancelled {
            return
        }

        isSearching = true
        searchErrorMessage = nil

        defer {
            isSearching = false
        }

        do {
            directoryResults = try await model.searchAccountDirectory(
                baseURLString: serverBaseURL,
                query: trimmedQuery,
                limit: 24,
                excludeSelf: true
            )
        } catch is CancellationError {
            return
        } catch {
            directoryResults = []
            searchErrorMessage = error.localizedDescription
        }
    }
}

private struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: EditProfileForm
    let errorMessage: String?
    let isSubmitting: Bool
    let saveAction: () async -> Bool

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("Profile Name", text: $draft.profileName)

                    TextField("Handle", text: $draft.handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Bio", text: $draft.profileBio, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Leave handle empty if you do not want a public @handle.")
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                if await saveAction() {
                                    dismiss()
                                }
                            }
                        }
                            .disabled(!draft.canSubmit)
                    }
                }
            }
        }
    }
}

private struct SelectedDirectoryAccountRow: View {
    let account: DirectoryAccountSummary
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatarView(title: account.profileName, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.profileName)
                    .font(.body.weight(.medium))

                Text(account.handle.map { "@\($0)" } ?? account.accountId)
                    .font(account.handle == nil ? .system(.caption, design: .monospaced) : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DirectoryAccountPickerRow: View {
    let account: DirectoryAccountSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatarView(title: account.profileName, size: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.profileName)
                        .font(.body.weight(.medium))

                    if let handle = account.handle {
                        Text("@\(handle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let profileBio = account.profileBio?.trix_trimmedOrNil() {
                    Text(profileBio)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(account.accountId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3)
                .foregroundStyle(isSelected ? dashboardAccent : .secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct AdvancedInfoRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private extension String {
    var trix_platformLabel: String {
        switch lowercased() {
        case let value where value.contains("ios"):
            return "iPhone"
        case let value where value.contains("mac"):
            return "Mac"
        case let value where value.contains("windows"):
            return "Windows"
        case let value where value.contains("linux"):
            return "Linux"
        default:
            return capitalized
        }
    }

    var trix_deviceIconName: String {
        switch lowercased() {
        case let value where value.contains("ios"):
            return "iphone.gen3"
        case let value where value.contains("mac"):
            return "laptopcomputer"
        case let value where value.contains("windows"):
            return "desktopcomputer"
        case let value where value.contains("linux"):
            return "desktopcomputer"
        default:
            return "ipad.and.iphone"
        }
    }
}

private extension DashboardData {
    func chatListRows(
        localCoreState: LocalCoreStateSnapshot?,
        fixtureManifest: UITestFixtureManifest?
    ) -> [DashboardChatListRowModel] {
        let latestInboxMessagesByChatId = latestInboxMessagesByChatId()
        let localChatListItemsByChatId = localCoreState?.localChatListItems.reduce(into: [String: LocalChatListItemSnapshot]()) { partialResult, item in
            partialResult[item.chatId] = item
        } ?? [:]
        let localReadStatesByChatId = localCoreState?.chatReadStates.reduce(into: [String: LocalChatReadStateSnapshot]()) { partialResult, readState in
            partialResult[readState.chatId] = readState
        } ?? [:]
        let fixtureKindsByChatId = fixtureManifest?.chats.reduce(into: [String: UITestFixtureChatKind]()) { partialResult, record in
            partialResult[record.chatId] = record.kind
        } ?? [:]

        return chats.map { chat in
            DashboardChatListRowModel(
                chat: chat,
                snapshot: chatListSnapshot(
                    for: chat,
                    localChatListItem: localChatListItemsByChatId[chat.chatId],
                    localReadState: localReadStatesByChatId[chat.chatId],
                    latestInboxMessage: latestInboxMessagesByChatId[chat.chatId]
                ),
                fixtureKind: fixtureKindsByChatId[chat.chatId]
            )
        }
    }

    func chatListSnapshot(
        for chat: ChatSummary,
        localChatListItem: LocalChatListItemSnapshot?,
        localReadState: LocalChatReadStateSnapshot?,
        latestInboxMessage: MessageEnvelope?
    ) -> ChatListSnapshot {
        let latestMessage = chat.lastMessage ?? latestInboxMessage
        return ChatListSnapshot(
            title: localChatListItem?.displayTitle ?? chat.resolvedTitle(currentAccountId: profile.accountId),
            avatarSeedTitle: localChatListItem?.displayTitle ?? chat.avatarSeedTitle(currentAccountId: profile.accountId),
            previewText: chatListPreviewText(
                for: chat,
                localChatListItem: localChatListItem,
                latestMessage: latestMessage
            ),
            previewDate: localChatListItem?.previewDate ?? latestMessage?.createdAtDate,
            unreadCount: resolvedUnreadCount(
                localChatListItem: localChatListItem,
                localReadState: localReadState
            )
        )
    }

    private func latestInboxMessagesByChatId() -> [String: MessageEnvelope] {
        inboxItems.reduce(into: [String: MessageEnvelope]()) { partialResult, item in
            let message = item.message
            if let current = partialResult[message.chatId] {
                if message.createdAtUnix > current.createdAtUnix {
                    partialResult[message.chatId] = message
                }
            } else {
                partialResult[message.chatId] = message
            }
        }
    }

    private func chatListPreviewText(
        for chat: ChatSummary,
        localChatListItem: LocalChatListItemSnapshot?,
        latestMessage: MessageEnvelope?
    ) -> String {
        if let localChatListItem,
           let previewText = sanitizedPreview(localChatListItem.previewText) {
            if let prefixed = prefixedLocalPreviewText(for: chat, localChatListItem: localChatListItem, previewText: previewText) {
                return prefixed
            }
            return previewText
        }

        if let latestMessage {
            let previewBody = latestMessage.debugPreview
            if let prefix = senderPrefix(for: latestMessage, in: chat) {
                return "\(prefix): \(previewBody)"
            }
            return previewBody
        }

        if chat.lastServerSeq == 0 {
            switch chat.chatType {
            case .dm:
                return "Tap to send the first message"
            case .group:
                let names = chat.participantProfiles
                    .filter { chat.participantProfiles.count <= 1 || $0.accountId != profile.accountId }
                    .map(\.primaryDisplayName)
                if names.isEmpty {
                    return "No messages yet"
                }
                if names.count == 1 {
                    return names[0]
                }
                if names.count == 2 {
                    return "\(names[0]), \(names[1])"
                }
                return "\(names[0]), \(names[1]) +\(names.count - 2)"
            case .accountSync:
                return "Secure device sync"
            }
        }

        return "Loading recent messages..."
    }

    private func resolvedUnreadCount(
        localChatListItem: LocalChatListItemSnapshot?,
        localReadState: LocalChatReadStateSnapshot?
    ) -> Int {
        if let localReadState {
            return Int(min(localReadState.unreadCount, UInt64(Int.max)))
        }

        if let localChatListItem {
            return Int(min(localChatListItem.unreadCount, UInt64(Int.max)))
        }

        return 0
    }

    private func prefixedLocalPreviewText(
        for chat: ChatSummary,
        localChatListItem: LocalChatListItemSnapshot,
        previewText: String
    ) -> String? {
        if localChatListItem.previewIsOutgoing == true {
            return chat.chatType == .dm ? nil : "You: \(previewText)"
        }

        guard chat.chatType == .group,
              let senderDisplayName = sanitizedPreview(localChatListItem.previewSenderDisplayName)
        else {
            return nil
        }

        return "\(senderDisplayName): \(previewText)"
    }

    private func senderPrefix(for message: MessageEnvelope, in chat: ChatSummary) -> String? {
        if message.senderAccountId == profile.accountId {
            return "You"
        }

        guard chat.chatType == .group else {
            return nil
        }

        return chat.participantProfiles
            .first { $0.accountId == message.senderAccountId }?
            .primaryDisplayName
    }

    private func sanitizedPreview(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    @Environment(\.dismiss) private var dismiss
    let device: DeviceSummary
    @Binding var revokeReason: String
    let errorMessage: String?
    let isSubmitting: Bool
    let confirmAction: () async -> Bool

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

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
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove", role: .destructive) {
                        Task {
                            if await confirmAction() {
                                dismiss()
                            }
                        }
                    }
                        .disabled(isSubmitting || revokeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LinkIntentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let linkIntent: CreateLinkIntentResponse
    @State private var isShowingRawPayload = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        LinkIntentQRCodeView(payload: linkIntent.qrPayload)
                            .frame(maxWidth: .infinity)

                        VStack(spacing: 6) {
                            Text("Share this secure code with the device you want to add.")
                                .font(.subheadline.weight(.medium))
                                .multilineTextAlignment(.center)

                            Text("Copy it, share it, or let another Trix client scan the QR code.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Expires") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(linkIntent.expirationDate.formatted(date: .abbreviated, time: .standard))

                        Text(linkIntent.expirationDate, style: .relative)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ShareLink(item: linkIntent.qrPayload) {
                        Label("Share Link Code", systemImage: "square.and.arrow.up")
                    }

                    Button("Copy Link Code") {
                        UIPasteboard.general.string = linkIntent.qrPayload
                    }
                }

                Section {
                    DisclosureGroup("Code Details", isExpanded: $isShowingRawPayload) {
                        Text(linkIntent.qrPayload)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("Link Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct LinkIntentQRCodeView: View {
    let payload: String
    @State private var qrImage: UIImage?

    var body: some View {
        Group {
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 14, y: 8)
            } else {
                ContentUnavailableView("QR Unavailable", systemImage: "qrcode", description: Text("Copy the link code instead."))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: payload) {
            qrImage = await Task.detached(priority: .userInitiated) {
                Self.makeQRCodeImage(for: payload)
            }.value
        }
    }

    nonisolated private static func makeQRCodeImage(for payload: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    DashboardView(
        serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
        model: AppModel()
    )
}
