import SwiftUI

struct ChatDetailView: View {
    let chatSummary: ChatSummary
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var snapshot: ChatSnapshot?
    @State private var isLoadingSnapshot = false
    @State private var localErrorMessage: String?
    @State private var activityMessage: String?
    @State private var messageText = ""
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
                            Text(member.accountId)
                                .font(.system(.footnote, design: .monospaced))

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
                    TextField("Write a debug plaintext message", text: $messageText, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)

                    Button(action: postDebugMessage) {
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Send Debug Message")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isLoading || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Send Message")
                } footer: {
                    Text("This PoC stores the plaintext as a base64-encoded debug payload so the server history flow can be exercised without an MLS bridge.")
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

                Section("History") {
                    if snapshot.history.isEmpty {
                        Text("No server history for this chat yet.")
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
        .navigationTitle(chatSummary.title ?? chatSummary.chatType.label)
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
            snapshot = try await model.fetchChatSnapshot(
                baseURLString: serverBaseURL,
                chatId: chatSummary.chatId
            )
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func postDebugMessage() {
        guard let snapshot else {
            return
        }

        let plaintext = messageText
        activityMessage = nil
        localErrorMessage = nil

        Task {
            if let response = await model.postDebugMessage(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                plaintext: plaintext
            ) {
                messageText = ""
                activityMessage = "Accepted message \(response.messageId) at server sequence \(response.serverSeq)."
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
}

private func chatDetailParsedIdentifiers(_ rawValue: String) -> [String] {
    rawValue
        .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
