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
            title: model.onboardingMode == .createAccount ? "Mac-First Bootstrap" : "Manual Device Linking",
            subtitle: model.onboardingMode == .createAccount
                ? "The first device flow should feel like a launch console, not a settings screen."
                : "Linking rides on copy/paste payloads until QR scanning and MLS key packages land."
            ,
            tone: .inverted
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
                        detail: "Current build already supports link intent creation, pending-device completion and explicit approval payloads."
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
                        title: "Approval stays explicit",
                        detail: "The new device emits a separate approval payload that a root-capable device signs."
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
                        Text("uptime \(formatUptime(health.uptimeMs))")
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
            subtitle: "Register the account root, transport key and local device profile in one pass.",
            tone: .strong
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
                        .textFieldStyle(.plain)
                        .trixInputChrome()
                }

                TrixInputBlock("Profile Name", hint: "Visible name for the account.") {
                    TextField("Maksym", text: $model.draft.profileName)
                        .textFieldStyle(.plain)
                        .trixInputChrome()
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
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: bioHeight)
                        .font(.body)
                        .trixInputChrome()
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
            subtitle: "Paste a link intent from another trusted device, then register this Mac as pending approval.",
            tone: .strong
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
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .font(.system(.body, design: .monospaced))
                        .trixInputChrome()
                }

                TrixInputBlock("Device Name", hint: "How this Mac should appear in the remote device directory.") {
                    TextField("This Mac", text: $model.linkDraft.deviceDisplayName)
                        .textFieldStyle(.plain)
                        .trixInputChrome()
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
                            .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                            .buttonStyle(TrixActionButtonStyle(tone: .primary))
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
                            .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                            .buttonStyle(TrixActionButtonStyle(tone: .primary))
                            .disabled(!model.canCompleteLink || model.isCompletingLink)
                            .frame(maxWidth: 260)
                        }
                    }
                }

                Text("This Mac will not receive the account-root key. After registration it emits a separate approval payload for another trusted device to sign.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pendingStatusPanel: some View {
        TrixPanel(
            title: "Pending Approval",
            subtitle: "This Mac has already registered a pending device record and is waiting for another trusted device to sign it.",
            tone: .inverted
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingFeature(
                    symbol: "desktopcomputer.trianglebadge.exclamationmark",
                    title: "Local transport key is ready",
                    detail: "Challenge/session auth will start working as soon as the pending device flips to active."
                )
                OnboardingFeature(
                    symbol: "square.and.arrow.up",
                    title: "Approval payload is below",
                    detail: "Copy it to a root-capable device and submit it via the workspace approval panel."
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
            title: "Hand Off The Approval Payload",
            subtitle: "The server knows about this Mac, but it is still `pending`. Another active device must sign the bootstrap payload.",
            tone: .strong
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let payload = model.pendingApprovalPayload {
                    TrixInputBlock(
                        "Approval Payload",
                        hint: "Copy this JSON to a root-capable device and paste it into the workspace approval panel."
                    ) {
                        TrixPayloadBox(payload: payload, minHeight: 180)
                    }

                    Group {
                        if prefersSingleColumn {
                            VStack(spacing: 12) {
                                Button {
                                    copyStringToPasteboard(payload)
                                } label: {
                                    Label("Copy Payload", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                                .buttonStyle(TrixActionButtonStyle(tone: .primary))
                                .frame(maxWidth: 280)
                                .disabled(model.isRestoringSession)
                            }
                        } else {
                            HStack(spacing: 12) {
                                Button {
                                    copyStringToPasteboard(payload)
                                } label: {
                                    Label("Copy Payload", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                                .buttonStyle(TrixActionButtonStyle(tone: .primary))
                                .frame(maxWidth: 280)
                                .disabled(model.isRestoringSession)
                            }
                        }
                    }
                } else {
                    EmptyWorkspaceLabel("The local approval payload could not be reconstructed from Keychain. Re-link the device if this persists.")
                }

                Text("Current API does not expose pending-device bootstrap data back to active devices, so approval stays explicit: the new Mac must hand over this payload out-of-band.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 10) {
            OnboardingModeButton(
                title: OnboardingMode.createAccount.title,
                isSelected: model.onboardingMode == .createAccount
            ) {
                model.onboardingMode = .createAccount
            }

            OnboardingModeButton(
                title: OnboardingMode.linkExisting.title,
                isSelected: model.onboardingMode == .linkExisting
            ) {
                model.onboardingMode = .linkExisting
            }
        }
    }

    private var handleField: some View {
        TrixInputBlock("Handle", hint: "Optional public handle.") {
            TextField("optional handle", text: $model.draft.handle)
                .textFieldStyle(.plain)
                .trixInputChrome()
        }
    }

    private var deviceField: some View {
        TrixInputBlock("Device Name", hint: "How this Mac appears in the device list.") {
            TextField("This Mac", text: $model.draft.deviceDisplayName)
                .textFieldStyle(.plain)
                .trixInputChrome()
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
                    .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
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
                    .buttonStyle(TrixActionButtonStyle(tone: .secondary))
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
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
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

    private func formatUptime(_ uptimeMs: UInt64) -> String {
        let seconds = Int(uptimeMs / 1000)
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return "\(hours)h \(remainderMinutes)m"
    }
}

private struct OnboardingFeature: View {
    @Environment(\.trixColors) private var colors
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(colors.accentSoft)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(colors.inverseInk)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(colors.inverseInkMuted)
            }
        }
    }
}

private struct OnboardingModeButton: View {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
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
