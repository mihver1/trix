import SwiftUI

struct UserDetailView: View {
    let accountId: UUID
    @ObservedObject var model: AdminAppModel

    @State private var showDisableConfirm = false
    @State private var showReactivateConfirm = false

    var body: some View {
        Group {
            if model.isUserDetailLoading, model.userDetail == nil {
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = model.userDetailError, model.userDetail == nil {
                ContentUnavailableView(
                    "User unavailable",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(err)
                )
            } else if let user = model.userDetail, user.accountId == accountId {
                Form {
                    Section("Profile") {
                        LabeledContent("Display name", value: user.profileName)
                        if let handle = user.handle, !handle.isEmpty {
                            LabeledContent("Handle", value: "@\(handle)")
                        }
                        if let bio = user.profileBio, !bio.isEmpty {
                            LabeledContent("Bio", value: bio)
                        }
                        LabeledContent("Account ID", value: user.accountId.uuidString)
                        LabeledContent("Created", value: String(user.createdAtUnix))
                        LabeledContent("Status", value: user.disabled ? "Disabled" : "Active")
                    }
                    Section("Devices") {
                        Text("The admin user API does not include device enrollment details for this account.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        if user.disabled {
                            Button("Reactivate user…") {
                                guard let clusterName = model.selectedCluster?.displayName else { return }
                                model.beginReactivate(userID: user.accountId, clusterName: clusterName)
                                showReactivateConfirm = true
                            }
                            .disabled(model.isReactivatingUser || model.activeSession == nil)
                        } else {
                            Button("Disable user…", role: .destructive) {
                                guard let clusterName = model.selectedCluster?.displayName else { return }
                                model.beginDisable(userID: user.accountId, clusterName: clusterName)
                                showDisableConfirm = true
                            }
                            .disabled(model.isDisablingUser || model.activeSession == nil)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "User",
                    systemImage: "person",
                    description: Text("Loading…")
                )
            }
        }
        .navigationTitle(model.userDetail?.profileName ?? "User")
        .task {
            await model.loadUserDetail(accountId: accountId)
        }
        .onDisappear {
            model.clearUserDetail()
        }
        .sheet(isPresented: $showDisableConfirm, onDismiss: {
            model.cancelDisableFlow()
        }) {
            disableConfirmationSheet
        }
        .sheet(isPresented: $showReactivateConfirm, onDismiss: {
            model.cancelReactivateFlow()
        }) {
            reactivateConfirmationSheet
        }
    }

    @ViewBuilder
    private var disableConfirmationSheet: some View {
        let clusterLabel = model.selectedCluster?.displayName ?? ""
        VStack(alignment: .leading, spacing: 16) {
            Text("Disable user")
                .font(.title2)
            Text("Type the cluster name “\(clusterLabel)” to confirm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Cluster name", text: $model.disableConfirmationText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    showDisableConfirm = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Disable", role: .destructive) {
                    Task {
                        do {
                            try await model.confirmDisableUser()
                            showDisableConfirm = false
                        } catch {}
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isDisablingUser)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }

    @ViewBuilder
    private var reactivateConfirmationSheet: some View {
        let clusterLabel = model.selectedCluster?.displayName ?? ""
        VStack(alignment: .leading, spacing: 16) {
            Text("Reactivate user")
                .font(.title2)
            Text("Type the cluster name “\(clusterLabel)” to confirm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Cluster name", text: $model.reactivateConfirmationText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    showReactivateConfirm = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Reactivate") {
                    Task {
                        do {
                            try await model.confirmReactivateUser()
                            showReactivateConfirm = false
                        } catch {}
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isReactivatingUser)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
