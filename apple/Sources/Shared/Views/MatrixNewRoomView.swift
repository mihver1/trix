import SwiftUI

struct MatrixNewRoomView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = MatrixNewRoomMode.direct
    @State private var selectedUsers: [MatrixUserProfile] = []
    @State private var roomName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $mode) {
                        ForEach(MatrixNewRoomMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(mode.inviteSectionTitle) {
                    MatrixUserDirectoryPickerView(
                        model: model,
                        selection: $selectedUsers,
                        mode: mode == .direct ? .single : .multiple,
                        excludedUserIDs: excludedUserIDs
                    )

                    if mode == .direct {
                        TextField("Chat name", text: $roomName)
                    } else {
                        TextField("Name", text: $roomName)
                    }
                }

                Section {
                    MatrixDeviceVerificationNoticeView(status: model.deviceVerificationViewModel.status)
                }

                if let errorMessage = model.roomListViewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .matrixScrollContentBackgroundHidden()
            .background(MatrixDesign.screenBackground)
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            switch mode {
                            case .direct:
                                guard let invitee = selectedUsers.first else {
                                    return
                                }
                                let didCreate = await model.createEncryptedDirectRoom(
                                    inviteeUserID: invitee.userID,
                                    roomName: roomName
                                )
                                if didCreate {
                                    dismiss()
                                }
                            case .group:
                                let didCreate = await model.createEncryptedGroupRoom(
                                    name: roomName,
                                    inviteeUserIDs: selectedUsers.map(\.userID)
                                )
                                if didCreate {
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        if isCreatingRoom {
                            ProgressView()
                        } else {
                            Label("Create", systemImage: mode.createSystemImage)
                        }
                    }
                    .disabled(isCreatingRoom || isCreateDisabled)
                }
            }
        }
        .matrixDialogSurface(minWidth: 440, minHeight: 340)
        .onChange(of: mode) { _, newMode in
            if newMode == .direct, selectedUsers.count > 1 {
                selectedUsers = Array(selectedUsers.prefix(1))
            }
        }
    }

    private var isCreatingRoom: Bool {
        model.roomListViewModel.isCreatingDirectRoom || model.roomListViewModel.isCreatingGroupRoom
    }

    private var isCreateDisabled: Bool {
        switch mode {
        case .direct:
            return selectedUsers.isEmpty
        case .group:
            return roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                selectedUsers.count < 2
        }
    }

    private var excludedUserIDs: Set<String> {
        if let currentUserID = model.session?.userID {
            return [currentUserID]
        }

        return []
    }
}

private enum MatrixNewRoomMode: String, CaseIterable, Identifiable {
    case direct
    case group

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .direct:
            return "DM"
        case .group:
            return "Group"
        }
    }

    var systemImage: String {
        switch self {
        case .direct:
            return "person.crop.circle"
        case .group:
            return "person.2.circle"
        }
    }

    var createSystemImage: String {
        switch self {
        case .direct:
            return "lock.bubble.left.fill"
        case .group:
            return "person.2.badge.plus"
        }
    }

    var inviteSectionTitle: String {
        switch self {
        case .direct:
            return "Invite"
        case .group:
            return "Group"
        }
    }
}
