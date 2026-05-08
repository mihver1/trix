import SwiftUI

struct MatrixProfileSettingsView: View {
    @ObservedObject var model: MatrixAppModel
    @StateObject private var viewModel = MatrixProfileViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isLoading, viewModel.profile == nil {
                ProgressView()
                    .controlSize(.small)
            }

            if let profile = viewModel.profile {
                LabeledContent("User", value: profile.userID)

                if let avatarURL = profile.avatarURL {
                    LabeledContent("Avatar", value: avatarURL)
                }
            }

            TextField("Name", text: $viewModel.draftDisplayName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Bio")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $viewModel.draftBio)
                    .frame(minHeight: 76)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(MatrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MatrixDesign.surfaceStroke, lineWidth: 1)
                    }
            }

            TextField("Status", text: $viewModel.draftStatusMessage)
                .textFieldStyle(.roundedBorder)

            TextField("Website", text: $viewModel.draftWebsite)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .textInputAutocapitalizationNever()

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.save { update in
                            try await model.updateProfile(update)
                        }
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .disabled(!viewModel.canSave)

                Button {
                    Task {
                        await viewModel.load {
                            try await model.profile()
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading || viewModel.isSaving)
            }
            .buttonStyle(.bordered)

            if viewModel.didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.session?.userID) {
            await viewModel.load {
                try await model.profile()
            }
        }
        .onChange(of: viewModel.draftDisplayName) { _, _ in
            viewModel.resetSavedState()
        }
        .onChange(of: viewModel.draftBio) { _, _ in
            viewModel.resetSavedState()
        }
        .onChange(of: viewModel.draftStatusMessage) { _, _ in
            viewModel.resetSavedState()
        }
        .onChange(of: viewModel.draftWebsite) { _, _ in
            viewModel.resetSavedState()
        }
    }
}

private extension View {
    @ViewBuilder
    func textInputAutocapitalizationNever() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }
}
