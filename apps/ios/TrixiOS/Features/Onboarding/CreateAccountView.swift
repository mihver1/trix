import SwiftUI

struct CreateAccountView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var form = CreateAccountForm()

    var body: some View {
        Form {
            ServerConnectionSection(
                serverBaseURL: $serverBaseURL,
                snapshot: model.systemSnapshot,
                lastUpdatedAt: model.lastUpdatedAt,
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                reloadTitle: "Check Server",
                onReload: reload
            )

            Section("Profile") {
                TextField("Profile Name", text: $form.profileName)
                TextField("Handle (optional)", text: $form.handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Bio (optional)", text: $form.profileBio, axis: .vertical)
                    .lineLimit(3, reservesSpace: false)
            }

            Section {
                TextField("This iPhone", text: $form.deviceDisplayName)

                LabeledContent("Platform") {
                    Text("ios")
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Creates a new account and registers this iPhone as the first trusted device.")
            }

            Section {
                Button(action: createAccount) {
                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Create Account")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.isLoading || !form.canSubmit)
            }
        }
        .navigationTitle("Set Up Trix")
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }

    private func createAccount() {
        Task {
            await model.createAccount(baseURLString: serverBaseURL, form: form)
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
