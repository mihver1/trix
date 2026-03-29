import SwiftUI

struct UserListView: View {
    @ObservedObject var model: AdminAppModel

    var body: some View {
        Group {
            if let artifact = model.lastProvisioningArtifact {
                provisionSummary(artifact)
            }
            if model.users.isEmpty, model.isUsersLoading {
                ProgressView("Loading users…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = model.usersError, model.users.isEmpty {
                ContentUnavailableView(
                    "Could not load users",
                    systemImage: "person.crop.circle.badge.xmark",
                    description: Text(err)
                )
            } else {
                List {
                    ForEach(model.users) { user in
                        NavigationLink(value: user.accountId) {
                            userRow(user)
                        }
                    }
                    if model.usersNextCursor != nil {
                        Button("Load more") {
                            Task { await model.loadMoreUsersIfNeeded() }
                        }
                        .disabled(model.isUsersLoading)
                        .accessibilityIdentifier(MacAdminAccessibilityIdentifier.usersLoadMoreButton)
                    }
                }
                .navigationTitle("Users")
                .navigationDestination(for: UUID.self) { accountId in
                    UserDetailView(accountId: accountId, model: model)
                }
            }
        }
        .searchable(text: $model.userSearchText, prompt: "Search users")
        .accessibilityIdentifier(MacAdminAccessibilityIdentifier.usersSearchField)
        .onChange(of: model.userSearchText) { _, _ in
            model.scheduleDebouncedUserListReload()
        }
        .onAppear {
            Task { await model.refreshUserList(replacingList: true) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Provision") {
                    model.beginProvisionUser()
                }
                .disabled(model.activeSession == nil || model.isProvisioning)
                .accessibilityIdentifier(MacAdminAccessibilityIdentifier.usersProvisionButton)
            }
            ToolbarItem(placement: .automatic) {
                Button("Refresh") {
                    Task { await model.refreshUserList(replacingList: true) }
                }
                .disabled(model.isUsersLoading || model.activeSession == nil)
                .accessibilityIdentifier(MacAdminAccessibilityIdentifier.usersRefreshButton)
            }
        }
        .sheet(isPresented: $model.isProvisionSheetPresented, onDismiss: {
            model.cancelProvisionUser()
        }) {
            ProvisionUserView(model: model)
        }
    }

    @ViewBuilder
    private func provisionSummary(_ artifact: AdminUserProvisioningArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest provision")
                .font(.headline)
            LabeledContent("Token", value: artifact.onboardingToken)
            if let url = URL(string: artifact.onboardingURL) {
                Link(artifact.onboardingURL, destination: url)
            } else {
                Text(artifact.onboardingURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Dismiss") {
                model.clearLastProvisioningArtifact()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2))
    }

    @ViewBuilder
    private func userRow(_ user: AdminUserSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(user.profileName)
                .font(.body.weight(.medium))
            HStack(spacing: 6) {
                if let handle = user.handle, !handle.isEmpty {
                    Text("@\(handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if user.disabled {
                    Text("Disabled")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }
}
