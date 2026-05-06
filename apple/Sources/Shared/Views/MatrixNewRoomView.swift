import SwiftUI

struct MatrixNewRoomView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = MatrixNewRoomMode.direct
    @State private var inviteeUserID = ""
    @State private var inviteeUserIDs = ""
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
                    if mode == .direct {
                        TextField("@user:trix.selfhost.ru", text: $inviteeUserID)
                            .matrixUserIDInput()

                        TextField("Room name", text: $roomName)
                    } else {
                        TextField("Name", text: $roomName)

                        TextField("@alice:trix.selfhost.ru, @bob:trix.selfhost.ru", text: $inviteeUserIDs, axis: .vertical)
                            .matrixUserIDInput()
                            .lineLimit(2...5)
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
            .navigationTitle("New Room")
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
                                let didCreate = await model.createEncryptedDirectRoom(
                                    inviteeUserID: inviteeUserID,
                                    roomName: roomName
                                )
                                if didCreate {
                                    dismiss()
                                }
                            case .group:
                                let didCreate = await model.createEncryptedGroupRoom(
                                    name: roomName,
                                    inviteeUserIDs: inviteeUserIDs
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
        .frame(minWidth: 440, minHeight: 340)
    }

    private var isCreatingRoom: Bool {
        model.roomListViewModel.isCreatingDirectRoom || model.roomListViewModel.isCreatingGroupRoom
    }

    private var isCreateDisabled: Bool {
        switch mode {
        case .direct:
            return inviteeUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .group:
            return roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                inviteeUserIDs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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

private extension View {
    @ViewBuilder
    func matrixUserIDInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)
        #else
        self
            .autocorrectionDisabled()
            .textContentType(.username)
        #endif
    }
}
