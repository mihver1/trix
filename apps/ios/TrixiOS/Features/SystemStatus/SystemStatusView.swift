import SwiftUI

struct ServerConnectionSection: View {
    @Binding var serverBaseURL: String
    let snapshot: ServerSnapshot?
    let lastUpdatedAt: Date?
    let isLoading: Bool
    let errorMessage: String?
    let reloadTitle: String
    let onReload: () -> Void

    var body: some View {
        Group {
            Section("Server") {
                TextField("http://127.0.0.1:8080", text: $serverBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button(action: onReload) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(reloadTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isLoading)

                if let lastUpdatedAt {
                    LabeledContent("Last Updated") {
                        Text(lastUpdatedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }

            if let snapshot {
                Section("Health") {
                    LabeledContent("Service") {
                        Text(snapshot.health.service)
                    }

                    LabeledContent("Status") {
                        StatusBadge(status: snapshot.health.status)
                    }

                    LabeledContent("Version") {
                        Text(snapshot.health.version)
                    }

                    LabeledContent("Uptime") {
                        Text("\(snapshot.health.uptimeMs) ms")
                            .monospacedDigit()
                    }
                }

                Section("Version") {
                    LabeledContent("Service") {
                        Text(snapshot.version.service)
                    }

                    LabeledContent("Build") {
                        Text(snapshot.version.version)
                    }

                    LabeledContent("Git SHA") {
                        Text(snapshot.version.gitSha ?? "Unavailable")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            if let errorMessage {
                Section("Last Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct StatusBadge: View {
    let status: ServiceStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

private extension ServiceStatus {
    var label: String {
        switch self {
        case .ok:
            return "OK"
        case .degraded:
            return "Degraded"
        }
    }

    var tint: Color {
        switch self {
        case .ok:
            return .green
        case .degraded:
            return .orange
        }
    }
}

#Preview {
    Form {
        ServerConnectionSection(
            serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
            snapshot: ServerSnapshot(
                health: HealthResponse(
                    service: "trixd",
                    status: .ok,
                    version: "0.1.0",
                    uptimeMs: 1234
                ),
                version: VersionResponse(
                    service: "trixd",
                    version: "0.1.0",
                    gitSha: "abc123"
                )
            ),
            lastUpdatedAt: .now,
            isLoading: false,
            errorMessage: nil,
            reloadTitle: "Refresh",
            onReload: {}
        )
    }
}
