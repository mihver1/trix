import SwiftUI

struct TrixGroupMembersView: View {
    @ObservedObject var model: TrixAppModel
    let room: TrixRoomSummary
    @Environment(\.dismiss) private var dismiss
    @State private var members: [TrixRoomMember] = []
    @State private var selectedInvitees: [TrixUserProfile] = []
    @State private var isLoading = false
    @State private var isUpdating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Members") {
                    if isLoading && members.isEmpty {
                        ProgressView("Loading members")
                    } else if members.isEmpty {
                        TrixEmptyStateView(
                            title: "No Members",
                            systemImage: "person.2",
                            message: "Members appear after the group is joined."
                        )
                    } else {
                        ForEach(activeMembers) { member in
                            TrixGroupMemberRow(
                                member: member,
                                isCurrentUser: isCurrentUser(member.userID),
                                isUpdating: isUpdating,
                                remove: {
                                    Task {
                                        await remove(member)
                                    }
                                }
                            )
                        }
                    }
                }

                Section("Add Member") {
                    TrixUserDirectoryPickerView(
                        model: model,
                        selection: $selectedInvitees,
                        mode: .single,
                        excludedUserIDs: excludedUserIDs
                    )

                    Button {
                        Task {
                            await inviteSelectedUser()
                        }
                    } label: {
                        if isUpdating {
                            ProgressView()
                        } else {
                            Label("Add Member", systemImage: "person.badge.plus")
                        }
                    }
                    .disabled(selectedInvitees.isEmpty || isUpdating)
                }

                if let errorMessage {
                    Section {
                        TrixBannerView(
                            text: errorMessage,
                            systemImage: "exclamationmark.triangle",
                            tint: .red
                        )
                    }
                }
            }
            .trixScrollContentBackgroundHidden()
            .background(TrixDesign.screenBackground)
            .navigationTitle("Members")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await loadMembers()
                        }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                    .help("Refresh members")
                }
            }
            .task(id: room.id) {
                await loadMembers()
            }
        }
        .trixDialogSurface(minWidth: 460, minHeight: 420)
    }

    private var activeMembers: [TrixRoomMember] {
        members
            .filter(\.membership.isActive)
            .sorted { lhs, rhs in
                if lhs.membership.sortOrder != rhs.membership.sortOrder {
                    return lhs.membership.sortOrder < rhs.membership.sortOrder
                }

                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private var excludedUserIDs: Set<String> {
        var userIDs = Set(activeMembers.map(\.userID))
        if let currentUserID = model.account?.userID ?? model.session?.userID {
            userIDs.insert(currentUserID)
        }
        return userIDs
    }

    private func loadMembers() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            members = try await model.members(roomID: room.id)
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    private func inviteSelectedUser() async {
        guard let invitee = selectedInvitees.first else {
            return
        }

        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }

        do {
            try await model.inviteUser(invitee.userID, to: room.id)
            selectedInvitees = []
            await loadMembers()
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    private func remove(_ member: TrixRoomMember) async {
        guard !isCurrentUser(member.userID) else {
            return
        }

        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }

        do {
            try await model.removeUser(member.userID, from: room.id)
            await loadMembers()
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    private func isCurrentUser(_ userID: String) -> Bool {
        let currentUserID = model.account?.userID ?? model.session?.userID ?? ""
        return userID.caseInsensitiveCompare(currentUserID) == .orderedSame
    }
}

private struct TrixGroupMemberRow: View {
    let member: TrixRoomMember
    let isCurrentUser: Bool
    let isUpdating: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TrixAvatarView(
                title: member.title,
                systemImage: "person.fill",
                size: 34,
                tint: isCurrentUser ? .secondary : TrixDesign.accent
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(member.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(isCurrentUser ? "You" : member.userID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if member.membership != .joined {
                Text(member.membership.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !isCurrentUser {
                Button(role: .destructive) {
                    remove()
                } label: {
                    Image(systemName: "person.fill.xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isUpdating)
                .help("Remove from group")
                .accessibilityLabel("Remove \(member.title)")
            }
        }
        .padding(.vertical, 3)
    }
}
