import SwiftUI

struct RegistrationSettingsView: View {
    @ObservedObject var model: AdminAppModel
    @State private var localAllowPublic = false
    @State private var confirmDisablePublic = false
    @State private var applyError: String?

    var body: some View {
        Group {
            if model.registrationSettings != nil {
                Form {
                    Section {
                        Toggle(
                            "Allow public account registration",
                            isOn: Binding(
                                get: { localAllowPublic },
                                set: { new in
                                    if new {
                                        localAllowPublic = true
                                        Task { await applyAllowPublic(true) }
                                    } else {
                                        confirmDisablePublic = true
                                    }
                                }
                            )
                        )
                        .disabled(model.isWorkspaceLoading)
                    } footer: {
                        Text("Turning this off prevents new self-serve signups.")
                    }
                }
                .formStyle(.grouped)
                .onAppear {
                    syncLocalFromModel()
                }
                .onChange(of: model.registrationSettings?.allowPublicAccountRegistration) { _, _ in
                    syncLocalFromModel()
                }
            } else if model.isWorkspaceLoading {
                ProgressView("Loading settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No registration settings",
                    systemImage: "person.badge.plus",
                    description: Text(model.workspaceError ?? "Unable to load settings.")
                )
            }
        }
        .alert("Disable public registration?", isPresented: $confirmDisablePublic) {
            Button("Cancel", role: .cancel) {}
            Button("Disable", role: .destructive) {
                localAllowPublic = false
                Task { await applyAllowPublic(false) }
            }
        } message: {
            Text("New users will not be able to register on their own.")
        }
        .alert("Could not update", isPresented: Binding(
            get: { applyError != nil },
            set: { if !$0 { applyError = nil } }
        )) {
            Button("OK", role: .cancel) { applyError = nil }
        } message: {
            Text(applyError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { await model.refreshWorkspaceData() }
                }
                .disabled(model.isWorkspaceLoading || model.activeSession == nil)
            }
        }
    }

    private func syncLocalFromModel() {
        if let v = model.registrationSettings?.allowPublicAccountRegistration {
            localAllowPublic = v
        }
    }

    @MainActor
    private func applyAllowPublic(_ allow: Bool) async {
        do {
            try await model.setPublicRegistrationEnabled(allow)
        } catch {
            applyError = error.localizedDescription
            syncLocalFromModel()
        }
    }
}
