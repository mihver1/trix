import SwiftUI

struct MatrixNewDirectMessageView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var inviteeUserID = ""
    @State private var roomName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite") {
                    TextField("@user:trix.selfhost.ru", text: $inviteeUserID)
                        .matrixUserIDInput()

                    TextField("Room name", text: $roomName)
                }

                Section {
                    MatrixDeviceVerificationNoticeView()
                }

                if let errorMessage = model.roomListViewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("New DM")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let didCreate = await model.createEncryptedDirectRoom(
                                inviteeUserID: inviteeUserID,
                                roomName: roomName
                            )
                            if didCreate {
                                dismiss()
                            }
                        }
                    } label: {
                        if model.roomListViewModel.isCreatingDirectRoom {
                            ProgressView()
                        } else {
                            Label("Create", systemImage: "lock.bubble.left.fill")
                        }
                    }
                    .disabled(model.roomListViewModel.isCreatingDirectRoom || inviteeUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
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
