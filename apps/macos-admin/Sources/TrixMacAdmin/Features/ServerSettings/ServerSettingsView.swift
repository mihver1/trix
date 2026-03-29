import SwiftUI

struct ServerSettingsView: View {
    @ObservedObject var model: AdminAppModel
    @State private var brandDraft = ""
    @State private var supportDraft = ""
    @State private var policyDraft = ""
    @State private var confirmApply = false
    @State private var pendingPatch: PatchAdminServerSettingsRequest?
    @State private var applyError: String?

    var body: some View {
        Group {
            if model.serverSettings != nil {
                Form {
                    Section("Branding") {
                        TextField("Brand display name", text: $brandDraft)
                        TextField("Support contact", text: $supportDraft, axis: .vertical)
                            .lineLimit(3 ... 6)
                    }
                    Section("Policy") {
                        TextField("Policy text", text: $policyDraft, axis: .vertical)
                            .lineLimit(4 ... 12)
                    }
                    Section {
                        Button("Save") {
                            preparePatchAndMaybeConfirm()
                        }
                        .disabled(model.isWorkspaceLoading || !hasChangesFromServer)
                    }
                }
                .formStyle(.grouped)
                .onAppear {
                    syncDraftFromModel()
                }
                .onChange(of: model.serverSettings) { _, _ in
                    syncDraftFromModel()
                }
            } else if model.isWorkspaceLoading {
                ProgressView("Loading server settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No server settings",
                    systemImage: "gearshape",
                    description: Text(model.workspaceError ?? "Unable to load settings.")
                )
            }
        }
        .alert("Apply server settings?", isPresented: $confirmApply) {
            Button("Cancel", role: .cancel) {
                pendingPatch = nil
            }
            Button("Apply", role: .destructive) {
                let patch = pendingPatch
                pendingPatch = nil
                if let patch {
                    Task { await applyPatch(patch) }
                }
            }
        } message: {
            Text("This updates live server metadata. Clearing fields removes published values.")
        }
        .alert("Could not save", isPresented: Binding(
            get: { applyError != nil },
            set: { if !$0 { applyError = nil } }
        )) {
            Button("OK", role: .cancel) { applyError = nil }
        } message: {
            Text(applyError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { await model.refreshWorkspaceData() }
                }
                .disabled(model.isWorkspaceLoading || model.activeSession == nil)
            }
        }
    }

    private var hasChangesFromServer: Bool {
        guard let s = model.serverSettings else { return false }
        return brandDraft != (s.brandDisplayName ?? "")
            || supportDraft != (s.supportContact ?? "")
            || policyDraft != (s.policyText ?? "")
    }

    private func syncDraftFromModel() {
        guard let s = model.serverSettings else { return }
        brandDraft = s.brandDisplayName ?? ""
        supportDraft = s.supportContact ?? ""
        policyDraft = s.policyText ?? ""
    }

    private func preparePatchAndMaybeConfirm() {
        guard let s = model.serverSettings else { return }
        let patch = PatchAdminServerSettingsRequest(
            brandDisplayName: patchValue(draft: brandDraft, original: s.brandDisplayName),
            supportContact: patchValue(draft: supportDraft, original: s.supportContact),
            policyText: patchValue(draft: policyDraft, original: s.policyText)
        )
        let clearsPublished = patch.brandDisplayName == .clear
            || patch.supportContact == .clear
            || patch.policyText == .clear
        pendingPatch = patch
        if clearsPublished {
            confirmApply = true
        } else {
            let p = patch
            pendingPatch = nil
            Task { await applyPatch(p) }
        }
    }

    private func patchValue(draft: String, original: String?) -> AdminOptionalStringPatch {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == (original ?? "") {
            return .unchanged
        }
        if trimmed.isEmpty {
            return .clear
        }
        return .set(trimmed)
    }

    @MainActor
    private func applyPatch(_ patch: PatchAdminServerSettingsRequest) async {
        do {
            try await model.updateServerSettings(patch: patch)
            syncDraftFromModel()
        } catch {
            applyError = error.localizedDescription
        }
    }
}
