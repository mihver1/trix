package chat.trix.android.core.chat

import android.content.Context
import android.net.Uri
import chat.trix.android.core.ffi.FfiChatParticipantProfile
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.DeviceDatabaseKeyStore
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiChatDetail
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiClientStore
import chat.trix.android.core.ffi.FfiClientStoreConfig
import chat.trix.android.core.ffi.FfiCreateChatControlInput
import chat.trix.android.core.ffi.FfiDirectoryAccount
import chat.trix.android.core.ffi.FfiLocalChatListItem
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiLocalOutboxAttachmentDraft
import chat.trix.android.core.ffi.FfiLocalOutboxItem
import chat.trix.android.core.ffi.FfiLocalOutboxStatus
import chat.trix.android.core.ffi.FfiLocalProjectionKind
import chat.trix.android.core.ffi.FfiLocalTimelineItem
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiMessageBodyKind
import chat.trix.android.core.ffi.FfiModifyChatMembersControlInput
import chat.trix.android.core.ffi.FfiMlsConversation
import chat.trix.android.core.ffi.FfiMlsFacade
import chat.trix.android.core.ffi.FfiReceiptType
import chat.trix.android.core.ffi.FfiSendMessageInput
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiSyncCoordinator
import chat.trix.android.core.ffi.TrixFfiException
import chat.trix.android.core.system.AppTelemetry
import chat.trix.android.core.system.deviceStorageLayout
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
    private val storageLayout = deviceStorageLayout(
        context = appContext,
        accountId = session.localState.accountId,
        deviceId = session.localState.deviceId,
    )
    private val databaseKeyStore = DeviceDatabaseKeyStore(appContext)
    private val corePersistencePrepared = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        storageLayout.prepareCorePersistenceMigration()
        true
    }
    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl)
    }
    private val clientStoreDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        corePersistencePrepared.value
        val databaseKey = runBlockingStoreKey()
        FfiClientStore.open(
            FfiClientStoreConfig(
                databasePath = storageLayout.stateDatabasePath.absolutePath,
                databaseKey = databaseKey,
                attachmentCacheRoot = storageLayout.attachmentCacheRoot.absolutePath,
            ),
        )
    }
    private val historyStoreDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        clientStore().historyStore()
    }
    private val syncCoordinatorDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        clientStore().syncCoordinator()
    }
    private val mlsFacadeDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        clientStore().openMlsFacade(session.localState.credentialIdentity)
    }
    private val attachmentRepositoryDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AttachmentRepository(
            context = appContext,
            session = session,
        )
    }
    private val telemetry = AppTelemetry(appContext)

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
        runLogged(
            operation = "refresh",
            fallbackMessage = "Failed to sync chats",
            successMessage = { result ->
                "refresh success history=${result.historyMessagesUpserted} inbox=${result.inboxMessagesUpserted} hydrated=${result.hydratedChatDetails} projected=${result.projectedChatTimelines} outbox=${result.flushedOutboxCount}"
            },
        ) {
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
            val flushedOutboxCount = flushPendingOutboxNow()

            ChatRefreshResult(
                overview = buildOverview(),
                historyMessagesUpserted = historyReport.messagesUpserted.toLong(),
                inboxMessagesUpserted = inboxOutcome.report.messagesUpserted.toLong(),
                ackedInboxCount = inboxOutcome.ackedInboxIds.size,
                hydratedChatDetails = hydratedChatDetails,
                projectedChatTimelines = projectedChatTimelines,
                flushedOutboxCount = flushedOutboxCount,
            )
        }
    }

    suspend fun hydrateChangedChats(chatIds: Set<String>): Int = withContext(Dispatchers.IO) {
        runFfi("Failed to hydrate changed chats") {
            hydrateChangedChatsNow(chatIds)
        }
    }

    suspend fun flushPendingOutbox(): Int = withContext(Dispatchers.IO) {
        runFfi("Failed to flush local outbox") {
            flushPendingOutboxNow()
        }
    }

    suspend fun searchAccountDirectory(query: String): List<ChatDirectoryAccount> = withContext(Dispatchers.IO) {
        runLogged(
            operation = "search_directory",
            fallbackMessage = "Failed to search account directory",
            startMessage = "search_directory start query_present=${query.isNotBlank()}",
            successMessage = { results -> "search_directory success results=${results.size}" },
        ) {
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
        val normalizedParticipants = normalizeParticipantAccountIds(listOf(targetAccountId))
        if (normalizedParticipants.isEmpty()) {
            throw IOException("Choose a valid account to start a direct message")
        }

        runLogged(
            operation = "create_dm",
            fallbackMessage = "Failed to create direct message",
            startMessage = "create_dm start peer=${shortId(normalizedParticipants.first())}",
            successMessage = { result -> "create_dm success chat=${shortId(result.conversation.chatId)}" },
        ) {
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
                    participantAccountIds = normalizedParticipants,
                    groupId = null,
                    commitAadJson = EMPTY_AAD_JSON,
                    welcomeAadJson = EMPTY_AAD_JSON,
                ),
            )
            hydrateChatDetail(client, store, outcome.chatId)

            ChatCreateResult(
                overview = buildOverview(),
                conversation = buildConversation(outcome.chatId)
                    ?: throw IOException("Conversation ${outcome.chatId} is no longer available"),
            )
        }
    }

    suspend fun createGroupChat(
        title: String?,
        participantAccountIds: List<String>,
    ): ChatCreateResult = withContext(Dispatchers.IO) {
        val normalizedParticipants = normalizeParticipantAccountIds(participantAccountIds)
        if (normalizedParticipants.size < MIN_GROUP_PARTICIPANTS) {
            throw IOException("Select at least $MIN_GROUP_PARTICIPANTS people for a group chat")
        }

        runLogged(
            operation = "create_group",
            fallbackMessage = "Failed to create group chat",
            startMessage = "create_group start participants=${normalizedParticipants.size}",
            successMessage = { result -> "create_group success chat=${shortId(result.conversation.chatId)}" },
        ) {
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
                    chatType = FfiChatType.GROUP,
                    title = title?.trim()?.takeIf(String::isNotEmpty),
                    participantAccountIds = normalizedParticipants,
                    groupId = null,
                    commitAadJson = EMPTY_AAD_JSON,
                    welcomeAadJson = EMPTY_AAD_JSON,
                ),
            )
            hydrateChatDetail(client, store, outcome.chatId)

            ChatCreateResult(
                overview = buildOverview(),
                conversation = buildConversation(outcome.chatId)
                    ?: throw IOException("Conversation ${outcome.chatId} is no longer available"),
            )
        }
    }

    suspend fun addMembers(
        chatId: String,
        participantAccountIds: List<String>,
    ): ChatMembershipUpdateResult = withContext(Dispatchers.IO) {
        val normalizedParticipants = normalizeParticipantAccountIds(participantAccountIds)
        if (normalizedParticipants.isEmpty()) {
            throw IOException("Select at least one person to add")
        }

        runLogged(
            operation = "add_members",
            fallbackMessage = "Failed to add group members",
            startMessage = "add_members start chat=${shortId(chatId)} count=${normalizedParticipants.size}",
            successMessage = { result -> "add_members success chat=${shortId(result.conversation.chatId)} members=${result.conversation.members.size}" },
        ) {
            val client = client()
            val store = historyStore()
            val syncCoordinator = syncCoordinator()
            val facade = mlsFacade()

            client.setAccessToken(session.accessToken)
            syncCoordinator.addChatMembersControl(
                client = client,
                store = store,
                facade = facade,
                input = FfiModifyChatMembersControlInput(
                    actorAccountId = session.localState.accountId,
                    actorDeviceId = session.localState.deviceId,
                    chatId = chatId,
                    participantAccountIds = normalizedParticipants,
                    commitAadJson = EMPTY_AAD_JSON,
                    welcomeAadJson = EMPTY_AAD_JSON,
                ),
            )
            hydrateChatDetail(client, store, chatId)

            ChatMembershipUpdateResult(
                overview = buildOverview(),
                conversation = buildConversation(chatId)
                    ?: throw IOException("Conversation $chatId is no longer available"),
            )
        }
    }

    suspend fun removeMember(
        chatId: String,
        accountId: String,
    ): ChatMembershipUpdateResult = withContext(Dispatchers.IO) {
        val normalizedParticipants = normalizeParticipantAccountIds(listOf(accountId))
        if (normalizedParticipants.isEmpty()) {
            throw IOException("Choose a valid member to remove")
        }

        runLogged(
            operation = "remove_member",
            fallbackMessage = "Failed to remove group member",
            startMessage = "remove_member start chat=${shortId(chatId)} account=${shortId(normalizedParticipants.first())}",
            successMessage = { result -> "remove_member success chat=${shortId(result.conversation.chatId)} members=${result.conversation.members.size}" },
        ) {
            val client = client()
            val store = historyStore()
            val syncCoordinator = syncCoordinator()
            val facade = mlsFacade()

            client.setAccessToken(session.accessToken)
            syncCoordinator.removeChatMembersControl(
                client = client,
                store = store,
                facade = facade,
                input = FfiModifyChatMembersControlInput(
                    actorAccountId = session.localState.accountId,
                    actorDeviceId = session.localState.deviceId,
                    chatId = chatId,
                    participantAccountIds = normalizedParticipants,
                    commitAadJson = EMPTY_AAD_JSON,
                    welcomeAadJson = EMPTY_AAD_JSON,
                ),
            )
            hydrateChatDetail(client, store, chatId)

            ChatMembershipUpdateResult(
                overview = buildOverview(),
                conversation = buildConversation(chatId)
                    ?: throw IOException("Conversation $chatId is no longer available"),
            )
        }
    }

    suspend fun sendTextMessage(chatId: String, draft: String): ChatSendResult = withContext(Dispatchers.IO) {
        val normalizedDraft = draft.trim()
        if (normalizedDraft.isEmpty()) {
            throw IOException("Message is empty")
        }

        runLogged(
            operation = "send_text",
            fallbackMessage = "Failed to send message",
            startMessage = "send_text start chat=${shortId(chatId)}",
            successMessage = { result -> "send_text success chat=${shortId(result.conversation.chatId)} messages=${result.conversation.messages.size}" },
        ) {
            val store = historyStore()
            store.enqueueOutboxMessage(
                chatId = chatId,
                senderAccountId = session.localState.accountId,
                senderDeviceId = session.localState.deviceId,
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
                queuedAtUnix = currentUnixSeconds().toULong(),
            )
            flushPendingOutboxNow(chatId)

            ChatSendResult(
                overview = buildOverview(),
                conversation = buildConversation(chatId)
                    ?: throw IOException("Conversation $chatId is no longer available"),
            )
        }
    }

    suspend fun sendAttachment(
        chatId: String,
        contentUri: Uri,
    ): ChatSendResult = withContext(Dispatchers.IO) {
        runLogged(
            operation = "send_attachment",
            fallbackMessage = "Failed to send attachment",
            startMessage = "send_attachment start chat=${shortId(chatId)}",
            successMessage = { result -> "send_attachment success chat=${shortId(result.conversation.chatId)} messages=${result.conversation.messages.size}" },
        ) {
            val store = historyStore()
            val messageId = UUID.randomUUID().toString()
            val stagedAttachment = attachmentRepository().stageAttachmentForOutbox(
                contentUri = contentUri,
                messageId = messageId,
            )
            store.enqueueOutboxAttachment(
                chatId = chatId,
                senderAccountId = session.localState.accountId,
                senderDeviceId = session.localState.deviceId,
                messageId = messageId,
                attachment = FfiLocalOutboxAttachmentDraft(
                    localPath = stagedAttachment.localPath,
                    mimeType = stagedAttachment.mimeType,
                    fileName = stagedAttachment.fileName,
                    widthPx = stagedAttachment.widthPx?.toUInt(),
                    heightPx = stagedAttachment.heightPx?.toUInt(),
                ),
                queuedAtUnix = currentUnixSeconds().toULong(),
            )
            flushPendingOutboxNow(chatId)

            ChatSendResult(
                overview = buildOverview(),
                conversation = buildConversation(chatId)
                    ?: throw IOException("Conversation $chatId is no longer available"),
            )
        }
    }

    suspend fun openAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        attachmentRepository().openAttachment(attachment)
    }

    suspend fun loadImagePreviewAttachment(attachment: ChatAttachment): LocalImagePreviewAttachment =
        withContext(Dispatchers.IO) {
            attachmentRepository().loadImagePreviewAttachment(attachment)
        }

    suspend fun shareAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        attachmentRepository().shareAttachment(attachment)
    }

    suspend fun markConversationRead(chatId: String): ChatReadResult = withContext(Dispatchers.IO) {
        runLogged(
            operation = "mark_read",
            fallbackMessage = "Failed to update chat read state",
            startMessage = "mark_read start chat=${shortId(chatId)}",
            successMessage = { result -> "mark_read success chat=${shortId(chatId)} changed=${result.changed}" },
        ) {
            val store = historyStore()
            val selfAccountId = session.localState.accountId
            val previous = store.getChatReadState(chatId, selfAccountId)
            val updated = store.markChatRead(chatId, null, selfAccountId)
            val previousReadCursor = previous?.readCursorServerSeq?.toLong()
            val updatedReadCursor = updated.readCursorServerSeq.toLong()
            if (updatedReadCursor > 0 && updatedReadCursor > (previousReadCursor ?: 0L)) {
                enqueueReadReceiptIfNeeded(
                    chatId = chatId,
                    selfAccountId = selfAccountId,
                    readCursorServerSeq = updatedReadCursor,
                    previousReadCursorServerSeq = previousReadCursor,
                    store = store,
                )
                flushPendingOutboxNow(chatId)
            }

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
        if (clientStoreDelegate.isInitialized()) {
            clientStoreDelegate.value.close()
        }
    }

    private fun buildOverview(): ChatOverview {
        val store = historyStore()
        val selfAccountId = session.localState.accountId
        val syncSnapshot = syncCoordinator().stateSnapshot()
        val conversations = store.listLocalChatListItems(selfAccountId).map { item ->
            val detail = store.getChat(item.chatId)
            val pendingOutboxMessages = store.listOutboxMessages(item.chatId)
            val timelineItems = store.getLocalTimelineItems(
                item.chatId,
                selfAccountId,
                null,
                null,
            )
            val messages = mergeTimelineMessages(
                timelineItems = timelineItems,
                pendingOutboxItems = pendingOutboxMessages,
            )
            val previewCreatedAtUnix = item.previewCreatedAtUnix?.toLong()
            val pendingPreview = pendingOutboxPreview(pendingOutboxMessages)
            val previewText = when {
                pendingPreview != null && (previewCreatedAtUnix == null || pendingPreview.queuedAtUnix >= previewCreatedAtUnix) ->
                    pendingPreview.previewText
                else -> chatPreviewLabel(item)
            }
            val timestampLabel = when {
                pendingPreview != null && (previewCreatedAtUnix == null || pendingPreview.queuedAtUnix >= previewCreatedAtUnix) ->
                    pendingPreview.queuedAtUnix.formatChatTimestamp()
                else -> previewCreatedAtUnix?.formatChatTimestamp() ?: "Pending"
            }

            ChatConversationSummary(
                chatId = item.chatId,
                chatType = item.chatType,
                title = item.displayTitle,
                participantsLabel = participantsLabel(
                    item = item,
                    detail = detail,
                ),
                lastMessagePreview = previewText,
                timestampLabel = timestampLabel,
                messageCount = messages.size,
                unreadCount = item.unreadCount.toInt(),
                hasProjectedTimeline = messages.isNotEmpty(),
                isAccountSyncChat = item.chatId == session.localState.accountSyncChatId,
            )
        }

        return ChatOverview(
            conversations = conversations,
            diagnostics = ChatDiagnostics(
                cachedChatCount = conversations.size,
                cachedMessageCount = conversations.sumOf { it.messageCount },
                projectedChatCount = conversations.count { it.hasProjectedTimeline },
                pendingOutboxCount = store.listOutboxMessages(null).size,
                lastAckedInboxId = syncSnapshot.lastAckedInboxId?.toLong(),
                leaseOwner = syncSnapshot.leaseOwner,
                historyStorePath = store.databasePath(),
                syncStatePath = clientStore().databasePath(),
            ),
        )
    }

    private fun buildConversation(chatId: String): ChatConversation? {
        val store = historyStore()
        val selfAccountId = session.localState.accountId
        val item = store.getLocalChatListItem(chatId, selfAccountId) ?: return null
        runCatching {
            ensureConversationProjection(chatId, store)
        }
        val detail = store.getChat(chatId)
        val timelineItems = store.getLocalTimelineItems(chatId, selfAccountId, null, null)
        val pendingOutboxItems = store.listOutboxMessages(chatId)
        val visiblePendingOutboxItems = pendingOutboxItems.filterNot(::isReceiptOutboxMessage)
        val hasLocalMlsState = hasLocalConversation(chatId)
        val canSend = item.chatType == FfiChatType.ACCOUNT_SYNC || hasLocalMlsState
        val messages = mergeTimelineMessages(
            timelineItems = timelineItems,
            pendingOutboxItems = pendingOutboxItems,
        )
        val members = conversationMembers(item, detail)

        return ChatConversation(
            chatId = chatId,
            chatType = item.chatType,
            title = item.displayTitle,
            participantsLabel = participantsLabel(
                item = item,
                detail = detail,
            ),
            timelineLabel = conversationTimelineLabel(item, timelineItems, pendingOutboxItems),
            isAccountSyncChat = chatId == session.localState.accountSyncChatId,
            canSend = canSend,
            canManageMembers = item.chatType == FfiChatType.GROUP && canSend,
            composerHint = when {
                item.chatType == FfiChatType.ACCOUNT_SYNC -> {
                    "Messages use this device's local MLS state for the account sync thread."
                }

                visiblePendingOutboxItems.isNotEmpty() -> "Queued messages retry automatically when the device reconnects."
                canSend -> "Send through the local MLS state already present on this device."
                else -> "Sending is disabled until this device has local MLS state for this chat."
            },
            members = members,
            messages = messages,
        )
    }

    private fun hydrateChatDetails(
        client: FfiServerApiClient,
        store: FfiLocalHistoryStore,
    ): Int {
        var changedChats = 0
        store.listChats().forEach { summary ->
            changedChats += hydrateChatDetail(client, store, summary.chatId)
        }
        return changedChats
    }

    private fun hydrateChatDetail(
        client: FfiServerApiClient,
        store: FfiLocalHistoryStore,
        chatId: String,
    ): Int {
        val detail = client.getChat(chatId)
        val report = store.applyChatDetail(detail)
        runCatching {
            ensureConversationProjection(chatId, store)
        }
        return report.chatsUpserted.toInt()
    }

    private fun hydrateChangedChatsNow(chatIds: Set<String>): Int {
        if (chatIds.isEmpty()) {
            return 0
        }

        val client = client()
        val store = historyStore()
        client.setAccessToken(session.accessToken)

        var hydratedChats = 0
        for (chatId in chatIds.sorted()) {
            hydratedChats += hydrateChatDetail(client, store, chatId)
        }
        return hydratedChats
    }

    private fun projectChatsWithLocalMlsState(store: FfiLocalHistoryStore): Int {
        var projectedChatTimelines = 0

        store.listChats().forEach { summary ->
            val projected = runCatching {
                ensureConversationProjection(summary.chatId, store)
            }.getOrDefault(false)

            if (projected && store.getProjectedMessages(summary.chatId, null, 1u).isNotEmpty()) {
                projectedChatTimelines += 1
            }
        }

        return projectedChatTimelines
    }

    private fun mergeTimelineMessages(
        timelineItems: List<FfiLocalTimelineItem>,
        pendingOutboxItems: List<FfiLocalOutboxItem>,
    ): List<ChatTimelineMessage> {
        val orderedTimelineItems = timelineItems.sortedWith(
            compareBy<FfiLocalTimelineItem> { it.serverSeq.toLong() }
                .thenBy { it.createdAtUnix.toLong() }
                .thenBy { it.messageId },
        )
        val receiptStatuses = receiptStatusByMessageId(orderedTimelineItems)
        val orderedMessages = orderedTimelineItems
            .filterNot(::isReceiptTimelineItem)
            .mapIndexed { index, message ->
            TimedChatTimelineMessage(
                sortUnix = message.createdAtUnix.toLong(),
                sourcePriority = 0,
                sourceOrder = index,
                message = mapTimelineMessage(
                    message = message,
                    receiptStatus = receiptStatuses[message.messageId],
                ),
            )
        } + pendingOutboxItems
            .filterNot(::isReceiptOutboxMessage)
            .mapIndexed { index, message ->
            TimedChatTimelineMessage(
                sortUnix = message.queuedAtUnix.toLong(),
                sourcePriority = 1,
                sourceOrder = index,
                message = mapOutboxMessage(message),
            )
        }

        return mergeChatTimelineMessages(orderedMessages)
    }

    private fun flushPendingOutboxNow(chatId: String? = null): Int {
        val store = historyStore()
        val pendingItems = store.listOutboxMessages(chatId)
        if (pendingItems.isEmpty()) {
            return 0
        }

        val client = client()
        val syncCoordinator = syncCoordinator()
        val facade = mlsFacade()
        client.setAccessToken(session.accessToken)

        var flushed = 0
        for (queued in pendingItems) {
            try {
                store.clearOutboxFailure(queued.messageId)
                flushOutboxItem(
                    queued = queued,
                    client = client,
                    syncCoordinator = syncCoordinator,
                    facade = facade,
                    store = store,
                )
                store.removeOutboxMessage(queued.messageId)
                queued.attachmentDraft?.localPath?.let { localPath ->
                    kotlinx.coroutines.runBlocking {
                        attachmentRepository().deleteStagedAttachment(localPath)
                    }
                }
                flushed += 1
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                store.markOutboxFailure(
                    queued.messageId,
                    error.message ?: "Retry pending",
                )
            }
        }

        return flushed
    }

    private fun enqueueReadReceiptIfNeeded(
        chatId: String,
        selfAccountId: String,
        readCursorServerSeq: Long,
        previousReadCursorServerSeq: Long?,
        store: FfiLocalHistoryStore,
    ) {
        if (!canQueueReceipt(chatId)) {
            return
        }

        val targetMessage = store.getLocalTimelineItems(chatId, selfAccountId, null, null)
            .asReversed()
            .firstOrNull { item ->
                !item.isOutgoing &&
                    item.serverSeq.toLong() <= readCursorServerSeq &&
                    item.contentType != FfiContentType.RECEIPT &&
                    item.body?.kind != FfiMessageBodyKind.RECEIPT
            }
            ?: return
        if (previousReadCursorServerSeq != null && targetMessage.serverSeq.toLong() <= previousReadCursorServerSeq) {
            return
        }

        val duplicateQueuedReceipt = store.listOutboxMessages(chatId).any { queued ->
            val queuedBody = queued.body ?: return@any false
            queuedBody.kind == FfiMessageBodyKind.RECEIPT &&
                queuedBody.targetMessageId == targetMessage.messageId &&
                queuedBody.receiptType == FfiReceiptType.READ
        }
        if (duplicateQueuedReceipt) {
            return
        }

        val queuedAtUnix = currentUnixSeconds().toULong()
        store.enqueueOutboxMessage(
            chatId = chatId,
            senderAccountId = session.localState.accountId,
            senderDeviceId = session.localState.deviceId,
            messageId = UUID.randomUUID().toString(),
            body = FfiMessageBody(
                kind = FfiMessageBodyKind.RECEIPT,
                text = null,
                targetMessageId = targetMessage.messageId,
                emoji = null,
                reactionAction = null,
                receiptType = FfiReceiptType.READ,
                receiptAtUnix = queuedAtUnix,
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
            queuedAtUnix = queuedAtUnix,
        )
    }

    private fun flushOutboxItem(
        queued: FfiLocalOutboxItem,
        client: FfiServerApiClient,
        syncCoordinator: FfiSyncCoordinator,
        facade: FfiMlsFacade,
        store: FfiLocalHistoryStore,
    ) {
        val conversation = getOrCreateSendConversation(queued.chatId)
            ?: throw IOException("Local MLS state is not available for this conversation")
        try {
            val queuedBody = queued.body
            val queuedAttachmentDraft = queued.attachmentDraft
            val body = when {
                queuedBody != null -> queuedBody
                queuedAttachmentDraft != null -> {
                    kotlinx.coroutines.runBlocking {
                        attachmentRepository().uploadStagedAttachment(
                            chatId = queued.chatId,
                            draft = StagedAttachmentDraft(
                                localPath = queuedAttachmentDraft.localPath,
                                mimeType = queuedAttachmentDraft.mimeType,
                                fileName = queuedAttachmentDraft.fileName,
                                widthPx = queuedAttachmentDraft.widthPx?.toInt(),
                                heightPx = queuedAttachmentDraft.heightPx?.toInt(),
                            ),
                        ).body
                    }
                }

                else -> throw IOException("Outbox message is missing payload")
            }

            syncCoordinator.sendMessageBody(
                client = client,
                store = store,
                facade = facade,
                conversation = conversation,
                input = FfiSendMessageInput(
                    senderAccountId = queued.senderAccountId,
                    senderDeviceId = queued.senderDeviceId,
                    chatId = queued.chatId,
                    messageId = queued.messageId,
                    body = body,
                    aadJson = EMPTY_AAD_JSON,
                ),
            )
        } finally {
            conversation.close()
        }
    }

    private fun getOrCreateSendConversation(chatId: String): FfiMlsConversation? {
        val bootstrapped = loadOrBootstrapConversation(chatId)
        if (bootstrapped != null) {
            return bootstrapped
        }
        if (chatId != session.localState.accountSyncChatId) {
            return null
        }
        val groupId = resolveChatGroupId(chatId) ?: return null
        return mlsFacade().createGroup(groupId)
    }

    private fun loadOrBootstrapConversation(chatId: String): FfiMlsConversation? {
        val existing = loadLocalConversation(chatId)
        if (existing != null) {
            return existing
        }
        if (chatId == session.localState.accountSyncChatId) {
            return null
        }
        return historyStore().loadOrBootstrapChatConversation(chatId, mlsFacade())
    }

    private fun canQueueReceipt(chatId: String): Boolean {
        if (chatId == session.localState.accountSyncChatId) {
            return true
        }

        val conversation = loadOrBootstrapConversation(chatId) ?: return false
        conversation.close()
        return true
    }

    private fun hasLocalConversation(chatId: String): Boolean {
        val conversation = loadOrBootstrapConversation(chatId) ?: return false
        conversation.close()
        return true
    }

    private fun ensureConversationProjection(
        chatId: String,
        store: FfiLocalHistoryStore = historyStore(),
    ): Boolean {
        if (chatId == session.localState.accountSyncChatId) {
            val conversation = getOrCreateSendConversation(chatId) ?: return false
            return try {
                store.projectChatMessages(chatId, mlsFacade(), conversation, null)
                true
            } finally {
                conversation.close()
            }
        }

        store.projectChatWithFacade(chatId, mlsFacade(), null)
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

    private fun clientStore(): FfiClientStore = clientStoreDelegate.value

    private fun historyStore(): FfiLocalHistoryStore = historyStoreDelegate.value

    private fun syncCoordinator(): FfiSyncCoordinator = syncCoordinatorDelegate.value

    private fun mlsFacade(): FfiMlsFacade = mlsFacadeDelegate.value

    private fun attachmentRepository(): AttachmentRepository = attachmentRepositoryDelegate.value

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

    private inline fun <T> runLogged(
        operation: String,
        fallbackMessage: String,
        startMessage: String = "$operation start",
        successMessage: (T) -> String = { "$operation success" },
        block: () -> T,
    ): T {
        telemetry.info(TAG, startMessage)
        return try {
            val result = runFfi(fallbackMessage, block)
            telemetry.info(TAG, successMessage(result))
            result
        } catch (error: IOException) {
            telemetry.warn(TAG, "$operation failed", error)
            throw error
        }
    }

    private fun shortId(value: String): String = value.take(8).lowercase()

    private fun runBlockingStoreKey(): ByteArray {
        return kotlinx.coroutines.runBlocking {
            databaseKeyStore.getOrCreate(storageLayout.storeKeyPath)
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

    private fun conversationMembers(
        item: FfiLocalChatListItem,
        detail: FfiChatDetail?,
    ): List<ChatConversationMember> {
        val profilesByAccountId = participantProfiles(item, detail).associateBy { it.accountId }
        val detailMembers = detail?.members.orEmpty()
        if (detailMembers.isNotEmpty()) {
            return detailMembers.map { member ->
                ChatConversationMember(
                    accountId = member.accountId,
                    displayName = profilesByAccountId[member.accountId]
                        ?.let(::participantDisplayName)
                        ?: fallbackMemberDisplayName(member.accountId),
                    role = member.role,
                    membershipStatus = member.membershipStatus,
                    isSelf = member.accountId == session.localState.accountId,
                )
            }
        }

        return profilesByAccountId.values.map { profile ->
            ChatConversationMember(
                accountId = profile.accountId,
                displayName = participantDisplayName(profile),
                role = "participant",
                membershipStatus = "active",
                isSelf = profile.accountId == session.localState.accountId,
            )
        }
    }

    private fun participantDisplayName(profile: FfiChatParticipantProfile): String {
        if (profile.accountId == session.localState.accountId) {
            return "You"
        }
        return profile.profileName.takeIf(String::isNotBlank)
            ?: profile.handle?.takeIf(String::isNotBlank)?.let { "@$it" }
            ?: shortAccountId(profile.accountId)
    }

    private fun fallbackMemberDisplayName(accountId: String): String {
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
        pendingOutboxItems: List<FfiLocalOutboxItem>,
    ): String {
        val visibleTimelineItems = timelineItems.filterNot(::isReceiptTimelineItem)
        val visiblePendingOutboxItems = pendingOutboxItems.filterNot(::isReceiptOutboxMessage)

        if (visibleTimelineItems.isEmpty()) {
            if (visiblePendingOutboxItems.isNotEmpty()) {
                return "Queued locally"
            }
            return if (item.previewText != null) {
                "Encrypted cache only"
            } else {
                "No local timeline"
            }
        }

        val latestTimelineSeq = visibleTimelineItems.last().serverSeq.toLong()
        if (item.previewServerSeq?.toLong()?.let { it > latestTimelineSeq } == true) {
            return "Mixed local timeline"
        }

        return if (visibleTimelineItems.any { it.projectionKind != FfiLocalProjectionKind.APPLICATION_MESSAGE }) {
            "Projected + MLS events"
        } else if (visiblePendingOutboxItems.isNotEmpty()) {
            "Projected timeline + queued outbox"
        } else {
            "Projected timeline"
        }
    }

    private fun mapTimelineMessage(
        message: FfiLocalTimelineItem,
        receiptStatus: String?,
    ): ChatTimelineMessage {
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
            note = timelineNote(message, receiptStatus),
            contentType = message.contentType,
            attachment = attachment,
        )
    }

    private fun mapOutboxMessage(message: FfiLocalOutboxItem): ChatTimelineMessage {
        val attachmentLabel = message.attachmentDraft?.fileName
            ?: message.attachmentDraft?.mimeType
            ?: "Attachment"
        val body = message.body?.let(::structuredBodyText) ?: attachmentLabel
        val note = when (message.status) {
            FfiLocalOutboxStatus.PENDING -> "Queued for delivery"
            FfiLocalOutboxStatus.FAILED -> message.failureMessage ?: "Delivery failed, will retry"
        }
        return ChatTimelineMessage(
            id = message.messageId,
            author = "You",
            body = body,
            timestampLabel = message.queuedAtUnix.toLong().formatChatTimestamp(),
            isMine = true,
            note = note,
            contentType = message.body?.let(::ffiContentTypeForBody) ?: FfiContentType.ATTACHMENT,
            attachment = null,
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

    private fun timelineNote(
        message: FfiLocalTimelineItem,
        receiptStatus: String?,
    ): String? {
        if (message.bodyParseError != null) {
            return message.bodyParseError
        }

        val projectionNote = when (message.projectionKind) {
            FfiLocalProjectionKind.APPLICATION_MESSAGE -> null
            FfiLocalProjectionKind.PROPOSAL_QUEUED -> "MLS proposal queued"
            FfiLocalProjectionKind.COMMIT_MERGED -> {
                message.mergedEpoch?.let { "MLS commit merged at epoch ${it.toLong()}" }
                    ?: "MLS commit merged"
            }

            FfiLocalProjectionKind.WELCOME_REF -> "Welcome reference"
            FfiLocalProjectionKind.SYSTEM -> "System event"
        }

        return listOfNotNull(receiptStatus, projectionNote)
            .takeIf(List<String>::isNotEmpty)
            ?.joinToString(separator = " · ")
    }

    private fun pendingOutboxPreview(
        pendingOutboxMessages: List<FfiLocalOutboxItem>,
    ): PendingOutboxPreview? {
        val latest = pendingOutboxMessages
            .filterNot(::isReceiptOutboxMessage)
            .maxByOrNull(FfiLocalOutboxItem::queuedAtUnix)
            ?: return null
        val previewText = latest.body?.let(::structuredBodyText)
            ?: latest.attachmentDraft?.fileName
            ?: latest.attachmentDraft?.mimeType
            ?: "Queued attachment"
        return PendingOutboxPreview(
            previewText = previewText,
            queuedAtUnix = latest.queuedAtUnix.toLong(),
        )
    }

    private fun ffiContentTypeForBody(body: FfiMessageBody): FfiContentType {
        return when (body.kind) {
            FfiMessageBodyKind.TEXT -> FfiContentType.TEXT
            FfiMessageBodyKind.REACTION -> FfiContentType.REACTION
            FfiMessageBodyKind.RECEIPT -> FfiContentType.RECEIPT
            FfiMessageBodyKind.ATTACHMENT -> FfiContentType.ATTACHMENT
            FfiMessageBodyKind.CHAT_EVENT -> FfiContentType.CHAT_EVENT
        }
    }

    private fun shortAccountId(accountId: String): String {
        return if (accountId.length <= 10) {
            accountId
        } else {
            "${accountId.take(6)}…${accountId.takeLast(4)}"
        }
    }

    private fun isReceiptTimelineItem(message: FfiLocalTimelineItem): Boolean {
        return message.contentType == FfiContentType.RECEIPT ||
            message.body?.kind == FfiMessageBodyKind.RECEIPT
    }

    private fun isReceiptOutboxMessage(message: FfiLocalOutboxItem): Boolean {
        return message.body?.kind == FfiMessageBodyKind.RECEIPT
    }

    private fun receiptStatusByMessageId(
        timelineItems: List<FfiLocalTimelineItem>,
    ): Map<String, String> {
        val timelineById = timelineItems.associateBy(FfiLocalTimelineItem::messageId)
        val receiptSummaries = linkedMapOf<String, ReceiptSummaryAccumulator>()

        timelineItems.forEach { message ->
            val body = message.body ?: return@forEach
            if (body.kind != FfiMessageBodyKind.RECEIPT || message.isOutgoing) {
                return@forEach
            }

            val targetMessageId = body.targetMessageId ?: return@forEach
            val targetMessage = timelineById[targetMessageId] ?: return@forEach
            if (!targetMessage.isOutgoing) {
                return@forEach
            }

            val readerLabel = message.senderDisplayName.takeIf(String::isNotBlank)
                ?: shortAccountId(message.senderAccountId)
            receiptSummaries
                .getOrPut(targetMessageId) { ReceiptSummaryAccumulator() }
                .record(
                    readerLabel = readerLabel,
                    receiptType = body.receiptType,
                )
        }

        return receiptSummaries
            .mapValues { (_, accumulator) -> accumulator.summaryText() }
            .filterValues(String::isNotBlank)
    }

    private fun shortMessageId(messageId: String): String {
        return if (messageId.length <= 10) {
            messageId
        } else {
            "${messageId.take(6)}…"
        }
    }

    private fun normalizeParticipantAccountIds(accountIds: List<String>): List<String> {
        return accountIds
            .asSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .filterNot { it == session.localState.accountId }
            .distinct()
            .toList()
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

    private fun currentUnixSeconds(): Long = Instant.now().epochSecond

    companion object {
        private const val TAG = "ChatRepository"
        private const val MAX_VISIBLE_MEMBERS = 3
        private val DIRECTORY_SEARCH_LIMIT = 20u
        private val HISTORY_SYNC_LIMIT = 200u
        private val INBOX_SYNC_LIMIT = 100u
        private val LEASE_TTL_SECONDS = 60uL
        private const val MIN_GROUP_PARTICIPANTS = 2
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
    val pendingOutboxCount: Int,
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
    val flushedOutboxCount: Int,
)

data class ChatSendResult(
    val overview: ChatOverview,
    val conversation: ChatConversation,
)

data class ChatCreateResult(
    val overview: ChatOverview,
    val conversation: ChatConversation,
)

data class ChatMembershipUpdateResult(
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
    val chatType: FfiChatType,
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
    val chatType: FfiChatType,
    val title: String,
    val participantsLabel: String,
    val timelineLabel: String,
    val isAccountSyncChat: Boolean,
    val canSend: Boolean,
    val canManageMembers: Boolean,
    val composerHint: String,
    val members: List<ChatConversationMember>,
    val messages: List<ChatTimelineMessage>,
)

data class ChatConversationMember(
    val accountId: String,
    val displayName: String,
    val role: String,
    val membershipStatus: String,
    val isSelf: Boolean,
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

private data class PendingOutboxPreview(
    val previewText: String,
    val queuedAtUnix: Long,
)

private class ReceiptSummaryAccumulator {
    private val deliveredReaders = linkedSetOf<String>()
    private val readReaders = linkedSetOf<String>()

    fun record(
        readerLabel: String,
        receiptType: FfiReceiptType?,
    ) {
        when (receiptType) {
            FfiReceiptType.READ -> {
                deliveredReaders.remove(readerLabel)
                readReaders += readerLabel
            }

            FfiReceiptType.DELIVERED, null -> {
                if (readerLabel !in readReaders) {
                    deliveredReaders += readerLabel
                }
            }
        }
    }

    fun summaryText(): String {
        if (readReaders.isNotEmpty()) {
            return formatSummary(
                prefix = "Read by",
                readers = readReaders.toList(),
            )
        }
        if (deliveredReaders.isNotEmpty()) {
            return formatSummary(
                prefix = "Delivered to",
                readers = deliveredReaders.toList(),
            )
        }
        return ""
    }

    private fun formatSummary(
        prefix: String,
        readers: List<String>,
    ): String {
        return when (readers.size) {
            0 -> ""
            1 -> "$prefix ${readers.first()}"
            2 -> "$prefix ${readers[0]}, ${readers[1]}"
            else -> "$prefix ${readers[0]}, ${readers[1]} +${readers.size - 2}"
        }
    }
}

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
