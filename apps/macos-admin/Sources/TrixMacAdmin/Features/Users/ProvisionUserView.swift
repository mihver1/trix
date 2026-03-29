import SwiftUI

struct ProvisionUserView: View {
    @ObservedObject var model: AdminAppModel
    @State private var handle = ""
    @State private var profileName = ""
    @State private var profileBio = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Handle (optional)", text: $handle)
                    TextField("Profile name", text: $profileName)
                    TextField("Bio (optional)", text: $profileBio, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
                if let err = model.provisionError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Provision user")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelProvisionUser()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await model.provisionUser(
                                    handle: handle.isEmpty ? nil : handle,
                                    profileName: profileName,
                                    profileBio: profileBio.isEmpty ? nil : profileBio
                                )
                                handle = ""
                                profileName = ""
                                profileBio = ""
                            } catch {
                                model.provisionError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isProvisioning)
                }
            }
            .overlay {
                if model.isProvisioning {
                    ProgressView("Provisioning…")
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(minWidth: 400, minHeight: 280)
    }
}
