package chat.trix.android.core.chat

import android.content.Context
import android.net.Uri
import chat.trix.android.core.ffi.FfiChatParticipantProfile
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiChatDetail
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiCreateChatControlInput
import chat.trix.android.core.ffi.FfiDirectoryAccount
import chat.trix.android.core.ffi.FfiLocalChatListItem
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiLocalProjectionKind
import chat.trix.android.core.ffi.FfiLocalTimelineItem
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiMessageBodyKind
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
    private val attachmentRepositoryDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AttachmentRepository(
            context = appContext,
            session = session,
        )
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

    suspend fun sendAttachment(
        chatId: String,
        contentUri: Uri,
    ): ChatSendResult = withContext(Dispatchers.IO) {
        runFfi("Failed to send attachment") {
            val client = client()
            val store = historyStore()
            val syncCoordinator = syncCoordinator()
            val facade = mlsFacade()

            client.setAccessToken(session.accessToken)
            val uploadedAttachment = attachmentRepository().uploadAttachment(
                chatId = chatId,
                contentUri = contentUri,
            )
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
                        body = uploadedAttachment.body,
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

    suspend fun openAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        attachmentRepository().openAttachment(attachment)
    }

    suspend fun shareAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        attachmentRepository().shareAttachment(attachment)
    }

    suspend fun markConversationRead(chatId: String): ChatReadResult = withContext(Dispatchers.IO) {
        runFfi("Failed to update chat read state") {
            val store = historyStore()
            val previous = store.getChatReadState(chatId, session.localState.accountId)
            val updated = store.markChatRead(chatId, null, session.localState.accountId)

            ChatReadResult(
                overview = buildOverview(),
                changed = previous == null ||
                    previous.readCursorServerSeq != updated.readCursorServerSeq ||
                    previous.unreadCount != updated.unreadCount,
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
        if (mlsFacadeDelegate.isInitialized()) {
            mlsFacadeDelegate.value.close()
        }
    }

    private fun buildOverview(): ChatOverview {
        val store = historyStore()
        val selfAccountId = session.localState.accountId
        val syncSnapshot = syncCoordinator().stateSnapshot()
        val conversations = store.listLocalChatListItems(selfAccountId).map { item ->
            val detail = store.getChat(item.chatId)
            val messageCount = store.getLocalTimelineItems(
                item.chatId,
                selfAccountId,
                null,
                null,
            ).size

            ChatConversationSummary(
                chatId = item.chatId,
                title = item.displayTitle,
                participantsLabel = participantsLabel(
                    item = item,
                    detail = detail,
                ),
                lastMessagePreview = chatPreviewLabel(item),
                timestampLabel = item.previewCreatedAtUnix?.toLong()?.formatChatTimestamp() ?: "Pending",
                messageCount = messageCount,
                unreadCount = item.unreadCount.toInt(),
                hasProjectedTimeline = messageCount > 0,
                isAccountSyncChat = item.chatId == session.localState.accountSyncChatId,
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
        val selfAccountId = session.localState.accountId
        val item = store.getLocalChatListItem(chatId, selfAccountId) ?: return null
        val detail = store.getChat(chatId)
        val timelineItems = store.getLocalTimelineItems(chatId, selfAccountId, null, null)
        val hasLocalMlsState = hasLocalConversation(chatId)
        val canSend = item.chatType == FfiChatType.ACCOUNT_SYNC || hasLocalMlsState
        val messages = timelineItems.map(::mapTimelineMessage)

        return ChatConversation(
            chatId = chatId,
            title = item.displayTitle,
            participantsLabel = participantsLabel(
                item = item,
                detail = detail,
            ),
            timelineLabel = conversationTimelineLabel(item, timelineItems),
            isAccountSyncChat = chatId == session.localState.accountSyncChatId,
            canSend = canSend,
            composerHint = when {
                item.chatType == FfiChatType.ACCOUNT_SYNC -> {
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

    private fun attachmentRepository(): AttachmentRepository = attachmentRepositoryDelegate.value

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

    private fun participantsLabel(
        item: FfiLocalChatListItem,
        detail: FfiChatDetail?,
    ): String {
        val profiles = participantProfiles(item, detail)
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
            return when (detail?.chatType ?: item.chatType) {
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
        item: FfiLocalChatListItem,
        detail: FfiChatDetail?,
    ): List<FfiChatParticipantProfile> {
        return item.participantProfiles.takeIf(List<FfiChatParticipantProfile>::isNotEmpty)
            ?: detail?.participantProfiles.orEmpty()
    }

    private fun participantDisplayName(profile: FfiChatParticipantProfile): String {
        if (profile.accountId == session.localState.accountId) {
            return "You"
        }
        return profile.profileName.takeIf(String::isNotBlank)
            ?: profile.handle?.takeIf(String::isNotBlank)?.let { "@$it" }
            ?: shortAccountId(profile.accountId)
    }

    private fun mapDirectoryAccount(account: FfiDirectoryAccount): ChatDirectoryAccount {
        return ChatDirectoryAccount(
            accountId = account.accountId,
            handle = account.handle,
            profileName = account.profileName,
            profileBio = account.profileBio,
        )
    }

    private fun chatPreviewLabel(item: FfiLocalChatListItem): String {
        val previewText = item.previewText?.trim()?.takeIf(String::isNotEmpty) ?: return "No messages yet"
        val senderLabel = previewSenderLabel(item)
        return if (senderLabel != null) {
            "$senderLabel: $previewText"
        } else {
            previewText
        }
    }

    private fun previewSenderLabel(item: FfiLocalChatListItem): String? {
        val senderDisplayName = item.previewSenderDisplayName
        val senderAccountId = item.previewSenderAccountId
        return when {
            item.previewIsOutgoing == true -> "You"
            !senderDisplayName.isNullOrBlank() -> senderDisplayName
            !senderAccountId.isNullOrBlank() -> shortAccountId(senderAccountId)
            else -> null
        }
    }

    private fun conversationTimelineLabel(
        item: FfiLocalChatListItem,
        timelineItems: List<FfiLocalTimelineItem>,
    ): String {
        if (timelineItems.isEmpty()) {
            return if (item.previewText != null) {
                "Encrypted cache only"
            } else {
                "No local timeline"
            }
        }

        val latestTimelineSeq = timelineItems.last().serverSeq.toLong()
        if (item.previewServerSeq?.toLong()?.let { it > latestTimelineSeq } == true) {
            return "Mixed local timeline"
        }

        return if (timelineItems.any { it.projectionKind != FfiLocalProjectionKind.APPLICATION_MESSAGE }) {
            "Projected + MLS events"
        } else {
            "Projected timeline"
        }
    }

    private fun mapTimelineMessage(message: FfiLocalTimelineItem): ChatTimelineMessage {
        val attachment = attachmentFrom(message)
        return ChatTimelineMessage(
            id = message.messageId,
            author = if (message.isOutgoing) {
                "You"
            } else {
                message.senderDisplayName.takeIf(String::isNotBlank)
                    ?: shortAccountId(message.senderAccountId)
            },
            body = timelineBody(message),
            timestampLabel = message.createdAtUnix.toLong().formatChatTimestamp(),
            isMine = message.isOutgoing,
            note = timelineNote(message),
            contentType = message.contentType,
            attachment = attachment,
        )
    }

    private fun attachmentFrom(message: FfiLocalTimelineItem): ChatAttachment? {
        val body = message.body ?: return null
        if (body.kind != FfiMessageBodyKind.ATTACHMENT) {
            return null
        }
        val blobId = body.blobId ?: return null
        val mimeType = body.mimeType ?: return null
        return ChatAttachment(
            messageId = message.messageId,
            blobId = blobId,
            mimeType = mimeType,
            fileName = body.fileName,
            sizeBytes = body.sizeBytes?.toLong(),
            widthPx = body.widthPx?.toInt(),
            heightPx = body.heightPx?.toInt(),
            body = body,
        )
    }

    private fun timelineBody(message: FfiLocalTimelineItem): String {
        val body = message.body
        if (body != null) {
            return structuredBodyText(body)
        }

        return message.previewText
            .trim()
            .takeIf(String::isNotEmpty)
            ?: message.bodyParseError
            ?: "Encrypted application payload"
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

    private fun timelineNote(message: FfiLocalTimelineItem): String? {
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

data class ChatReadResult(
    val overview: ChatOverview,
    val changed: Boolean,
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
    val unreadCount: Int,
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
    val contentType: FfiContentType,
    val attachment: ChatAttachment? = null,
)

data class ChatAttachment(
    val messageId: String,
    val blobId: String,
    val mimeType: String,
    val fileName: String?,
    val sizeBytes: Long?,
    val widthPx: Int?,
    val heightPx: Int?,
    val body: FfiMessageBody,
)
