import SwiftUI
import UniformTypeIdentifiers

private struct AttachmentDraftSelection {
    let fileURL: URL
    let fileName: String
    let fileSizeBytes: Int64?
}

struct ChatDetailView: View {
    let chatSummary: ChatSummary
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var snapshot: ChatSnapshot?
    @State private var memberProfiles: [String: DirectoryAccountSummary] = [:]
    @State private var isLoadingSnapshot = false
    @State private var localErrorMessage: String?
    @State private var activityMessage: String?
    @State private var messageDraft = DebugMessageDraft()
    @State private var selectedAttachment: AttachmentDraftSelection?
    @State private var isImportingAttachment = false
    @State private var addMemberAccountIds = ""
    @State private var removeMemberAccountIds = ""
    @State private var addDeviceAccountId = ""
    @State private var addDeviceIds = ""
    @State private var removeDeviceIds = ""

    var body: some View {
        List {
            if let activityMessage {
                Section("Last Action") {
                    Text(activityMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let localErrorMessage {
                Section("Error") {
                    Text(localErrorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let snapshot {
                Section("Metadata") {
                    LabeledContent("Chat ID") {
                        Text(snapshot.detail.chatId)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Type") {
                        Text(snapshot.detail.chatType.label)
                    }

                    if let title = snapshot.detail.title {
                        LabeledContent("Title") {
                            Text(title)
                        }
                    }

                    LabeledContent("Epoch") {
                        Text(String(snapshot.detail.epoch))
                    }

                    LabeledContent("Last Server Seq") {
                        Text(String(snapshot.detail.lastServerSeq))
                    }

                    if let lastCommitMessageId = snapshot.detail.lastCommitMessageId {
                        LabeledContent("Last Commit") {
                            Text(lastCommitMessageId)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Members") {
                    ForEach(snapshot.detail.members) { member in
                        VStack(alignment: .leading, spacing: 6) {
                            if let account = memberProfiles[member.accountId] {
                                Text(account.profileName)
                                    .font(.body.weight(.medium))

                                if let handle = account.handle?.trix_trimmedOrNil() {
                                    Text("@\(handle)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Text(member.accountId)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(member.accountId)
                                    .font(.system(.footnote, design: .monospaced))
                            }

                            HStack {
                                Text(member.role)
                                Spacer()
                                Text(member.membershipStatus)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Picker("Body Type", selection: $messageDraft.kind) {
                        ForEach(DebugMessageDraftKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch messageDraft.kind {
                    case .text:
                        TextField("Text body", text: $messageDraft.text, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                    case .attachment:
                        if let selectedAttachment {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(selectedAttachment.fileName)
                                    .font(.subheadline.weight(.medium))

                                if let fileSizeBytes = selectedAttachment.fileSizeBytes {
                                    Text(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        } else {
                            Text("Pick a file to encrypt, upload as a blob, and reference from an attachment message body.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button(selectedAttachment == nil ? "Choose File" : "Choose Different File") {
                            isImportingAttachment = true
                        }

                        if selectedAttachment != nil {
                            Button("Clear Selection", role: .destructive) {
                                selectedAttachment = nil
                            }
                        }
                    case .reaction:
                        TextField("Target Message ID", text: $messageDraft.targetMessageId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))

                        TextField("Emoji", text: $messageDraft.emoji)

                        Picker("Action", selection: $messageDraft.reactionAction) {
                            ForEach(DebugReactionAction.allCases) { action in
                                Text(action.rawValue.capitalized).tag(action)
                            }
                        }
                        .pickerStyle(.segmented)
                    case .receipt:
                        TextField("Target Message ID", text: $messageDraft.targetMessageId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))

                        Picker("Receipt Type", selection: $messageDraft.receiptKind) {
                            ForEach(DebugReceiptKind.allCases) { receiptKind in
                                Text(receiptKind.rawValue.capitalized).tag(receiptKind)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Receipt Timestamp (optional Unix)", text: $messageDraft.receiptAtUnix)
                            .keyboardType(.numberPad)
                    case .chatEvent:
                        TextField("Event Type", text: $messageDraft.eventType)

                        TextField("Event JSON", text: $messageDraft.eventJSON, axis: .vertical)
                            .lineLimit(4, reservesSpace: true)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                    }

                    Button(action: sendSelectedMessage) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(messageDraft.kind == .attachment ? "Upload Attachment" : "Send Typed Message")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading || !canSendSelectedMessage)
                } header: {
                    Text("Send Message")
                } footer: {
                    Text("Typed bodies are serialized through `trix-core`. Attachment mode also encrypts the file locally, uploads the blob, and sends the descriptor as a debug application payload until the real MLS conversation bridge is wired.")
                }

                Section {
                    TextField("Account IDs", text: $addMemberAccountIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))

                    Button("Add Accounts", action: addMembers)
                        .disabled(model.isLoading || chatDetailParsedIdentifiers(addMemberAccountIds).isEmpty)
                } header: {
                    Text("Add Members")
                } footer: {
                    Text("The client reserves key packages for each target account and submits placeholder commit and welcome references.")
                }

                Section {
                    TextField("Account IDs", text: $removeMemberAccountIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))

                    Button("Remove Accounts", role: .destructive, action: removeMembers)
                        .disabled(model.isLoading || chatDetailParsedIdentifiers(removeMemberAccountIds).isEmpty)
                } header: {
                    Text("Remove Members")
                } footer: {
                    Text("Account removal does not require new key package reservations, only an updated commit reference.")
                }

                Section {
                    TextField("Target Account ID", text: $addDeviceAccountId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))

                    TextField("Device IDs", text: $addDeviceIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))

                    Button("Add Devices", action: addDevices)
                        .disabled(
                            model.isLoading ||
                            addDeviceAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            chatDetailParsedIdentifiers(addDeviceIds).isEmpty
                        )
                } header: {
                    Text("Add Devices")
                } footer: {
                    Text("Use this after a new device has been approved on an existing account and has published key packages.")
                }

                Section {
                    TextField("Device IDs", text: $removeDeviceIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))

                    Button("Remove Devices", role: .destructive, action: removeDevices)
                        .disabled(model.isLoading || chatDetailParsedIdentifiers(removeDeviceIds).isEmpty)
                } header: {
                    Text("Remove Devices")
                } footer: {
                    Text("The acting device cannot remove itself through this endpoint.")
                }

                Section {
                    if snapshot.history.isEmpty {
                        Text("No \(snapshot.historySource.label.lowercased()) history for this chat yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.history) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(message.messageKind.label)
                                        .font(.headline)

                                    Spacer()

                                    Text("Seq \(message.serverSeq)")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                Text(message.debugPreview)
                                    .font(.subheadline)

                                if let debugDetail = message.debugDetail {
                                    Text(debugDetail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Text(message.messageId)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text(message.contentType.label)
                                    Spacer()
                                    Text(message.createdAtDate.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                                Text("Sender \(message.senderDeviceId)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("History (\(snapshot.historySource.label))")
                } footer: {
                    Text(snapshot.historySource.description)
                }
            } else {
                Section {
                    HStack {
                        Spacer()

                        if isLoadingSnapshot {
                            ProgressView("Loading Chat")
                        } else {
                            Text("Chat snapshot is unavailable.")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", action: reload)
                    .disabled(isLoadingSnapshot || model.isLoading)
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

    private var canSendSelectedMessage: Bool {
        if messageDraft.kind == .attachment {
            return selectedAttachment != nil
        }
        return messageDraft.canSubmit
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

    private func sendSelectedMessage() {
        if messageDraft.kind == .attachment {
            postAttachmentMessage()
        } else {
            postDebugMessage()
        }
    }

    private func postDebugMessage() {
        guard let snapshot else {
            return
        }

        let draft = messageDraft
        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let response = await model.postDebugMessage(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                draft: draft
            ) {
                messageDraft = DebugMessageDraft()
                activityMessage = "Accepted message \(response.messageId) at server sequence \(response.serverSeq)."
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func postAttachmentMessage() {
        guard let snapshot, let selectedAttachment else {
            return
        }

        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let outcome = await model.postDebugAttachment(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                fileURL: selectedAttachment.fileURL
            ) {
                messageDraft = DebugMessageDraft()
                self.selectedAttachment = nil
                activityMessage = "Uploaded \(outcome.fileName ?? "attachment") as blob \(outcome.blobId) and accepted message \(outcome.createMessage.messageId) at server sequence \(outcome.createMessage.serverSeq)."
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func addMembers() {
        guard let snapshot else {
            return
        }

        let accountIds = chatDetailParsedIdentifiers(addMemberAccountIds)
        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let response = await model.addChatMembers(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                participantAccountIds: accountIds
            ) {
                addMemberAccountIds = ""
                activityMessage = "Added \(response.changedAccountIds.count) account memberships. Chat epoch is now \(response.epoch)."
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func removeMembers() {
        guard let snapshot else {
            return
        }

        let accountIds = chatDetailParsedIdentifiers(removeMemberAccountIds)
        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let response = await model.removeChatMembers(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                participantAccountIds: accountIds
            ) {
                removeMemberAccountIds = ""
                activityMessage = "Removed \(response.changedAccountIds.count) account memberships. Chat epoch is now \(response.epoch)."
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func addDevices() {
        guard let snapshot else {
            return
        }

        let deviceIds = chatDetailParsedIdentifiers(addDeviceIds)
        let accountId = addDeviceAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let response = await model.addChatDevices(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                accountId: accountId,
                deviceIds: deviceIds
            ) {
                addDeviceAccountId = ""
                addDeviceIds = ""
                activityMessage = "Added \(response.changedDeviceIds.count) devices. Chat epoch is now \(response.epoch)."
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func removeDevices() {
        guard let snapshot else {
            return
        }

        let deviceIds = chatDetailParsedIdentifiers(removeDeviceIds)
        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let response = await model.removeChatDevices(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                deviceIds: deviceIds
            ) {
                removeDeviceIds = ""
                activityMessage = "Removed \(response.changedDeviceIds.count) devices. Chat epoch is now \(response.epoch)."
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
            let fileSizeBytes = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize

            selectedAttachment = AttachmentDraftSelection(
                fileURL: fileURL,
                fileName: fileName.isEmpty ? "Attachment" : fileName,
                fileSizeBytes: fileSizeBytes.map(Int64.init)
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

private extension ChatHistorySource {
    var label: String {
        switch self {
        case .server:
            return "Server"
        case .localStore:
            return "Local Store"
        }
    }

    var description: String {
        switch self {
        case .server:
            return "This chat is currently showing the latest server history payload."
        case .localStore:
            return "This chat is showing history cached in the persistent `trix-core` local store."
        }
    }
}

private func chatDetailParsedIdentifiers(_ rawValue: String) -> [String] {
    rawValue
        .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
