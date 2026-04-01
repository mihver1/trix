package chat.trix.android.core.chat

import android.content.Context
import android.net.Uri
import chat.trix.android.core.ffi.FfiChatParticipantProfile
import chat.trix.android.core.ffi.FfiAppendHistorySyncChunkResponse
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.DeviceDatabaseKeyStore
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiChatDetail
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiClientStore
import chat.trix.android.core.ffi.FfiClientStoreConfig
import chat.trix.android.core.ffi.FfiCreateChatControlInput
import chat.trix.android.core.ffi.FfiDirectoryAccount
import chat.trix.android.core.ffi.FfiInboxItem
import chat.trix.android.core.ffi.FfiHistorySyncChunk
import chat.trix.android.core.ffi.FfiHistorySyncJob
import chat.trix.android.core.ffi.FfiHistorySyncJobRole
import chat.trix.android.core.ffi.FfiLocalChatListItem
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiLocalOutboxAttachmentDraft
import chat.trix.android.core.ffi.FfiLocalOutboxItem
import chat.trix.android.core.ffi.FfiLocalOutboxStatus
import chat.trix.android.core.ffi.FfiLocalProjectionKind
import chat.trix.android.core.ffi.FfiLocalStoreApplyReport
import chat.trix.android.core.ffi.FfiLeaseInboxParams
import chat.trix.android.core.ffi.FfiLeaseInboxResponse
import chat.trix.android.core.ffi.FfiLocalTimelineItem
import chat.trix.android.core.ffi.FfiMessengerConversationSummary
import chat.trix.android.core.ffi.FfiMessengerException
import chat.trix.android.core.ffi.FfiMessengerMessageBody
import chat.trix.android.core.ffi.FfiMessengerMessageBodyKind
import chat.trix.android.core.ffi.FfiMessengerMessageRecord
import chat.trix.android.core.ffi.FfiMessengerParticipantProfile
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiMessageBodyKind
import chat.trix.android.core.ffi.FfiMessageReactionSummary
import chat.trix.android.core.ffi.FfiModifyChatMembersControlInput
import chat.trix.android.core.ffi.FfiMlsConversation
import chat.trix.android.core.ffi.FfiMlsFacade
import chat.trix.android.core.ffi.FfiReactionAction
import chat.trix.android.core.ffi.FfiReceiptType
import chat.trix.android.core.ffi.FfiSendMessageInput
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiSyncCoordinator
import chat.trix.android.core.ffi.TrixFfiException
import chat.trix.android.core.ffi.ffiParseMessageBody
import chat.trix.android.core.ffi.ffiSerializeMessageBody
import chat.trix.android.core.system.deviceStorageLayout
import java.io.IOException
import java.nio.ByteBuffer
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlin.coroutines.CoroutineContext

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
    private val messengerDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidMessengerClient(appContext, session)
    }
    private val attachmentRepositoryDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AttachmentRepository(
            context = appContext,
            session = session,
        )
    }

    suspend fun loadOverview(): ChatOverview = withContext(Dispatchers.IO) {
        runFfi("Failed to read local chat cache") {
            buildMessengerOverview(
                conversations = messenger().listConversations(),
                rootPath = messenger().rootPath(),
            )
        }
    }

    suspend fun loadConversation(chatId: String): ChatConversation? = withContext(Dispatchers.IO) {
        runFfi("Failed to read conversation") {
            buildMessengerConversation(chatId)
        }
    }

    suspend fun refresh(): ChatRefreshResult = withContext(Dispatchers.IO) {
        runFfi("Failed to sync chats") {
            val snapshot = messenger().loadSnapshot()

            ChatRefreshResult(
                overview = buildMessengerOverview(
                    conversations = snapshot.conversations,
                    rootPath = messenger().rootPath(),
                ),
                historyMessagesUpserted = 0,
                inboxMessagesUpserted = 0,
                ackedInboxCount = 0,
                hydratedChatDetails = 0,
                projectedChatTimelines = snapshot.conversations.size,
                flushedOutboxCount = 0,
            )
        }
    }

    suspend fun hydrateChangedChats(chatIds: Set<String>): Int = withContext(Dispatchers.IO) {
        runFfi("Failed to hydrate changed chats") {
            chatIds.count { chatId -> buildMessengerConversation(chatId) != null }
        }
    }

    suspend fun flushPendingOutbox(): Int = withContext(Dispatchers.IO) {
        runFfi("Failed to flush local outbox") {
            0
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
        val normalizedParticipants = normalizeParticipantAccountIds(listOf(targetAccountId))
        if (normalizedParticipants.isEmpty()) {
            throw IOException("Choose a valid account to start a direct message")
        }

        runFfi("Failed to create direct message") {
            val outcome = messenger().createConversation(
                chatType = FfiChatType.DM,
                title = null,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation ${outcome.conversationId} is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(outcome.conversationId) },
                createResult = ::ChatCreateResult,
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

        runFfi("Failed to create group chat") {
            val outcome = messenger().createConversation(
                chatType = FfiChatType.GROUP,
                title = title,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation ${outcome.conversationId} is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(outcome.conversationId) },
                createResult = ::ChatCreateResult,
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

        runFfi("Failed to add group members") {
            messenger().updateConversationMembers(
                conversationId = chatId,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(chatId) },
                createResult = ::ChatMembershipUpdateResult,
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

        runFfi("Failed to remove group member") {
            messenger().removeConversationMembers(
                conversationId = chatId,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(chatId) },
                createResult = ::ChatMembershipUpdateResult,
            )
        }
    }

    suspend fun sendTextMessage(chatId: String, draft: String): ChatSendResult = withContext(Dispatchers.IO) {
        val normalizedDraft = draft.trim()
        if (normalizedDraft.isEmpty()) {
            throw IOException("Message is empty")
        }

        runFfi("Failed to send message") {
            messenger().sendTextMessage(chatId, normalizedDraft)

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(chatId) },
                createResult = ::ChatSendResult,
            )
        }
    }

    suspend fun sendAttachment(
        chatId: String,
        contentUri: Uri,
    ): ChatSendResult = withContext(Dispatchers.IO) {
        runFfi("Failed to send attachment") {
            val attachment = attachmentRepository().prepareMessengerAttachment(contentUri)
            messenger().sendAttachmentMessage(
                conversationId = chatId,
                payload = attachment.payload,
                metadata = attachment.metadata,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(chatId) },
                createResult = ::ChatSendResult,
            )
        }
    }

    suspend fun sendReaction(
        chatId: String,
        targetMessageId: String,
        emoji: String,
        removeExisting: Boolean,
    ): ChatSendResult = withContext(Dispatchers.IO) {
        val normalizedTargetMessageId = targetMessageId.trim()
        val normalizedEmoji = emoji.trim()
        if (normalizedTargetMessageId.isEmpty() || normalizedEmoji.isEmpty()) {
            throw IOException("Reaction is incomplete")
        }

        runFfi("Failed to send reaction") {
            val store = historyStore()
            store.enqueueOutboxMessage(
                chatId = chatId,
                senderAccountId = session.localState.accountId,
                senderDeviceId = session.localState.deviceId,
                messageId = UUID.randomUUID().toString(),
                body = canonicalizeMessageBody(
                    FfiMessageBody(
                        kind = FfiMessageBodyKind.REACTION,
                        text = null,
                        targetMessageId = normalizedTargetMessageId,
                        emoji = normalizedEmoji,
                        reactionAction = if (removeExisting) {
                            FfiReactionAction.REMOVE
                        } else {
                            FfiReactionAction.ADD
                        },
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
                ),
                queuedAtUnix = currentUnixSeconds().toULong(),
            )
            flushPendingOutboxNow(chatId)

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = ::buildOverview,
                buildConversation = { buildConversation(chatId) },
                createResult = ::ChatSendResult,
            )
        }
    }

    suspend fun openAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        attachmentRepository().openAttachment(attachment)
    }

    suspend fun shareAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        attachmentRepository().shareAttachment(attachment)
    }

    suspend fun loadImagePreviewAttachment(
        attachment: ChatAttachment,
    ): LocalImagePreviewAttachment = withContext(Dispatchers.IO) {
        attachmentRepository().loadImagePreviewAttachment(attachment)
    }

    suspend fun markConversationRead(chatId: String): ChatReadResult = withContext(Dispatchers.IO) {
        runFfi("Failed to update chat read state") {
            val previousUnreadCount = messengerConversationSummary(chatId)?.unreadCount?.toLong()
            messenger().markRead(chatId)
            val updatedUnreadCount = messengerConversationSummary(chatId)?.unreadCount?.toLong()

            ChatReadResult(
                overview = buildMessengerOverview(
                    conversations = messenger().listConversations(),
                    rootPath = messenger().rootPath(),
                ),
                changed = previousUnreadCount != updatedUnreadCount,
            )
        }
    }

    // region FFI parity — methods aligned with iOS/macOS bridge surfaces

    suspend fun getAccount(accountId: String): ChatDirectoryAccount = withContext(Dispatchers.IO) {
        runFfi("Failed to look up account") {
            val client = client()
            client.setAccessToken(session.accessToken)
            mapDirectoryAccount(client.getAccount(accountId))
        }
    }

    suspend fun getChatHistory(
        chatId: String,
        afterServerSeq: ULong? = null,
        limit: UInt = HISTORY_SYNC_LIMIT,
    ): List<ChatTimelineMessage> = withContext(Dispatchers.IO) {
        runFfi("Failed to load chat history") {
            val client = client()
            client.setAccessToken(session.accessToken)
            val history = client.getChatHistory(chatId, afterServerSeq, limit)
            history.messages.map { envelope ->
                ChatTimelineMessage(
                    id = envelope.messageId,
                    author = accountDisplayName(envelope.senderAccountId),
                    body = "seq=${envelope.serverSeq} epoch=${envelope.epoch}",
                    timestampLabel = envelope.createdAtUnix.toLong().formatChatTimestamp(),
                    isMine = envelope.senderAccountId == session.localState.accountId,
                    note = null,
                    contentType = envelope.contentType,
                )
            }
        }
    }

    suspend fun listChatReadStates(): List<ChatReadStateSummary> = withContext(Dispatchers.IO) {
        runFfi("Failed to list chat read states") {
            val store = historyStore()
            store.listChatReadStates(session.localState.accountId).map { state ->
                ChatReadStateSummary(
                    chatId = state.chatId,
                    readCursorServerSeq = state.readCursorServerSeq.toLong(),
                    unreadCount = state.unreadCount.toLong(),
                )
            }
        }
    }

    suspend fun projectedCursor(chatId: String): Long? = withContext(Dispatchers.IO) {
        runFfi("Failed to read projected cursor") {
            historyStore().projectedCursor(chatId)?.toLong()
        }
    }

    suspend fun pollOnce(): ChatRefreshResult = withContext(Dispatchers.IO) {
        runFfi("Failed to poll realtime") {
            val batch = messenger().getNewEvents(checkpoint = null)

            ChatRefreshResult(
                overview = buildMessengerOverview(
                    conversations = messenger().listConversations(),
                    rootPath = messenger().rootPath(),
                ),
                historyMessagesUpserted = 0,
                inboxMessagesUpserted = batch.changedChatIds.size.toLong(),
                ackedInboxCount = 0,
                hydratedChatDetails = 0,
                projectedChatTimelines = batch.changedChatIds.size,
                flushedOutboxCount = 0,
            )
        }
    }

    suspend fun ciphersuiteLabel(): String = withContext(Dispatchers.IO) {
        runFfi("Failed to read MLS ciphersuite") {
            mlsFacade().ciphersuiteLabel()
        }
    }

    suspend fun clearSessionToken() = withContext(Dispatchers.IO) {
        runFfi("Failed to clear session token") {
            client().clearAccessToken()
        }
    }

    suspend fun addChatDevices(
        chatId: String,
        deviceIds: List<String>,
    ): ChatMembershipUpdateResult = withContext(Dispatchers.IO) {
        runFfi("Failed to add chat devices") {
            messenger().updateConversationDevices(
                conversationId = chatId,
                deviceIds = deviceIds,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(chatId) },
                createResult = ::ChatMembershipUpdateResult,
            )
        }
    }

    suspend fun removeChatDevices(
        chatId: String,
        deviceIds: List<String>,
    ): ChatMembershipUpdateResult = withContext(Dispatchers.IO) {
        runFfi("Failed to remove chat devices") {
            messenger().removeConversationDevices(
                conversationId = chatId,
                deviceIds = deviceIds,
            )

            buildMutationConversationResult(
                unavailableMessage = "Conversation $chatId is no longer available",
                buildOverview = {
                    buildMessengerOverview(
                        conversations = messenger().listConversations(),
                        rootPath = messenger().rootPath(),
                    )
                },
                buildConversation = { buildMessengerConversation(chatId) },
                createResult = ::ChatMembershipUpdateResult,
            )
        }
    }

    suspend fun mlsStorageRoot(): String? = withContext(Dispatchers.IO) {
        runFfi("Failed to read MLS storage root") {
            clientStore().mlsStorageRoot()
        }
    }

    suspend fun mlsCredentialIdentity(): ByteArray = withContext(Dispatchers.IO) {
        runFfi("Failed to read MLS credential identity") {
            mlsFacade().credentialIdentity()
        }
    }

    suspend fun listHistorySyncJobs(
        role: FfiHistorySyncJobRole? = null,
    ): List<FfiHistorySyncJob> = withContext(Dispatchers.IO) {
        runFfi("Failed to list history sync jobs") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.listHistorySyncJobs(role, null, null)
        }
    }

    suspend fun getHistorySyncChunks(jobId: String): List<FfiHistorySyncChunk> = withContext(Dispatchers.IO) {
        runFfi("Failed to load history sync chunks") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.getHistorySyncChunks(jobId)
        }
    }

    suspend fun appendHistorySyncChunk(
        jobId: String,
        sequenceNo: ULong,
        payload: ByteArray,
        cursorJson: String?,
        isFinal: Boolean,
    ): FfiAppendHistorySyncChunkResponse = withContext(Dispatchers.IO) {
        runFfi("Failed to append history sync chunk") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.appendHistorySyncChunk(jobId, sequenceNo, payload, cursorJson, isFinal)
        }
    }

    suspend fun getInbox(
        afterInboxId: ULong? = null,
        limit: UInt = INBOX_SYNC_LIMIT,
    ): List<FfiInboxItem> = withContext(Dispatchers.IO) {
        runFfi("Failed to fetch inbox") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.getInbox(afterInboxId, limit).items
        }
    }

    suspend fun leaseInbox(
        leaseOwner: String? = null,
        limit: UInt? = INBOX_SYNC_LIMIT,
        afterInboxId: ULong? = null,
        leaseTtlSeconds: ULong? = LEASE_TTL_SECONDS,
    ): FfiLeaseInboxResponse = withContext(Dispatchers.IO) {
        runFfi("Failed to lease inbox") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.leaseInbox(
                FfiLeaseInboxParams(
                    leaseOwner = leaseOwner ?: syncCoordinator().leaseOwner(),
                    limit = limit,
                    afterInboxId = afterInboxId,
                    leaseTtlSeconds = leaseTtlSeconds,
                ),
            )
        }
    }

    suspend fun ackInbox(inboxIds: List<ULong>): List<ULong> = withContext(Dispatchers.IO) {
        runFfi("Failed to ack inbox") {
            val client = client()
            client.setAccessToken(session.accessToken)
            syncCoordinator().ackInbox(client = client, inboxIds = inboxIds).ackedInboxIds
        }
    }

    suspend fun leaseInboxWithSyncCoordinator(
        limit: UInt? = INBOX_SYNC_LIMIT,
        leaseTtlSeconds: ULong? = LEASE_TTL_SECONDS,
    ): FfiLeaseInboxResponse = withContext(Dispatchers.IO) {
        runFfi("Failed to lease inbox through sync coordinator") {
            val client = client()
            client.setAccessToken(session.accessToken)
            syncCoordinator().leaseInbox(
                client = client,
                limit = limit,
                leaseTtlSeconds = leaseTtlSeconds,
            )
        }
    }

    suspend fun ackInboxWithSyncCoordinator(inboxIds: List<ULong>): List<ULong> = withContext(Dispatchers.IO) {
        runFfi("Failed to ack inbox through sync coordinator") {
            val client = client()
            client.setAccessToken(session.accessToken)
            syncCoordinator().ackInbox(client = client, inboxIds = inboxIds).ackedInboxIds
        }
    }

    suspend fun applyLeasedInbox(
        lease: FfiLeaseInboxResponse,
    ): FfiLocalStoreApplyReport = withContext(Dispatchers.IO) {
        runFfi("Failed to apply leased inbox to local store") {
            val report = historyStore().applyLeasedInbox(lease)
            lease.items.forEach { item ->
                syncCoordinator().recordChatServerSeq(
                    chatId = item.message.chatId,
                    serverSeq = item.message.serverSeq,
                )
            }
            report
        }
    }

    suspend fun recordChatServerSeq(
        chatId: String,
        serverSeq: ULong,
    ): Boolean = withContext(Dispatchers.IO) {
        runFfi("Failed to record chat server sequence") {
            syncCoordinator().recordChatServerSeq(chatId, serverSeq)
        }
    }

    suspend fun completeHistorySyncJob(
        jobId: String,
        cursorJson: String? = null,
    ): chat.trix.android.core.ffi.FfiCompleteHistorySyncJobResponse = withContext(Dispatchers.IO) {
        runFfi("Failed to complete history sync job") {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.completeHistorySyncJob(jobId, cursorJson)
        }
    }

    suspend fun signingKeyFingerprint(prefixBytes: Int = 8): String = withContext(Dispatchers.IO) {
        runFfi("Failed to read signing key fingerprint") {
            mlsFacade()
                .signaturePublicKey()
                .take(prefixBytes)
                .joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
        }
    }

    suspend fun inspectLocalConversation(chatId: String): LocalConversationDiagnostics? = withContext(Dispatchers.IO) {
        runFfi("Failed to inspect local conversation state") {
            val conversation = historyStore().loadOrBootstrapChatConversation(chatId, mlsFacade()) ?: return@runFfi null
            val members = mlsFacade().members(conversation)
            val ratchetTree = conversation.exportRatchetTree()
            LocalConversationDiagnostics(
                chatCursor = syncCoordinator().chatCursor(chatId)?.toLong(),
                memberCount = members.size,
                ratchetTreeBytes = ratchetTree.size,
            )
        }
    }

    // endregion

    override fun close() {
        if (messengerDelegate.isInitialized()) {
            messengerDelegate.value.close()
        }
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

    private fun buildMessengerOverview(
        conversations: List<FfiMessengerConversationSummary>,
        rootPath: String,
    ): ChatOverview {
        val summaries = conversations.map(::mapMessengerConversationSummary)
        val cachedMessageCount = conversations.sumOf { conversation ->
            conversation.lastServerSeq.toLong().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }

        return ChatOverview(
            conversations = summaries,
            diagnostics = ChatDiagnostics(
                cachedChatCount = summaries.size,
                cachedMessageCount = cachedMessageCount,
                projectedChatCount = summaries.size,
                pendingOutboxCount = conversations.sumOf { it.pendingMessageCount.toIntClamped() },
                lastAckedInboxId = null,
                leaseOwner = "messenger-core",
                historyStorePath = "$rootPath/client-store.sqlite",
                syncStatePath = "$rootPath/messenger-state.bin",
            ),
        )
    }

    private fun buildMessengerConversation(chatId: String): ChatConversation? {
        val conversation = messengerConversationSummary(chatId) ?: return null
        val messages = messenger().getAllMessages(chatId)
        return ChatConversation(
            chatId = conversation.conversationId,
            chatType = conversation.conversationType,
            title = conversation.displayTitle,
            participantsLabel = messengerParticipantsLabel(conversation),
            timelineLabel = if (messages.isEmpty()) "No messages yet" else "Synced by messenger core",
            isAccountSyncChat = conversation.conversationId == session.localState.accountSyncChatId,
            canSend = session.localState.deviceStatus.equals("active", ignoreCase = true),
            canManageMembers = conversation.conversationType == FfiChatType.GROUP,
            composerHint = when (conversation.conversationType) {
                FfiChatType.ACCOUNT_SYNC ->
                    "This private account sync thread is fully handled by the shared messenger core."

                FfiChatType.GROUP ->
                    "Messages, attachments, receipts, and membership changes are handled by the shared messenger core."

                FfiChatType.DM ->
                    "Messages, attachments, and receipts are handled by the shared messenger core."
            },
            members = messengerConversationMembers(conversation),
            messages = mapMessengerTimelineMessages(messages),
        )
    }

    private fun mapMessengerConversationSummary(
        conversation: FfiMessengerConversationSummary,
    ): ChatConversationSummary {
        return ChatConversationSummary(
            chatId = conversation.conversationId,
            chatType = conversation.conversationType,
            title = conversation.displayTitle,
            participantsLabel = messengerParticipantsLabel(conversation),
            lastMessagePreview = messengerPreviewLabel(conversation),
            timestampLabel = conversation.previewCreatedAtUnix?.toLong()?.formatChatTimestamp() ?: "No messages yet",
            messageCount = conversation.lastServerSeq.toIntClamped(),
            unreadCount = conversation.unreadCount.toIntClamped(),
            hasProjectedTimeline = true,
            isAccountSyncChat = conversation.conversationId == session.localState.accountSyncChatId,
        )
    }

    private fun messengerConversationSummary(chatId: String): FfiMessengerConversationSummary? {
        return messenger().listConversations().firstOrNull { it.conversationId == chatId }
    }

    private fun messengerParticipantsLabel(
        conversation: FfiMessengerConversationSummary,
    ): String {
        val participants = conversation.participantProfiles
            .filterNot { profile ->
                profile.accountId == session.localState.accountId && conversation.participantProfiles.size > 1
            }
            .ifEmpty { conversation.participantProfiles }

        if (participants.isEmpty()) {
            return when (conversation.conversationType) {
                FfiChatType.ACCOUNT_SYNC -> "Private cross-device sync channel"
                FfiChatType.GROUP -> "Member metadata pending"
                FfiChatType.DM -> "Direct conversation"
            }
        }

        val visibleMembers = participants
            .take(MAX_VISIBLE_MEMBERS)
            .joinToString(", ", transform = ::messengerParticipantDisplayName)
        val remainder = participants.size - MAX_VISIBLE_MEMBERS
        return if (remainder > 0) {
            "$visibleMembers +$remainder"
        } else {
            visibleMembers
        }
    }

    private fun messengerConversationMembers(
        conversation: FfiMessengerConversationSummary,
    ): List<ChatConversationMember> {
        return conversation.participantProfiles.map { profile ->
            ChatConversationMember(
                accountId = profile.accountId,
                displayName = messengerParticipantDisplayName(profile),
                role = if (profile.accountId == session.localState.accountId) "self" else "participant",
                membershipStatus = "active",
                isSelf = profile.accountId == session.localState.accountId,
            )
        }
    }

    private fun messengerParticipantDisplayName(profile: FfiMessengerParticipantProfile): String {
        if (profile.accountId == session.localState.accountId) {
            return "You"
        }
        return profile.profileName.takeIf(String::isNotBlank)
            ?: profile.handle?.takeIf(String::isNotBlank)?.let { "@$it" }
            ?: shortAccountId(profile.accountId)
    }

    private fun messengerPreviewLabel(conversation: FfiMessengerConversationSummary): String {
        val previewText = conversation.previewText?.trim()?.takeIf(String::isNotEmpty) ?: return "No messages yet"
        val senderLabel = when {
            conversation.previewIsOutgoing == true -> "You"
            !conversation.previewSenderDisplayName.isNullOrBlank() -> conversation.previewSenderDisplayName
            !conversation.previewSenderAccountId.isNullOrBlank() -> shortAccountId(conversation.previewSenderAccountId!!)
            else -> null
        }
        return if (senderLabel != null) {
            "$senderLabel: $previewText"
        } else {
            previewText
        }
    }

    private fun mapMessengerTimelineMessages(
        messages: List<FfiMessengerMessageRecord>,
    ): List<ChatTimelineMessage> {
        return messages
            .filterNot(::isMessengerReceiptMessage)
            .map { message ->
                mapMessengerTimelineMessage(
                    message = message,
                    receiptStatus = message.receiptStatus?.let(::receiptStatusFromFfi),
                )
            }
    }

    private fun mapMessengerTimelineMessage(
        message: FfiMessengerMessageRecord,
        receiptStatus: ChatReceiptStatus?,
    ): ChatTimelineMessage {
        return ChatTimelineMessage(
            id = message.messageId,
            author = if (message.isOutgoing) {
                "You"
            } else {
                message.senderDisplayName?.takeIf(String::isNotBlank)
                    ?: shortAccountId(message.senderAccountId)
            },
            body = messengerTimelineBody(message),
            timestampLabel = message.createdAtUnix.toLong().formatChatTimestamp(),
            isMine = message.isOutgoing,
            note = null,
            contentType = message.contentType,
            attachment = messengerAttachmentFrom(message),
            receiptStatus = if (message.isOutgoing) receiptStatus else null,
        )
    }

    private fun messengerAttachmentFrom(
        message: FfiMessengerMessageRecord,
    ): ChatAttachment? {
        val attachment = message.body?.attachment ?: return null
        return ChatAttachment(
            messageId = message.messageId,
            blobId = attachment.attachmentRef,
            attachmentRef = attachment.attachmentRef,
            mimeType = attachment.mimeType,
            fileName = attachment.fileName,
            sizeBytes = attachment.sizeBytes.toLong(),
            widthPx = attachment.widthPx?.toInt(),
            heightPx = attachment.heightPx?.toInt(),
            body = null,
        )
    }

    private fun messengerTimelineBody(message: FfiMessengerMessageRecord): String {
        val body = message.body ?: return message.previewText.trim().takeIf(String::isNotEmpty)
            ?: "Encrypted application payload"
        return when (body.kind) {
            FfiMessengerMessageBodyKind.TEXT -> body.text
                ?.trim()
                ?.takeIf(String::isNotEmpty)
                ?: message.previewText.trim().takeIf(String::isNotEmpty)
                ?: "Message content is unavailable on this device."

            FfiMessengerMessageBodyKind.REACTION ->
                "Reacted ${body.emoji.orEmpty()} to ${body.targetMessageId?.let(::shortMessageId) ?: "message"}"

            FfiMessengerMessageBodyKind.RECEIPT ->
                "${body.receiptType?.name?.lowercase()?.replaceFirstChar(Char::uppercase) ?: "Delivery"} receipt"

            FfiMessengerMessageBodyKind.ATTACHMENT ->
                body.attachment?.fileName ?: body.attachment?.mimeType ?: "Attachment"

            FfiMessengerMessageBodyKind.CHAT_EVENT ->
                body.eventType?.trim()?.takeIf(String::isNotEmpty) ?: "Chat event"
        }
    }

    private fun isMessengerReceiptMessage(message: FfiMessengerMessageRecord): Boolean {
        return message.contentType == FfiContentType.RECEIPT ||
            message.body?.kind == FfiMessengerMessageBodyKind.RECEIPT
    }

    private fun buildOverview(): ChatOverview {
        val store = historyStore()
        val selfAccountId = session.localState.accountId
        val syncSnapshot = syncCoordinator().stateSnapshot()
        val leaseOwner = syncCoordinator().leaseOwner()
        val syncStatePath = syncCoordinator().statePath() ?: clientStore().databasePath()
        val conversations = store.listLocalChatListItems(selfAccountId).map { item ->
            val detail = store.getChat(item.chatId)
            val pendingOutboxMessages = store.listOutboxMessages(item.chatId)
            val filteredTimelineItems = visibleTimelineItems(
                store.getLocalTimelineItems(
                    item.chatId,
                    selfAccountId,
                    null,
                    null,
                ),
            )
            val filteredPendingOutboxMessages = visiblePendingOutboxMessages(pendingOutboxMessages)
            val visibleMessageCount = filteredTimelineItems.size + filteredPendingOutboxMessages.size
            val pendingPreview = pendingOutboxPreview(filteredPendingOutboxMessages)
            val latestVisibleTimelineItem = filteredTimelineItems.maxWithOrNull(
                compareBy<FfiLocalTimelineItem> { it.serverSeq }
                    .thenBy { it.createdAtUnix },
            )
            val previewText = when {
                pendingPreview != null && (
                    latestVisibleTimelineItem == null ||
                        pendingPreview.queuedAtUnix >= latestVisibleTimelineItem.createdAtUnix.toLong()
                ) ->
                    pendingPreview.previewText
                latestVisibleTimelineItem != null -> timelinePreviewLabel(latestVisibleTimelineItem)
                else -> if (visibleMessageCount > 0) chatPreviewLabel(item) else "No messages yet"
            }
            val timestampLabel = when {
                pendingPreview != null && (
                    latestVisibleTimelineItem == null ||
                        pendingPreview.queuedAtUnix >= latestVisibleTimelineItem.createdAtUnix.toLong()
                ) ->
                    pendingPreview.queuedAtUnix.formatChatTimestamp()
                latestVisibleTimelineItem != null -> latestVisibleTimelineItem.createdAtUnix.toLong().formatChatTimestamp()
                else -> "No local timeline"
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
                messageCount = visibleMessageCount,
                unreadCount = item.unreadCount.toInt(),
                hasProjectedTimeline = visibleMessageCount > 0,
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
                leaseOwner = leaseOwner,
                historyStorePath = store.databasePath(),
                syncStatePath = syncStatePath,
            ),
        )
    }

    private fun buildConversation(chatId: String): ChatConversation? {
        val store = historyStore()
        val selfAccountId = session.localState.accountId
        val item = store.getLocalChatListItem(chatId, selfAccountId) ?: return null
        recoverConversationProjectionBestEffort(
            projectLocally = {
                ensureConversationProjection(chatId, store)
            },
            repairHistoryLocally = {
                repairConversationHistoryIfNeeded(
                    chatId = chatId,
                    lastKnownServerSeq = item.lastServerSeq.toLong(),
                    store = store,
                )
            },
            refreshFromServer = {
                val client = client()
                client.setAccessToken(session.accessToken)
                refreshConversationFromServer(
                    chatId = chatId,
                    client = client,
                    store = store,
                )
            },
        )
        val detail = store.getChat(chatId)
        val timelineItems = store.getLocalTimelineItems(chatId, selfAccountId, null, null)
        val pendingOutboxItems = store.listOutboxMessages(chatId)
        val filteredTimelineItems = visibleTimelineItems(timelineItems)
        val filteredPendingOutboxItems = visiblePendingOutboxMessages(pendingOutboxItems)
        val hasLocalMlsState = hasLocalConversation(chatId)
        val canSend = item.chatType == FfiChatType.ACCOUNT_SYNC || hasLocalMlsState
        val messages = mergeTimelineMessages(
            timelineItems = filteredTimelineItems,
            pendingOutboxItems = filteredPendingOutboxItems,
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
            timelineLabel = conversationTimelineLabel(item, filteredTimelineItems, filteredPendingOutboxItems),
            isAccountSyncChat = chatId == session.localState.accountSyncChatId,
            canSend = canSend,
            canManageMembers = item.chatType == FfiChatType.GROUP && canSend,
            composerHint = when {
                item.chatType == FfiChatType.ACCOUNT_SYNC -> {
                    "Messages use this device's local MLS state for the account sync thread."
                }

                filteredPendingOutboxItems.isNotEmpty() -> "Queued messages retry automatically when the device reconnects."
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
        val orderedMessages = timelineItems.mapIndexed { index, message ->
            TimedChatTimelineMessage(
                sortUnix = message.createdAtUnix.toLong(),
                sourcePriority = 0,
                sourceOrder = index,
                message = mapTimelineMessage(message),
                isVisibleInTimeline = message.isVisibleInTimeline,
            )
        } + pendingOutboxItems.mapIndexed { index, message ->
            TimedChatTimelineMessage(
                sortUnix = message.queuedAtUnix.toLong(),
                sourcePriority = 1,
                sourceOrder = index,
                message = mapOutboxMessage(message),
                isVisibleInTimeline = isVisibleOutboxMessage(message),
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
                    item.isVisibleInTimeline &&
                    item.serverSeq.toLong() <= readCursorServerSeq &&
                    item.serverSeq.toLong() > (previousReadCursorServerSeq ?: 0L)
            }
            ?: return

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
            body = canonicalizeMessageBody(
                FfiMessageBody(
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

    private fun repairConversationHistoryIfNeeded(
        chatId: String,
        lastKnownServerSeq: Long,
        store: FfiLocalHistoryStore = historyStore(),
    ) {
        val projectedCursor = store.projectedCursor(chatId)?.toLong() ?: 0L
        if (projectedCursor >= lastKnownServerSeq) {
            return
        }

        val client = client()
        client.setAccessToken(session.accessToken)
        refreshConversationFromServer(
            chatId = chatId,
            client = client,
            store = store,
        )
    }

    private fun refreshConversationFromServer(
        chatId: String,
        client: FfiServerApiClient,
        store: FfiLocalHistoryStore = historyStore(),
    ) {
        val detail = client.getChat(chatId)
        store.applyChatDetail(detail)
        val history = client.getChatHistory(chatId, null, null)
        store.applyChatHistory(history)
        history.messages.maxOfOrNull { it.serverSeq.toLong() }?.let { lastServerSeq ->
            syncCoordinator().recordChatServerSeq(chatId, lastServerSeq.toULong())
        }
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

    private fun canonicalizeMessageBody(body: FfiMessageBody): FfiMessageBody {
        val payload = ffiSerializeMessageBody(body)
        return ffiParseMessageBody(ffiContentTypeForBody(body), payload)
    }

    private fun messenger(): AndroidMessengerClient = messengerDelegate.value

    private fun client(): FfiServerApiClient = clientDelegate.value

    private fun clientStore(): FfiClientStore = clientStoreDelegate.value

    private fun historyStore(): FfiLocalHistoryStore = historyStoreDelegate.value

    private fun syncCoordinator(): FfiSyncCoordinator = syncCoordinatorDelegate.value

    private fun mlsFacade(): FfiMlsFacade = mlsFacadeDelegate.value

    private fun attachmentRepository(): AttachmentRepository = attachmentRepositoryDelegate.value

    private suspend fun <T> runFfi(
        fallbackMessage: String,
        block: suspend () -> T,
    ): T {
        return sessionOperationGate().withLock {
            try {
                block()
            } catch (error: CancellationException) {
                throw error
            } catch (error: FfiMessengerException) {
                throw IOException(ffiMessengerMessage(error), error)
            } catch (error: TrixFfiException) {
                throw IOException(error.message ?: fallbackMessage, error)
            } catch (error: UnsatisfiedLinkError) {
                throw IOException("Rust FFI library is not available in the Android app bundle", error)
            } catch (error: RuntimeException) {
                throw IOException(fallbackMessage, error)
            }
        }
    }

    private fun sessionOperationGate(): SessionOperationGate {
        return SESSION_OPERATION_GATES.computeIfAbsent(
            storageLayout.sessionRoot.absolutePath,
        ) { SessionOperationGate() }
    }

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
        if (timelineItems.isEmpty()) {
            if (pendingOutboxItems.isNotEmpty()) {
                return "Queued locally"
            }
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
        } else if (pendingOutboxItems.isNotEmpty()) {
            "Projected timeline + queued outbox"
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
            receiptStatus = message.receiptStatus?.let(::receiptStatusFromFfi),
            reactions = message.reactions.map(::mapReactionSummary),
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
            receiptStatus = null,
            reactions = emptyList(),
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
            FfiMessageBodyKind.TEXT -> body.text
                ?.trim()
                ?.takeIf(String::isNotEmpty)
                ?: "Message content is unavailable on this device."
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

    private fun pendingOutboxPreview(
        pendingOutboxMessages: List<FfiLocalOutboxItem>,
    ): PendingOutboxPreview? {
        val latest = pendingOutboxMessages.maxByOrNull(FfiLocalOutboxItem::queuedAtUnix) ?: return null
        val previewText = latest.body?.let(::structuredBodyText)
            ?: latest.attachmentDraft?.fileName
            ?: latest.attachmentDraft?.mimeType
            ?: "Queued attachment"
        return PendingOutboxPreview(
            previewText = previewText,
            queuedAtUnix = latest.queuedAtUnix.toLong(),
        )
    }

    private fun timelinePreviewLabel(item: FfiLocalTimelineItem): String {
        val previewText = item.body?.let(::structuredBodyText)
            ?: item.previewText
                .trim()
                .takeIf(String::isNotEmpty)
            ?: item.bodyParseError
            ?: "Encrypted application payload"
        val senderLabel = if (item.isOutgoing) {
            "You"
        } else {
            item.senderDisplayName.takeIf(String::isNotBlank)
                ?: shortAccountId(item.senderAccountId)
        }
        return "$senderLabel: $previewText"
    }

    private fun visibleTimelineItems(
        timelineItems: List<FfiLocalTimelineItem>,
    ): List<FfiLocalTimelineItem> {
        return timelineItems.filter(FfiLocalTimelineItem::isVisibleInTimeline)
    }

    private fun visiblePendingOutboxMessages(
        pendingOutboxMessages: List<FfiLocalOutboxItem>,
    ): List<FfiLocalOutboxItem> {
        return pendingOutboxMessages.filter(::isVisibleOutboxMessage)
    }

    private fun isVisibleOutboxMessage(message: FfiLocalOutboxItem): Boolean {
        return when (message.body?.kind) {
            FfiMessageBodyKind.REACTION, FfiMessageBodyKind.RECEIPT -> false
            else -> true
        }
    }

    private fun receiptStatusFromFfi(status: FfiReceiptType): ChatReceiptStatus {
        return when (status) {
            FfiReceiptType.READ -> ChatReceiptStatus.READ
            FfiReceiptType.DELIVERED -> ChatReceiptStatus.DELIVERED
        }
    }

    private fun mapReactionSummary(summary: FfiMessageReactionSummary): ChatMessageReaction {
        return ChatMessageReaction(
            emoji = summary.emoji,
            reactorAccountIds = summary.reactorAccountIds,
            count = summary.count.toInt(),
            includesSelf = summary.includesSelf,
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

    private fun shortMessageId(messageId: String): String {
        return if (messageId.length <= 10) {
            messageId
        } else {
            "${messageId.take(6)}…"
        }
    }

    private fun ULong.toIntClamped(): Int {
        return toLong().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    private fun accountDisplayName(accountId: String): String {
        return if (accountId == session.localState.accountId) {
            "You"
        } else {
            shortAccountId(accountId)
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
        private val SESSION_OPERATION_GATES = ConcurrentHashMap<String, SessionOperationGate>()
    }
}

internal class SessionOperationGate {
    private val mutex = Mutex()

    suspend fun <T> withLock(block: suspend () -> T): T {
        val token = currentCoroutineContext()[SessionOperationGateContext]
        if (token?.gate === this) {
            return block()
        }

        mutex.lock()
        try {
            return withContext(SessionOperationGateContext(this)) {
                block()
            }
        } finally {
            mutex.unlock()
        }
    }
}

private class SessionOperationGateContext(
    val gate: SessionOperationGate,
) : CoroutineContext.Element {
    companion object Key : CoroutineContext.Key<SessionOperationGateContext>

    override val key: CoroutineContext.Key<*>
        get() = Key
}

internal fun recoverConversationProjectionBestEffort(
    projectLocally: () -> Unit,
    repairHistoryLocally: () -> Unit,
    refreshFromServer: () -> Unit,
) {
    try {
        projectLocally()
        repairHistoryLocally()
        projectLocally()
    } catch (_: Exception) {
        try {
            refreshFromServer()
            projectLocally()
        } catch (_: Exception) {
            // Keep successful mutations visible even when best-effort repair is offline.
        }
    }
}

internal fun <T> buildMutationConversationResult(
    unavailableMessage: String,
    buildOverview: () -> ChatOverview,
    buildConversation: () -> ChatConversation?,
    createResult: (ChatOverview, ChatConversation) -> T,
): T {
    val overview = buildOverview()
    val conversation = buildConversation() ?: throw IOException(unavailableMessage)
    return createResult(overview, conversation)
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

data class LocalConversationDiagnostics(
    val chatCursor: Long?,
    val memberCount: Int,
    val ratchetTreeBytes: Int,
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

data class ChatReadStateSummary(
    val chatId: String,
    val readCursorServerSeq: Long,
    val unreadCount: Long,
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
    val receiptStatus: ChatReceiptStatus? = null,
    val reactions: List<ChatMessageReaction> = emptyList(),
)

enum class ChatReceiptStatus {
    DELIVERED,
    READ,
}

data class ChatMessageReaction(
    val emoji: String,
    val reactorAccountIds: List<String>,
    val count: Int,
    val includesSelf: Boolean,
)

private data class PendingOutboxPreview(
    val previewText: String,
    val queuedAtUnix: Long,
)

data class ChatAttachment(
    val messageId: String,
    val blobId: String,
    val attachmentRef: String? = null,
    val mimeType: String,
    val fileName: String?,
    val sizeBytes: Long?,
    val widthPx: Int?,
    val heightPx: Int?,
    val body: FfiMessageBody? = null,
)
