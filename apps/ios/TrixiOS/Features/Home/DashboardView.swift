import SwiftUI

struct DashboardView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var isShowingForgetAlert = false

    var body: some View {
        List {
            ServerConnectionSection(
                serverBaseURL: $serverBaseURL,
                snapshot: model.systemSnapshot,
                lastUpdatedAt: model.lastUpdatedAt,
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                reloadTitle: "Refresh",
                onReload: reload
            )

            if let dashboard = model.dashboard {
                Section("Session") {
                    LabeledContent("Expires") {
                        Text(dashboard.sessionExpirationDate.formatted(date: .abbreviated, time: .standard))
                    }

                    LabeledContent("Device Status") {
                        DeviceStatusBadge(status: dashboard.session.deviceStatus)
                    }
                }

                Section("Account") {
                    LabeledContent("Profile") {
                        Text(dashboard.profile.profileName)
                    }

                    if let handle = dashboard.profile.handle {
                        LabeledContent("Handle") {
                            Text("@\(handle)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let profileBio = dashboard.profile.profileBio {
                        LabeledContent("Bio") {
                            Text(profileBio)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    LabeledContent("Account ID") {
                        Text(dashboard.profile.accountId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Current Device") {
                    if let currentDevice = dashboard.currentDevice {
                        LabeledContent("Name") {
                            Text(currentDevice.displayName)
                        }

                        LabeledContent("Platform") {
                            Text(currentDevice.platform)
                        }

                        LabeledContent("Status") {
                            DeviceStatusBadge(status: currentDevice.deviceStatus)
                        }
                    }

                    LabeledContent("Device ID") {
                        Text(dashboard.profile.deviceId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Trusted Devices") {
                    ForEach(dashboard.devices) { device in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(device.displayName)
                                    .font(.headline)

                                Spacer()

                                DeviceStatusBadge(status: device.deviceStatus)
                            }

                            Text(device.platform)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text(device.deviceId)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Section {
                    HStack {
                        Spacer()

                        if model.isLoading {
                            ProgressView("Authenticating Device")
                        } else {
                            Text("No authenticated session yet.")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
            }

            if let localIdentity = model.localIdentity {
                Section("Local Storage") {
                    LabeledContent("Stored Account ID") {
                        Text(localIdentity.accountId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Sync Chat ID") {
                        Text(localIdentity.accountSyncChatId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }

                    Button("Forget This Device", role: .destructive) {
                        isShowingForgetAlert = true
                    }
                }
            }
        }
        .navigationTitle("Trix")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", action: reload)
                    .disabled(model.isLoading)
            }
        }
        .alert("Forget this device?", isPresented: $isShowingForgetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                model.forgetLocalDevice()
            }
        } message: {
            Text("This removes local keys and session state from the iPhone. The server-side account and device record stay unchanged.")
        }
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }
}

private struct DeviceStatusBadge: View {
    let status: DeviceStatus

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

private extension DeviceStatus {
    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .active:
            return "Active"
        case .revoked:
            return "Revoked"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            return .orange
        case .active:
            return .green
        case .revoked:
            return .red
        }
    }
}

#Preview {
    NavigationStack {
        DashboardView(
            serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
            model: AppModel()
        )
    }
}
