import SwiftUI

struct MatrixRoomListView: View {
    @ObservedObject var model: MatrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel
    @ObservedObject private var deviceVerificationViewModel: DeviceVerificationViewModel
    @State private var isShowingNewDirectMessage = false

    init(model: MatrixAppModel) {
        self.model = model
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
        self._deviceVerificationViewModel = ObservedObject(wrappedValue: model.deviceVerificationViewModel)
    }

    var body: some View {
        List(selection: $model.selectedRoomID) {
            Section {
                if roomListViewModel.rooms.isEmpty {
                    ContentUnavailableView(
                        "No Rooms",
                        systemImage: "bubble.left",
                        description: Text("Start an encrypted DM or accept an invite.")
                    )
                } else {
                    ForEach(roomListViewModel.rooms) { room in
                        MatrixRoomRow(room: room)
                            .tag(room.id as String?)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await model.selectRoom(room)
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Rooms")
                    Spacer()
                    if roomListViewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if !roomListViewModel.invitations.isEmpty {
                Section("Invites") {
                    ForEach(roomListViewModel.invitations) { invitation in
                        MatrixInviteRow(
                            invitation: invitation,
                            isWorking: roomListViewModel.invitationActionRoomID == invitation.id,
                            accept: {
                                Task {
                                    await model.acceptInvitation(invitation)
                                }
                            },
                            decline: {
                                Task {
                                    await model.declineInvitation(invitation)
                                }
                            }
                        )
                    }
                }
            }

            Section("Account") {
                if let account = model.account {
                    LabeledContent("User", value: account.userID)
                    LabeledContent("Device", value: account.deviceID)
                }

                Button {
                    Task {
                        await model.reloadRooms()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    Task {
                        await model.logout()
                    }
                } label: {
                    Label(model.isLoggingOut ? "Logging Out" : "Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(model.isLoggingOut)
            }

            Section("Device Verification") {
                MatrixDeviceVerificationStatusView(viewModel: deviceVerificationViewModel)

                Button {
                    Task {
                        await model.reloadDeviceVerificationStatus()
                    }
                } label: {
                    Label("Refresh Verification", systemImage: "arrow.clockwise")
                }
                .disabled(deviceVerificationViewModel.isLoading)
            }

            Section {
                MatrixLimitationsView()
            }
        }
        .toolbar {
            Button {
                isShowingNewDirectMessage = true
            } label: {
                Label("New DM", systemImage: "square.and.pencil")
            }
            .help("New encrypted DM")
        }
        .sheet(isPresented: $isShowingNewDirectMessage) {
            MatrixNewDirectMessageView(model: model)
        }
    }
}

private struct MatrixRoomRow: View {
    let room: MatrixRoomSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: room.kind == .direct ? "person.crop.circle" : "person.2.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.headline)
                        .lineLimit(1)
                    if room.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Text(room.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(room.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if room.unreadCount > 0 {
                Text("\(room.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MatrixInviteRow: View {
    let invitation: MatrixRoomInvite
    let isWorking: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: invitation.kind == .direct ? "person.crop.circle.badge.plus" : "person.2.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(invitation.title)
                            .font(.headline)
                            .lineLimit(1)
                        if invitation.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Text(invitation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    accept()
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Accept", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                Button(role: .destructive) {
                    decline()
                } label: {
                    Label("Decline", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
