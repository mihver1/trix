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
                SidebarView(model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
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

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ContentHeader(model: model, size: proxy.size)

                            if let message = model.lastErrorMessage {
                                ErrorStrip(message: message) {
                                    model.dismissError()
                                }
                            }

                            if model.showsWorkspace {
                                WorkspaceView(model: model, availableSize: proxy.size)
                            } else {
                                OnboardingView(model: model, availableSize: proxy.size)
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.trixColors, TrixColors.resolve(for: colorScheme))
    }
}

private struct SidebarView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                TrixToneBadge(label: "alpha / macOS", tint: colors.accentSoft)

                Text("Trix")
                    .font(.system(size: 38, weight: .bold, design: .serif))
                    .foregroundStyle(colors.inverseInk)

                Text("Native encrypted messaging, starting with a Mac-first control room.")
                    .font(.subheadline)
                    .foregroundStyle(colors.inverseInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                        SidebarValue(label: "Devices", value: "\(model.devices.count)")
                        SidebarValue(label: "Chats", value: "\(model.chats.count)")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SidebarBullet("health and version handshake")
                        SidebarBullet("first-device bootstrap")
                        SidebarBullet("manual device linking + approval payloads")
                        SidebarBullet("challenge/session auth restore")
                        SidebarBullet("chat metadata + encrypted history browser")
                    }
                }
            }

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

            Spacer()

            Text("Local keys. Server-assisted coordination. Message crypto next.")
                .font(.footnote)
                .foregroundStyle(colors.inverseInkMuted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(headerTitle)
                        .font(.system(size: titleFontSize, weight: .bold, design: .serif))
                        .foregroundStyle(colors.ink)

                    Text(subtitle)
                        .font(size.height < 760 ? .headline : .title3)
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
                    footnote: model.isAuthenticated ? "\(model.devices.count) device records visible" : (model.isAwaitingLinkApproval ? "Approval payload export and reconnect loop" : "First-device onboarding and history inspection")
                )
            }
        }
    }

    private var subtitle: String {
        model.showsWorkspace
            ? "A calmer shell for browsing account state, devices, chats and encrypted history."
            : (model.isAwaitingLinkApproval
                ? "This Mac is registered as a pending device and is waiting for a root-capable device to approve it."
                : "The UI now leads with runtime diagnostics and a cleaner first-device bootstrap flow.")
    }

    private var headerTitle: String {
        if model.showsWorkspace {
            return "Workspace"
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

private struct ErrorStrip: View {
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
