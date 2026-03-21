import SwiftUI

struct DiagnosticsLogView: View {
    @ObservedObject var logStore: SafeDiagnosticLogStore

    var body: some View {
        List {
            Section {
                LabeledContent("Active Log") {
                    Text(logStore.activeLogURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                Text("Only safe client events are recorded here: lifecycle, sync, membership, device actions, counts, short IDs, and failures. Message plaintext and decrypted payloads are never logged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Reload") {
                        logStore.reload()
                    }

                    Button("Clear", role: .destructive) {
                        logStore.clear()
                    }
                }
            }

            Section("Recent Events") {
                if logStore.entries.isEmpty {
                    Text("No safe client logs yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(logStore.entries.reversed())) { entry in
                        Text(entry.line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Client Logs")
        .onAppear {
            logStore.reload()
        }
    }
}
