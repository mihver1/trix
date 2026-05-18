import SwiftUI

struct TrixLoginView: View {
    @ObservedObject var model: TrixAppModel
    @State private var authMode: AuthMode = .login
    @State private var userID = "friend@trix.selfhost.ru"
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var registrationLocalpart = ""
    @State private var registrationDisplayName = ""
    @State private var registrationPassword = ""
    @State private var registrationPasswordConfirmation = ""
    @State private var registrationValidationMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                form
                TrixLimitationsView()

                if let errorMessage = model.errorMessage {
                    TrixBannerView(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }

                if let sessionCleanupMessage = model.sessionCleanupMessage {
                    TrixBannerView(
                        text: sessionCleanupMessage,
                        systemImage: "checkmark.shield.fill",
                        tint: .green
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TrixDesign.screenBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            TrixAvatarView(
                title: "Trix",
                systemImage: "bubble.left.and.bubble.right.fill",
                size: 58
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("Trix")
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)

                TrixStatusPill(
                    title: XMPPClientConfiguration.serverName,
                    systemImage: "server.rack"
                )
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrixAuthModeSelector(selection: $authMode)

            switch authMode {
            case .login:
                loginForm
            case .registration:
                registrationForm
            }
        }
        .padding(16)
        .background(TrixDesign.primarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("XMPP account")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("user@trix.selfhost.ru", text: $userID)
                    .trixUserIDTextField()
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                let enteredPassword = password
                password = ""
                Task {
                    await model.login(userID: userID, password: enteredPassword)
                }
            } label: {
                if model.isLoggingIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Log In", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLoggingIn || model.isRegistering)
        }
    }

    private var registrationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let registrationValidationMessage {
                TrixBannerView(
                    text: registrationValidationMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Invite code")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Invite code", text: $inviteCode)
                    .trixInviteTextField()
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Handle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("friend", text: $registrationLocalpart)
                        .trixUserIDTextField()
                        .textFieldStyle(.roundedBorder)
                    Text("@\(XMPPClientConfiguration.serverName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Display name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Display name", text: $registrationDisplayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $registrationPassword)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Confirm password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Confirm password", text: $registrationPasswordConfirmation)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                submitRegistration()
            } label: {
                if model.isRegistering {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Create Account", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLoggingIn || model.isRegistering)
        }
    }

    private func submitRegistration() {
        let enteredPassword = registrationPassword
        let enteredConfirmation = registrationPasswordConfirmation
        guard enteredPassword == enteredConfirmation else {
            registrationValidationMessage = "Passwords do not match."
            return
        }

        registrationValidationMessage = nil
        registrationPassword = ""
        registrationPasswordConfirmation = ""
        Task {
            await model.registerWithInvite(
                inviteCode: inviteCode,
                localpart: registrationLocalpart,
                displayName: registrationDisplayName,
                password: enteredPassword
            )
        }
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case login
    case registration

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .login:
            return "Log In"
        case .registration:
            return "Join"
        }
    }
}

private struct TrixAuthModeSelector: View {
    @Binding var selection: AuthMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AuthMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == mode ? Color.primary : Color.secondary)
                .background {
                    if selection == mode {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(TrixDesign.primarySurface)
                            .shadow(color: TrixDesign.softShadow, radius: 2, y: 1)
                    }
                }
                .accessibilityLabel(mode.title)
                .accessibilityValue(selection == mode ? "Selected" : "")
            }
        }
        .padding(3)
        .background(TrixDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

private extension View {
    @ViewBuilder
    func trixUserIDTextField() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)
        #else
        self
            .autocorrectionDisabled()
            .textContentType(.username)
        #endif
    }

    @ViewBuilder
    func trixInviteTextField() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .textContentType(.oneTimeCode)
        #else
        self
            .autocorrectionDisabled()
        #endif
    }
}
