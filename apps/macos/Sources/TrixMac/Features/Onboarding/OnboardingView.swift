import SwiftUI

struct OnboardingView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let availableSize: CGSize

    private var prefersSingleColumn: Bool {
        availableSize.width < 1380 || availableSize.height < 860
    }

    private var featurePanelWidth: CGFloat {
        min(380, max(320, availableSize.width * 0.28))
    }

    private var bioHeight: CGFloat {
        availableSize.height < 760 ? 108 : 136
    }

    var body: some View {
        Group {
            if prefersSingleColumn {
                VStack(alignment: .leading, spacing: 20) {
                    formColumn
                    leadingColumn
                }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    leadingColumn
                        .frame(width: featurePanelWidth)

                    formColumn
                }
            }
        }
    }

    private var leadingColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.isAwaitingLinkApproval {
                pendingStatusPanel
            } else {
                modeSummaryPanel
            }

            environmentPanel
        }
    }

    private var formColumn: some View {
        Group {
            if model.isAwaitingLinkApproval {
                pendingApprovalColumn
            } else {
                switch model.onboardingMode {
                case .createAccount:
                    createAccountColumn
                case .linkExisting:
                    linkExistingColumn
                }
            }
        }
    }

    private var modeSummaryPanel: some View {
        TrixPanel(
            title: model.onboardingMode == .createAccount ? "Mac-First Bootstrap" : "Device Linking",
            subtitle: model.onboardingMode == .createAccount
                ? "The first device flow should feel like a launch console, not a settings screen."
                : "Linking still starts from a payload, but approval now happens directly from the trusted device directory."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if model.onboardingMode == .createAccount {
                    OnboardingFeature(
                        symbol: "wave.3.right.circle.fill",
                        title: "Live runtime handshake",
                        detail: "Reads `/v0/system/health` and `/v0/system/version` before you register anything."
                    )
                    OnboardingFeature(
                        symbol: "key.horizontal.fill",
                        title: "Real device material",
                        detail: "Generates account-root and transport signing keys locally on this Mac."
                    )
                    OnboardingFeature(
                        symbol: "rectangle.stack.badge.person.crop.fill",
                        title: "Stateful restore",
                        detail: "Replays challenge/session auth using stored device keys instead of fake local login."
                    )
                    OnboardingFeature(
                        symbol: "link.badge.plus",
                        title: "Next slice is live",
                        detail: "Current build already supports link intent creation, pending-device completion and server-backed approval."
                    )
                } else {
                    OnboardingFeature(
                        symbol: "qrcode.viewfinder",
                        title: "Bring a link payload",
                        detail: "Paste the JSON payload created by an already active Trix device."
                    )
                    OnboardingFeature(
                        symbol: "desktopcomputer.trianglebadge.exclamationmark",
                        title: "Generate local transport keys",
                        detail: "The linked Mac keeps only its own transport key and credential identity."
                    )
                    OnboardingFeature(
                        symbol: "lock.shield",
                        title: "Approval is directory-backed",
                        detail: "Once this Mac registers as pending, another active trusted device can approve it directly from the device list."
                    )
                    OnboardingFeature(
                        symbol: "arrow.clockwise.circle",
                        title: "Reconnect after approval",
                        detail: "Once another trusted device approves the payload, this Mac can authenticate normally."
                    )
                }
            }
        }
    }

    private var environmentPanel: some View {
        TrixPanel(
            title: "Environment Readiness",
            subtitle: "Useful when the local backend is down or only partially started."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    TrixToneBadge(label: readinessLabel, tint: readinessTint)

                    if let health = model.health {
                        Text("uptime \(formattedUptime(health.uptimeMs))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.inkMuted)
                    }
                }

                TrixMetricTile(
                    label: "Suggested target",
                    value: model.serverBaseURLString,
                    footnote: model.health == nil ? "Make sure the backend is reachable from this Mac." : "Handshake succeeded at least once in this session."
                )

                VStack(alignment: .leading, spacing: 10) {
                    CommandLineChip("docker compose up postgres")
                    CommandLineChip("cargo run -p trixd")
                }

                Text("Until MLS and native Rust bindings land, these bootstrap screens stay deliberately manual and inspectable.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
            }
        }
    }

    private var createAccountColumn: some View {
        TrixPanel(
            title: "Create The First Trusted Device",
            subtitle: "Register the account root, transport key and local device profile in one pass."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                modeSelector

                HStack(spacing: 12) {
                    TrixToneBadge(label: endpointLabel, tint: readinessTint)
                    Text("platform macos")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.inkMuted)
                }

                TrixInputBlock("Server URL", hint: "Usually `http://127.0.0.1:8080` in local development.") {
                    TextField("http://127.0.0.1:8080", text: $model.serverBaseURLString)
                        .textFieldStyle(.roundedBorder)
                }

                TrixInputBlock("Profile Name", hint: "Visible name for the account.") {
                    TextField("Maksym", text: $model.draft.profileName)
                        .textFieldStyle(.roundedBorder)
                }

                if prefersSingleColumn {
                    VStack(alignment: .leading, spacing: 16) {
                        handleField
                        deviceField
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        handleField
                        deviceField
                    }
                }

                TrixInputBlock("Profile Bio", hint: "Stored as profile metadata on the server.") {
                    TextEditor(text: $model.draft.profileBio)
                        .frame(minHeight: bioHeight)
                        .font(.body)
                }

                createActionRow

                Text("Private keys stay on this Mac. The server only receives public material and the signed bootstrap payload.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var linkExistingColumn: some View {
        TrixPanel(
            title: "Link This Mac To An Existing Account",
            subtitle: "Paste a link intent from another trusted device, then register this Mac as pending approval."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                modeSelector

                HStack(spacing: 12) {
                    TrixToneBadge(label: "Manual payload flow", tint: colors.rust)
                    Text("approval happens on a root-capable device")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.inkMuted)
                }

                TrixInputBlock(
                    "Link Payload",
                    hint: "Paste the JSON from `Create Link Intent` on an already active device."
                ) {
                    TextEditor(text: $model.linkDraft.linkPayload)
                        .frame(minHeight: 160)
                        .font(.system(.body, design: .monospaced))
                }

                TrixInputBlock("Device Name", hint: "How this Mac should appear in the remote device directory.") {
                    TextField("This Mac", text: $model.linkDraft.deviceDisplayName)
                        .textFieldStyle(.roundedBorder)
                }

                Group {
                    if prefersSingleColumn {
                        VStack(spacing: 12) {
                            Button {
                                Task {
                                    await model.refreshServerStatus()
                                }
                            } label: {
                                Label("Check Server", systemImage: "bolt.horizontal.circle")
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: 190)

                            Button {
                                Task {
                                    await model.completeLink()
                                }
                            } label: {
                                if model.isCompletingLink {
                                    Label("Registering Device…", systemImage: "hourglass")
                                } else {
                                    Label("Register Pending Device", systemImage: "link.badge.plus")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canCompleteLink || model.isCompletingLink)
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    await model.refreshServerStatus()
                                }
                            } label: {
                                Label("Check Server", systemImage: "bolt.horizontal.circle")
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: 190)

                            Button {
                                Task {
                                    await model.completeLink()
                                }
                            } label: {
                                if model.isCompletingLink {
                                    Label("Registering Device…", systemImage: "hourglass")
                                } else {
                                    Label("Register Pending Device", systemImage: "link.badge.plus")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canCompleteLink || model.isCompletingLink)
                            .frame(maxWidth: 260)
                        }
                    }
                }

                Text("This Mac will not receive the account-root key. After registration it appears as a pending device, and another trusted device can approve it directly from the workspace.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pendingStatusPanel: some View {
        TrixPanel(
            title: "Pending Approval",
            subtitle: "This Mac has already registered a pending device record and is waiting for another trusted device to approve it from the device directory."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingFeature(
                    symbol: "desktopcomputer.trianglebadge.exclamationmark",
                    title: "Local transport key is ready",
                    detail: "Challenge/session auth will start working as soon as the pending device flips to active."
                )
                OnboardingFeature(
                    symbol: "list.bullet.rectangle",
                    title: "Look for this Mac in Devices",
                    detail: "Another active trusted device can now approve or reject this pending record directly from its device list."
                )
                OnboardingFeature(
                    symbol: "arrow.clockwise.circle",
                    title: "Reconnect is safe to retry",
                    detail: "Once approval lands on the server, this screen can re-authenticate without re-registering."
                )
            }
        }
    }

    private var pendingApprovalColumn: some View {
        TrixPanel(
            title: "Waiting For Approval",
            subtitle: "The server knows about this Mac, but it is still `pending`. Another active trusted device must approve it from the workspace device directory."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let deviceID = model.pendingLinkedDeviceID {
                    TrixInputBlock(
                        "Pending Device ID",
                        hint: "Use this to identify the Mac inside the trusted device directory on another active device."
                    ) {
                        TrixPayloadBox(payload: deviceID.uuidString, minHeight: 84)
                    }

                    Group {
                        if prefersSingleColumn {
                            VStack(spacing: 12) {
                                Button {
                                    copyStringToPasteboard(deviceID.uuidString)
                                } label: {
                                    Label("Copy Device ID", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: 220)

                                Button {
                                    Task {
                                        await model.restoreSession()
                                    }
                                } label: {
                                    Label(
                                        model.isRestoringSession ? "Reconnecting…" : "Reconnect After Approval",
                                        systemImage: "arrow.clockwise.circle.fill"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: 280)
                                .disabled(model.isRestoringSession)

                                Button(role: .destructive) {
                                    model.restartPendingLinkFlow()
                                } label: {
                                    Label("Restart Link", systemImage: "arrow.uturn.backward.circle")
                                }
                                .buttonStyle(.borderless)
                                .frame(maxWidth: 220)
                            }
                        } else {
                            HStack(spacing: 12) {
                                Button {
                                    copyStringToPasteboard(deviceID.uuidString)
                                } label: {
                                    Label("Copy Device ID", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: 220)

                                Button {
                                    Task {
                                        await model.restoreSession()
                                    }
                                } label: {
                                    Label(
                                        model.isRestoringSession ? "Reconnecting…" : "Reconnect After Approval",
                                        systemImage: "arrow.clockwise.circle.fill"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: 280)
                                .disabled(model.isRestoringSession)

                                Button(role: .destructive) {
                                    model.restartPendingLinkFlow()
                                } label: {
                                    Label("Restart Link", systemImage: "arrow.uturn.backward.circle")
                                }
                                .buttonStyle(.borderless)
                                .frame(maxWidth: 220)
                            }
                        }
                    }
                } else {
                    EmptyWorkspaceLabel("The pending device ID is missing from local session state. Re-link the device if this persists.")
                }

                Text("Another active trusted device can now fetch the canonical approval payload directly from the server. No manual JSON handoff is required anymore.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeSelector: some View {
        Picker("Setup Flow", selection: $model.onboardingMode) {
            ForEach(OnboardingMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var handleField: some View {
        TrixInputBlock("Handle", hint: "Optional public handle.") {
            TextField("optional handle", text: $model.draft.handle)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var deviceField: some View {
        TrixInputBlock("Device Name", hint: "How this Mac appears in the device list.") {
            TextField("This Mac", text: $model.draft.deviceDisplayName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var createActionRow: some View {
        Group {
            if prefersSingleColumn {
                VStack(spacing: 12) {
                    Button {
                        Task {
                            await model.refreshServerStatus()
                        }
                    } label: {
                        Label("Check Server", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 190)

                    Button {
                        Task {
                            await model.createAccount()
                        }
                    } label: {
                        if model.isCreatingAccount {
                            Label("Creating Device…", systemImage: "hourglass")
                        } else {
                            Label("Create Account", systemImage: "arrow.up.right.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreateAccount || model.isCreatingAccount)
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await model.refreshServerStatus()
                        }
                    } label: {
                        Label("Check Server", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 190)

                    Button {
                        Task {
                            await model.createAccount()
                        }
                    } label: {
                        if model.isCreatingAccount {
                            Label("Creating Device…", systemImage: "hourglass")
                        } else {
                            Label("Create Account", systemImage: "arrow.up.right.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreateAccount || model.isCreatingAccount)
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    private var readinessLabel: String {
        if model.isRefreshingStatus {
            return "Checking runtime"
        }
        if let health = model.health {
            return health.status == .ok ? "Runtime ready" : "Runtime degraded"
        }
        return "Runtime offline"
    }

    private var endpointLabel: String {
        model.health == nil ? "Handshake pending" : "Handshake complete"
    }

    private var readinessTint: Color {
        if model.isRefreshingStatus {
            return colors.rust
        }
        if let health = model.health {
            return health.status == .ok ? colors.success : colors.warning
        }
        return colors.warning
    }

}

private struct OnboardingFeature: View {
    @Environment(\.trixColors) private var colors
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(colors.ink)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(colors.inkMuted)
        }
    }
}

private struct CommandLineChip: View {
    @Environment(\.trixColors) private var colors
    let command: String

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        Text(command)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(colors.ink)
            .textSelection(.enabled)
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
