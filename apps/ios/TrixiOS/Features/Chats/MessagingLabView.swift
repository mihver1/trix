import SwiftUI

private struct CreateChatDraft {
    var chatType: ChatType = .dm
    var title = ""
    var participantAccountIds = ""
}

private struct KeyPackageDebugDraft {
    var accountId = ""
    var deviceIds = ""
}

struct MessagingLabView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var createChatDraft = CreateChatDraft()
    @State private var keyPackageDebugDraft = KeyPackageDebugDraft()
    @State private var activityMessage: String?
    @State private var leasedInboxBatch: LeaseInboxResponse?
    @State private var localInboxSync: LocalInboxSyncResult?
    @State private var inspectedKeyPackages: AccountKeyPackagesResponse?

    var body: some View {
        List {
            if let activityMessage {
                Section("Last Action") {
                    Text(activityMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = model.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let dashboard = model.dashboard {
                Section {
                    if let localIdentity = model.localIdentity {
                        LabeledContent("Current Device") {
                            Text(localIdentity.deviceId)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    Button(action: publishKeyPackages) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Publish 5 MLS Key Packages")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)
                } header: {
                    Text("MLS Key Packages")
                } footer: {
                    Text("Key packages now come from the persistent `trix-core` MLS facade stored on-device. Chat creation and membership flows can reserve these packages from the server.")
                }

                Section {
                    TextField(
                        "Account ID",
                        text: Binding(
                            get: {
                                if keyPackageDebugDraft.accountId.isEmpty {
                                    return dashboard.profile.accountId
                                }
                                return keyPackageDebugDraft.accountId
                            },
                            set: { keyPackageDebugDraft.accountId = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))

                    TextField(
                        "Target Device IDs (comma or newline separated)",
                        text: $keyPackageDebugDraft.deviceIds,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3, reservesSpace: true)
                    .font(.system(.footnote, design: .monospaced))

                    Button(action: loadReservedKeyPackages) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Load Reserved Packages")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)

                    Button(action: reserveKeyPackages) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Reserve Packages For Device IDs")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading || parsedIdentifiers(keyPackageDebugDraft.deviceIds).isEmpty)

                    Button(action: dryRunGroupCommit) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Dry-Run MLS Group Commit")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading || (inspectedKeyPackages?.packages.isEmpty ?? true))

                    if let inspectedKeyPackages {
                        LabeledContent("Reserved Packages") {
                            Text(String(inspectedKeyPackages.packages.count))
                        }

                        ForEach(inspectedKeyPackages.packages.prefix(8)) { package in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(package.deviceId)
                                    .font(.system(.footnote, design: .monospaced))

                                Text(package.keyPackageId)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)

                                Text(package.cipherSuite)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Reserved Key Packages")
                } footer: {
                    Text("Use this to inspect or reserve server-held MLS key packages through `trix-core`, then dry-run a detached local group commit against those packages.")
                }

                Section {
                    Button(action: syncChatHistoriesIntoLocalStore) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sync Histories Into Local Store")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)

                    Button(action: leaseInboxIntoLocalStore) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Lease Inbox Into Local Store")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)

                    if let localCoreState = model.localCoreState {
                        LabeledContent("Cipher Suite") {
                            Text(localCoreState.ciphersuiteLabel)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("Local Chats") {
                            Text(String(localCoreState.localChats.count))
                        }

                        LabeledContent("Lease Owner") {
                            Text(localCoreState.leaseOwner)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("Inbox Cursor") {
                            Text(localCoreState.lastAckedInboxId.map(String.init) ?? "None")
                        }

                        if let localInboxSync {
                            LabeledContent("Last Lease Acked") {
                                Text(String(localInboxSync.ackedInboxIds.count))
                            }

                            LabeledContent("Lease Expires") {
                                Text(localInboxSync.leaseExpiresAtDate.formatted(date: .abbreviated, time: .standard))
                            }
                        }

                        if !localCoreState.chatCursors.isEmpty {
                            ForEach(localCoreState.chatCursors.prefix(5)) { cursor in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cursor.chatId)
                                        .font(.system(.footnote, design: .monospaced))
                                    Text("Cursor \(cursor.lastServerSeq)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } else {
                        Text("Persistent `trix-core` state will be created on first MLS publish or sync.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Local Core Store")
                } footer: {
                    Text("This is the on-device `trix-core` cache for MLS state, chat history, and inbox sync cursors. Chat detail prefers local history after you sync it here.")
                }

                Section {
                    Picker("Chat Type", selection: $createChatDraft.chatType) {
                        Text(ChatType.dm.label).tag(ChatType.dm)
                        Text(ChatType.group.label).tag(ChatType.group)
                    }
                    .pickerStyle(.segmented)

                    if createChatDraft.chatType == .group {
                        TextField("Group Title (optional)", text: $createChatDraft.title)
                    }

                    TextField("Participant Account IDs", text: $createChatDraft.participantAccountIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))

                    Button(action: createChat) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Create Chat")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading || parsedIdentifiers(createChatDraft.participantAccountIds).isEmpty)
                } header: {
                    Text("Create Chat")
                } footer: {
                    Text("Use one peer account ID for a DM, or multiple account IDs for a group. The client will reserve key packages for those accounts automatically.")
                }

                Section("Chats") {
                    if dashboard.chats.isEmpty {
                        Text("No chats visible to this device yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dashboard.chats) { chat in
                            NavigationLink {
                                ChatDetailView(
                                    chatSummary: chat,
                                    serverBaseURL: $serverBaseURL,
                                    model: model
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(chat.title ?? chat.chatType.label)
                                        .font(.headline)

                                    Text(chat.chatId)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.secondary)

                                    HStack {
                                        Text(chat.chatType.label)
                                        Spacer()
                                        Text("Last Seq \(chat.lastServerSeq)")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                Section {
                    Button(action: pollInboxIncremental) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Poll Inbox Incrementally")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)

                    Button(action: leaseInboxBatch) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Lease Inbox Batch")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)

                    if let leasedInboxBatch {
                        LabeledContent("Lease Owner") {
                            Text(leasedInboxBatch.leaseOwner)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("Lease Expires") {
                            Text(leasedInboxBatch.leaseExpiresAtDate.formatted(date: .abbreviated, time: .standard))
                        }

                        LabeledContent("Leased Items") {
                            Text(String(leasedInboxBatch.items.count))
                        }
                    }

                    if !dashboard.inboxItems.isEmpty {
                        Button(action: acknowledgeAllInbox) {
                            if model.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Acknowledge All Inbox Items")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(model.isLoading)
                    }

                    if dashboard.inboxItems.isEmpty {
                        Text("No pending inbox items for this device.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dashboard.inboxItems) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.message.messageKind.label)
                                        .font(.headline)

                                    Spacer()

                                    Text("#\(item.inboxId)")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                Text(item.message.debugPreview)
                                    .font(.subheadline)

                                if let debugDetail = item.message.debugDetail {
                                    Text(debugDetail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Text(item.message.chatId)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text(item.message.createdAtDate.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Ack") {
                                        acknowledgeInbox(ids: [item.inboxId])
                                    }
                                    .disabled(model.isLoading)
                                }
                                .font(.footnote)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Inbox")
                } footer: {
                    Text("Inbox rows are fan-out records for this device. Incremental polling uses `after_inbox_id`. Leasing is a debug worker-style path that claims temporary delivery ownership until the lease expires or the items are acknowledged.")
                }
            } else {
                Section {
                    if model.isLoading {
                        ProgressView("Loading Messaging State")
                    } else {
                        Text("Messaging state is unavailable until the device is authenticated.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Messaging")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", action: reload)
                    .disabled(model.isLoading)
            }
        }
    }

    private func reload() {
        activityMessage = nil

        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }

    private func publishKeyPackages() {
        activityMessage = nil

        Task {
            if let response = await model.publishKeyPackages(baseURLString: serverBaseURL) {
                activityMessage = "Published \(response.packages.count) MLS key packages for device \(response.deviceId)."
            }
        }
    }

    private func syncChatHistoriesIntoLocalStore() {
        activityMessage = nil

        Task {
            if let result = await model.syncChatHistoriesIntoLocalStore(baseURLString: serverBaseURL) {
                activityMessage = "Local history sync upserted \(result.chatsUpserted) chats and \(result.messagesUpserted) messages."
            }
        }
    }

    private func leaseInboxIntoLocalStore() {
        activityMessage = nil
        localInboxSync = nil

        Task {
            if let result = await model.leaseInboxIntoLocalStore(baseURLString: serverBaseURL) {
                localInboxSync = result
                activityMessage = "Leased, applied, and acknowledged \(result.ackedInboxIds.count) inbox items into the local store."
            }
        }
    }

    private func pollInboxIncremental() {
        activityMessage = nil

        Task {
            if let response = await model.pollInboxIncremental(baseURLString: serverBaseURL) {
                activityMessage = "Incremental inbox poll returned \(response.items.count) items."
            }
        }
    }

    private func leaseInboxBatch() {
        activityMessage = nil
        leasedInboxBatch = nil

        Task {
            if let response = await model.leaseInboxBatch(baseURLString: serverBaseURL) {
                leasedInboxBatch = response
                activityMessage = "Leased \(response.items.count) inbox items to \(response.leaseOwner)."
            }
        }
    }

    private func createChat() {
        activityMessage = nil

        let participantAccountIds = parsedIdentifiers(createChatDraft.participantAccountIds)

        Task {
            if let response = await model.createChat(
                baseURLString: serverBaseURL,
                chatType: createChatDraft.chatType,
                title: createChatDraft.title,
                participantAccountIds: participantAccountIds
            ) {
                createChatDraft = CreateChatDraft()
                activityMessage = "Created \(response.chatType.label) chat \(response.chatId) at epoch \(response.epoch)."
            }
        }
    }

    private func loadReservedKeyPackages() {
        activityMessage = nil
        let accountId = effectiveKeyPackageAccountId()

        Task {
            if let response = await model.fetchAccountKeyPackages(
                baseURLString: serverBaseURL,
                accountId: accountId
            ) {
                inspectedKeyPackages = response
                activityMessage = "Loaded \(response.packages.count) reserved packages for account \(response.accountId)."
            }
        }
    }

    private func reserveKeyPackages() {
        activityMessage = nil
        let accountId = effectiveKeyPackageAccountId()
        let deviceIds = parsedIdentifiers(keyPackageDebugDraft.deviceIds)

        Task {
            if let response = await model.reserveAccountKeyPackages(
                baseURLString: serverBaseURL,
                accountId: accountId,
                deviceIds: deviceIds
            ) {
                inspectedKeyPackages = response
                activityMessage = "Reserved \(response.packages.count) packages for \(deviceIds.count) device IDs."
            }
        }
    }

    private func dryRunGroupCommit() {
        activityMessage = nil
        guard let reservedPackages = inspectedKeyPackages?.packages else {
            return
        }

        Task {
            if let epoch = await model.dryRunReservedKeyPackageCommit(
                reservedPackages: reservedPackages
            ) {
                activityMessage = "Dry-run MLS commit produced epoch \(epoch) using \(reservedPackages.count) reserved packages."
            }
        }
    }

    private func effectiveKeyPackageAccountId() -> String {
        let trimmed = keyPackageDebugDraft.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return model.dashboard?.profile.accountId ?? ""
    }

    private func acknowledgeAllInbox() {
        guard let dashboard = model.dashboard else {
            return
        }

        acknowledgeInbox(ids: dashboard.inboxItems.map(\.inboxId))
    }

    private func acknowledgeInbox(ids: [UInt64]) {
        activityMessage = nil

        Task {
            if let response = await model.acknowledgeInbox(
                baseURLString: serverBaseURL,
                inboxIds: ids
            ) {
                activityMessage = "Acknowledged \(response.ackedInboxIds.count) inbox items."
            }
        }
    }
}

extension ChatType {
    var label: String {
        switch self {
        case .dm:
            return "DM"
        case .group:
            return "Group"
        case .accountSync:
            return "Account Sync"
        }
    }
}

extension MessageKind {
    var label: String {
        switch self {
        case .application:
            return "Application"
        case .commit:
            return "Commit"
        case .welcomeRef:
            return "Welcome Ref"
        case .system:
            return "System"
        }
    }
}

extension ContentType {
    var label: String {
        switch self {
        case .text:
            return "Text"
        case .reaction:
            return "Reaction"
        case .receipt:
            return "Receipt"
        case .attachment:
            return "Attachment"
        case .chatEvent:
            return "Chat Event"
        }
    }
}

extension MessageEnvelope {
    var debugPreview: String {
        if let preview = TrixCoreMessageBridge.preview(for: self) {
            return preview.title
        }

        if let data = Data(base64Encoded: ciphertextB64),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }

        if case let .object(values) = aadJson,
           case let .string(text)? = values["debug_plaintext"] {
            return text
        }

        return ciphertextB64
    }

    var debugDetail: String? {
        TrixCoreMessageBridge.preview(for: self)?.detail
    }
}

private func parsedIdentifiers(_ rawValue: String) -> [String] {
    rawValue
        .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
