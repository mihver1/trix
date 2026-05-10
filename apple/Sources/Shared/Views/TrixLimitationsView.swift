import SwiftUI

struct TrixLimitationsView: View {
    private let pendingItems = [
        "group OMEMO",
        "encrypted attachments",
        "push notifications",
        "timeline restart refresh",
        "TestFlight packaging",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MVP limitations", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(pendingItems.joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(TrixDesign.warningSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

struct TrixDeviceVerificationNoticeView: View {
    let status: TrixDeviceVerificationStatus?

    init(status: TrixDeviceVerificationStatus? = nil) {
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
            return "Device verification is not production-ready yet. Trix requires OMEMO, and new devices are not silently trusted."
        }

        if status.state == .verified {
            return "OMEMO local identity is available. New devices still require explicit confirmation; the app does not silently trust them."
        }

        return "\(status.explanation) The app does not silently trust OMEMO devices."
    }
}

struct TrixDeviceVerificationStatusView: View {
    @ObservedObject var viewModel: DeviceVerificationViewModel
    @State private var hasCopiedRecoveryKey = false

    let requestVerification: () -> Void
    let acceptRequest: (TrixDeviceVerificationRequest) -> Void
    let startSas: () -> Void
    let approve: () -> Void
    let decline: () -> Void
    let cancel: () -> Void
    let trustAccountDevice: (TrixPeerDeviceIdentity) -> Void
    let setUpRecovery: () -> Void
    let confirmRecoveryKey: () -> Void
    let dismissRecoveryKey: () -> Void

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
                LabeledContent("Other device", value: otherDeviceAvailabilityLabel(for: status))
                LabeledContent("Recovery", value: status.recoveryState.label)
                LabeledContent("Key backup", value: status.backupState.label)
                LabeledContent("Remote backup", value: status.backupAvailabilityLabel)

                if status.lacksEligibleVerificationDevice {
                    Label {
                        Text("No trusted session is available for interactive SAS. Recovery and account-level verification are still blocked in this client slice.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "key.horizontal")
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)

                    Text(status.recoveryExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                TrixAccountDeviceManagementView(
                    devices: viewModel.accountDevices,
                    refreshMessage: viewModel.accountDeviceRefreshMessage,
                    actionInFlight: viewModel.actionInFlight,
                    trust: trustAccountDevice
                )

                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !viewModel.isLoading {
                TrixDeviceVerificationNoticeView()
            }

            Divider()

            if !(viewModel.status?.lacksEligibleVerificationDevice == true && viewModel.flow.phase == .idle) {
                TrixDeviceVerificationFlowView(flow: viewModel.flow)
            }
            actionButtons
            recoveryControls
            recoveryAndReinstallLimitations

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iconName(for state: TrixDeviceVerificationState) -> String {
        switch state {
        case .verified:
            return "checkmark.shield.fill"
        case .unverified:
            return "exclamationmark.shield"
        case .unknown:
            return "questionmark.shield"
        }
    }

    private func tint(for state: TrixDeviceVerificationState) -> Color {
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

    private func otherDeviceAvailabilityLabel(for status: TrixDeviceVerificationStatus) -> String {
        let activeOtherDeviceCount = viewModel.accountDevices.filter { device in
            !device.isLocalDevice && device.isActive
        }.count

        guard activeOtherDeviceCount > 0 else {
            return status.deviceAvailabilityLabel
        }

        return activeOtherDeviceCount == 1 ? "1 active account device" : "\(activeOtherDeviceCount) active account devices"
    }

    @ViewBuilder
    private var recoveryControls: some View {
        if let status = viewModel.status, status.lacksEligibleVerificationDevice {
            let isBusy = viewModel.actionInFlight != nil

            VStack(alignment: .leading, spacing: 8) {
                if status.canSetUpRecovery {
                    Button {
                        setUpRecovery()
                    } label: {
                        actionLabel("Set Up Recovery", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }

                if let recoveryKey = viewModel.displayedRecoveryKey {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Save this recovery key before continuing. It will not be shown in logs.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(recoveryKey)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                recoveryKeyCopyButton(recoveryKey)
                                savedRecoveryKeyButton
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                recoveryKeyCopyButton(recoveryKey)
                                savedRecoveryKeyButton
                            }
                        }
                    }
                    .onChange(of: viewModel.displayedRecoveryKey) {
                        hasCopiedRecoveryKey = false
                    }
                }

                if status.canConfirmRecovery && viewModel.displayedRecoveryKey == nil {
                    SecureField("Recovery key", text: $viewModel.recoveryKeyConfirmation)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        confirmRecoveryKey()
                    } label: {
                        actionLabel("Confirm Recovery Key", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || viewModel.recoveryKeyConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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

    private func recoveryKeyCopyButton(_ recoveryKey: String) -> some View {
        Button {
            TrixPasteboard.copy(recoveryKey)
            hasCopiedRecoveryKey = true
        } label: {
            actionLabel(
                hasCopiedRecoveryKey ? "Copied" : "Copy Recovery Key",
                systemImage: hasCopiedRecoveryKey ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.bordered)
    }

    private var savedRecoveryKeyButton: some View {
        Button {
            hasCopiedRecoveryKey = false
            dismissRecoveryKey()
        } label: {
            actionLabel("I've Saved This Key", systemImage: "checkmark")
        }
        .buttonStyle(.bordered)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
    }

    private var recoveryAndReinstallLimitations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recovery and reinstall", systemImage: "externaldrive.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))

            Text("Server-side OMEMO key recovery is not wired in this client slice. Deleting the app or resetting Keychain creates a new OMEMO device; old encrypted history that was not encrypted for this device can remain unavailable. Trust replacement devices only after comparing fingerprints from an existing trusted session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

private struct TrixAccountDeviceManagementView: View {
    let devices: [TrixPeerDeviceIdentity]
    let refreshMessage: String?
    let actionInFlight: TrixDeviceVerificationAction?
    let trust: (TrixPeerDeviceIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Account OMEMO Devices", systemImage: "macbook.and.iphone")
                .font(.subheadline.weight(.semibold))

            Text("Published devices for this account are shown for fingerprint comparison. Trix does not trust new devices automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let refreshMessage {
                Label {
                    Text(refreshMessage)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if devices.isEmpty {
                Text("No OMEMO device identities are available yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(devices) { device in
                        accountDeviceRow(device)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func accountDeviceRow(_ device: TrixPeerDeviceIdentity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(device.isLocalDevice ? "Current Device" : "Account Device", systemImage: deviceIcon(for: device))
                    .font(.callout.weight(.semibold))

                Spacer(minLength: 8)

                Text(device.trustState.label)
                    .font(.caption)
                    .foregroundStyle(device.canSendEncrypted || device.isLocalDevice ? .green : .orange)
            }

            LabeledContent("Device ID", value: device.deviceID)

            LabeledContent {
                Text(device.shortFingerprint)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(device.hasFingerprint ? .primary : .secondary)
            } label: {
                Text("Fingerprint")
            }

            Text(device.isActive ? "Published active OMEMO device" : "Inactive OMEMO device")
                .font(.caption)
                .foregroundStyle(.secondary)

            if canTrust(device) {
                Button {
                    trust(device)
                } label: {
                    Label("Trust This Device", systemImage: "checkmark.shield")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(actionInFlight != nil)
                .help("Trust only after comparing the fingerprint on this device with another trusted session.")
            }
        }
        .padding(.vertical, 4)
    }

    private func canTrust(_ device: TrixPeerDeviceIdentity) -> Bool {
        !device.isLocalDevice && device.isActive && !device.canSendEncrypted
    }

    private func deviceIcon(for device: TrixPeerDeviceIdentity) -> String {
        if device.isLocalDevice {
            return "iphone.and.arrow.forward"
        }

        return device.canSendEncrypted ? "checkmark.shield" : "exclamationmark.shield"
    }
}

private struct TrixDeviceVerificationFlowView: View {
    let flow: TrixDeviceVerificationFlow

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
                TrixDeviceVerificationChallengeView(challenge: challenge)
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

private struct TrixDeviceVerificationChallengeView: View {
    let challenge: TrixDeviceVerificationChallenge

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
