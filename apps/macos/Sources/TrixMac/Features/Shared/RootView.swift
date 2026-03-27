import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    private var colors: TrixColors {
        TrixColors.resolve()
    }

    private var rootDetailAccessibilityIdentifier: String {
        if model.showsWorkspace {
            if model.currentAccount == nil {
                return TrixMacAccessibilityID.Root.restoreSessionScreen
            }
            return TrixMacAccessibilityID.Root.workspaceScreen
        }
        if model.isAwaitingLinkApproval {
            return TrixMacAccessibilityID.Root.pendingApprovalScreen
        }
        return TrixMacAccessibilityID.Root.onboardingScreen
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if model.showsWorkspace {
                    WorkspaceSidebarView(model: model)
                } else {
                    SidebarView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(
                min: model.showsWorkspace ? 260 : 240,
                ideal: model.showsWorkspace ? 300 : 260,
                max: model.showsWorkspace ? 360 : 300
            )
        } detail: {
            GeometryReader { proxy in
                detailPane(size: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(TrixCanvas())
                    .background {
                        Color.clear
                            .accessibilityIdentifier(rootDetailAccessibilityIdentifier)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.trixColors, colors)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.setApplicationActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.setApplicationActive(false)
        }
    }

    @ViewBuilder
    private func detailPane(size: CGSize) -> some View {
        if model.showsWorkspace {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.lastErrorMessage {
                    ErrorStrip(message: message) {
                        model.dismissError()
                    }
                }

                WorkspaceView(model: model, availableSize: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(16)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ContentHeader(model: model, size: size)

                    if let message = model.lastErrorMessage {
                        ErrorStrip(message: message) {
                            model.dismissError()
                        }
                    }

                    OnboardingView(model: model, availableSize: size)
                }
                .padding(20)
                .frame(maxWidth: 1100, alignment: .topLeading)
            }
        }
    }
}

private struct WorkspaceSidebarView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedChatID },
            set: { newValue in
                guard let newValue else {
                    // The workspace keeps one chat selected whenever conversations exist.
                    return
                }
                Task {
                    await model.selectChat(newValue)
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                if model.visibleLocalChatListItems.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Create a chat from the toolbar to start messaging.")
                    )
                } else {
                    ForEach(model.visibleLocalChatListItems) { chat in
                        WorkspaceSidebarChatRow(
                            chat: chat,
                            currentAccountID: model.chatPresentationAccountID,
                            isLoading: chat.chatId == model.selectedChatID && model.isLoadingSelectedChat
                        )
                        .tag(chat.chatId as UUID?)
                    }
                }
            } header: {
                HStack {
                    Text("Messages")
                    Spacer()
                    if !model.visibleLocalChatListItems.isEmpty {
                        Text("\(model.visibleLocalChatListItems.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trix")
                        .font(.title2.weight(.semibold))
                    Text("Native encrypted messaging on macOS, with operational tools kept close at hand.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TrixToneBadge(label: "alpha / macOS", tint: colors.accent)
                }
                .padding(.vertical, 4)
            }

            Section(model.showsWorkspace ? "Account" : "Runtime") {
                SidebarValueRow(label: "Endpoint", value: model.serverBaseURLString)
                SidebarValueRow(label: "Connection", value: connectionLabel, tint: connectionTint)
                if let version = model.version {
                    SidebarValueRow(label: "Version", value: version.version)
                }
            }

            Section(model.isAuthenticated ? "Session" : "Current Scope") {
                if let account = model.currentAccount {
                    SidebarValueRow(label: "Profile", value: account.profileName)
                    SidebarValueRow(label: "Handle", value: account.handle ?? "not set")
                    SidebarValueRow(label: "Chats", value: "\(model.chats.count)")
                    SidebarValueRow(label: "Device", value: account.deviceStatus.label)
                } else {
                    ForEach(scopeHighlights, id: \.self) { highlight in
                        Text(highlight)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Actions") {
                Button {
                    Task {
                        await model.refreshServerStatus()
                    }
                } label: {
                    Label(
                        model.isRefreshingStatus ? "Refreshing Server…" : "Refresh Server",
                        systemImage: "wave.3.right.circle"
                    )
                }
                .disabled(model.isRefreshingStatus)

                if model.hasPersistedSession && !model.isAuthenticated {
                    Button {
                        Task {
                            await model.restoreSession()
                        }
                    } label: {
                        Label(
                            model.isRestoringSession ? "Reconnecting…" : "Reconnect Session",
                            systemImage: "arrow.clockwise.circle"
                        )
                    }
                    .disabled(model.isRestoringSession)
                }

                if model.isAuthenticated {
                    Button {
                        Task {
                            await model.refreshWorkspace()
                        }
                    } label: {
                        Label(
                            model.isRefreshingWorkspace ? "Syncing Workspace…" : "Refresh Workspace",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(model.isRefreshingWorkspace)
                }

                if model.showsWorkspace {
                    Button(role: .destructive) {
                        model.signOut()
                    } label: {
                        Label("Forget This Device", systemImage: "trash")
                    }
                }
            }

            Section {
                Text("Local keys and a persistent conversation cache stay on this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
    }

    private var scopeHighlights: [String] {
        [
            "Health and version handshake",
            "First-device bootstrap",
            "Device linking and approval",
            "Persistent local history",
            "Chat metadata inspection",
        ]
    }

    private var connectionLabel: String {
        if model.isRefreshingStatus {
            return "Checking"
        }

        if let health = model.health {
            return health.status == .ok ? "Healthy" : "Degraded"
        }

        return "Offline"
    }

    private var connectionTint: Color {
        if model.isRefreshingStatus {
            return colors.accent
        }

        if let health = model.health {
            return health.status == .ok ? colors.success : colors.warning
        }

        return colors.warning
    }
}

private struct WorkspaceSidebarChatRow: View {
    let chat: LocalChatListItem
    let currentAccountID: UUID?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(chat.displayTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(chat.sidebarPreview(for: currentAccountID))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(alignment: .trailing, spacing: 6) {
                if chat.hasUnread {
                    Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                } else if let previewCreatedAt = chat.previewCreatedAt {
                    Text(Self.relativeFormatter.localizedString(for: previewCreatedAt, relativeTo: .now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch chat.chatType {
        case .dm:
            return "person.crop.circle"
        case .group:
            return "person.3"
        case .accountSync:
            return "arrow.triangle.2.circlepath"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct ContentHeader: View {
    @ObservedObject var model: AppModel
    let size: CGSize

    private var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: size.width < 1180 ? 220 : 250), spacing: 14)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headerTitle)
                        .font(.largeTitle.weight(.semibold))

                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(connectionBadgeLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(connectionTint)
                    if let version = model.version {
                        Text("server \(version.version)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.showsWorkspace {
                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 14) {
                    TrixMetricTile(
                        label: "Endpoint",
                        value: endpointValue,
                        footnote: model.health == nil ? "No successful handshake yet" : "Active development target"
                    )
                    TrixMetricTile(
                        label: "Mode",
                        value: model.isAuthenticated ? "Authenticated" : (model.isAwaitingLinkApproval ? "Pending Approval" : (model.hasPersistedSession ? "Reconnectable" : "Bootstrap")),
                        footnote: model.isAuthenticated ? "Device and chats loaded from the server" : (model.isAwaitingLinkApproval ? "Waiting for another trusted device to sign this Mac" : "Create or restore the first trusted device")
                    )
                    TrixMetricTile(
                        label: "Scope",
                        value: model.isAuthenticated ? "\(model.chats.count) chats" : (model.isAwaitingLinkApproval ? "Link handoff" : "Mac alpha"),
                        footnote: model.isAuthenticated ? "\(model.devices.count) device records visible" : (model.isAwaitingLinkApproval ? "Device-directory approval and reconnect loop" : "First-device onboarding and history inspection")
                    )
                }
            }
        }
    }

    private var subtitle: String {
        model.showsWorkspace
            ? "Chat-first conversations with device and sync tooling moved into dedicated settings and inspectors."
            : (model.isAwaitingLinkApproval
                ? "This Mac is registered as a pending device and is waiting for another trusted device to approve it from the device directory."
                : "Set up the first trusted device or connect this Mac to an existing account.")
    }

    private var headerTitle: String {
        if model.showsWorkspace {
            return "Messages"
        }
        if model.isAwaitingLinkApproval {
            return "Finish Linking This Mac"
        }
        return "Bring the First Device Online"
    }

    private var endpointValue: String {
        if let host = ServerEndpoint.normalizedURL(from: model.serverBaseURLString)?.host(percentEncoded: false) {
            return host
        }
        return "invalid url"
    }

    private var connectionBadgeLabel: String {
        if model.isRefreshingStatus {
            return "Checking server"
        }
        if let health = model.health {
            return health.status == .ok ? "Server healthy" : "Server degraded"
        }
        return "Server unreachable"
    }

    private var connectionTint: Color {
        if model.isRefreshingStatus {
            return .accentColor
        }
        if let health = model.health {
            return health.status == .ok ? .green : .orange
        }
        return .orange
    }
}

private struct SidebarValueRow: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(tint)
                .textSelection(.enabled)
        }
    }
}

struct ErrorStrip: View {
    @Environment(\.trixColors) private var colors
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colors.warning)

            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(colors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(colors.warning.opacity(0.22), lineWidth: 1)
        }
    }
}
