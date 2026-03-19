import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
                .background(
                    LinearGradient(
                        colors: [TrixPalette.sidebarElevated, TrixPalette.sidebar],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                TrixCanvas()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ContentHeader(model: model)

                        if let message = model.lastErrorMessage {
                            ErrorStrip(message: message) {
                                model.dismissError()
                            }
                        }

                        if model.showsWorkspace {
                            WorkspaceView(model: model)
                        } else {
                            OnboardingView(model: model)
                        }
                    }
                    .padding(32)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                TrixToneBadge(label: "alpha / macOS", tint: TrixPalette.accentSoft)

                Text("Trix")
                    .font(.system(size: 42, weight: .bold, design: .serif))
                    .foregroundStyle(.white)

                Text("Native encrypted messaging, starting with a Mac-first control room.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
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
                .foregroundStyle(.white.opacity(0.55))
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
            return Color.white
        }

        if let health = model.health {
            return health.status == .ok ? TrixPalette.accentSoft : Color(red: 0.98, green: 0.77, blue: 0.42)
        }

        return Color(red: 0.95, green: 0.66, blue: 0.42)
    }
}

private struct ContentHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.showsWorkspace ? "Workspace" : "Bring The First Device Online")
                        .font(.system(size: 42, weight: .bold, design: .serif))
                        .foregroundStyle(TrixPalette.ink)

                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(TrixPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 10) {
                    TrixToneBadge(label: connectionBadgeLabel, tint: connectionTint)
                    if let version = model.version {
                        Text("server \(version.version)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrixPalette.inkMuted)
                    }
                }
            }

            HStack(spacing: 16) {
                TrixMetricTile(
                    label: "Endpoint",
                    value: endpointValue,
                    footnote: model.health == nil ? "No successful handshake yet" : "Active development target"
                )
                TrixMetricTile(
                    label: "Mode",
                    value: model.isAuthenticated ? "Authenticated" : (model.hasPersistedSession ? "Reconnectable" : "Bootstrap"),
                    footnote: model.isAuthenticated ? "Device and chats loaded from the server" : "Create or restore the first trusted device"
                )
                TrixMetricTile(
                    label: "Scope",
                    value: model.isAuthenticated ? "\(model.chats.count) chats" : "Mac alpha",
                    footnote: model.isAuthenticated ? "\(model.devices.count) device records visible" : "First-device onboarding and history inspection"
                )
            }
        }
    }

    private var subtitle: String {
        model.showsWorkspace
            ? "A calmer shell for browsing account state, devices, chats and encrypted history."
            : "The UI now leads with runtime diagnostics and a cleaner first-device bootstrap flow."
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
            return TrixPalette.rust
        }
        if let health = model.health {
            return health.status == .ok ? TrixPalette.success : TrixPalette.warning
        }
        return TrixPalette.warning
    }
}

private struct SidebarModule<Content: View>: View {
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
                .foregroundStyle(.white.opacity(0.48))

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct SidebarValue: View {
    let label: String
    let value: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SidebarBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(TrixPalette.accentSoft.opacity(0.86))
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct ErrorStrip: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title3)
                .foregroundStyle(TrixPalette.warning)

            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(TrixPalette.ink)

            Button("Dismiss", action: dismiss)
                .buttonStyle(TrixActionButtonStyle(tone: .ghost))
                .frame(width: 140)
        }
        .padding(18)
        .background(TrixPalette.panelStrong, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(TrixPalette.warning.opacity(0.24), lineWidth: 1)
        }
    }
}
