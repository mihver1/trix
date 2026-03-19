import SwiftUI

struct PendingApprovalView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var isShowingForgetAlert = false

    var body: some View {
        Form {
            ServerConnectionSection(
                serverBaseURL: $serverBaseURL,
                snapshot: model.systemSnapshot,
                lastUpdatedAt: model.lastUpdatedAt,
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                reloadTitle: "Check Approval",
                onReload: reload
            )

            Section("Pending Approval") {
                Text("This device finished link setup and is waiting for approval from an already trusted device on the same account.")
                    .foregroundStyle(.secondary)
                Text("A trusted device can now use the `Approve Device` action in its `Trusted Devices` list to activate this pending device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let localIdentity = model.localIdentity {
                    LabeledContent("Account ID") {
                        Text(localIdentity.accountId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Pending Device ID") {
                        Text(localIdentity.deviceId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Device Name") {
                        Text(localIdentity.deviceDisplayName)
                    }
                }
            }

            Section {
                Button("Forget This Device", role: .destructive) {
                    isShowingForgetAlert = true
                }
            }
        }
        .navigationTitle("Waiting")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", action: reload)
                    .disabled(model.isLoading)
            }
        }
        .alert("Forget this device?", isPresented: $isShowingForgetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                model.forgetLocalDevice()
            }
        } message: {
            Text("This removes the locally stored pending device identity so you can restart the link flow.")
        }
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }
}

#Preview {
    NavigationStack {
        PendingApprovalView(
            serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
            model: AppModel()
        )
    }
}
