package chat.trix.android.core.chat

import android.content.Context
import android.net.Uri
import chat.trix.android.R
import chat.trix.android.core.ffi.FfiChatParticipantProfile
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.DeviceDatabaseKeyStore
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiChatDetail
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiLeaveChatScope
import chat.trix.android.core.ffi.FfiClientStore
import chat.trix.android.core.ffi.FfiClientStoreConfig
import chat.trix.android.core.ffi.FfiCreateChatControlInput
import chat.trix.android.core.ffi.FfiDirectoryAccount
import chat.trix.android.core.ffi.FfiHistorySyncJobStatus
import chat.trix.android.core.ffi.FfiHistorySyncJobType
import chat.trix.android.core.ffi.FfiInboxItem
import chat.trix.android.core.ffi.FfiLocalChatListItem
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiLocalOutboxItem
import chat.trix.android.core.ffi.FfiLocalOutboxStatus
import chat.trix.android.core.ffi.FfiLocalProjectionKind
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
import chat.trix.android.core.ffi.FfiMlsFacade
import chat.trix.android.core.ffi.FfiReactionAction
import chat.trix.android.core.ffi.FfiReceiptType
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiSyncCoordinator
import chat.trix.android.core.ffi.TrixFfiException
import chat.trix.android.core.system.deviceStorageLayout
import java.io.IOException
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
        runFfi(text(R.string.chat_error_read_local_cache)) {
            buildMessengerOverview(
                conversations = messenger().listConversations(),
                rootPath = messenger().rootPath(),
            )
        }
    }

    suspend fun loadConversation(chatId: String): ChatConversation? = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_read_conversation)) {
            buildMessengerConversation(chatId)
        }
    }

    suspend fun refresh(): ChatRefreshResult = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_sync_chats)) {
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
        runFfi(text(R.string.chat_error_hydrate_changed_chats)) {
            chatIds.count { chatId -> buildMessengerConversation(chatId) != null }
        }
    }

    suspend fun flushPendingOutbox(): Int = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_flush_local_outbox)) {
            0
        }
    }

    suspend fun searchAccountDirectory(query: String): List<ChatDirectoryAccount> = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_search_account_directory)) {
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
            throw IOException(text(R.string.chat_error_invalid_dm_account))
        }

        runFfi(text(R.string.chat_error_create_direct_message)) {
            val outcome = messenger().createConversation(
                chatType = FfiChatType.DM,
                title = null,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    outcome.conversationId,
                ),
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
            throw IOException(text(R.string.chat_error_group_minimum_participants, MIN_GROUP_PARTICIPANTS))
        }

        runFfi(text(R.string.chat_error_create_group_chat)) {
            val outcome = messenger().createConversation(
                chatType = FfiChatType.GROUP,
                title = title,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    outcome.conversationId,
                ),
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
            throw IOException(text(R.string.chat_error_select_member_to_add))
        }

        runFfi(text(R.string.chat_error_add_group_members)) {
            messenger().updateConversationMembers(
                conversationId = chatId,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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
            throw IOException(text(R.string.chat_error_invalid_remove_member))
        }

        runFfi(text(R.string.chat_error_remove_group_member)) {
            messenger().removeConversationMembers(
                conversationId = chatId,
                participantAccountIds = normalizedParticipants,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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
            throw IOException(text(R.string.chat_error_message_empty))
        }

        runFfi(text(R.string.chat_error_send_message)) {
            messenger().sendTextMessage(chatId, normalizedDraft)

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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
        runFfi(text(R.string.chat_error_send_attachment)) {
            val attachment = attachmentRepository().prepareMessengerAttachment(contentUri)
            messenger().sendAttachmentMessage(
                conversationId = chatId,
                payload = attachment.payload,
                metadata = attachment.metadata,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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
            throw IOException(text(R.string.chat_error_reaction_incomplete))
        }

        runFfi(text(R.string.chat_error_send_reaction)) {
            messenger().sendReaction(
                conversationId = chatId,
                targetMessageId = normalizedTargetMessageId,
                emoji = normalizedEmoji,
                removeExisting = removeExisting,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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
        runFfi(text(R.string.chat_error_update_read_state)) {
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
        runFfi(text(R.string.chat_error_lookup_account)) {
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
        runFfi(text(R.string.chat_error_load_chat_history)) {
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

    suspend fun clearSessionToken() = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_clear_session_token)) {
            client().clearAccessToken()
        }
    }

    suspend fun addChatDevices(
        chatId: String,
        deviceIds: List<String>,
    ): ChatMembershipUpdateResult = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_add_chat_devices)) {
            messenger().updateConversationDevices(
                conversationId = chatId,
                deviceIds = deviceIds,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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
        runFfi(text(R.string.chat_error_remove_chat_devices)) {
            messenger().removeConversationDevices(
                conversationId = chatId,
                deviceIds = deviceIds,
            )

            buildMutationConversationResult(
                unavailableMessage = text(
                    R.string.chat_error_conversation_no_longer_available,
                    chatId,
                ),
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

    suspend fun leaveChat(
        chatId: String,
        scope: FfiLeaveChatScope,
    ): ChatLifecycleMutationResult = withContext(Dispatchers.IO) {
        val summary = messengerConversationSummary(chatId)
            ?: throw IOException("Conversation is not available in the local cache")
        if (summary.conversationType == FfiChatType.ACCOUNT_SYNC) {
            throw IOException("This chat cannot be left")
        }

        runFfi("Failed to leave chat") {
            messenger().leaveConversation(chatId, scope)
            ChatLifecycleMutationResult(
                overview = buildMessengerOverview(
                    conversations = messenger().listConversations(),
                    rootPath = messenger().rootPath(),
                ),
                conversation = buildMessengerConversation(chatId),
            )
        }
    }

    suspend fun dmGlobalDeleteChat(chatId: String): ChatLifecycleMutationResult = withContext(Dispatchers.IO) {
        val summary = messengerConversationSummary(chatId)
            ?: throw IOException("Conversation is not available in the local cache")
        if (summary.conversationType != FfiChatType.DM) {
            throw IOException("Global delete is only available for direct messages")
        }

        runFfi("Failed to delete direct message") {
            messenger().dmGlobalDeleteConversation(chatId)
            ChatLifecycleMutationResult(
                overview = buildMessengerOverview(
                    conversations = messenger().listConversations(),
                    rootPath = messenger().rootPath(),
                ),
                conversation = buildMessengerConversation(chatId),
            )
        }
    }

    suspend fun mlsStorageRoot(): String? = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_read_mls_storage_root)) {
            clientStore().mlsStorageRoot()
        }
    }

    suspend fun mlsCredentialIdentity(): ByteArray = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_read_mls_credential_identity)) {
            mlsFacade().credentialIdentity()
        }
    }

    suspend fun getInbox(
        afterInboxId: ULong? = null,
        limit: UInt = INBOX_SYNC_LIMIT,
    ): List<FfiInboxItem> = withContext(Dispatchers.IO) {
        runFfi(text(R.string.chat_error_fetch_inbox)) {
            val client = client()
            client.setAccessToken(session.accessToken)
            client.getInbox(afterInboxId, limit).items
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
        val activeBackfillChats = activeBackfillChatIds()
        val summaries = conversations.map { conversation ->
            mapMessengerConversationSummary(
                conversation = conversation,
                hasActiveBackfill = activeBackfillChats.contains(conversation.conversationId),
            )
        }
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
        val hasActiveBackfill = activeBackfillChatIds().contains(chatId)
        val messages = messenger().getAllMessages(chatId)
        return ChatConversation(
            chatId = conversation.conversationId,
            chatType = conversation.conversationType,
            title = conversation.displayTitle,
            participantsLabel = messengerParticipantsLabel(conversation),
            timelineLabel = if (messages.isEmpty()) {
                text(R.string.chat_label_no_messages_yet)
            } else {
                text(R.string.chat_label_synced_by_core)
            },
            isAccountSyncChat = conversation.conversationId == session.localState.accountSyncChatId,
            canSend = session.localState.deviceStatus.equals("active", ignoreCase = true),
            canManageMembers = conversation.conversationType == FfiChatType.GROUP,
            composerHint = when (conversation.conversationType) {
                FfiChatType.ACCOUNT_SYNC ->
                    text(R.string.chat_hint_account_sync_managed)

                FfiChatType.GROUP ->
                    text(R.string.chat_hint_group_managed)

                FfiChatType.DM ->
                    text(R.string.chat_hint_dm_managed)
            },
            members = messengerConversationMembers(conversation),
            messages = mapMessengerTimelineMessages(messages, hasActiveBackfill),
        )
    }

    private fun mapMessengerConversationSummary(
        conversation: FfiMessengerConversationSummary,
        hasActiveBackfill: Boolean,
    ): ChatConversationSummary {
        return ChatConversationSummary(
            chatId = conversation.conversationId,
            chatType = conversation.conversationType,
            title = conversation.displayTitle,
            participantsLabel = messengerParticipantsLabel(conversation),
            lastMessagePreview = messengerPreviewLabel(conversation, hasActiveBackfill),
            timestampLabel = conversation.previewCreatedAtUnix?.toLong()?.formatChatTimestamp()
                ?: text(R.string.chat_label_no_messages_yet),
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
                FfiChatType.ACCOUNT_SYNC -> text(R.string.chat_participants_private_sync)
                FfiChatType.GROUP -> text(R.string.chat_participants_pending_members)
                FfiChatType.DM -> text(R.string.chat_participants_direct_conversation)
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
                role = if (profile.accountId == session.localState.accountId) {
                    text(R.string.chat_role_self)
                } else {
                    text(R.string.chat_role_participant)
                },
                membershipStatus = text(R.string.chat_membership_active),
                isSelf = profile.accountId == session.localState.accountId,
            )
        }
    }

    private fun messengerParticipantDisplayName(profile: FfiMessengerParticipantProfile): String {
        if (profile.accountId == session.localState.accountId) {
            return text(R.string.chat_you)
        }
        return profile.profileName.takeIf(String::isNotBlank)
            ?: profile.handle?.takeIf(String::isNotBlank)?.let { "@$it" }
            ?: shortAccountId(profile.accountId)
    }

    private fun messengerPreviewLabel(
        conversation: FfiMessengerConversationSummary,
        hasActiveBackfill: Boolean,
    ): String {
        val previewText = conversation.previewText
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.let { sanitizeUnavailableContentMessage(it, hasActiveBackfill) }
            ?: return text(R.string.chat_label_no_messages_yet)
        val senderLabel = when {
            conversation.previewIsOutgoing == true -> text(R.string.chat_you)
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
        hasActiveBackfill: Boolean,
    ): List<ChatTimelineMessage> {
        return messages
            .filterNot(::isMessengerReceiptMessage)
            .map { message ->
                mapMessengerTimelineMessage(
                    message = message,
                    hasActiveBackfill = hasActiveBackfill,
                    receiptStatus = message.receiptStatus?.let(::receiptStatusFromFfi),
                )
            }
    }

    private fun mapMessengerTimelineMessage(
        message: FfiMessengerMessageRecord,
        hasActiveBackfill: Boolean,
        receiptStatus: ChatReceiptStatus?,
    ): ChatTimelineMessage {
        return ChatTimelineMessage(
            id = message.messageId,
            author = if (message.isOutgoing) {
                text(R.string.chat_you)
            } else {
                message.senderDisplayName?.takeIf(String::isNotBlank)
                    ?: shortAccountId(message.senderAccountId)
            },
            body = messengerTimelineBody(message, hasActiveBackfill),
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

    private fun messengerTimelineBody(
        message: FfiMessengerMessageRecord,
        hasActiveBackfill: Boolean,
    ): String {
        val body = message.body ?: return message.previewText
            .trim()
            .takeIf(String::isNotEmpty)
            ?.let { sanitizeUnavailableContentMessage(it, hasActiveBackfill) }
            ?: text(R.string.chat_preview_encrypted_payload)
        return when (body.kind) {
            FfiMessengerMessageBodyKind.TEXT -> body.text
                ?.trim()
                ?.takeIf(String::isNotEmpty)
                ?: message.previewText.trim().takeIf(String::isNotEmpty)?.let {
                    sanitizeUnavailableContentMessage(it, hasActiveBackfill)
                }
                ?: if (hasActiveBackfill) {
                    text(R.string.chat_preview_backfill_queued)
                } else {
                    text(R.string.chat_preview_loading_on_device)
                }

            FfiMessengerMessageBodyKind.REACTION -> text(
                R.string.chat_preview_reacted_to_message,
                body.emoji.orEmpty(),
                body.targetMessageId?.let(::shortMessageId)
                    ?: text(R.string.chat_preview_default_message_target),
            )

            FfiMessengerMessageBodyKind.RECEIPT -> text(
                R.string.chat_preview_receipt,
                when (body.receiptType) {
                    FfiReceiptType.READ -> text(R.string.chat_preview_receipt_read)
                    FfiReceiptType.DELIVERED, null -> text(R.string.chat_preview_receipt_delivery)
                },
            )

            FfiMessengerMessageBodyKind.ATTACHMENT ->
                body.attachment?.fileName ?: body.attachment?.mimeType ?: text(R.string.chat_preview_attachment)

            FfiMessengerMessageBodyKind.CHAT_EVENT ->
                body.eventType?.trim()?.takeIf(String::isNotEmpty) ?: text(R.string.chat_preview_chat_event)
        }
    }

    private fun isMessengerReceiptMessage(message: FfiMessengerMessageRecord): Boolean {
        return message.contentType == FfiContentType.RECEIPT ||
            message.body?.kind == FfiMessengerMessageBodyKind.RECEIPT
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
                throw IOException(
                    sanitizedUserFacingErrorMessage(
                        rawMessage = ffiMessengerMessage(error),
                        fallbackMessage = fallbackMessage,
                    ),
                    error,
                )
            } catch (error: TrixFfiException) {
                throw IOException(
                    sanitizedUserFacingErrorMessage(
                        rawMessage = error.message,
                        fallbackMessage = fallbackMessage,
                    ),
                    error,
                )
            } catch (error: UnsatisfiedLinkError) {
                throw IOException(text(R.string.chat_error_rust_ffi_unavailable), error)
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

    private fun mapDirectoryAccount(account: FfiDirectoryAccount): ChatDirectoryAccount {
        return ChatDirectoryAccount(
            accountId = account.accountId,
            handle = account.handle,
            profileName = account.profileName,
            profileBio = account.profileBio,
        )
    }

    private fun receiptStatusFromFfi(status: FfiReceiptType): ChatReceiptStatus {
        return when (status) {
            FfiReceiptType.READ -> ChatReceiptStatus.READ
            FfiReceiptType.DELIVERED -> ChatReceiptStatus.DELIVERED
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
            text(R.string.chat_you)
        } else {
            shortAccountId(accountId)
        }
    }

    private fun text(resourceId: Int, vararg args: Any): String {
        return appContext.getString(resourceId, *args)
    }

    private fun activeBackfillChatIds(): Set<String> {
        return runCatching {
            val apiClient = client()
            apiClient.setAccessToken(session.accessToken)
            apiClient.listHistorySyncJobs(null, null, HISTORY_SYNC_LIMIT)
                .asSequence()
                .filter { job ->
                    job.jobType == FfiHistorySyncJobType.CHAT_BACKFILL &&
                        (job.jobStatus == FfiHistorySyncJobStatus.PENDING ||
                            job.jobStatus == FfiHistorySyncJobStatus.RUNNING)
                }
                .mapNotNull { job -> job.chatId?.trim()?.takeIf(String::isNotEmpty) }
                .toSet()
        }.getOrDefault(emptySet())
    }

    private fun sanitizeUnavailableContentMessage(
        rawValue: String,
        hasActiveBackfill: Boolean,
    ): String {
        val trimmed = rawValue.trim()
        return if (isUnavailableContentMessage(trimmed.lowercase())) {
            if (hasActiveBackfill) {
                text(R.string.chat_preview_backfill_queued)
            } else {
                text(R.string.chat_preview_loading_on_device)
            }
        } else {
            trimmed
        }
    }

    private fun sanitizedUserFacingErrorMessage(
        rawMessage: String?,
        fallbackMessage: String,
    ): String {
        val trimmed = rawMessage?.trim().orEmpty()
        if (trimmed.isEmpty()) {
            return fallbackMessage
        }

        val normalized = trimmed.lowercase()
        return when {
            isUnavailableContentMessage(normalized) -> text(R.string.chat_preview_loading_on_device)
            normalized.contains("epoch") ||
                normalized.contains("mls") ||
                normalized.contains("projected") ||
                normalized.contains("group state") ||
                normalized.contains("conversation material") -> text(R.string.chat_error_send_retry)
            normalized.contains("ffimessengererror") ||
                normalized.contains("trixffierror") ||
                normalized.contains("panic") -> text(R.string.chat_error_generic_try_again)
            else -> trimmed
        }
    }

    private fun isUnavailableContentMessage(normalized: String): Boolean {
        return normalized.contains("unavailable on this device") ||
            normalized.contains("content is unavailable") ||
            normalized.contains("backfill queued")
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

data class ChatLifecycleMutationResult(
    val overview: ChatOverview,
    val conversation: ChatConversation?,
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
