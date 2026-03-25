import SwiftUI

struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    private var colors: TrixColors {
        TrixColors.resolve(for: colorScheme)
    }

    var body: some View {
        NavigationSplitView {
            ScrollView(.vertical, showsIndicators: false) {
                if model.showsWorkspace {
                    WorkspaceSidebarView(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 18)
                } else {
                    SidebarView(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            }
            .navigationSplitViewColumnWidth(
                min: model.showsWorkspace ? 248 : 228,
                ideal: model.showsWorkspace ? 284 : 244,
                max: model.showsWorkspace ? 320 : 272
            )
            .background(
                LinearGradient(
                    colors: [colors.sidebarElevated, colors.sidebar],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            GeometryReader { proxy in
                ZStack {
                    TrixCanvas()

                    if model.showsWorkspace {
                        VStack(alignment: .leading, spacing: 20) {
                            if let message = model.lastErrorMessage {
                                ErrorStrip(message: message) {
                                    model.dismissError()
                                }
                            }

                            WorkspaceView(model: model, availableSize: proxy.size)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                            .padding(.top, 26)
                            .padding(.horizontal, 22)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                ContentHeader(model: model, size: proxy.size)

                                if let message = model.lastErrorMessage {
                                    ErrorStrip(message: message) {
                                        model.dismissError()
                                    }
                                }

                                OnboardingView(model: model, availableSize: proxy.size)
                            }
                            .padding(24)
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.trixColors, TrixColors.resolve(for: colorScheme))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.setApplicationActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.setApplicationActive(false)
        }
    }
}

private struct WorkspaceSidebarView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("Chats")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(colors.inverseInk)

                Spacer(minLength: 0)

                if !model.visibleLocalChatListItems.isEmpty {
                    Text("\(model.visibleLocalChatListItems.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colors.inverseInkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(colors.inverseInk.opacity(0.06), in: Capsule())
                }
            }

            if model.visibleLocalChatListItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No conversations yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.inverseInk)

                    Text("Start a new chat from the main header.")
                        .font(.footnote)
                        .foregroundStyle(colors.inverseInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.visibleLocalChatListItems) { chat in
                        WorkspaceSidebarChatRow(
                            chat: chat,
                            currentAccountID: model.chatPresentationAccountID,
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

private struct SidebarView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sidebarBrand

            if model.showsWorkspace {
                SidebarModule(title: "Account") {
                    VStack(alignment: .leading, spacing: 14) {
                        TrixToneBadge(label: connectionLabel, tint: connectionTint)
                        if let account = model.currentAccount {
                            SidebarValue(label: "Profile", value: account.profileName)
                            SidebarValue(label: "Handle", value: account.handle ?? "not set")
                            SidebarValue(label: "Chats", value: "\(model.chats.count)")
                        }
                        if let version = model.version {
                            SidebarValue(label: "Version", value: version.version)
                        }
                    }
                }

                sidebarActions
            } else {
                SidebarModule(title: "Runtime") {
                    VStack(alignment: .leading, spacing: 14) {
                        SidebarValue(label: "Endpoint", value: model.serverBaseURLString)
                        SidebarValue(
                            label: "Connection",
                            value: connectionLabel,
                            tint: connectionTint
                        )

                        if let version = model.version {
                            SidebarValue(label: "Version", value: version.version)
                        }
                    }
                }

                SidebarModule(title: model.isAuthenticated ? "Session" : "Current Scope") {
                    if let account = model.currentAccount {
                        VStack(alignment: .leading, spacing: 14) {
                            SidebarValue(label: "Profile", value: account.profileName)
                            SidebarValue(label: "Handle", value: account.handle ?? "not set")
                            SidebarValue(label: "Chats", value: "\(model.chats.count)")
                            SidebarValue(label: "Device", value: account.deviceStatus.label)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            SidebarBullet("health and version handshake")
                            SidebarBullet("first-device bootstrap")
                            SidebarBullet("device linking + server-backed approval")
                            SidebarBullet("inbox leasing + incremental polling")
                            SidebarBullet("manual key-package publish + reserve")
                            SidebarBullet("history sync job inspector")
                            SidebarBullet("challenge/session auth restore")
                            SidebarBullet("persistent local history + sync cursors")
                            SidebarBullet("chat metadata + encrypted history browser")
                        }
                    }
                }

                sidebarActions
            }

            Spacer()

            Text("Local keys and a persistent conversation cache stay on this Mac.")
                .font(.footnote)
                .foregroundStyle(colors.inverseInkMuted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarBrand: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrixToneBadge(label: "alpha / macOS", tint: colors.accentSoft)

            Text("Trix")
                .font(.system(size: 38, weight: .bold, design: .serif))
                .foregroundStyle(colors.inverseInk)

            Text("Native encrypted messaging, with a chat-first Mac client and a separate control surface.")
                .font(.subheadline)
                .foregroundStyle(colors.inverseInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarActions: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .buttonStyle(TrixActionButtonStyle(tone: .sidebar))
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
                .buttonStyle(TrixActionButtonStyle(tone: .sidebar))
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
                .buttonStyle(TrixActionButtonStyle(tone: .sidebar))
                .disabled(model.isRefreshingWorkspace)
            }

            if model.showsWorkspace {
                Button(role: .destructive) {
                    model.signOut()
                } label: {
                    Label("Forget This Device", systemImage: "trash")
                }
                .buttonStyle(TrixActionButtonStyle(tone: .sidebar))
            }
        }
    }

    private var connectionLabel: String {
        if model.isRefreshingStatus {
            return "checking"
        }

        if let health = model.health {
            return health.status == .ok ? "healthy" : "degraded"
        }

        return "offline"
    }

    private var connectionTint: Color {
        if model.isRefreshingStatus {
            return colors.inverseInk
        }

        if let health = model.health {
            return health.status == .ok ? colors.accentSoft : colors.warning
        }

        return colors.warning
    }
}

private struct WorkspaceSidebarChatRow: View {
    @Environment(\.trixColors) private var colors
    let chat: LocalChatListItem
    let currentAccountID: UUID?
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? colors.accent.opacity(0.22) : colors.inverseInk.opacity(0.07))
                        .frame(width: 42, height: 42)

                    Image(systemName: iconName)
                        .font(.headline)
                        .foregroundStyle(isSelected ? colors.accentSoft : colors.inverseInkMuted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.displayTitle)
                        .font(.headline)
                        .foregroundStyle(colors.inverseInk)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(chat.sidebarPreview(for: currentAccountID))
                        .font(.subheadline)
                        .foregroundStyle(colors.inverseInkMuted)
                        .lineLimit(2)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    if chat.hasUnread {
                        Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(colors.accent, in: Capsule())
                    } else if let previewCreatedAt = chat.previewCreatedAt {
                        Text(Self.relativeFormatter.localizedString(for: previewCreatedAt, relativeTo: .now))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colors.inverseInkMuted)
                    }

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(colors.accentSoft)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? colors.inverseInk.opacity(0.10) : colors.inverseInk.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? colors.accentSoft.opacity(0.24) : colors.inverseInk.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let size: CGSize

    private var titleFontSize: CGFloat {
        size.height < 760 ? 34 : 42
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: size.width < 1180 ? 220 : 250), spacing: 14),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: model.showsWorkspace ? 8 : 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(headerTitle)
                        .font(.system(size: titleFontSize, weight: .bold, design: .serif))
                        .foregroundStyle(colors.ink)

                    Text(subtitle)
                        .font(model.showsWorkspace ? .headline : (size.height < 760 ? .headline : .title3))
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 10) {
                    TrixToneBadge(label: connectionBadgeLabel, tint: connectionTint)
                    if let version = model.version {
                        Text("server \(version.version)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.inkMuted)
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
            ? "Chat-first workspace for conversations, with device and sync tooling moved behind Control."
            : (model.isAwaitingLinkApproval
                ? "This Mac is registered as a pending device and is waiting for another trusted device to approve it from the device directory."
                : "The UI now leads with runtime diagnostics and a cleaner first-device bootstrap flow.")
    }

    private var headerTitle: String {
        if model.showsWorkspace {
            return "Messages"
        }
        if model.isAwaitingLinkApproval {
            return "Finish Linking This Mac"
        }
        return "Bring The First Device Online"
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
            return colors.rust
        }
        if let health = model.health {
            return health.status == .ok ? colors.success : colors.warning
        }
        return colors.warning
    }
}

private struct SidebarModule<Content: View>: View {
    @Environment(\.trixColors) private var colors
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(colors.inverseInkMuted.opacity(0.68))

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.inverseInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(colors.inverseInk.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct SidebarValue: View {
    @Environment(\.trixColors) private var colors
    let label: String
    let value: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(colors.inverseInkMuted.opacity(0.58))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SidebarBullet: View {
    @Environment(\.trixColors) private var colors
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(colors.accentSoft.opacity(0.86))
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(colors.inverseInkMuted)
        }
    }
}

struct ErrorStrip: View {
    @Environment(\.trixColors) private var colors
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title3)
                .foregroundStyle(colors.warning)

            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(colors.ink)

            Button("Dismiss", action: dismiss)
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                .frame(width: 140)
        }
        .padding(18)
        .background(colors.panelStrong, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(colors.warning.opacity(0.24), lineWidth: 1)
        }
    }
}
