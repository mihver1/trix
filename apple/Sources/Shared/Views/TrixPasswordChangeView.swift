import SwiftUI

struct TrixPasswordChangeView: View {
    @ObservedObject var model: TrixAppModel
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isChanging = false
    @State private var didChange = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Current password", text: $currentPassword)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)

            SecureField("New password", text: $newPassword)
                .textContentType(.newPassword)
                .textFieldStyle(.roundedBorder)

            SecureField("Confirm new password", text: $confirmation)
                .textContentType(.newPassword)
                .textFieldStyle(.roundedBorder)

            Button {
                Task {
                    await changePassword()
                }
            } label: {
                if isChanging {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Change Password", systemImage: "key")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit || isChanging)

            if didChange {
                Label("Password changed", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: currentPassword) { _, _ in
            clearStatus()
        }
        .onChange(of: newPassword) { _, _ in
            clearStatus()
        }
        .onChange(of: confirmation) { _, _ in
            clearStatus()
        }
    }

    private var canSubmit: Bool {
        model.isAuthenticated &&
            !currentPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !confirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func changePassword() async {
        guard !isChanging else {
            return
        }

        guard !currentPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            didChange = false
            errorMessage = "Enter current password."
            return
        }

        guard newPassword.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else {
            didChange = false
            errorMessage = TrixClientError.registrationPasswordTooWeak.trixUserFacingMessage
            return
        }

        guard newPassword == confirmation else {
            didChange = false
            errorMessage = "Passwords do not match."
            return
        }

        isChanging = true
        errorMessage = nil
        didChange = false
        defer { isChanging = false }

        do {
            _ = try await model.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            currentPassword = ""
            newPassword = ""
            confirmation = ""
            didChange = true
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    private func clearStatus() {
        didChange = false
        errorMessage = nil
    }
}
