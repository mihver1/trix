package chat.trix.android.core.chat

import android.content.Context
import chat.trix.android.core.ffi.FfiChatParticipantProfile
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.ffi.FfiChatDetail
import chat.trix.android.core.ffi.FfiChatSummary
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiCreateChatControlInput
import chat.trix.android.core.ffi.FfiDirectoryAccount
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiLocalProjectedMessage
import chat.trix.android.core.ffi.FfiLocalProjectionKind
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiMessageBodyKind
import chat.trix.android.core.ffi.FfiMessageEnvelope
import chat.trix.android.core.ffi.FfiMessageKind
import chat.trix.android.core.ffi.FfiMlsConversation
import chat.trix.android.core.ffi.FfiMlsFacade
import chat.trix.android.core.ffi.FfiSendMessageInput
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiSyncCoordinator
import chat.trix.android.core.ffi.TrixFfiException
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ChatRepository(
    context: Context,
    private val session: AuthenticatedSession,
) : AutoCloseable {
    private val appContext = context.applicationContext
    private val sessionRoot = File(
        appContext.filesDir,
        "trix/accounts/${session.localState.accountId}/devices/${session.localState.deviceId}",
    )
    private val historyStorePath = File(sessionRoot, "history/local-history-v1.json")
    private val syncStatePath = File(sessionRoot, "sync/sync-state-v1.json")
    private val mlsStorageRoot = File(sessionRoot, "mls")
    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl)
    }
    private val historyStoreDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiLocalHistoryStore.newPersistent(historyStorePath.absolutePath)
    }
    private val syncCoordinatorDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiSyncCoordinator.newPersistent(syncStatePath.absolutePath)
    }
    private val mlsFacadeDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        if (mlsMetadataFile().exists() && mlsStorageFile().exists()) {
            FfiMlsFacade.loadPersistent(mlsStorageRoot.absolutePath)
        } else {
            FfiMlsFacade.newPersistent(
                session.localState.credentialIdentity,
                mlsStorageRoot.absolutePath,
            )
        }
    }

    suspend fun loadOverview(): ChatOverview = withContext(Dispatchers.IO) {
        runFfi("Failed to read local chat cache") {
            buildOverview()
        }
    }

    suspend fun loadConversation(chatId: String): ChatConversation? = withContext(Dispatchers.IO) {
        runFfi("Failed to read conversation") {
            buildConversation(chatId)
        }
    }

    suspend fun refresh(): ChatRefreshResult = withContext(Dispatchers.IO) {
        runFfi("Failed to sync chats") {
            val client = client()
            val store = historyStore()
            val syncCoordinator = syncCoordinator()

            client.setAccessToken(session.accessToken)
            val historyReport = syncCoordinator.syncChatHistoriesIntoStore(
                client = client,
                store = store,
                limitPerChat = HISTORY_SYNC_LIMIT,
            )
            val inboxOutcome = syncCoordinator.leaseInboxIntoStore(
                client = client,
                store = store,
                limit = INBOX_SYNC_LIMIT,
                leaseTtlSeconds = LEASE_TTL_SECONDS,
            )
            val hydratedChatDetails = hydrateChatDetails(client, store)
            val projectedChatTimelines = projectChatsWithLocalMlsState(store)

            ChatRefreshResult(
                overview = buildOverview(),
                historyMessagesUpserted = historyReport.messagesUpserted.toLong(),
                inboxMessagesUpserted = inboxOutcome.report.messagesUpserted.toLong(),
                ackedInboxCount = inboxOutcome.ackedInboxIds.size,
                hydratedChatDetails = hydratedChatDetails,
                projectedChatTimelines = projectedChatTimelines,
            )
        }
    }

    suspend fun searchAccountDirectory(query: String): List<ChatDirectoryAccount> = withContext(Dispatchers.IO) {
        runFfi("Failed to search account directory") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.searchAccountDirectory(
                query.trim().takeIf(String::isNotEmpty),
                DIRECTORY_SEARCH_LIMIT,
                true,
            )
                .accounts
                .map(::mapDirectoryAccount)
        }
    }

    suspend fun createDirectMessage(targetAccountId: String): ChatCreateResult = withContext(Dispatchers.IO) {
        runFfi("Failed to create direct message") {
            val client = client()
            val store = historyStore()
            val syncCoordinator = syncCoordinator()
            val facade = mlsFacade()

            client.setAccessToken(session.accessToken)
            val outcome = syncCoordinator.createChatControl(
                client = client,
                store = store,
                facade = facade,
                input = FfiCreateChatControlInput(
                    creatorAccountId = session.localState.accountId,
                    creatorDeviceId = session.localState.deviceId,
                    chatType = FfiChatType.DM,
                    title = null,
                    participantAccountIds = listOf(targetAccountId),
                    groupId = null,
                    commitAadJson = EMPTY_AAD_JSON,
                    welcomeAadJson = EMPTY_AAD_JSON,
                ),
            )

            ChatCreateResult(
                overview = buildOverview(),
                conversation = buildConversation(outcome.chatId)
                    ?: throw IOException("Conversation ${outcome.chatId} is no longer available"),
            )
        }
    }

    suspend fun sendTextMessage(chatId: String, draft: String): ChatSendResult = withContext(Dispatchers.IO) {
        val normalizedDraft = draft.trim()
        if (normalizedDraft.isEmpty()) {
            throw IOException("Message is empty")
        }

        runFfi("Failed to send message") {
            val client = client()
            val store = historyStore()
            val syncCoordinator = syncCoordinator()
            val facade = mlsFacade()

            client.setAccessToken(session.accessToken)
            val conversation = getOrCreateSendConversation(chatId)
                ?: throw IOException("Local MLS state is not available for this conversation")

            try {
                syncCoordinator.sendMessageBody(
                    client = client,
                    store = store,
                    facade = facade,
                    conversation = conversation,
                    input = FfiSendMessageInput(
                        senderAccountId = session.localState.accountId,
                        senderDeviceId = session.localState.deviceId,
                        chatId = chatId,
                        messageId = UUID.randomUUID().toString(),
                        body = FfiMessageBody(
                            kind = FfiMessageBodyKind.TEXT,
                            text = normalizedDraft,
                            targetMessageId = null,
                            emoji = null,
                            reactionAction = null,
                            receiptType = null,
                            receiptAtUnix = null,
                            blobId = null,
                            mimeType = null,
                            sizeBytes = null,
                            sha256 = null,
                            fileName = null,
                            widthPx = null,
                            heightPx = null,
                            fileKey = null,
                            nonce = null,
                            eventType = null,
                            eventJson = null,
                        ),
                        aadJson = EMPTY_AAD_JSON,
                    ),
                )

                ChatSendResult(
                    overview = buildOverview(),
                    conversation = buildConversation(chatId)
                        ?: throw IOException("Conversation $chatId is no longer available"),
                )
            } finally {
                conversation.close()
            }
        }
    }

    override fun close() {
        if (clientDelegate.isInitialized()) {
            clientDelegate.value.close()
        }
        if (historyStoreDelegate.isInitialized()) {
            historyStoreDelegate.value.close()
        }
        if (syncCoordinatorDelegate.isInitialized()) {
            syncCoordinatorDelegate.value.close()
        }
        if (mlsFacadeDelegate.isInitialized()) {
            mlsFacadeDelegate.value.close()
        }
    }

    private fun buildOverview(): ChatOverview {
        val store = historyStore()
        val syncSnapshot = syncCoordinator().stateSnapshot()
        val conversations = store.listChats().map { summary ->
            val detail = store.getChat(summary.chatId)
            val history = store.getChatHistory(summary.chatId, null, null)
            val projectedMessages = store.getProjectedMessages(summary.chatId, null, null)
            val mergedTimeline = mergeTimeline(
                historyMessages = history.messages,
                projectedMessages = projectedMessages,
            )
            val latestEntry = mergedTimeline.lastOrNull()

            ChatConversationSummary(
                chatId = summary.chatId,
                title = resolveChatTitle(summary, detail),
                participantsLabel = participantsLabel(
                    summary = summary,
                    detail = detail,
                ),
                lastMessagePreview = latestEntry?.let { entry ->
                    when (entry) {
                        is ChatTimelineEntry.Projected -> {
                            val prefix = authorLabel(entry.projected.senderAccountId)
                            "$prefix: ${projectedMessageBody(entry.projected)}"
                        }

                        is ChatTimelineEntry.EncryptedEnvelope -> {
                            val prefix = authorLabel(entry.envelope.senderAccountId)
                            "$prefix: ${rawEnvelopeBody(entry.envelope)}"
                        }
                    }
                } ?: "No messages yet",
                timestampLabel = latestEntry?.let { entry ->
                    when (entry) {
                        is ChatTimelineEntry.Projected -> entry.projected.createdAtUnix.toLong().formatChatTimestamp()
                        is ChatTimelineEntry.EncryptedEnvelope -> entry.envelope.createdAtUnix.toLong().formatChatTimestamp()
                    }
                } ?: "Pending",
                messageCount = mergedTimeline.size,
                hasProjectedTimeline = projectedMessages.isNotEmpty(),
                isAccountSyncChat = summary.chatId == session.localState.accountSyncChatId,
            )
        }

        return ChatOverview(
            conversations = conversations,
            diagnostics = ChatDiagnostics(
                cachedChatCount = conversations.size,
                cachedMessageCount = conversations.sumOf { it.messageCount },
                projectedChatCount = conversations.count { it.hasProjectedTimeline },
                lastAckedInboxId = syncSnapshot.lastAckedInboxId?.toLong(),
                leaseOwner = syncSnapshot.leaseOwner,
                historyStorePath = store.databasePath(),
                syncStatePath = syncCoordinator().statePath(),
            ),
        )
    }

    private fun buildConversation(chatId: String): ChatConversation? {
        val store = historyStore()
        val detail = store.getChat(chatId) ?: return null
        val history = store.getChatHistory(chatId, null, null)
        val projectedMessages = store.getProjectedMessages(chatId, null, null)
        val mergedTimeline = mergeTimeline(
            historyMessages = history.messages,
            projectedMessages = projectedMessages,
        )
        val hasLocalMlsState = hasLocalConversation(chatId)
        val canSend = detail.chatType == FfiChatType.ACCOUNT_SYNC || hasLocalMlsState
        val messages = mergedTimeline.map { message ->
            when (message) {
                is ChatTimelineEntry.Projected -> ChatTimelineMessage(
                    id = message.projected.messageId,
                    author = authorLabel(message.projected.senderAccountId),
                    body = projectedMessageBody(message.projected),
                    timestampLabel = message.projected.createdAtUnix.toLong().formatChatTimestamp(),
                    isMine = message.projected.senderAccountId == session.localState.accountId,
                    note = projectedMessageNote(message.projected),
                )

                is ChatTimelineEntry.EncryptedEnvelope -> ChatTimelineMessage(
                    id = message.envelope.messageId,
                    author = authorLabel(message.envelope.senderAccountId),
                    body = rawEnvelopeBody(message.envelope),
                    timestampLabel = message.envelope.createdAtUnix.toLong().formatChatTimestamp(),
                    isMine = message.envelope.senderAccountId == session.localState.accountId,
                    note = "Encrypted envelope cached locally",
                )
            }
        }

        return ChatConversation(
            chatId = chatId,
            title = resolveChatTitle(
                summary = FfiChatSummary(
                    chatId = detail.chatId,
                    chatType = detail.chatType,
                    title = detail.title,
                    lastServerSeq = detail.lastServerSeq,
                    participantProfiles = detail.participantProfiles,
                ),
                detail = detail,
            ),
            participantsLabel = participantsLabel(
                summary = FfiChatSummary(
                    chatId = detail.chatId,
                    chatType = detail.chatType,
                    title = detail.title,
                    lastServerSeq = detail.lastServerSeq,
                    participantProfiles = detail.participantProfiles,
                ),
                detail = detail,
            ),
            timelineLabel = when {
                projectedMessages.isEmpty() -> "Encrypted cache only"
                projectedMessages.size == mergedTimeline.size -> "Projected timeline"
                else -> "Mixed local timeline"
            },
            isAccountSyncChat = chatId == session.localState.accountSyncChatId,
            canSend = canSend,
            composerHint = when {
                detail.chatType == FfiChatType.ACCOUNT_SYNC -> {
                    "Messages use this device's local MLS state for the account sync thread."
                }

                canSend -> "Send through the local MLS state already present on this device."
                else -> "Sending is disabled until this device has local MLS state for this chat."
            },
            messages = messages,
        )
    }

    private fun hydrateChatDetails(
        client: FfiServerApiClient,
        store: FfiLocalHistoryStore,
    ): Int {
        var changedChats = 0
        store.listChats().forEach { summary ->
            val detail = client.getChat(summary.chatId)
            changedChats += store.applyChatDetail(detail).chatsUpserted.toInt()
        }
        return changedChats
    }

    private fun projectChatsWithLocalMlsState(store: FfiLocalHistoryStore): Int {
        val facade = mlsFacade()
        var projectedChatTimelines = 0

        store.listChats().forEach { summary ->
            val conversation = try {
                loadLocalConversation(summary.chatId)
            } catch (_: TrixFfiException) {
                null
            }

            if (conversation == null) {
                return@forEach
            }

            try {
                try {
                    store.projectChatMessages(summary.chatId, facade, conversation, null)
                } catch (_: TrixFfiException) {
                    return@forEach
                }

                if (store.getProjectedMessages(summary.chatId, null, 1u).isNotEmpty()) {
                    projectedChatTimelines += 1
                }
            } finally {
                conversation.close()
            }
        }

        return projectedChatTimelines
    }

    private fun getOrCreateSendConversation(chatId: String): FfiMlsConversation? {
        val existing = loadLocalConversation(chatId)
        if (existing != null) {
            return existing
        }
        if (chatId != session.localState.accountSyncChatId) {
            return null
        }
        val groupId = resolveChatGroupId(chatId) ?: return null
        return mlsFacade().createGroup(groupId)
    }

    private fun hasLocalConversation(chatId: String): Boolean {
        val conversation = loadLocalConversation(chatId) ?: return false
        conversation.close()
        return true
    }

    private fun loadLocalConversation(chatId: String): FfiMlsConversation? {
        val groupId = resolveChatGroupId(chatId) ?: return null
        return mlsFacade().loadGroup(groupId)
    }

    private fun resolveChatGroupId(chatId: String): ByteArray? {
        val store = historyStore()
        store.chatMlsGroupId(chatId)?.let { return it }
        if (chatId != session.localState.accountSyncChatId) {
            return null
        }

        val fallback = stableLocalGroupId(chatId)
        store.setChatMlsGroupId(chatId, fallback)
        return fallback
    }

    private fun stableLocalGroupId(chatId: String): ByteArray {
        return runCatching {
            val uuid = UUID.fromString(chatId)
            ByteBuffer.allocate(16)
                .putLong(uuid.mostSignificantBits)
                .putLong(uuid.leastSignificantBits)
                .array()
        }.getOrElse {
            chatId.encodeToByteArray()
        }
    }

    private fun client(): FfiServerApiClient = clientDelegate.value

    private fun historyStore(): FfiLocalHistoryStore = historyStoreDelegate.value

    private fun syncCoordinator(): FfiSyncCoordinator = syncCoordinatorDelegate.value

    private fun mlsFacade(): FfiMlsFacade = mlsFacadeDelegate.value

    private fun mlsMetadataFile(): File = File(mlsStorageRoot, "metadata.json")

    private fun mlsStorageFile(): File = File(mlsStorageRoot, "storage.json")

    private inline fun <T> runFfi(
        fallbackMessage: String,
        block: () -> T,
    ): T {
        return try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: TrixFfiException) {
            throw IOException(error.message ?: fallbackMessage, error)
        } catch (error: UnsatisfiedLinkError) {
            throw IOException("Rust FFI library is not available in the Android app bundle", error)
        } catch (error: RuntimeException) {
            throw IOException(fallbackMessage, error)
        }
    }

    private fun resolveChatTitle(
        summary: FfiChatSummary,
        detail: FfiChatDetail?,
    ): String {
        val explicitTitle = detail?.title?.takeIf(String::isNotBlank)
            ?: summary.title?.takeIf(String::isNotBlank)
        if (explicitTitle != null) {
            return explicitTitle
        }

        return when (detail?.chatType ?: summary.chatType) {
            FfiChatType.DM -> {
                participantProfiles(summary, detail)
                    .firstOrNull { it.accountId != session.localState.accountId }
                    ?.let(::participantDisplayName)
                    ?.let { "DM with $it" }
                    ?: detail?.members
                        ?.asSequence()
                        ?.map { it.accountId }
                        ?.firstOrNull { it != session.localState.accountId }
                        ?.let(::shortAccountId)
                        ?.let { "DM with $it" }
                    ?: "Direct message"
            }

            FfiChatType.GROUP -> "Group chat"
            FfiChatType.ACCOUNT_SYNC -> "Account sync"
        }
    }

    private fun participantsLabel(
        summary: FfiChatSummary,
        detail: FfiChatDetail?,
    ): String {
        val profiles = participantProfiles(summary, detail)
        if (profiles.isNotEmpty()) {
            val visibleMembers = profiles
                .take(MAX_VISIBLE_MEMBERS)
                .joinToString(", ", transform = ::participantDisplayName)
            val remainder = profiles.size - MAX_VISIBLE_MEMBERS
            return if (remainder > 0) {
                "$visibleMembers +$remainder"
            } else {
                visibleMembers
            }
        }

        val members = detail?.members.orEmpty()
        if (members.isEmpty()) {
            return when (detail?.chatType ?: summary.chatType) {
                FfiChatType.ACCOUNT_SYNC -> "Private cross-device sync channel"
                FfiChatType.GROUP -> "Member metadata pending"
                else -> "Member metadata pending"
            }
        }

        val visibleMembers = members
            .take(MAX_VISIBLE_MEMBERS)
            .joinToString(", ") { member ->
                if (member.accountId == session.localState.accountId) {
                    "You"
                } else {
                    shortAccountId(member.accountId)
                }
            }
        val remainder = members.size - MAX_VISIBLE_MEMBERS
        return if (remainder > 0) {
            "$visibleMembers +$remainder"
        } else {
            visibleMembers
        }
    }

    private fun participantProfiles(
        summary: FfiChatSummary,
        detail: FfiChatDetail?,
    ): List<FfiChatParticipantProfile> {
        return detail?.participantProfiles?.takeIf(List<FfiChatParticipantProfile>::isNotEmpty)
            ?: summary.participantProfiles
    }

    private fun participantDisplayName(profile: FfiChatParticipantProfile): String {
        if (profile.accountId == session.localState.accountId) {
            return "You"
        }
        return profile.profileName.takeIf(String::isNotBlank)
            ?: profile.handle?.takeIf(String::isNotBlank)?.let { "@$it" }
            ?: shortAccountId(profile.accountId)
    }

    private fun authorLabel(accountId: String): String {
        return if (accountId == session.localState.accountId) {
            "You"
        } else {
            shortAccountId(accountId)
        }
    }

    private fun mapDirectoryAccount(account: FfiDirectoryAccount): ChatDirectoryAccount {
        return ChatDirectoryAccount(
            accountId = account.accountId,
            handle = account.handle,
            profileName = account.profileName,
            profileBio = account.profileBio,
        )
    }

    private fun projectedMessageBody(message: FfiLocalProjectedMessage): String {
        val body = message.body
        if (body != null) {
            return structuredBodyText(body)
        }

        val fallbackText = if (message.contentType == FfiContentType.TEXT) {
            message.payload
                ?.decodeToString()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
        } else {
            null
        }
        return fallbackText
            ?: message.bodyParseError
            ?: when (message.projectionKind) {
                FfiLocalProjectionKind.APPLICATION_MESSAGE -> "Encrypted application payload"
                FfiLocalProjectionKind.PROPOSAL_QUEUED -> "MLS proposal queued"
                FfiLocalProjectionKind.COMMIT_MERGED -> "MLS commit merged"
                FfiLocalProjectionKind.WELCOME_REF -> "Welcome reference"
                FfiLocalProjectionKind.SYSTEM -> "System event"
            }
    }

    private fun structuredBodyText(body: FfiMessageBody): String {
        return when (body.kind) {
            FfiMessageBodyKind.TEXT -> body.text ?: "Text message"
            FfiMessageBodyKind.REACTION -> "Reacted ${body.emoji.orEmpty()} to ${body.targetMessageId?.let(::shortMessageId) ?: "message"}"
            FfiMessageBodyKind.RECEIPT -> "${body.receiptType?.name?.lowercase()?.replaceFirstChar(Char::uppercase) ?: "Delivery"} receipt"
            FfiMessageBodyKind.ATTACHMENT -> body.fileName ?: body.mimeType ?: "Attachment"
            FfiMessageBodyKind.CHAT_EVENT -> body.eventType ?: "Chat event"
        }
    }

    private fun projectedMessageNote(message: FfiLocalProjectedMessage): String? {
        if (message.bodyParseError != null) {
            return message.bodyParseError
        }

        return when (message.projectionKind) {
            FfiLocalProjectionKind.APPLICATION_MESSAGE -> null
            FfiLocalProjectionKind.PROPOSAL_QUEUED -> "MLS proposal queued"
            FfiLocalProjectionKind.COMMIT_MERGED -> {
                message.mergedEpoch?.let { "MLS commit merged at epoch ${it.toLong()}" }
                    ?: "MLS commit merged"
            }

            FfiLocalProjectionKind.WELCOME_REF -> "Welcome reference"
            FfiLocalProjectionKind.SYSTEM -> "System event"
        }
    }

    private fun rawEnvelopeBody(envelope: FfiMessageEnvelope): String {
        val contentLabel = when (envelope.contentType) {
            FfiContentType.TEXT -> "encrypted text message"
            FfiContentType.REACTION -> "encrypted reaction"
            FfiContentType.RECEIPT -> "encrypted receipt"
            FfiContentType.ATTACHMENT -> "encrypted attachment"
            FfiContentType.CHAT_EVENT -> "encrypted chat event"
        }

        return when (envelope.messageKind) {
            FfiMessageKind.APPLICATION -> contentLabel.replaceFirstChar(Char::uppercase)
            FfiMessageKind.COMMIT -> "MLS commit"
            FfiMessageKind.WELCOME_REF -> "Welcome reference"
            FfiMessageKind.SYSTEM -> "System message"
        }
    }

    private fun shortAccountId(accountId: String): String {
        return if (accountId.length <= 10) {
            accountId
        } else {
            "${accountId.take(6)}…${accountId.takeLast(4)}"
        }
    }

    private fun shortMessageId(messageId: String): String {
        return if (messageId.length <= 10) {
            messageId
        } else {
            "${messageId.take(6)}…"
        }
    }

    private fun Long.formatChatTimestamp(): String {
        val zoneId = ZoneId.systemDefault()
        val messageTime = Instant.ofEpochSecond(this).atZone(zoneId)
        val now = ZonedDateTime.now(zoneId)
        return when {
            messageTime.toLocalDate() == now.toLocalDate() -> TIME_FORMATTER.format(messageTime)
            messageTime.year == now.year -> MONTH_DAY_FORMATTER.format(messageTime)
            else -> DATE_FORMATTER.format(messageTime)
        }
    }

    private fun mergeTimeline(
        historyMessages: List<FfiMessageEnvelope>,
        projectedMessages: List<FfiLocalProjectedMessage>,
    ): List<ChatTimelineEntry> {
        val historyByServerSeq = historyMessages.associateBy { it.serverSeq }
        val projectedByServerSeq = projectedMessages.associateBy { it.serverSeq }
        return (historyByServerSeq.keys + projectedByServerSeq.keys)
            .sorted()
            .mapNotNull { serverSeq ->
                projectedByServerSeq[serverSeq]?.let(ChatTimelineEntry::Projected)
                    ?: historyByServerSeq[serverSeq]?.let(ChatTimelineEntry::EncryptedEnvelope)
            }
    }

    companion object {
        private const val MAX_VISIBLE_MEMBERS = 3
        private val DIRECTORY_SEARCH_LIMIT = 20u
        private val HISTORY_SYNC_LIMIT = 200u
        private val INBOX_SYNC_LIMIT = 100u
        private val LEASE_TTL_SECONDS = 60uL
        private val TIME_FORMATTER = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        private val MONTH_DAY_FORMATTER = DateTimeFormatter.ofPattern("MMM d")
        private val DATE_FORMATTER = DateTimeFormatter.ofPattern("MMM d, yyyy")
        private const val EMPTY_AAD_JSON = "{}"
    }
}

private sealed interface ChatTimelineEntry {
    data class Projected(
        val projected: FfiLocalProjectedMessage,
    ) : ChatTimelineEntry

    data class EncryptedEnvelope(
        val envelope: FfiMessageEnvelope,
    ) : ChatTimelineEntry
}

data class ChatOverview(
    val conversations: List<ChatConversationSummary>,
    val diagnostics: ChatDiagnostics,
)

data class ChatDiagnostics(
    val cachedChatCount: Int,
    val cachedMessageCount: Int,
    val projectedChatCount: Int,
    val lastAckedInboxId: Long?,
    val leaseOwner: String,
    val historyStorePath: String?,
    val syncStatePath: String?,
)

data class ChatRefreshResult(
    val overview: ChatOverview,
    val historyMessagesUpserted: Long,
    val inboxMessagesUpserted: Long,
    val ackedInboxCount: Int,
    val hydratedChatDetails: Int,
    val projectedChatTimelines: Int,
)

data class ChatSendResult(
    val overview: ChatOverview,
    val conversation: ChatConversation,
)

data class ChatCreateResult(
    val overview: ChatOverview,
    val conversation: ChatConversation,
)

data class ChatDirectoryAccount(
    val accountId: String,
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
)

data class ChatConversationSummary(
    val chatId: String,
    val title: String,
    val participantsLabel: String,
    val lastMessagePreview: String,
    val timestampLabel: String,
    val messageCount: Int,
    val hasProjectedTimeline: Boolean,
    val isAccountSyncChat: Boolean,
)

data class ChatConversation(
    val chatId: String,
    val title: String,
    val participantsLabel: String,
    val timelineLabel: String,
    val isAccountSyncChat: Boolean,
    val canSend: Boolean,
    val composerHint: String,
    val messages: List<ChatTimelineMessage>,
)

data class ChatTimelineMessage(
    val id: String,
    val author: String,
    val body: String,
    val timestampLabel: String,
    val isMine: Boolean,
    val note: String?,
)
