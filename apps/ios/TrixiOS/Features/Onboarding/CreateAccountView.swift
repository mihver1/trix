import SwiftUI

struct CreateAccountView: View {
    private enum SetupMode: String, CaseIterable, Identifiable {
        case createAccount = "Create Account"
        case linkExisting = "Link Existing"

        var id: String { rawValue }
    }

    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var setupMode: SetupMode = .createAccount
    @State private var form = CreateAccountForm()
    @State private var linkForm = LinkExistingAccountForm()
    @State private var onboardingErrorMessage: String?

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

            Section("Mode") {
                Picker("Setup Mode", selection: $setupMode) {
                    ForEach(SetupMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let onboardingErrorMessage {
                Section("Input Error") {
                    Text(onboardingErrorMessage)
                        .foregroundStyle(.red)
                }
            }

            switch setupMode {
            case .createAccount:
                createAccountSections
            case .linkExisting:
                linkExistingSections
            }
        }
        .navigationTitle("Set Up Trix")
    }

    @ViewBuilder
    private var createAccountSections: some View {
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

    @ViewBuilder
    private var linkExistingSections: some View {
        Section {
            TextField("Paste QR payload JSON", text: $linkForm.linkPayload, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(6, reservesSpace: true)
                .font(.system(.footnote, design: .monospaced))
        } header: {
            Text("Link Payload")
        } footer: {
            Text("Use the JSON payload created by another trusted device from the link-intent flow.")
        }

        Section {
            TextField("This iPhone", text: $linkForm.deviceDisplayName)

            LabeledContent("Platform") {
                Text("ios")
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("New Device")
        } footer: {
            Text("This registers the iPhone as a pending device. It will stay in waiting state until a trusted device approves it.")
        }

        Section {
            Button(action: completeLinkIntent) {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Complete Link Intent")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(model.isLoading || !linkForm.canSubmit)
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
            onboardingErrorMessage = "Invalid link payload JSON."
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
