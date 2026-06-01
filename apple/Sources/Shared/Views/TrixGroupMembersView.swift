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
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    membersSection
                    addMemberSection

                    if let errorMessage {
                        TrixBannerView(
                            text: errorMessage,
                            systemImage: "exclamationmark.triangle",
                            tint: .red
                        )
                    }
                }
                .padding(20)
            }
            .trixScrollContentBackgroundHidden()
        }
        .background(TrixDesign.screenBackground)
        .task(id: room.id) {
            await loadMembers()
        }
        .trixDialogSurface(minWidth: 520, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 14) {
            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 44,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Members")
                    .font(.headline)
                    .lineLimit(1)

                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                Task {
                    await loadMembers()
                }
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .help("Refresh members")
            .accessibilityLabel("Refresh members")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close members")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(TrixDesign.primarySurface)
    }

    private var headerSubtitle: String {
        let count = activeMembers.count
        let countLabel = "\(count) member\(count == 1 ? "" : "s")"
        guard !room.name.isEmpty else {
            return countLabel
        }
        return "\(room.name) - \(countLabel)"
    }

    private var membersSection: some View {
        let visibleMembers = activeMembers

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "People",
                systemImage: "person.2",
                detail: "\(visibleMembers.count)"
            )

            VStack(spacing: 0) {
                if isLoading && visibleMembers.isEmpty {
                    loadingMembersRow
                } else if visibleMembers.isEmpty {
                    emptyMembersRow
                } else {
                    ForEach(Array(visibleMembers.enumerated()), id: \.element.id) { index, member in
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

                        if index < visibleMembers.count - 1 {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TrixDesign.primarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
            }
        }
    }

    private var addMemberSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Add Member", systemImage: "person.badge.plus")

            VStack(alignment: .leading, spacing: 12) {
                TrixUserDirectoryPickerView(
                    model: model,
                    selection: $selectedInvitees,
                    mode: .single,
                    excludedUserIDs: excludedUserIDs
                )

                HStack {
                    Spacer()

                    Button {
                        Task {
                            await inviteSelectedUser()
                        }
                    } label: {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Add Member", systemImage: "person.badge.plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedInvitees.isEmpty || isUpdating)
                }
            }
            .padding(12)
            .background(TrixDesign.primarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
            }
        }
    }

    private var loadingMembersRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading members")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    private var emptyMembersRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TrixDesign.accent)
                .frame(width: 34, height: 34)
                .background(TrixDesign.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("No Members")
                    .font(.callout.weight(.semibold))

                Text("Members appear after the group is joined.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private func sectionHeader(title: String, systemImage: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
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

                Text(isCurrentUser ? "You" : TrixUserIdentity.handle(from: member.userID))
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
                .help("Remove from group")
                .accessibilityLabel("Remove \(member.title)")
            }
        }
        .padding(.vertical, 8)
    }
}
