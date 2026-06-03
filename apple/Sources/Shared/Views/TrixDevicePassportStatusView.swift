import SwiftUI

struct TrixDevicePassportStatusView: View {
    @ObservedObject var viewModel: DevicePassportViewModel
    let refresh: () -> Void
    let approve: (TrixDevicePassportApprovalRequest) -> Void
    let decline: (TrixDevicePassportApprovalRequest) -> Void
    let dismissNotice: (TrixDevicePassportNotice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let challenge = viewModel.currentApprovalChallenge {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Approval code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(challenge)
                        .font(.title3.monospaced().weight(.bold))
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let snapshot = viewModel.snapshot,
               !snapshot.pendingApprovalRequests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Waiting devices")
                        .font(.headline)
                    ForEach(snapshot.pendingApprovalRequests) { request in
                        pendingRequestRow(request)
                    }
                }
            }

            if !viewModel.notices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Device notices")
                        .font(.headline)
                    ForEach(viewModel.notices) { notice in
                        noticeRow(notice)
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: refresh) {
                Label("Refresh Device Passport", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(statusTitle, systemImage: statusIcon)
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        guard let device = viewModel.snapshot?.currentDevice else {
            return "Device Passport"
        }
        return "Device Passport: \(device.state.label)"
    }

    private var statusIcon: String {
        guard let device = viewModel.snapshot?.currentDevice else {
            return "lock.shield"
        }
        return device.isCurrentDeviceReadOnly ? "exclamationmark.shield" : "checkmark.shield.fill"
    }

    private var statusMessage: String {
        if let block = viewModel.currentDeviceBlockMessage {
            return block
        }
        guard let device = viewModel.snapshot?.currentDevice else {
            return "Trix syncs device approval state without treating the server as a trust authority."
        }
        return "\(device.deviceLabel) is \(device.state.label.lowercased()). Server state still requires local OMEMO proof before contacts auto-trust new devices."
    }

    private func pendingRequestRow(_ request: TrixDevicePassportApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device \(request.deviceID)")
                        .font(.subheadline.weight(.semibold))
                    Text("Code \(request.challenge)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Decline") {
                    decline(request)
                }
                Button("Approve") {
                    approve(request)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func noticeRow(_ notice: TrixDevicePassportNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.severity == .high ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .foregroundStyle(notice.severity == .high ? .orange : .green)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                dismissNotice(notice)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(10)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
