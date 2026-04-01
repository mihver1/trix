import SwiftUI

struct OnboardingView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let availableSize: CGSize

    private var prefersCompactActions: Bool {
        availableSize.width < 920 || availableSize.height < 760
    }

    private var parsedLinkPayload: LinkIntentPayload? {
        let trimmedPayload = model.linkDraft.linkPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty, let data = trimmedPayload.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(LinkIntentPayload.self, from: data)
    }

    private var effectiveServerBaseURL: String {
        if model.onboardingMode == .linkExisting, let payload = parsedLinkPayload {
            return payload.baseURL
        }

        return model.serverBaseURLString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.isAwaitingLinkApproval {
                pendingApprovalColumn
            } else {
                header
                serverPanel
                setupPanel
            }
        }
        .onChange(of: model.serverBaseURLString) { _, _ in
            model.clearServerStatus()
        }
        .onChange(of: model.onboardingMode) { _, _ in
            model.clearServerStatus()
        }
        .onChange(of: model.linkDraft.linkPayload) { _, _ in
            guard model.onboardingMode == .linkExisting else {
                return
            }

            model.clearServerStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set Up Trix")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(colors.ink)

            Text("Choose a server, then create a user or link this Mac.")
                .font(.subheadline)
                .foregroundStyle(colors.inkMuted)
        }
    }

    private var serverPanel: some View {
        TrixPanel(
            title: "Server",
            subtitle: "Check the target server before you create a user or link this Mac."
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

                if let serverSourceText {
                    Text(serverSourceText)
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TrixInputBlock(
                    "Server URL",
                    hint: model.onboardingMode == .linkExisting
                        ? "Used when the link payload does not include a server URL."
                        : "Used for account creation and reconnects."
                ) {
                    TextField("https://trix.artelproject.tech", text: $model.serverBaseURLString)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.serverURLField)
                }

                if prefersCompactActions {
                    VStack(alignment: .leading, spacing: 12) {
                        checkServerButton
                    }
                } else {
                    HStack(spacing: 12) {
                        checkServerButton
                    }
                }
            }
        }
    }

    private var setupPanel: some View {
        TrixPanel(
            title: model.onboardingMode == .createAccount ? "Create User" : "Link Device",
            subtitle: model.onboardingMode == .createAccount
                ? "Create the first trusted device on this server."
                : "Register this Mac as a device for an existing account."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                modeSelector

                switch model.onboardingMode {
                case .createAccount:
                    createFields
                    createActionRow
                case .linkExisting:
                    linkFields

                    Text("After linking, approve this Mac from another trusted device.")
                        .font(.footnote)
                        .foregroundStyle(colors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    linkActionRow
                }
            }
        }
    }

    private var createFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrixInputBlock("Profile Name", hint: "Visible name for the account.") {
                TextField("Maksym", text: $model.draft.profileName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.profileNameField)
            }

            TrixInputBlock("Handle", hint: "Public handle (optional).") {
                TextField("optional public handle", text: $model.draft.handle)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.handleField)
            }

            TrixInputBlock("Device Name", hint: "How this Mac appears in the device list.") {
                TextField("This Mac", text: $model.draft.deviceDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.deviceNameField)
            }
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrixInputBlock(
                "Link Code",
                hint: "Paste the JSON payload from an already trusted device."
            ) {
                TextEditor(text: $model.linkDraft.linkPayload)
                    .frame(minHeight: 160)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.linkCodeField)
            }

            TrixInputBlock("Device Name", hint: "How this Mac should appear in the device list.") {
                TextField("This Mac", text: $model.linkDraft.deviceDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.linkDeviceNameField)
            }
        }
    }

    private var pendingApprovalColumn: some View {
        TrixPanel(
            title: "Pending Approval",
            subtitle: "This Mac is waiting for approval from another trusted device."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let deviceID = model.pendingLinkedDeviceID {
                    TrixInputBlock(
                        "Pending Device ID",
                        hint: "Use this to identify the Mac on another trusted device."
                    ) {
                        TrixPayloadBox(
                            payload: deviceID.uuidString,
                            minHeight: 84,
                            valueAccessibilityIdentifier: TrixMacAccessibilityID.Onboarding.pendingDeviceIDValue
                        )
                    }

                    if prefersCompactActions {
                        VStack(alignment: .leading, spacing: 12) {
                            copyPendingDeviceButton(deviceID)
                            reconnectAfterApprovalButton
                            restartLinkButton
                        }
                    } else {
                        HStack(spacing: 12) {
                            copyPendingDeviceButton(deviceID)
                            reconnectAfterApprovalButton
                            restartLinkButton
                        }
                    }
                } else {
                    EmptyWorkspaceLabel("The pending device ID is missing from local session state. Re-link the device if this persists.")
                }

                Text("Approve the device from another trusted client, then reconnect here.")
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeSelector: some View {
        Picker("Setup Flow", selection: $model.onboardingMode) {
            Text(OnboardingMode.createAccount.title)
                .tag(OnboardingMode.createAccount)
                .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.createModeButton)
            Text(OnboardingMode.linkExisting.title)
                .tag(OnboardingMode.linkExisting)
                .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.linkModeButton)
        }
        .pickerStyle(.segmented)
    }

    private var checkServerButton: some View {
        Button {
            if effectiveServerBaseURL != model.serverBaseURLString {
                model.serverBaseURLString = effectiveServerBaseURL
            }

            model.clearServerStatus()

            Task {
                await model.refreshServerStatus()
            }
        } label: {
            Label("Check Server", systemImage: "bolt.horizontal.circle")
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: 190)
        .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.testConnectionButton)
    }

    private var createActionRow: some View {
        Group {
            if prefersCompactActions {
                VStack(alignment: .leading, spacing: 12) {
                    createUserButton
                }
            } else {
                HStack(spacing: 12) {
                    createUserButton
                }
            }
        }
    }

    private var linkActionRow: some View {
        Group {
            if prefersCompactActions {
                VStack(alignment: .leading, spacing: 12) {
                    linkDeviceButton
                }
            } else {
                HStack(spacing: 12) {
                    linkDeviceButton
                }
            }
        }
    }

    private var createUserButton: some View {
        Button {
            Task {
                await model.createAccount()
            }
        } label: {
            if model.isCreatingAccount {
                Label("Creating User…", systemImage: "hourglass")
            } else {
                Label("Create User", systemImage: "person.crop.circle.badge.plus")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canCreateAccount || model.isCreatingAccount)
        .frame(maxWidth: 220)
        .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.primaryActionButton)
    }

    private var linkDeviceButton: some View {
        Button {
            Task {
                await model.completeLink()
            }
        } label: {
            if model.isCompletingLink {
                Label("Linking Device…", systemImage: "hourglass")
            } else {
                Label("Link Device", systemImage: "link.badge.plus")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canCompleteLink || model.isCompletingLink)
        .frame(maxWidth: 220)
        .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.registerPendingDeviceButton)
    }

    private func copyPendingDeviceButton(_ deviceID: UUID) -> some View {
        Button {
            copyStringToPasteboard(deviceID.uuidString)
        } label: {
            Label("Copy Device ID", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: 220)
    }

    private var reconnectAfterApprovalButton: some View {
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
        .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.reconnectAfterApprovalButton)
    }

    private var restartLinkButton: some View {
        Button(role: .destructive) {
            model.restartPendingLinkFlow()
        } label: {
            Label("Restart Link", systemImage: "arrow.uturn.backward.circle")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 220)
        .accessibilityIdentifier(TrixMacAccessibilityID.Onboarding.restartLinkButton)
    }

    private var serverSourceText: String? {
        guard model.onboardingMode == .linkExisting else {
            return nil
        }

        if let payload = parsedLinkPayload {
            return "Using server from link payload: \(payload.baseURL)"
        }

        return "If the link payload contains a server URL, it overrides the field above."
    }

    private var readinessLabel: String {
        if model.isRefreshingStatus {
            return "Checking"
        }
        if let health = model.health {
            return health.status == .ok ? "Connected" : "Degraded"
        }
        return "Unchecked"
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
