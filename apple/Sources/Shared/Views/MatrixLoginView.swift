import SwiftUI

struct MatrixLoginView: View {
    @ObservedObject var model: MatrixAppModel
    @State private var userID = "@me:trix.selfhost.ru"
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trix")
                    .font(.largeTitle.weight(.semibold))
                Text("Matrix private messenger")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Homeserver") {
                    Text(MatrixClientConfiguration.homeserverURL.absoluteString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                TextField("Matrix user ID", text: $userID)
                    .matrixUserIDTextField()

                SecureField("Password", text: $password)

                Button {
                    let enteredPassword = password
                    password = ""
                    Task {
                        await model.login(userID: userID, password: enteredPassword)
                    }
                } label: {
                    if model.isLoggingIn {
                        ProgressView()
                    } else {
                        Label("Log In", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoggingIn)
            }
            .textFieldStyle(.roundedBorder)

            MatrixLimitationsView()

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension View {
    @ViewBuilder
    func matrixUserIDTextField() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }
}
