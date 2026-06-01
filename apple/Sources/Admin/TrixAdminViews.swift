import SwiftUI

struct TrixAdminRootView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        NavigationSplitView {
            List(TrixAdminSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section as TrixAdminSection?)
            }
            .navigationTitle("Trix Admin")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
                TrixAdminConnectionBar(model: model)
                Divider()
                TrixAdminDetailView(model: model)
            }
        }
    }
}

private struct TrixAdminConnectionBar: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        HStack(spacing: 12) {
            TextField("Server URL", text: $model.serverURLString)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
            SecureField("Admin token", text: $model.token)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)

            Button {
                Task { await model.connect() }
            } label: {
                Label(model.isConnected ? "Reconnect" : "Connect", systemImage: "lock.open")
            }
            .disabled(model.isLoading)

            Button {
                model.disconnect()
            } label: {
                Label("Disconnect", systemImage: "lock")
            }
            .disabled(!model.isConnected || model.isLoading)

            Spacer()

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            TrixAdminStatusPill(title: model.isConnected ? "Connected" : "Offline", status: model.isConnected ? "ok" : "offline")

            Button {
                Task { await model.refreshSelected() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.isConnected || model.isLoading)
        }
        .padding(12)
    }
}

private struct TrixAdminDetailView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = model.errorMessage {
                TrixAdminBanner(text: errorMessage, systemImage: "exclamationmark.triangle", color: .red)
            } else if let lastResult = model.lastResult {
                TrixAdminBanner(text: lastResult, systemImage: "checkmark.circle", color: .green)
            }

            Group {
                if !model.isConnected {
                    TrixAdminLoginState()
                } else {
                    switch model.currentSection {
                    case .dashboard:
                        TrixAdminDashboardView(model: model)
                    case .users:
                        TrixAdminUsersView(model: model)
                    case .pushes:
                        TrixAdminPushesView(model: model)
                    case .media:
                        TrixAdminMediaView(model: model)
                    case .flags:
                        TrixAdminFeatureFlagsView(model: model)
                    case .logs:
                        TrixAdminLogsView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct TrixAdminLoginState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Server authorization required", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text("Connect to the loopback admin API or an SSH tunnel using a server-issued operator token.")
                .foregroundStyle(.secondary)
            Text("Default local URL: http://127.0.0.1:8093")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

private struct TrixAdminDashboardView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrixAdminSectionHeader(title: "Dashboard", symbol: "gauge.with.dots.needle.bottom.50percent")

                HStack(alignment: .top, spacing: 16) {
                    TrixAdminPanel("Services") {
                        if let status = model.opsStatus {
                            TrixAdminMetricRow("ejabberd API", value: status.ejabberdAPI)
                            TrixAdminMetricRow("Push gateway", value: status.pushGateway)
                            TrixAdminMetricRow("Media storage", value: status.mediaStorage)
                        } else {
                            Text("No status loaded")
                                .foregroundStyle(.secondary)
                        }
                    }

                    TrixAdminPanel("Metrics") {
                        if let metrics = model.metrics {
                            TrixAdminMetricRow("Feature flags", value: "\(metrics.enabledFeatureFlags)/\(metrics.totalFeatureFlags) enabled")
                            TrixAdminMetricRow("Media files", value: "\(metrics.mediaFileCount)")
                            TrixAdminMetricRow("Media size", value: TrixAdminFormat.bytes(metrics.mediaTotalBytes))
                            TrixAdminMetricRow("ejabberd reachable", value: metrics.ejabberdAPIReachable ? "true" : "false")
                        } else {
                            Text("No metrics loaded")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let session = model.session {
                    TrixAdminPanel("Session") {
                        TrixAdminMetricRow("Role", value: session.role)
                        TrixAdminMetricRow("Capabilities", value: session.capabilities.joined(separator: ", "))
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct TrixAdminUsersView: View {
    @ObservedObject var model: TrixAdminAppModel

    private var selectedUserID: Binding<String?> {
        Binding {
            model.selectedUser?.id
        } set: { id in
            model.selectedUser = model.users.first { $0.id == id }
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                TrixAdminSectionHeader(title: "Users", symbol: "person.2")

                HStack {
                    TextField("Search", text: $model.userQuery)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await model.refreshSelected() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }

                List(model.users, selection: selectedUserID) { user in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.jid)
                            .font(.headline)
                        Text(user.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(user.id as String?)
                }
            }
            .padding(20)
            .frame(minWidth: 420)

            VStack(alignment: .leading, spacing: 16) {
                TrixAdminPanel("Provision") {
                    TextField("Localpart", text: $model.newUserLocalpart)
                    SecureField("Initial password", text: $model.userPassword)
                    Button {
                        Task { await model.provisionUser() }
                    } label: {
                        Label("Create User", systemImage: "person.badge.plus")
                    }
                }

                TrixAdminPanel("Selected User") {
                    if let user = model.selectedUser {
                        TrixAdminMetricRow("JID", value: user.jid)
                        SecureField("New password", text: $model.userPassword)
                        TextField("Disable reason", text: $model.disableReason)
                        HStack {
                            Button {
                                Task { await model.resetSelectedUserPassword() }
                            } label: {
                                Label("Reset Password", systemImage: "key")
                            }
                            Button {
                                Task { await model.disableSelectedUser() }
                            } label: {
                                Label("Disable", systemImage: "person.crop.circle.badge.xmark")
                            }
                            Button {
                                Task { await model.enableSelectedUser() }
                            } label: {
                                Label("Enable", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    } else {
                        Text("No user selected")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            .frame(minWidth: 480)
        }
    }
}

private struct TrixAdminPushesView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrixAdminSectionHeader(title: "Test Pushes", symbol: "bell.badge")

                TrixAdminPanel("Wake Push") {
                    TextField("APNs token hex", text: $model.wakeTokenHex)
                    Picker("Environment", selection: $model.wakeEnvironment) {
                        Text("Sandbox").tag("sandbox")
                        Text("Production").tag("production")
                    }
                    .pickerStyle(.segmented)
                    TextField("Account", text: $model.wakeAccount)
                    TextField("Room", text: $model.wakeRoom)
                    TextField("Badge", text: $model.wakeBadge)
                    Button {
                        Task { await model.sendWakePush() }
                    } label: {
                        Label("Send Wake", systemImage: "bell")
                    }
                }

                TrixAdminPanel("VoIP Call Push") {
                    TextField("Account", text: $model.voipAccount)
                    TextField("Call ID", text: $model.voipCallID)
                    Button {
                        Task { await model.sendVoIPPush() }
                    } label: {
                        Label("Send VoIP", systemImage: "phone.arrow.up.right")
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct TrixAdminMediaView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixAdminSectionHeader(title: "Media Storage", symbol: "internaldrive")

            TrixAdminPanel("HTTP Upload Volume") {
                if let media = model.media {
                    TrixAdminMetricRow("Status", value: media.status)
                    TrixAdminMetricRow("Root", value: media.rootPath)
                    TrixAdminMetricRow("Files", value: "\(media.fileCount)")
                    TrixAdminMetricRow("Bytes", value: TrixAdminFormat.bytes(media.totalBytes))
                    TrixAdminMetricRow("Newest modified", value: media.newestModifiedUnix.map(String.init) ?? "n/a")
                } else {
                    Text("No media snapshot loaded")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

private struct TrixAdminFeatureFlagsView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrixAdminSectionHeader(title: "Feature Flags", symbol: "flag")

            HStack {
                TextField("New flag key", text: $model.newFlagKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Button {
                    Task { await model.createFeatureFlag() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            List {
                ForEach($model.featureFlags) { $flag in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(flag.key)
                                .font(.headline)
                            Spacer()
                            TrixAdminStatusPill(title: flag.enabled ? "Enabled" : "Disabled", status: flag.enabled ? "ok" : "off")
                        }
                        TextField("Description", text: $flag.description)
                        HStack {
                            Toggle("Enabled", isOn: $flag.enabled)
                            Toggle("Client visible", isOn: $flag.clientVisible)
                            Stepper("Rollout \(flag.rolloutPercentage)%", value: $flag.rolloutPercentage, in: 0...100)
                            Spacer()
                            Button {
                                Task { await model.saveFeatureFlag(flag) }
                            } label: {
                                Label("Save", systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                Task { await model.deleteFeatureFlag(flag.key) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
    }
}

private struct TrixAdminLogsView: View {
    @ObservedObject var model: TrixAdminAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrixAdminSectionHeader(title: "Logs", symbol: "doc.text.magnifyingglass")

            HStack {
                TextField("Service", text: $model.logsService)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Slider(value: $model.logsLimit, in: 50...1000, step: 50) {
                    Text("Lines")
                }
                Text("\(Int(model.logsLimit))")
                    .frame(width: 48, alignment: .trailing)
                Button {
                    Task { await model.refreshSelected() }
                } label: {
                    Label("Load", systemImage: "arrow.down.doc")
                }
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Service Logs")
                            .font(.headline)
                        TrixAdminStatusPill(title: model.recentLogs.status, status: model.recentLogs.status)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.recentLogs.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(minWidth: 420)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Audit Trail")
                            .font(.headline)
                        TrixAdminStatusPill(title: model.recentAudit.status, status: model.recentAudit.status)
                    }
                    List(model.recentAudit.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.action)
                                    .font(.headline)
                                Spacer()
                                TrixAdminStatusPill(title: event.outcome, status: event.outcome)
                            }
                            Text(event.target)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            HStack {
                                Text(event.actor)
                                Text("\(event.timestampUnix)")
                                if let detail = event.detail {
                                    Text(detail)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(20)
    }
}

private struct TrixAdminSectionHeader: View {
    var title: String
    var symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.title2.weight(.semibold))
    }
}

private struct TrixAdminPanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TrixAdminMetricRow: View {
    var title: String
    var value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct TrixAdminStatusPill: View {
    var title: String
    var status: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case "ok", "true", "success":
            .green
        case "offline", "unavailable", "off", "false", "empty":
            .secondary
        default:
            .orange
        }
    }
}

private struct TrixAdminBanner: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10))
    }
}

private enum TrixAdminFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
