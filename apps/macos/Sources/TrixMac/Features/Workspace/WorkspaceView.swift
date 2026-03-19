import SwiftUI

struct WorkspaceView: View {
    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let availableSize: CGSize

    private var prefersSingleColumn: Bool {
        availableSize.width < 1380 || availableSize.height < 860
    }

    var body: some View {
        if let currentAccount = model.currentAccount {
            VStack(alignment: .leading, spacing: 20) {
                TrixPanel(
                    title: currentAccount.profileName,
                    subtitle: currentAccount.handle ?? "No public handle yet.",
                    tone: .strong
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let profileBio = currentAccount.profileBio, !profileBio.isEmpty {
                            Text(profileBio)
                                .font(.body)
                                .foregroundStyle(colors.inkMuted)
                        }

                        HStack(spacing: 16) {
                            TrixMetricTile(
                                label: "Account",
                                value: shortID(currentAccount.accountId),
                                footnote: "Authenticated via challenge/session"
                            )
                            TrixMetricTile(
                                label: "Devices",
                                value: "\(model.devices.count)",
                                footnote: "Visible in the active device directory"
                            )
                            TrixMetricTile(
                                label: "Chats",
                                value: "\(model.chats.count)",
                                footnote: "Sorted from live server metadata"
                            )
                        }
                    }
                }

                if prefersSingleColumn {
                    VStack(alignment: .leading, spacing: 20) {
                        inspectorColumn
                        sidebarColumn
                    }
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        sidebarColumn
                            .frame(width: 340)

                        inspectorColumn
                    }
                }
            }
        } else {
            TrixPanel(
                title: "Restore Session",
                subtitle: "A local device profile exists, but the app still needs to re-authenticate against the server."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reconnect to reload account metadata, device state and encrypted chat history.")
                        .foregroundStyle(colors.inkMuted)

                    Button {
                        Task {
                            await model.restoreSession()
                        }
                    } label: {
                        Label(
                            model.isRestoringSession ? "Reconnecting…" : "Reconnect",
                            systemImage: "arrow.clockwise.circle.fill"
                        )
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .frame(maxWidth: 220)
                    .disabled(model.isRestoringSession)
                }
            }
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            TrixPanel(
                title: "Chats",
                subtitle: "Choose a chat to inspect current members and encrypted history metadata."
            ) {
                if model.chats.isEmpty {
                    EmptyWorkspaceLabel("No chats are visible yet. Create another account or use the API to open the first DM or group.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.chats) { chat in
                            ChatRow(
                                chat: chat,
                                isSelected: chat.chatId == model.selectedChatID,
                                isLoading: chat.chatId == model.selectedChatID && model.isLoadingSelectedChat
                            ) {
                                Task {
                                    await model.selectChat(chat.chatId)
                                }
                            }
                        }
                    }
                }
            }

            TrixPanel(
                title: "Devices",
                subtitle: "Current account device directory."
            ) {
                if model.devices.isEmpty {
                    EmptyWorkspaceLabel("No devices returned by the server.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.devices) { device in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.displayName)
                                        .font(.headline)
                                        .foregroundStyle(colors.ink)
                                    Text(device.platform)
                                        .font(.subheadline)
                                        .foregroundStyle(colors.inkMuted)
                                }
                                Spacer()
                                TrixToneBadge(
                                    label: device.deviceStatus.label,
                                    tint: device.deviceStatus == .active ? colors.success : colors.warning
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary = model.selectedChatSummary {
                TrixPanel(
                    title: summary.displayTitle,
                    subtitle: "\(summary.chatType.rawValue.replacingOccurrences(of: "_", with: " ")) conversation"
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            TrixToneBadge(label: summary.chatType.rawValue.replacingOccurrences(of: "_", with: " "), tint: colors.accent)
                            if model.isLoadingSelectedChat {
                                TrixToneBadge(label: "Refreshing detail", tint: colors.rust)
                            }
                        }

                        if let detail = model.selectedChatDetail {
                            HStack(spacing: 16) {
                                TrixMetricTile(label: "Epoch", value: "\(detail.epoch)")
                                TrixMetricTile(label: "Server seq", value: "\(detail.lastServerSeq)")
                                TrixMetricTile(
                                    label: "Members",
                                    value: "\(detail.members.count)",
                                    footnote: detail.lastCommitMessageId.map { "commit \(shortID($0))" }
                                )
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Members")
                                    .font(.headline)
                                    .foregroundStyle(colors.ink)

                                ForEach(detail.members) { member in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(shortID(member.accountId))
                                                .font(.system(.subheadline, design: .monospaced))
                                                .foregroundStyle(colors.ink)
                                            Text(member.role)
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(colors.inkMuted)
                                        }
                                        Spacer()
                                        Text(member.membershipStatus)
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(colors.tileFill, in: Capsule())
                                            .foregroundStyle(colors.inkMuted)
                                    }
                                    .padding(.bottom, 2)
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading chat detail…")
                                    .foregroundStyle(colors.inkMuted)
                            }
                        }
                    }
                }

                TrixPanel(
                    title: "Encrypted History",
                    subtitle: "Raw metadata only for now. Message decryption and compose flow come next."
                ) {
                    if model.isLoadingSelectedChat && model.selectedChatHistory.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading history…")
                                .foregroundStyle(colors.inkMuted)
                        }
                    } else if model.selectedChatHistory.isEmpty {
                        EmptyWorkspaceLabel("This chat has no server-stored messages yet.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.selectedChatHistory) { message in
                                MessageHistoryRow(message: message)
                            }
                        }
                    }
                }
            } else {
                TrixPanel(
                    title: "No Chat Selected",
                    subtitle: "Once chats exist, the inspector will show membership and encrypted message envelopes here."
                ) {
                    EmptyWorkspaceLabel("Select a chat from the left rail or create one through the API to continue.")
                }
            }
        }
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }
}

private struct ChatRow: View {
    @Environment(\.trixColors) private var colors
    let chat: ChatSummary
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isSelected ? colors.accent.opacity(0.18) : colors.tileFill)
                        .frame(width: 48, height: 48)

                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? colors.accent : colors.inkMuted)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.displayTitle)
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(chat.chatType.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }

                VStack(alignment: .trailing, spacing: 6) {
                    Text("seq \(chat.lastServerSeq)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colors.inkMuted)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .background(
                isSelected ? colors.accentSoft.opacity(0.66) : colors.panel,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? colors.accent.opacity(0.26) : colors.outline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch chat.chatType {
        case .dm:
            return "person.2.fill"
        case .group:
            return "person.3.fill"
        case .accountSync:
            return "arrow.triangle.2.circlepath"
        }
    }
}

private struct MessageHistoryRow: View {
    @Environment(\.trixColors) private var colors
    let message: MessageEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("seq \(message.serverSeq) • \(message.messageKind.label)")
                        .font(.headline)
                        .foregroundStyle(colors.ink)
                    Text("sender \(message.senderShortID) • epoch \(message.epoch)")
                        .font(.subheadline)
                        .foregroundStyle(colors.inkMuted)
                }
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: .now))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.inkMuted)
            }

            HStack(spacing: 10) {
                InlineMeta(label: message.contentType.label)
                InlineMeta(label: "\(message.ciphertextSizeBytes) bytes")
                InlineMeta(label: message.aadSummary)
            }
        }
        .padding(16)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct InlineMeta: View {
    @Environment(\.trixColors) private var colors
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colors.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(colors.inputFill, in: Capsule())
    }
}

private struct EmptyWorkspaceLabel: View {
    @Environment(\.trixColors) private var colors
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(colors.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
