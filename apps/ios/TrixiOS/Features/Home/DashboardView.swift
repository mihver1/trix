import SwiftUI
import UIKit

struct DashboardView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var isShowingForgetAlert = false
    @State private var revokeCandidate: DeviceSummary?
    @State private var revokeReason = ""

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

                    if !model.canManageAccountDevices {
                        Text("This linked device does not have shared account-management key material yet, so revoke actions stay disabled here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Link Devices") {
                    Button(action: createLinkIntent) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Create Link Intent")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)
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

                            if device.deviceId == dashboard.profile.deviceId {
                                Text("Current device")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            } else if model.canManageAccountDevices {
                                if device.deviceStatus == .pending {
                                    Button("Approve Device") {
                                        approvePendingDevice(deviceId: device.deviceId)
                                    }
                                    .disabled(model.isLoading)
                                }

                                if device.deviceStatus == .active {
                                    Button("Revoke Device", role: .destructive) {
                                        revokeCandidate = device
                                        revokeReason = ""
                                    }
                                    .disabled(model.isLoading)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("History Sync Jobs") {
                    if dashboard.historySyncJobs.isEmpty {
                        Text("No history sync jobs assigned to this device.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dashboard.historySyncJobs) { job in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(job.jobType.label)
                                        .font(.headline)

                                    Spacer()

                                    HistorySyncStatusBadge(status: job.jobStatus)
                                }

                                Text("Job \(job.jobId)")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text("Target")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(job.targetDeviceId)
                                        .font(.system(.footnote, design: .monospaced))
                                }

                                if let chatId = job.chatId {
                                    HStack {
                                        Text("Chat")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(chatId)
                                            .font(.system(.footnote, design: .monospaced))
                                    }
                                }

                                HStack {
                                    Text("Updated")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Date(timeIntervalSince1970: TimeInterval(job.updatedAtUnix)).formatted(date: .abbreviated, time: .shortened))
                                }

                                if job.jobStatus.canComplete {
                                    Button("Mark Completed") {
                                        completeHistorySyncJob(jobId: job.jobId)
                                    }
                                    .disabled(model.isLoading)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Messaging PoC") {
                    NavigationLink {
                        MessagingLabView(
                            serverBaseURL: $serverBaseURL,
                            model: model
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chats, Inbox, Membership")
                            Text("\(dashboard.chats.count) chats, \(dashboard.inboxItems.count) inbox items")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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

                    if let accountSyncChatId = localIdentity.accountSyncChatId {
                        LabeledContent("Sync Chat ID") {
                            Text(accountSyncChatId)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    if let localCoreState = model.localCoreState {
                        LabeledContent("Local Chat Cache") {
                            Text("\(localCoreState.localChats.count) chats")
                        }

                        LabeledContent("Inbox Cursor") {
                            Text(localCoreState.lastAckedInboxId.map(String.init) ?? "None")
                        }
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
        .sheet(item: $revokeCandidate) { device in
            RevokeDeviceSheet(
                device: device,
                revokeReason: $revokeReason,
                isSubmitting: model.isLoading,
                onCancel: {
                    revokeCandidate = nil
                },
                onConfirm: {
                    let deviceId = device.deviceId
                    let reason = revokeReason
                    revokeCandidate = nil
                    revokeReason = ""
                    Task {
                        await model.revokeDevice(
                            baseURLString: serverBaseURL,
                            deviceId: deviceId,
                            reason: reason
                        )
                    }
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(item: linkIntentBinding) { linkIntent in
            LinkIntentSheet(
                linkIntent: linkIntent,
                onClose: model.dismissActiveLinkIntent
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }

    private func completeHistorySyncJob(jobId: String) {
        Task {
            await model.completeHistorySyncJob(
                baseURLString: serverBaseURL,
                jobId: jobId
            )
        }
    }

    private func createLinkIntent() {
        Task {
            await model.createLinkIntent(baseURLString: serverBaseURL)
        }
    }

    private func approvePendingDevice(deviceId: String) {
        Task {
            _ = await model.approvePendingDevice(
                baseURLString: serverBaseURL,
                deviceId: deviceId
            )
        }
    }

    private var linkIntentBinding: Binding<CreateLinkIntentResponse?> {
        Binding(
            get: { model.activeLinkIntent },
            set: { value in
                if value == nil {
                    model.dismissActiveLinkIntent()
                }
            }
        )
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

private struct HistorySyncStatusBadge: View {
    let status: HistorySyncJobStatus

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

private extension HistorySyncJobType {
    var label: String {
        switch self {
        case .initialSync:
            return "Initial Sync"
        case .chatBackfill:
            return "Chat Backfill"
        case .deviceRekey:
            return "Device Rekey"
        }
    }
}

private extension HistorySyncJobStatus {
    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            return .orange
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .gray
        }
    }

    var canComplete: Bool {
        switch self {
        case .pending, .running:
            return true
        case .completed, .failed, .canceled:
            return false
        }
    }
}

private struct RevokeDeviceSheet: View {
    let device: DeviceSummary
    @Binding var revokeReason: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Name") {
                        Text(device.displayName)
                    }

                    LabeledContent("Platform") {
                        Text(device.platform)
                    }

                    LabeledContent("Device ID") {
                        Text(device.deviceId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    TextField("Compromised, lost, replaced...", text: $revokeReason, axis: .vertical)
                        .lineLimit(3, reservesSpace: false)
                } header: {
                    Text("Reason")
                } footer: {
                    Text("The server now requires a signed revoke reason. This action cuts off future server-side access for the selected device.")
                }
            }
            .navigationTitle("Revoke Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Revoke", role: .destructive, action: onConfirm)
                        .disabled(isSubmitting || revokeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LinkIntentSheet: View {
    let linkIntent: CreateLinkIntentResponse
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Expires") {
                    Text(linkIntent.expirationDate.formatted(date: .abbreviated, time: .standard))
                }

                Section {
                    Text(linkIntent.qrPayload)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Payload")
                } footer: {
                    Text("For now the iOS PoC exposes the QR payload as JSON so it can be copied into another device manually.")
                }

                Section {
                    Button("Copy Payload") {
                        UIPasteboard.general.string = linkIntent.qrPayload
                    }
                }
            }
            .navigationTitle("Link Intent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
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
