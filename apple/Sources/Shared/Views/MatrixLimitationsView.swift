import SwiftUI

struct MatrixLimitationsView: View {
    private let pendingItems = [
        "device verification",
        "key backup and recovery",
        "push notifications",
        "media",
        "group room creation",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MVP limitations", systemImage: "exclamationmark.triangle")
                .font(.headline)

            Text(pendingItems.joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MatrixDeviceVerificationNoticeView: View {
    let status: MatrixDeviceVerificationStatus?

    init(status: MatrixDeviceVerificationStatus? = nil) {
        self.status = status
    }

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var message: String {
        guard let status else {
            return "Device verification is not production-ready yet. Encrypted DMs use Matrix SDK E2EE, but new devices are not silently trusted."
        }

        if status.state == .verified {
            return "Matrix SDK reports this device as verified. New devices still require explicit confirmation; the app does not silently trust them."
        }

        return "\(status.explanation) The app does not silently trust Matrix devices."
    }
}

struct MatrixDeviceVerificationStatusView: View {
    @ObservedObject var viewModel: DeviceVerificationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isLoading, viewModel.status == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading verification state")
                        .foregroundStyle(.secondary)
                }
            }

            if let status = viewModel.status {
                Label(status.state.label, systemImage: iconName(for: status.state))
                    .font(.headline)
                    .foregroundStyle(tint(for: status.state))

                Text(status.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Current device", value: status.deviceID)
                LabeledContent("Other device", value: status.deviceAvailabilityLabel)

                if let fingerprint = status.ed25519Fingerprint {
                    LabeledContent {
                        Text(shortKey(fingerprint))
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } label: {
                        Text("Fingerprint")
                    }
                }

                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !viewModel.isLoading {
                MatrixDeviceVerificationNoticeView()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iconName(for state: MatrixDeviceVerificationState) -> String {
        switch state {
        case .verified:
            return "checkmark.shield.fill"
        case .unverified:
            return "exclamationmark.shield"
        case .unknown:
            return "questionmark.shield"
        }
    }

    private func tint(for state: MatrixDeviceVerificationState) -> Color {
        switch state {
        case .verified:
            return .green
        case .unverified:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private func shortKey(_ key: String) -> String {
        guard key.count > 16 else {
            return key
        }

        return "\(key.prefix(8))...\(key.suffix(8))"
    }
}
