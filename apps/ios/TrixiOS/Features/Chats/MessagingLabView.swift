import SwiftUI

private struct CreateChatDraft {
    var chatType: ChatType = .dm
    var title = ""
    var participantAccountIds = ""
}

struct MessagingLabView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var createChatDraft = CreateChatDraft()
    @State private var activityMessage: String?

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

                    Button(action: publishDebugKeyPackages) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Publish 5 Debug Key Packages")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading)
                } header: {
                    Text("Debug Key Packages")
                } footer: {
                    Text("Chat creation and device membership flows require published key packages on the target devices. This PoC publishes placeholder payloads under the server test cipher suite.")
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
                    Text("Inbox rows are fan-out records for this device. Acknowledging them only clears the local server queue, not the underlying chat history.")
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

    private func publishDebugKeyPackages() {
        activityMessage = nil

        Task {
            if let response = await model.publishDebugKeyPackages(baseURLString: serverBaseURL) {
                activityMessage = "Published \(response.packages.count) debug key packages for device \(response.deviceId)."
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
}

private func parsedIdentifiers(_ rawValue: String) -> [String] {
    rawValue
        .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
