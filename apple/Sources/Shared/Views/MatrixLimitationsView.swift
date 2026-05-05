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
    var body: some View {
        Label {
            Text("Device verification is not production-ready yet. Encrypted DMs use Matrix SDK E2EE, but new devices are not silently trusted.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
