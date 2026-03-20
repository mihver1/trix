import SwiftUI
import UniformTypeIdentifiers

private let consumerChatAccent = Color(red: 0.14, green: 0.55, blue: 0.98)
private let consumerChatBackground = Color(red: 0.93, green: 0.97, blue: 1.0)

private struct ConsumerAttachmentDraft {
    let fileURL: URL
    let fileName: String
}

struct ConsumerChatDetailView: View {
    let chatSummary: ChatSummary
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var snapshot: ChatSnapshot?
    @State private var memberProfiles: [String: DirectoryAccountSummary] = [:]
    @State private var isLoadingSnapshot = false
    @State private var composerText = ""
    @State private var selectedAttachment: ConsumerAttachmentDraft?
    @State private var isImportingAttachment = false
    @State private var localErrorMessage: String?
    @State private var activityMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let activityMessage {
                ConsumerChatBanner(
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    text: activityMessage
                )
            }

            if let localErrorMessage {
                ConsumerChatBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: localErrorMessage
                )
            }

            if let snapshot {
                ConsumerHistorySourcePill(source: snapshot.historySource)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if snapshot.history.isEmpty {
                            ContentUnavailableView(
                                "No Messages Yet",
                                systemImage: "bubble.left.and.text.bubble.right",
                                description: Text("This conversation is ready, but there is no message history available yet.")
                            )
                            .padding(.top, 80)
                        } else {
                            ForEach(snapshot.history) { message in
                                ConsumerMessageRow(
                                    message: message,
                                    isCurrentDevice: message.senderDeviceId == model.localIdentity?.deviceId
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                }
                .background(consumerChatBackground)

                composer
            } else {
                Spacer()

                if isLoadingSnapshot {
                    ProgressView("Loading Conversation")
                } else {
                    ContentUnavailableView(
                        "Conversation Unavailable",
                        systemImage: "icloud.slash",
                        description: Text(localErrorMessage ?? "The chat snapshot could not be loaded.")
                    )
                }

                Spacer()
            }
        }
        .background(consumerChatBackground.ignoresSafeArea())
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading || isLoadingSnapshot)
            }
        }
        .task(id: chatSummary.chatId) {
            await loadSnapshot()
        }
        .refreshable {
            await loadSnapshot()
        }
        .fileImporter(
            isPresented: $isImportingAttachment,
            allowedContentTypes: [.item]
        ) { result in
            handleAttachmentImport(result)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let selectedAttachment {
                HStack(spacing: 10) {
                    Image(systemName: "paperclip.circle.fill")
                        .foregroundStyle(consumerChatAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedAttachment.fileName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        Text("Attachment ready to send")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        self.selectedAttachment = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    isImportingAttachment = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(consumerChatAccent)
                        .frame(width: 38, height: 38)
                }

                TextField(
                    selectedAttachment == nil ? "Message" : "Add a caption later",
                    text: $composerText,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button(action: sendCurrentPayload) {
                    Image(systemName: canSend ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? consumerChatAccent : .secondary)
                }
                .disabled(!canSend || model.isLoading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        selectedAttachment != nil || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var conversationTitle: String {
        resolvedConversationTitle ?? chatSummary.title ?? chatSummary.chatType.label
    }

    private var resolvedConversationTitle: String? {
        if let explicitTitle = snapshot?.detail.title?.trix_trimmedOrNil() {
            return explicitTitle
        }

        guard let detail = snapshot?.detail, detail.chatType == .dm else {
            return nil
        }

        guard let account = otherParticipantAccount(in: detail) else {
            return nil
        }

        if let handle = account.handle?.trix_trimmedOrNil() {
            return "@\(handle)"
        }

        return account.profileName
    }

    private func reload() {
        Task {
            await loadSnapshot()
        }
    }

    private func loadSnapshot() async {
        isLoadingSnapshot = true
        localErrorMessage = nil

        defer {
            isLoadingSnapshot = false
        }

        do {
            let loadedSnapshot = try await model.fetchChatSnapshot(
                baseURLString: serverBaseURL,
                chatId: chatSummary.chatId
            )
            snapshot = loadedSnapshot
            memberProfiles = await model.resolveDirectoryAccounts(
                baseURLString: serverBaseURL,
                accountIds: loadedSnapshot.detail.members.map(\.accountId)
            )
        } catch {
            memberProfiles = [:]
            localErrorMessage = error.localizedDescription
        }
    }

    private func sendCurrentPayload() {
        if selectedAttachment != nil {
            sendAttachment()
        } else {
            sendText()
        }
    }

    private func sendText() {
        guard let snapshot else {
            return
        }

        let trimmedText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        localErrorMessage = nil
        activityMessage = nil

        Task {
            let draft = DebugMessageDraft(kind: .text, text: trimmedText)
            if let response = await model.postDebugMessage(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                draft: draft
            ) {
                composerText = ""
                activityMessage = "Sent at \(response.serverSeq)"
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func sendAttachment() {
        guard let snapshot, let selectedAttachment else {
            return
        }

        localErrorMessage = nil
        activityMessage = nil

        Task {
            if let outcome = await model.postDebugAttachment(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                fileURL: selectedAttachment.fileURL
            ) {
                composerText = ""
                self.selectedAttachment = nil
                activityMessage = "Uploaded \(outcome.fileName ?? "attachment")"
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func handleAttachmentImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(fileURL):
            let fileName = fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedAttachment = ConsumerAttachmentDraft(
                fileURL: fileURL,
                fileName: fileName.isEmpty ? "Attachment" : fileName
            )
            localErrorMessage = nil
        case let .failure(error):
            localErrorMessage = error.localizedDescription
        }
    }

    private func otherParticipantAccount(in detail: ChatDetailResponse) -> DirectoryAccountSummary? {
        let currentAccountId = model.localIdentity?.accountId

        if let currentAccountId {
            for member in detail.members where member.accountId != currentAccountId {
                if let account = memberProfiles[member.accountId] {
                    return account
                }
            }
        }

        for member in detail.members {
            if let account = memberProfiles[member.accountId] {
                return account
            }
        }

        return nil
    }
}

private struct ConsumerChatBanner: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08))
    }
}

private struct ConsumerHistorySourcePill: View {
    let source: ChatHistorySource

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.85))
            .clipShape(Capsule())
    }

    private var label: String {
        switch source {
        case .localStore:
            return "Synced locally"
        case .server:
            return "Live server history"
        }
    }
}

private struct ConsumerMessageRow: View {
    let message: MessageEnvelope
    let isCurrentDevice: Bool

    var body: some View {
        HStack {
            if isCurrentDevice {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                if message.contentType != .text {
                    Label(message.contentType.label, systemImage: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrentDevice ? .white.opacity(0.9) : consumerChatAccent)
                }

                Text(message.debugPreview)
                    .font(.body)
                    .foregroundStyle(isCurrentDevice ? .white : .primary)

                if let debugDetail = message.debugDetail {
                    Text(debugDetail)
                        .font(.caption)
                        .foregroundStyle(isCurrentDevice ? .white.opacity(0.88) : .secondary)
                }

                HStack(spacing: 8) {
                    Text(message.createdAtDate.formatted(date: .omitted, time: .shortened))
                    Text("Seq \(message.serverSeq)")
                }
                .font(.caption2)
                .foregroundStyle(isCurrentDevice ? .white.opacity(0.78) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isCurrentDevice ? consumerChatAccent : .white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(isCurrentDevice ? 0.08 : 0.05), radius: 10, y: 6)

            if !isCurrentDevice {
                Spacer(minLength: 44)
            }
        }
    }

    private var iconName: String {
        switch message.contentType {
        case .text:
            return "text.bubble"
        case .attachment:
            return "paperclip"
        case .reaction:
            return "face.smiling"
        case .receipt:
            return "checkmark.circle"
        case .chatEvent:
            return "sparkles"
        }
    }
}
