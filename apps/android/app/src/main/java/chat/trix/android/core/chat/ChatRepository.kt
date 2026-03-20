package chat.trix.android.core.chat

import android.content.Context
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.ffi.FfiChatDetail
import chat.trix.android.core.ffi.FfiChatHistory
import chat.trix.android.core.ffi.FfiChatSummary
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiLocalProjectedMessage
import chat.trix.android.core.ffi.FfiLocalProjectionKind
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiMessageBodyKind
import chat.trix.android.core.ffi.FfiMessageEnvelope
import chat.trix.android.core.ffi.FfiMessageKind
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiSyncCoordinator
import chat.trix.android.core.ffi.TrixFfiException
import java.io.File
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
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
    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl)
    }
    private val historyStoreDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiLocalHistoryStore.newPersistent(historyStorePath.absolutePath)
    }
    private val syncCoordinatorDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiSyncCoordinator.newPersistent(syncStatePath.absolutePath)
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

            ChatRefreshResult(
                overview = buildOverview(),
                historyMessagesUpserted = historyReport.messagesUpserted.toLong(),
                inboxMessagesUpserted = inboxOutcome.report.messagesUpserted.toLong(),
                ackedInboxCount = inboxOutcome.ackedInboxIds.size,
                hydratedChatDetails = hydratedChatDetails,
            )
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
    }

    private fun buildOverview(): ChatOverview {
        val store = historyStore()
        val syncSnapshot = syncCoordinator().stateSnapshot()
        val conversations = store.listChats().map { summary ->
            val detail = store.getChat(summary.chatId)
            val history = store.getChatHistory(summary.chatId, null, null)
            val projectedMessages = store.getProjectedMessages(summary.chatId, null, null)
            val latestProjected = projectedMessages.lastOrNull()
            val latestEnvelope = history.messages.lastOrNull()
            ChatConversationSummary(
                chatId = summary.chatId,
                title = resolveChatTitle(summary, detail),
                participantsLabel = participantsLabel(detail),
                lastMessagePreview = previewFor(
                    projectedMessage = latestProjected,
                    envelope = latestEnvelope,
                ),
                timestampLabel = timestampLabelFor(
                    projectedMessage = latestProjected,
                    envelope = latestEnvelope,
                ),
                messageCount = maxOf(projectedMessages.size, history.messages.size),
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
        val timelineMessages = if (projectedMessages.isNotEmpty()) {
            projectedMessages.map { projected ->
                ChatTimelineMessage(
                    id = projected.messageId,
                    author = authorLabel(projected.senderAccountId),
                    body = projectedMessageBody(projected),
                    timestampLabel = projected.createdAtUnix.toLong().formatChatTimestamp(),
                    isMine = projected.senderAccountId == session.localState.accountId,
                    note = projectedMessageNote(projected),
                )
            }
        } else {
            history.messages.map { envelope ->
                ChatTimelineMessage(
                    id = envelope.messageId,
                    author = authorLabel(envelope.senderAccountId),
                    body = rawEnvelopeBody(envelope),
                    timestampLabel = envelope.createdAtUnix.toLong().formatChatTimestamp(),
                    isMine = envelope.senderAccountId == session.localState.accountId,
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
                ),
                detail = detail,
            ),
            participantsLabel = participantsLabel(detail),
            timelineLabel = if (projectedMessages.isNotEmpty()) {
                "Projected timeline"
            } else {
                "Encrypted cache only"
            },
            isAccountSyncChat = chatId == session.localState.accountSyncChatId,
            messages = timelineMessages,
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

    private fun client(): FfiServerApiClient = clientDelegate.value

    private fun historyStore(): FfiLocalHistoryStore = historyStoreDelegate.value

    private fun syncCoordinator(): FfiSyncCoordinator = syncCoordinatorDelegate.value

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
                detail?.members
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

    private fun participantsLabel(detail: FfiChatDetail?): String {
        val members = detail?.members.orEmpty()
        if (members.isEmpty()) {
            return when (detail?.chatType) {
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

    private fun previewFor(
        projectedMessage: FfiLocalProjectedMessage?,
        envelope: FfiMessageEnvelope?,
    ): String {
        return when {
            projectedMessage != null -> {
                val prefix = authorLabel(projectedMessage.senderAccountId)
                "$prefix: ${projectedMessageBody(projectedMessage)}"
            }

            envelope != null -> {
                val prefix = authorLabel(envelope.senderAccountId)
                "$prefix: ${rawEnvelopeBody(envelope)}"
            }

            else -> "No messages yet"
        }
    }

    private fun timestampLabelFor(
        projectedMessage: FfiLocalProjectedMessage?,
        envelope: FfiMessageEnvelope?,
    ): String {
        return projectedMessage?.createdAtUnix?.toLong()?.formatChatTimestamp()
            ?: envelope?.createdAtUnix?.toLong()?.formatChatTimestamp()
            ?: "Pending"
    }

    private fun authorLabel(accountId: String): String {
        return if (accountId == session.localState.accountId) {
            "You"
        } else {
            shortAccountId(accountId)
        }
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

    companion object {
        private const val MAX_VISIBLE_MEMBERS = 3
        private val HISTORY_SYNC_LIMIT = 200u
        private val INBOX_SYNC_LIMIT = 100u
        private val LEASE_TTL_SECONDS = 60uL
        private val TIME_FORMATTER = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        private val MONTH_DAY_FORMATTER = DateTimeFormatter.ofPattern("MMM d")
        private val DATE_FORMATTER = DateTimeFormatter.ofPattern("MMM d, yyyy")
    }
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
