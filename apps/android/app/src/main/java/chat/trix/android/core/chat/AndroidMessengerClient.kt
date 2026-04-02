package chat.trix.android.core.chat

import android.content.Context
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.DeviceDatabaseKeyStore
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiMessengerAttachmentFile
import chat.trix.android.core.ffi.FfiMessengerAttachmentMetadata
import chat.trix.android.core.ffi.FfiMessengerClient
import chat.trix.android.core.ffi.FfiMessengerConversationMutationResult
import chat.trix.android.core.ffi.FfiMessengerConversationSummary
import chat.trix.android.core.ffi.FfiMessengerEventBatch
import chat.trix.android.core.ffi.FfiMessengerEventKind
import chat.trix.android.core.ffi.FfiMessengerException
import chat.trix.android.core.ffi.FfiMessengerMessageBodyKind
import chat.trix.android.core.ffi.FfiMessengerMessageRecord
import chat.trix.android.core.ffi.FfiMessengerOpenConfig
import chat.trix.android.core.ffi.FfiMessengerReadStateResult
import chat.trix.android.core.ffi.FfiMessengerSendMessageRequest
import chat.trix.android.core.ffi.FfiMessengerSendMessageResult
import chat.trix.android.core.ffi.FfiMessengerSnapshot
import chat.trix.android.core.ffi.FfiMessengerUpdateConversationDevicesRequest
import chat.trix.android.core.ffi.FfiMessengerUpdateConversationMembersRequest
import chat.trix.android.core.ffi.FfiReactionAction
import chat.trix.android.core.system.deviceStorageLayout
import java.util.UUID
import kotlinx.coroutines.runBlocking

internal data class MessengerEventBatchSummary(
    val checkpoint: String?,
    val changedChatIds: Set<String>,
    val hasDeviceChanges: Boolean,
)

internal class AndroidMessengerClient(
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
    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        storageLayout.prepareCorePersistenceMigration()
        val databaseKey = runBlocking {
            databaseKeyStore.getOrCreate(storageLayout.storeKeyPath)
        }
        FfiMessengerClient.open(
            FfiMessengerOpenConfig(
                rootPath = storageLayout.sessionRoot.absolutePath,
                databaseKey = databaseKey,
                baseUrl = session.baseUrl,
                accessToken = session.accessToken,
                accountId = session.localState.accountId,
                deviceId = session.localState.deviceId,
                accountSyncChatId = session.localState.accountSyncChatId,
                deviceDisplayName = session.localState.deviceDisplayName,
                platform = "android",
                credentialIdentity = session.localState.credentialIdentity,
                accountRootPrivateKey = session.localState.accountRootPrivateSeed,
                transportPrivateKey = session.localState.transportPrivateSeed,
            ),
        )
    }

    fun rootPath(): String = client().rootPath()

    fun listConversations(): List<FfiMessengerConversationSummary> = client().listConversations()

    fun loadSnapshot(): FfiMessengerSnapshot = client().loadSnapshot()

    fun getAllMessages(
        conversationId: String,
        pageLimit: Int = DEFAULT_PAGE_LIMIT,
    ): List<FfiMessengerMessageRecord> {
        val dedupedMessages = linkedMapOf<String, FfiMessengerMessageRecord>()
        var pageCursor: String? = null
        val clampedLimit = pageLimit.coerceIn(1, MAX_PAGE_LIMIT)

        while (true) {
            val page = client().getMessages(
                conversationId = conversationId,
                pageCursor = pageCursor,
                limit = clampedLimit.toUInt(),
            )
            if (page.messages.isEmpty()) {
                break
            }
            page.messages.forEach { message ->
                dedupedMessages[message.messageId] = message
            }
            val nextCursor = page.nextCursor ?: break
            if (nextCursor == pageCursor) {
                break
            }
            pageCursor = nextCursor
        }

        return dedupedMessages.values.sortedWith(
            compareBy<FfiMessengerMessageRecord> { it.serverSeq.toLong() }
                .thenBy { it.createdAtUnix.toLong() },
        )
    }

    fun sendTextMessage(
        conversationId: String,
        text: String,
    ): FfiMessengerSendMessageResult {
        return client().sendMessage(
            FfiMessengerSendMessageRequest(
                conversationId = conversationId,
                messageId = UUID.randomUUID().toString(),
                kind = FfiMessengerMessageBodyKind.TEXT,
                text = text,
                targetMessageId = null,
                emoji = null,
                reactionAction = null,
                receiptType = null,
                receiptAtUnix = null,
                eventType = null,
                eventJson = null,
                attachmentTokens = emptyList(),
            ),
        )
    }

    fun sendAttachmentMessage(
        conversationId: String,
        payload: ByteArray,
        metadata: FfiMessengerAttachmentMetadata,
    ): FfiMessengerSendMessageResult {
        val token = client().sendAttachment(
            conversationId = conversationId,
            payload = payload,
            metadata = metadata,
        )
        return client().sendMessage(
            FfiMessengerSendMessageRequest(
                conversationId = conversationId,
                messageId = UUID.randomUUID().toString(),
                kind = FfiMessengerMessageBodyKind.ATTACHMENT,
                text = null,
                targetMessageId = null,
                emoji = null,
                reactionAction = null,
                receiptType = null,
                receiptAtUnix = null,
                eventType = null,
                eventJson = null,
                attachmentTokens = listOf(token.token),
            ),
        )
    }

    fun sendReaction(
        conversationId: String,
        targetMessageId: String,
        emoji: String,
        removeExisting: Boolean,
    ): FfiMessengerSendMessageResult {
        return client().sendMessage(
            FfiMessengerSendMessageRequest(
                conversationId = conversationId,
                messageId = UUID.randomUUID().toString(),
                kind = FfiMessengerMessageBodyKind.REACTION,
                text = null,
                targetMessageId = targetMessageId,
                emoji = emoji,
                reactionAction = if (removeExisting) {
                    FfiReactionAction.REMOVE
                } else {
                    FfiReactionAction.ADD
                },
                receiptType = null,
                receiptAtUnix = null,
                eventType = null,
                eventJson = null,
                attachmentTokens = emptyList(),
            ),
        )
    }

    fun createConversation(
        chatType: FfiChatType,
        title: String?,
        participantAccountIds: List<String>,
    ): FfiMessengerConversationMutationResult {
        return client().createConversation(
            chat.trix.android.core.ffi.FfiMessengerCreateConversationRequest(
                conversationType = chatType,
                title = title?.trim()?.takeIf(String::isNotEmpty),
                participantAccountIds = participantAccountIds,
            ),
        )
    }

    fun updateConversationMembers(
        conversationId: String,
        participantAccountIds: List<String>,
    ): FfiMessengerConversationMutationResult {
        return client().updateConversationMembers(
            FfiMessengerUpdateConversationMembersRequest(
                conversationId = conversationId,
                participantAccountIds = participantAccountIds,
            ),
        )
    }

    fun removeConversationMembers(
        conversationId: String,
        participantAccountIds: List<String>,
    ): FfiMessengerConversationMutationResult {
        return client().removeConversationMembers(
            FfiMessengerUpdateConversationMembersRequest(
                conversationId = conversationId,
                participantAccountIds = participantAccountIds,
            ),
        )
    }

    fun updateConversationDevices(
        conversationId: String,
        deviceIds: List<String>,
    ): FfiMessengerConversationMutationResult {
        return client().updateConversationDevices(
            FfiMessengerUpdateConversationDevicesRequest(
                conversationId = conversationId,
                deviceIds = deviceIds,
            ),
        )
    }

    fun removeConversationDevices(
        conversationId: String,
        deviceIds: List<String>,
    ): FfiMessengerConversationMutationResult {
        return client().removeConversationDevices(
            FfiMessengerUpdateConversationDevicesRequest(
                conversationId = conversationId,
                deviceIds = deviceIds,
            ),
        )
    }

    fun markRead(
        conversationId: String,
        throughMessageId: String? = null,
    ): FfiMessengerReadStateResult {
        return client().markRead(conversationId, throughMessageId)
    }

    fun getAttachment(attachmentRef: String): FfiMessengerAttachmentFile =
        client().getAttachment(attachmentRef)

    fun setTyping(
        conversationId: String,
        isTyping: Boolean,
    ) {
        client().setTyping(conversationId, isTyping)
    }

    fun getNewEvents(checkpoint: String?): MessengerEventBatchSummary {
        val batch = client().getNewEvents(checkpoint)
        return batch.toSummary()
    }

    fun getNewEventsRealtime(checkpoint: String?): MessengerEventBatchSummary {
        val batch = client().getNewEventsRealtime(checkpoint)
        return batch.toSummary()
    }

    fun sendPresencePing(nonce: String? = null) {
        client().sendPresencePing(nonce)
    }

    fun sendHistorySyncProgress(
        jobId: String,
        cursorJson: String? = null,
        completedChunks: ULong? = null,
    ) {
        client().sendHistorySyncProgress(jobId, cursorJson, completedChunks)
    }

    fun closeRealtime() {
        client().closeRealtime()
    }

    override fun close() {
        if (clientDelegate.isInitialized()) {
            clientDelegate.value.close()
        }
    }

    private fun client(): FfiMessengerClient = clientDelegate.value

    companion object {
        private const val DEFAULT_PAGE_LIMIT = 200
        private const val MAX_PAGE_LIMIT = 500
    }
}

internal fun ffiMessengerMessage(error: FfiMessengerException): String {
    return when (error) {
        is FfiMessengerException.Message -> error.v1
        is FfiMessengerException.RequiresResync -> error.v1
        is FfiMessengerException.AttachmentExpired -> error.v1
        is FfiMessengerException.AttachmentInvalid -> error.v1
        is FfiMessengerException.DeviceNotApprovable -> error.v1
        is FfiMessengerException.NotConfigured -> error.v1
    }
}

private fun FfiMessengerEventBatch.toSummary(): MessengerEventBatchSummary {
    val changedChatIds = linkedSetOf<String>()
    events.forEach { event ->
        when {
            event.conversation != null -> changedChatIds += event.conversation!!.conversationId
            event.message != null -> changedChatIds += event.message!!.conversationId
            event.readState != null -> changedChatIds += event.readState!!.conversationId
            event.conversationId != null -> changedChatIds += event.conversationId!!
        }
    }

    return MessengerEventBatchSummary(
        checkpoint = checkpoint,
        changedChatIds = changedChatIds,
        hasDeviceChanges = events.any { event ->
            when (event.kind) {
                FfiMessengerEventKind.DEVICE_PENDING,
                FfiMessengerEventKind.DEVICE_APPROVED,
                FfiMessengerEventKind.DEVICE_REVOKED,
                -> true

                else -> false
            }
        },
    )
}
