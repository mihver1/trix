import SwiftUI

struct ClusterProfileEditorView: View {
    @ObservedObject var model: AdminAppModel

    var body: some View {
        Form {
            TextField("Display name", text: binding(\.displayName))
            TextField("Base URL", text: baseURLBinding)
            TextField("Environment label", text: binding(\.environmentLabel))
            Picker("Auth mode", selection: binding(\.authMode)) {
                ForEach(ClusterAuthMode.allCases, id: \.self) { mode in
                    Text(mode.displayTitle).tag(mode)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 360, minHeight: 220)
        .navigationTitle(model.editorIsNewCluster ? "New cluster" : "Edit cluster")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.cancelClusterEditor()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { @MainActor in
                        await model.saveClusterEditor()
                    }
                }
                .disabled(!model.isClusterEditorValid)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ClusterProfile, String>) -> Binding<String> {
        Binding(
            get: {
                guard let draft = model.clusterEditorDraft else { return "" }
                return draft[keyPath: keyPath]
            },
            set: { newValue in
                guard var draft = model.clusterEditorDraft else { return }
                draft[keyPath: keyPath] = newValue
                model.clusterEditorDraft = draft
            }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<ClusterProfile, ClusterAuthMode>) -> Binding<ClusterAuthMode> {
        Binding(
            get: {
                model.clusterEditorDraft?.authMode ?? .localCredentials
            },
            set: { newValue in
                guard var draft = model.clusterEditorDraft else { return }
                draft[keyPath: keyPath] = newValue
                model.clusterEditorDraft = draft
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: {
                model.clusterEditorDraft?.baseURL.absoluteString ?? ""
            },
            set: { newValue in
                guard var draft = model.clusterEditorDraft else { return }
                if let url = URL(string: newValue), let scheme = url.scheme, scheme == "http" || scheme == "https" {
                    draft.baseURL = url
                    model.clusterEditorDraft = draft
                }
            }
        )
    }
}

private extension ClusterAuthMode {
    var displayTitle: String {
        switch self {
        case .localCredentials:
            return "Local credentials"
        }
    }
}
