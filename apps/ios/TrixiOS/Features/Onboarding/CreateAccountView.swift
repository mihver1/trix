import SwiftUI

private let onboardingAccent = TrixTheme.accent
private let onboardingSurface = TrixTheme.primarySurface

struct CreateAccountView: View {
    private enum SetupMode: String, CaseIterable, Identifiable {
        case createAccount = "Create Account"
        case linkExisting = "Link Existing"

        var id: String { rawValue }

        var sectionTitle: String {
            switch self {
            case .createAccount:
                return "Create User"
            case .linkExisting:
                return "Link Device"
            }
        }

        var helperText: String? {
            switch self {
            case .createAccount:
                return nil
            case .linkExisting:
                return "Approve this device from another trusted device after linking."
            }
        }

        var buttonTitle: String {
            switch self {
            case .createAccount:
                return "Create User"
            case .linkExisting:
                return "Link Device"
            }
        }
    }

    @Binding var serverBaseURL: String
    var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var setupMode: SetupMode = .createAccount
    @State private var form = CreateAccountForm()
    @State private var linkForm = LinkExistingAccountForm()
    @State private var onboardingErrorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    TrixTheme.screenGradientTop,
                    TrixTheme.screenGradientMiddle,
                    TrixTheme.screenGradientBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    connectionCard
                    modePicker

                    if let bannerText {
                        OnboardingBanner(
                            tint: .red,
                            systemImage: "exclamationmark.triangle.fill",
                            text: bannerText
                        )
                    }

                    setupCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
        .accessibilityIdentifier(TrixAccessibilityID.Root.onboardingScreen)
        .accessibilityValue(colorScheme == .dark ? "dark" : "light")
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: serverBaseURL) { _, _ in
            model.clearServerStatus()
            onboardingErrorMessage = nil
        }
        .onChange(of: setupMode) { _, _ in
            model.clearServerStatus()
            onboardingErrorMessage = nil
        }
        .onChange(of: linkForm.linkPayload) { _, _ in
            guard setupMode == .linkExisting else {
                return
            }

            model.clearServerStatus()
            onboardingErrorMessage = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set Up Trix")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Text("Choose a server, then create a user or link this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(SetupMode.allCases) { mode in
                Button {
                    setupMode = mode
                } label: {
                    Text(mode.sectionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(setupMode == mode ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(setupMode == mode ? onboardingAccent : TrixTheme.secondarySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(setupMode == mode ? .clear : TrixTheme.surfaceStroke, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    mode == .createAccount
                        ? TrixAccessibilityID.Onboarding.createModeButton
                        : TrixAccessibilityID.Onboarding.linkModeButton
                )
            }
        }
    }

    @ViewBuilder
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(setupMode.sectionTitle)
                .font(.headline)

            switch setupMode {
            case .createAccount:
                VStack(spacing: 12) {
                    OnboardingField(
                        label: "Profile Name",
                        text: $form.profileName,
                        icon: "person.fill",
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.profileNameField
                    )
                    OnboardingField(
                        label: "Handle (public, optional)",
                        text: $form.handle,
                        icon: "at",
                        autocapitalization: .never,
                        disableAutocorrection: true,
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.handleField
                    )
                    OnboardingField(
                        label: "Device Name",
                        text: $form.deviceDisplayName,
                        icon: "iphone.gen3",
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.deviceNameField
                    )
                }
            case .linkExisting:
                VStack(spacing: 12) {
                    OnboardingField(
                        label: "Link Code",
                        text: $linkForm.linkPayload,
                        icon: "qrcode.viewfinder",
                        axis: .vertical,
                        autocapitalization: .never,
                        disableAutocorrection: true,
                        lineLimit: 7,
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.linkCodeField
                    )

                    OnboardingField(
                        label: "Device Name",
                        text: $linkForm.deviceDisplayName,
                        icon: "iphone.gen3",
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.deviceNameField
                    )
                }
            }

            if let helperText = setupMode.helperText {
                Text(helperText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(onboardingSurface)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
        }
        .shadow(color: TrixTheme.softShadow, radius: 18, y: 10)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server")
                        .font(.headline)

                    Text(connectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                ConnectionStatusPill(snapshot: model.systemSnapshot)
            }

            if let serverSourceText {
                Text(serverSourceText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            OnboardingField(
                label: "Server URL",
                text: $serverBaseURL,
                icon: "network",
                autocapitalization: .never,
                disableAutocorrection: true,
                keyboardType: .URL,
                accessibilityIdentifier: TrixAccessibilityID.Onboarding.serverURLField
            )

            Button(action: reload) {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Check Server")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)
            .accessibilityIdentifier(TrixAccessibilityID.Onboarding.testConnectionButton)

            if let lastUpdatedAt = model.lastUpdatedAt {
                Text("Last checked \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(TrixTheme.tertiarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
        }
    }

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    Text(setupMode.buttonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
            }
            .foregroundStyle(.white)
            .background(canSubmit ? onboardingAccent : onboardingAccent.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .disabled(model.isLoading || !canSubmit)
            .accessibilityIdentifier(TrixAccessibilityID.Onboarding.primaryActionButton)

            if setupMode == .linkExisting {
                Text("This may switch to a pending approval state before the device is fully trusted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    private var bannerText: String? {
        onboardingErrorMessage ?? model.errorMessage
    }

    private var parsedLinkPayload: LinkIntentPayload? {
        try? LinkIntentPayload.parse(linkForm.linkPayload)
    }

    private var effectiveServerBaseURL: String {
        if setupMode == .linkExisting, let payload = parsedLinkPayload {
            return payload.baseURL
        }

        return serverBaseURL
    }

    private var serverSourceText: String? {
        guard setupMode == .linkExisting else {
            return nil
        }

        if let payload = parsedLinkPayload {
            return "Using server from link code: \(payload.baseURL)"
        }

        return "If the link code contains a server URL, it overrides the field above."
    }

    private var connectionSummary: String {
        if let host = URL(string: effectiveServerBaseURL)?.host {
            return "Current target: \(host)"
        }

        return "Custom server connection"
    }

    private var canSubmit: Bool {
        switch setupMode {
        case .createAccount:
            return form.canSubmit
        case .linkExisting:
            return linkForm.canSubmit
        }
    }

    private func primaryAction() {
        switch setupMode {
        case .createAccount:
            createAccount()
        case .linkExisting:
            completeLinkIntent()
        }
    }

    private func reload() {
        let targetBaseURL = effectiveServerBaseURL
        onboardingErrorMessage = nil

        if setupMode == .linkExisting, targetBaseURL != serverBaseURL {
            serverBaseURL = targetBaseURL
        }

        Task {
            await model.refresh(baseURLString: targetBaseURL)
        }
    }

    private func createAccount() {
        onboardingErrorMessage = nil

        Task {
            await model.createAccount(baseURLString: serverBaseURL, form: form)
        }
    }

    private func completeLinkIntent() {
        do {
            let payload = try LinkIntentPayload.parse(linkForm.linkPayload)
            onboardingErrorMessage = nil
            serverBaseURL = payload.baseURL

            Task {
                await model.completeLinkIntent(
                    baseURLString: payload.baseURL,
                    payload: payload,
                    form: linkForm
                )
            }
        } catch {
            onboardingErrorMessage = "Link code is not valid JSON."
        }
    }
}

private struct OnboardingField: View {
    let label: String
    @Binding var text: String
    let icon: String
    var axis: Axis = .horizontal
    var autocapitalization: TextInputAutocapitalization = .sentences
    var disableAutocorrection = false
    var keyboardType: UIKeyboardType = .default
    var lineLimit: Int = 3
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(onboardingAccent)
                .frame(width: 18)
                .padding(.top, axis == .vertical ? 4 : 0)

            TextField(label, text: $text, axis: axis)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(disableAutocorrection)
                .keyboardType(keyboardType)
                .lineLimit(axis == .vertical ? lineLimit : 1, reservesSpace: axis == .vertical)
                .accessibilityIdentifier(accessibilityIdentifier ?? label)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(TrixTheme.elevatedFieldSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
        }
    }
}

private struct OnboardingBanner: View {
    let tint: Color
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier(TrixAccessibilityID.Onboarding.errorBanner)
    }
}

private struct ConnectionStatusPill: View {
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
        if let snapshot {
            return snapshot.health.status == .ok ? "Connected" : "Degraded"
        }
        return "Unchecked"
    }

    private var tint: Color {
        guard let snapshot else {
            return .secondary
        }

        switch snapshot.health.status {
        case .ok:
            return .green
        case .degraded:
            return .orange
        }
    }
}

#Preview {
    NavigationStack {
        CreateAccountView(
            serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
            model: AppModel()
        )
    }
}
