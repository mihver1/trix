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
    let requestVerification: () -> Void
    let acceptRequest: (MatrixDeviceVerificationRequest) -> Void
    let startSas: () -> Void
    let approve: () -> Void
    let decline: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Divider()

            MatrixDeviceVerificationFlowView(flow: viewModel.flow)
            actionButtons

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

    @ViewBuilder
    private var actionButtons: some View {
        let isBusy = viewModel.actionInFlight != nil

        switch viewModel.flow.phase {
        case .idle, .cancelled, .failed:
            if let status = viewModel.status,
               status.needsUserConfirmation,
               status.hasDevicesToVerifyAgainst {
                Button {
                    requestVerification()
                } label: {
                    actionLabel("Request Verification", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }

        case .incomingRequest:
            if let request = viewModel.flow.request {
                Button {
                    acceptRequest(request)
                } label: {
                    actionLabel("Accept Request", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }

            cancelButton(isBusy: isBusy)

        case .accepted:
            if viewModel.flow.request == nil {
                Button {
                    startSas()
                } label: {
                    actionLabel("Start SAS", systemImage: "number")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }

            cancelButton(isBusy: isBusy)

        case .requestSent, .sasStarted, .approved:
            cancelButton(isBusy: isBusy)

        case .challengeReceived:
            HStack(spacing: 8) {
                Button {
                    approve()
                } label: {
                    actionLabel("Codes Match", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                Button(role: .destructive) {
                    decline()
                } label: {
                    actionLabel("No Match", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }

        case .finished:
            EmptyView()
        }

        if isBusy {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Working")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cancelButton(isBusy: Bool) -> some View {
        Button(role: .destructive) {
            cancel()
        } label: {
            actionLabel("Cancel Verification", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
    }
}

private struct MatrixDeviceVerificationFlowView: View {
    let flow: MatrixDeviceVerificationFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(flow.phase.label, systemImage: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)

            Text(flow.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let request = flow.request {
                LabeledContent("Requester", value: request.senderLabel)
                LabeledContent("Request device", value: request.deviceLabel)
                LabeledContent("First seen", value: request.firstSeenAt.formatted(date: .abbreviated, time: .shortened))
            }

            if let challenge = flow.challenge {
                MatrixDeviceVerificationChallengeView(challenge: challenge)
            }
        }
    }

    private var iconName: String {
        switch flow.phase {
        case .idle:
            return "shield"
        case .requestSent:
            return "paperplane"
        case .incomingRequest:
            return "person.badge.key"
        case .accepted, .sasStarted:
            return "number"
        case .challengeReceived:
            return "checklist"
        case .approved:
            return "hourglass"
        case .finished:
            return "checkmark.shield.fill"
        case .cancelled:
            return "xmark.shield"
        case .failed:
            return "exclamationmark.shield"
        }
    }

    private var tint: Color {
        switch flow.phase {
        case .finished:
            return .green
        case .cancelled, .failed:
            return .orange
        case .idle:
            return .secondary
        case .requestSent, .incomingRequest, .accepted, .sasStarted, .challengeReceived, .approved:
            return .blue
        }
    }
}

private struct MatrixDeviceVerificationChallengeView: View {
    let challenge: MatrixDeviceVerificationChallenge

    var body: some View {
        switch challenge {
        case .emojis(let emojis):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(emojis) { emoji in
                    HStack(spacing: 8) {
                        Text(emoji.symbol)
                            .font(.title3)
                            .frame(width: 28)
                        Text(emoji.description.capitalized)
                            .font(.callout)
                    }
                }
            }

        case .decimals(let values):
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }
}
