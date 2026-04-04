import SwiftUI

private enum FeatureFlagsSubtab: String, CaseIterable, Identifiable {
    case definitions
    case overrides

    var id: String { rawValue }

    var title: String {
        switch self {
        case .definitions: return "Definitions"
        case .overrides: return "Overrides"
        }
    }
}

struct FeatureFlagsWorkspaceView: View {
    @ObservedObject var model: AdminAppModel
    @State private var subtab: FeatureFlagsSubtab = .definitions
    @State private var showAddDefinition = false
    @State private var showAddOverride = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Section", selection: $subtab) {
                ForEach(FeatureFlagsSubtab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            Group {
                switch subtab {
                case .definitions:
                    definitionsPane
                case .overrides:
                    overridesPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.selectedClusterID) {
            await model.refreshFeatureFlagsWorkspace()
        }
        .sheet(isPresented: $showAddDefinition) {
            AddFeatureFlagDefinitionSheet(model: model, isPresented: $showAddDefinition)
        }
        .sheet(isPresented: $showAddOverride) {
            AddFeatureFlagOverrideSheet(model: model, isPresented: $showAddOverride)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { await model.refreshFeatureFlagsWorkspace() }
                }
                .disabled(model.isFeatureFlagsLoading || model.activeSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Menu("Add") {
                    Button("Definition…") { showAddDefinition = true }
                    Button("Override…") { showAddOverride = true }
                }
                .disabled(model.activeSession == nil)
            }
        }
    }

    private var definitionsPane: some View {
        Group {
            if let err = model.featureFlagsError, !err.isEmpty {
                Text(err).foregroundStyle(.red).padding()
            }
            if model.isFeatureFlagsLoading && model.featureFlagDefinitions.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.featureFlagDefinitions) {
                    TableColumn("Key") { row in
                        Text(row.flagKey).font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Default") { row in
                        Text(row.defaultEnabled ? "On" : "Off")
                    }
                    TableColumn("Archived") { row in
                        Text(row.isArchived ? "Yes" : "No")
                    }
                    TableColumn("Updated") { row in
                        Text(String(row.updatedAtUnix))
                    }
                    TableColumn("") { row in
                        if !row.isArchived {
                            Button("Archive") {
                                Task {
                                    try? await model.archiveFeatureFlagDefinition(flagKey: row.flagKey)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .width(80)
                }
            }
        }
    }

    private var overridesPane: some View {
        Group {
            if model.isFeatureFlagsLoading && model.featureFlagOverrides.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.featureFlagOverrides) {
                    TableColumn("Flag") { row in
                        Text(row.flagKey).font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Scope") { row in
                        Text(row.scope.title)
                    }
                    TableColumn("Enabled") { row in
                        Text(row.enabled ? "On" : "Off")
                    }
                    TableColumn("Target") { row in
                        Text(overrideTargetDescription(row))
                            .lineLimit(2)
                    }
                    TableColumn("") { row in
                        if let uuid = UUID(uuidString: row.overrideId) {
                            Button("Delete") {
                                Task {
                                    try? await model.deleteFeatureFlagOverride(overrideId: uuid)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .width(72)
                }
            }
        }
    }

    private func overrideTargetDescription(_ row: AdminFeatureFlagOverride) -> String {
        switch row.scope {
        case .global:
            return "—"
        case .platform:
            return row.platform ?? "—"
        case .account:
            return row.accountId?.uuidString ?? "—"
        case .device:
            let a = row.accountId.map(\.uuidString) ?? "—"
            let d = row.deviceId.map(\.uuidString) ?? "—"
            return "acct \(a) / dev \(d)"
        }
    }
}

private struct AddFeatureFlagDefinitionSheet: View {
    @ObservedObject var model: AdminAppModel
    @Binding var isPresented: Bool
    @State private var flagKey = ""
    @State private var description = ""
    @State private var defaultEnabled = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Flag key (e.g. my_feature)", text: $flagKey)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3 ... 8)
                Toggle("Default enabled", isOn: $defaultEnabled)
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New definition")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await submit() }
                    }
                    .disabled(flagKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private func submit() async {
        errorText = nil
        let key = flagKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try await model.createFeatureFlagDefinition(
                flagKey: key,
                description: description,
                defaultEnabled: defaultEnabled
            )
            isPresented = false
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct AddFeatureFlagOverrideSheet: View {
    @ObservedObject var model: AdminAppModel
    @Binding var isPresented: Bool
    @State private var flagKey = ""
    @State private var scope: AdminFeatureFlagScope = .global
    @State private var platform = ""
    @State private var accountIdText = ""
    @State private var deviceIdText = ""
    @State private var enabled = true
    @State private var errorText: String?

    private var activeFlagKeys: [String] {
        model.featureFlagDefinitions.filter { !$0.isArchived }.map(\.flagKey).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Flag key", selection: $flagKey) {
                    Text("Select…").tag("")
                    ForEach(activeFlagKeys, id: \.self) { k in
                        Text(k).tag(k)
                    }
                }
                Picker("Scope", selection: $scope) {
                    ForEach(AdminFeatureFlagScope.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                if scope == .platform {
                    TextField("Platform (e.g. ios)", text: $platform)
                }
                if scope == .account || scope == .device {
                    TextField("Account UUID", text: $accountIdText)
                }
                if scope == .device {
                    TextField("Device UUID", text: $deviceIdText)
                }
                Toggle("Enabled", isOn: $enabled)
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New override")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .onAppear {
            if flagKey.isEmpty, let first = activeFlagKeys.first {
                flagKey = first
            }
        }
    }

    private var canSubmit: Bool {
        guard !flagKey.isEmpty else { return false }
        switch scope {
        case .global:
            return true
        case .platform:
            return !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .account:
            return UUID(uuidString: accountIdText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .device:
            let a = UUID(uuidString: accountIdText.trimmingCharacters(in: .whitespacesAndNewlines))
            let d = UUID(uuidString: deviceIdText.trimmingCharacters(in: .whitespacesAndNewlines))
            return a != nil && d != nil
        }
    }

    private func submit() async {
        errorText = nil
        let acc = UUID(uuidString: accountIdText.trimmingCharacters(in: .whitespacesAndNewlines))
        let dev = UUID(uuidString: deviceIdText.trimmingCharacters(in: .whitespacesAndNewlines))
        let plat = scope == .platform
            ? platform.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let req = CreateAdminFeatureFlagOverrideRequest(
            flagKey: flagKey,
            scope: scope,
            platform: plat,
            accountId: (scope == .account || scope == .device) ? acc : nil,
            deviceId: scope == .device ? dev : nil,
            enabled: enabled,
            expiresAtUnix: nil
        )
        do {
            try await model.createFeatureFlagOverride(request: req)
            isPresented = false
        } catch {
            errorText = error.localizedDescription
        }
    }
}
