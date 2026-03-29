import SwiftUI

private let onboardingAccent = TrixTheme.accent
private let onboardingSurface = TrixTheme.primarySurface

struct CreateAccountView: View {
    private enum SetupMode: String, CaseIterable, Identifiable {
        case createAccount = "Create Account"
        case linkExisting = "Link Existing"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .createAccount:
                return "Start Your Private Inbox"
            case .linkExisting:
                return "Bring Your Account Here"
            }
        }

        var subtitle: String {
            switch self {
            case .createAccount:
                return "Create a new Trix profile and land directly in encrypted chats."
            case .linkExisting:
                return "Paste a secure link code from a phone or desktop that is already signed in."
            }
        }

        var buttonTitle: String {
            switch self {
            case .createAccount:
                return "Create Account"
            case .linkExisting:
                return "Continue"
            }
        }
    }

    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var setupMode: SetupMode = .createAccount
    @State private var form = CreateAccountForm()
    @State private var linkForm = LinkExistingAccountForm()
    @State private var onboardingErrorMessage: String?
    @State private var isShowingServerDetails = false

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
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    modePicker

                    if let bannerText {
                        OnboardingBanner(
                            tint: .red,
                            systemImage: "exclamationmark.triangle.fill",
                            text: bannerText
                        )
                    }

                    setupCard
                    connectionCard
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
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Circle()
                    .fill(onboardingAccent.opacity(0.12))
                    .frame(width: 78, height: 78)

                Image(systemName: setupMode == .createAccount ? "bubble.left.and.bubble.right.fill" : "iphone.gen3.badge.plus")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(onboardingAccent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(setupMode.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text(setupMode.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(SetupMode.allCases) { mode in
                Button {
                    setupMode = mode
                    onboardingErrorMessage = nil
                } label: {
                    Text(mode == .createAccount ? "Get Started" : "Use Existing")
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
            Text(setupMode == .createAccount ? "Profile" : "Link Code")
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
                        label: "Handle",
                        text: $form.handle,
                        icon: "at",
                        autocapitalization: .never,
                        disableAutocorrection: true,
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.handleField
                    )
                    OnboardingField(
                        label: "Bio",
                        text: $form.profileBio,
                        icon: "text.alignleft",
                        axis: .vertical,
                        accessibilityIdentifier: TrixAccessibilityID.Onboarding.bioField
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

            Text(setupMode == .createAccount
                 ? "A new account is created on the server and this iPhone becomes the first trusted device."
                 : "This iPhone will wait for approval from one of your already trusted devices before it unlocks.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    Text("Connection")
                        .font(.headline)

                    Text(connectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                ConnectionStatusPill(snapshot: model.systemSnapshot)
            }

            if let lastUpdatedAt = model.lastUpdatedAt {
                Text("Last checked \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(isShowingServerDetails ? "Hide Server Details" : "Show Server Details") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingServerDetails.toggle()
                }
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier(TrixAccessibilityID.Onboarding.serverDetailsToggle)

            if isShowingServerDetails {
                VStack(spacing: 12) {
                    Text(serverBaseURL)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                            Text("Test Connection")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoading)
                    .accessibilityIdentifier(TrixAccessibilityID.Onboarding.testConnectionButton)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
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

            Text(setupMode == .createAccount ? "You can link more devices later from Settings." : "Approval usually completes after an existing device confirms this phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    private var bannerText: String? {
        onboardingErrorMessage ?? model.errorMessage
    }

    private var connectionSummary: String {
        if let host = URL(string: serverBaseURL)?.host {
            return "Secure connection to \(host)"
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
        Task {
            await model.refresh(baseURLString: serverBaseURL)
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
