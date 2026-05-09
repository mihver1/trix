import SwiftUI

struct TrixLoginView: View {
    @ObservedObject var model: TrixAppModel
    @State private var userID = "friend@trix.selfhost.ru"
    @State private var password = ""

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
            .disabled(model.isLoggingIn)
        }
        .padding(16)
        .background(TrixDesign.primarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
}
