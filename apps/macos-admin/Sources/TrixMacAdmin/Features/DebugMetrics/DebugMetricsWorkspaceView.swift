import SwiftUI

struct DebugMetricsWorkspaceView: View {
    @ObservedObject var model: AdminAppModel
    @State private var showCreateSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let overview = model.overview, !overview.response.debugMetricsEnabled {
                Label(
                    "Overview reports debug metrics as disabled on this server. Set TRIX_DEBUG_METRICS_ENABLED to enable ingestion.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.secondary)
                .padding()
            }

            HStack {
                TextField("Filter by account UUID (optional)", text: $model.debugMetricSessionsFilterAccountText)
                    .textFieldStyle(.roundedBorder)
                Button("Apply filter") {
                    Task { await model.refreshDebugMetricSessions() }
                }
                .disabled(model.activeSession == nil)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if let err = model.debugMetricsError, !err.isEmpty {
                Text(err)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            HSplitView {
                sessionList
                    .frame(minWidth: 320)

                batchPane
                    .frame(minWidth: 400)
            }
        }
        .task(id: model.selectedClusterID) {
            await model.refreshDebugMetricSessions()
        }
        .onChange(of: model.selectedDebugMetricSessionId) { _, _ in
            Task { await model.refreshDebugMetricBatches() }
        }
        .sheet(isPresented: $showCreateSession) {
            CreateDebugMetricSessionSheet(model: model, isPresented: $showCreateSession)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task {
                        await model.refreshDebugMetricSessions()
                        await model.refreshDebugMetricBatches()
                    }
                }
                .disabled(model.isDebugMetricSessionsLoading || model.activeSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button("New session…") { showCreateSession = true }
                    .disabled(model.activeSession == nil)
            }
        }
    }

    private var sessionList: some View {
        Group {
            if model.isDebugMetricSessionsLoading && model.debugMetricSessions.isEmpty {
                ProgressView("Loading sessions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedDebugMetricSessionId) {
                    ForEach(model.debugMetricSessions) { session in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.sessionId)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Text(session.userVisibleMessage)
                                    .font(.subheadline)
                                Text("Account \(session.accountId.uuidString)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if session.isRevoked {
                                    Text("Revoked")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            Spacer(minLength: 8)
                            if let uuid = UUID(uuidString: session.sessionId), !session.isRevoked {
                                Button("Revoke") {
                                    Task {
                                        try? await model.revokeDebugMetricSession(sessionId: uuid)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .tag(session.sessionId)
                    }
                }
            }
        }
    }

    private var batchPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedDebugMetricSessionId == nil {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "tray",
                    description: Text("Choose a session to inspect uploaded metric batches.")
                )
            } else if model.isDebugMetricBatchesLoading && model.debugMetricBatches.isEmpty {
                ProgressView("Loading batches…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Batches (\(model.debugMetricBatches.count))")
                    .font(.headline)
                    .padding(.horizontal)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.debugMetricBatches) { batch in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(batch.batchId)
                                    .font(.system(.caption, design: .monospaced))
                                Text("Device \(batch.deviceId.uuidString) · received \(batch.receivedAtUnix)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(batch.payload.prettyPrinted())
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CreateDebugMetricSessionSheet: View {
    @ObservedObject var model: AdminAppModel
    @Binding var isPresented: Bool
    @State private var accountIdText = ""
    @State private var deviceIdText = ""
    @State private var message = "Technical metrics collection is active for your account."
    @State private var ttlHours: Double = 24
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Account UUID", text: $accountIdText)
                TextField("Device UUID (optional)", text: $deviceIdText)
                TextField("User-visible message", text: $message, axis: .vertical)
                    .lineLimit(2 ... 6)
                Stepper(value: $ttlHours, in: 1 ... 168) {
                    Text("TTL: \(Int(ttlHours)) hours")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Debug metric session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await submit() }
                    }
                    .disabled(UUID(uuidString: accountIdText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }

    private func submit() async {
        errorText = nil
        guard let accountId = UUID(uuidString: accountIdText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        let devTrim = deviceIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceId = devTrim.isEmpty ? nil : UUID(uuidString: devTrim)
        if deviceId == nil, !devTrim.isEmpty {
            errorText = "Invalid device UUID."
            return
        }
        let ttl = UInt64(ttlHours * 3600)
        do {
            try await model.createDebugMetricSession(
                accountId: accountId,
                deviceId: deviceId,
                userVisibleMessage: message,
                ttlSeconds: ttl
            )
            isPresented = false
        } catch {
            errorText = error.localizedDescription
        }
    }
}
