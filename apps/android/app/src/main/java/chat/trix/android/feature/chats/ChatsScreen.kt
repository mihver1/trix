package chat.trix.android.feature.chats

import android.graphics.Rect
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.AttachFile
import androidx.compose.material.icons.rounded.Done
import androidx.compose.material.icons.rounded.DoneAll
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.MarkUnreadChatAlt
import androidx.compose.material.icons.rounded.PersonAddAlt1
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedAssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.core.chat.ChatAttachment
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.chat.ChatConversation
import chat.trix.android.core.chat.ChatConversationMember
import chat.trix.android.core.chat.ChatConversationSummary
import chat.trix.android.core.chat.ChatDirectoryAccount
import chat.trix.android.core.chat.ChatDiagnostics
import chat.trix.android.core.chat.ChatOverview
import chat.trix.android.core.chat.ChatMessageReaction
import chat.trix.android.core.chat.ChatRefreshResult
import chat.trix.android.core.chat.ChatRepository
import chat.trix.android.core.chat.ChatReceiptStatus
import chat.trix.android.core.chat.ChatTimelineMessage
import chat.trix.android.core.chat.supportsLocalImagePreview
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.ffiDefaultQuickReactionEmojis
import chat.trix.android.core.runtime.RealtimeForegroundService
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import chat.trix.android.ui.adaptive.TrixFoldPosture
import java.io.IOException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val fallbackQuickReactionEmojis = listOf(
    "👍", "❤️", "🔥", "👎", "💔", "🤔", "😕", "🤨", "😡", "🤡", "💩", "🗿",
)

internal fun resolveQuickReactionEmojis(
    loadFromFfi: () -> List<String>,
    fallback: List<String> = fallbackQuickReactionEmojis,
): List<String> {
    return runCatching {
        loadFromFfi().ifEmpty { fallback }
    }.getOrElse {
        fallback
    }
}

internal fun reactionSendBlockReason(
    conversation: ChatConversation,
    isSending: Boolean,
): String? {
    return when {
        !conversation.canSend -> conversation.composerHint
        isSending -> "Finish the current send before adding a reaction."
        else -> null
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatsScreen(
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    realtimeChangeSignal: Int = 0,
    realtimeChangedChatIds: Set<String> = emptySet(),
    requestedConversationId: String? = null,
    onConversationRequestConsumed: (String) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val repository = remember(
        context,
        session.localState.accountId,
        session.localState.deviceId,
        session.accessToken,
        session.baseUrl,
    ) {
        ChatRepository(
            context = context,
            session = session,
        )
    }
    val coroutineScope = rememberCoroutineScope()
    val showTwoPane = windowInfo.prefersTwoPaneChat

    var selectedConversationId by rememberSaveable(session.localState.deviceId) { mutableStateOf<String?>(null) }
    var overviewVersion by remember(repository) { mutableIntStateOf(0) }
    var overviewState by remember(repository) { mutableStateOf(ChatsOverviewState(isRefreshing = true)) }
    var detailState by remember(repository) { mutableStateOf(ChatsDetailState()) }
    var sendState by remember(selectedConversationId) { mutableStateOf(ChatSendState()) }
    var composerDraft by rememberSaveable(selectedConversationId) { mutableStateOf("") }
    var directorySheetConfig by remember(session.localState.deviceId) { mutableStateOf<DirectorySheetConfig?>(null) }
    var directoryQuery by rememberSaveable(session.localState.deviceId) { mutableStateOf("") }
    var groupDraftTitle by rememberSaveable(session.localState.deviceId) { mutableStateOf("") }
    var selectedDirectoryAccountIds by remember(session.localState.deviceId) { mutableStateOf(setOf<String>()) }
    var directoryState by remember(repository) { mutableStateOf(ChatsDirectoryState()) }
    var isGroupMembersSheetVisible by rememberSaveable(session.localState.deviceId) { mutableStateOf(false) }
    var activeGroupMemberAccountId by remember(repository) { mutableStateOf<String?>(null) }
    var groupMembershipErrorMessage by remember(repository) { mutableStateOf<String?>(null) }
    var activeAttachmentMessageId by remember(repository) { mutableStateOf<String?>(null) }
    var attachmentErrorMessage by remember(repository) { mutableStateOf<String?>(null) }
    var reactionPickerMessageId by rememberSaveable(selectedConversationId) { mutableStateOf<String?>(null) }
    var publishedTypingState by remember(session.localState.deviceId) {
        mutableStateOf<Pair<String?, Boolean>>(null to false)
    }
    val quickReactionEmojis = remember {
        resolveQuickReactionEmojis(
            loadFromFfi = ::ffiDefaultQuickReactionEmojis,
        )
    }

    fun openDirectorySheet(config: DirectorySheetConfig) {
        directorySheetConfig = config
        directoryQuery = ""
        groupDraftTitle = ""
        selectedDirectoryAccountIds = emptySet()
        directoryState = ChatsDirectoryState()
    }

    fun closeDirectorySheet() {
        directorySheetConfig = null
        directoryQuery = ""
        groupDraftTitle = ""
        selectedDirectoryAccountIds = emptySet()
        directoryState = ChatsDirectoryState()
    }

    suspend fun <T> withFreshRepository(
        block: suspend (ChatRepository) -> T,
    ): T {
        val freshRepository = ChatRepository(
            context = context,
            session = session,
        )
        return try {
            block(freshRepository)
        } finally {
            freshRepository.close()
        }
    }

    suspend fun loadCachedOverview(): ChatOverview? {
        return try {
            withFreshRepository { freshRepository ->
                freshRepository.loadOverview()
            }
        } catch (_: IOException) {
            null
        }
    }

    suspend fun loadCachedConversation(chatId: String): ChatConversation? {
        return try {
            withFreshRepository { freshRepository ->
                freshRepository.loadConversation(chatId)
            }
        } catch (_: IOException) {
            null
        }
    }

    suspend fun syncChats() {
        val cachedOverview = loadCachedOverview()
        if (cachedOverview != null && overviewState.overview == null) {
            overviewState = overviewState.copy(
                overview = cachedOverview,
                isRefreshing = true,
                errorMessage = null,
            )
            overviewVersion += 1
        } else {
            overviewState = overviewState.copy(
                isRefreshing = true,
                errorMessage = null,
            )
        }

        try {
            val result = repository.refresh()
            overviewState = ChatsOverviewState(
                overview = result.overview,
                isRefreshing = false,
                errorMessage = null,
                lastRefreshSummary = result.toSummary(),
            )
            overviewVersion += 1
        } catch (error: IOException) {
            val fallbackOverview = loadCachedOverview() ?: overviewState.overview
            overviewState = overviewState.copy(
                overview = fallbackOverview,
                isRefreshing = false,
                errorMessage = error.message ?: "Chat sync failed",
            )
            if (fallbackOverview != null) {
                overviewVersion += 1
            }
        }
    }

    suspend fun sendDraftMessage() {
        val chatId = selectedConversationId ?: return
        val conversation = detailState.conversation?.takeIf { it.chatId == chatId } ?: return
        if (!conversation.canSend || sendState.isSending) {
            return
        }

        val draft = composerDraft
        if (draft.isBlank()) {
            return
        }

        sendState = sendState.copy(isSending = true, sendErrorMessage = null)

        try {
            val result = repository.sendTextMessage(chatId, draft)
            composerDraft = ""
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            detailState = detailState.copy(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
            sendState = sendState.copy(
                isSending = false,
                sendErrorMessage = null,
            )
        } catch (error: IOException) {
            sendState = sendState.copy(
                isSending = false,
                sendErrorMessage = error.message ?: "Failed to send message",
            )
        }
    }

    suspend fun sendAttachment(contentUri: Uri) {
        val chatId = selectedConversationId ?: return
        val conversation = detailState.conversation?.takeIf { it.chatId == chatId } ?: return
        if (!conversation.canSend || sendState.isSending) {
            return
        }

        sendState = sendState.copy(isSending = true, sendErrorMessage = null)
        attachmentErrorMessage = null

        try {
            val result = repository.sendAttachment(chatId, contentUri)
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            detailState = detailState.copy(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
            sendState = sendState.copy(
                isSending = false,
                sendErrorMessage = null,
            )
        } catch (error: IOException) {
            sendState = sendState.copy(
                isSending = false,
                sendErrorMessage = error.message ?: "Failed to send attachment",
            )
        }
    }

    suspend fun sendReaction(message: ChatTimelineMessage, emoji: String) {
        val chatId = selectedConversationId ?: return
        val conversation = detailState.conversation?.takeIf { it.chatId == chatId } ?: return
        val blockReason = reactionSendBlockReason(conversation, sendState.isSending)
        if (blockReason != null) {
            reactionPickerMessageId = null
            sendState = sendState.copy(
                sendErrorMessage = blockReason,
            )
            return
        }

        sendState = sendState.copy(isSending = true, sendErrorMessage = null)

        try {
            val removeExisting = message.reactions.any {
                it.emoji == emoji && it.includesSelf
            }
            val result = repository.sendReaction(
                chatId = chatId,
                targetMessageId = message.id,
                emoji = emoji,
                removeExisting = removeExisting,
            )
            reactionPickerMessageId = null
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            detailState = detailState.copy(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
            sendState = sendState.copy(
                isSending = false,
                sendErrorMessage = null,
            )
        } catch (error: IOException) {
            sendState = sendState.copy(
                isSending = false,
                sendErrorMessage = error.message ?: "Failed to send reaction",
            )
        }
    }

    suspend fun markConversationRead(chatId: String) {
        try {
            val result = repository.markConversationRead(chatId)
            if (result.changed) {
                overviewState = overviewState.copy(
                    overview = result.overview,
                    errorMessage = null,
                )
                overviewVersion += 1
            }
        } catch (_: IOException) {
            // Keep the transcript interactive even if the local read cursor could not be updated.
        }
    }

    suspend fun searchDirectory() {
        directoryState = directoryState.copy(
            isLoading = true,
            errorMessage = null,
        )

        try {
            val accounts = repository.searchAccountDirectory(directoryQuery)
            directoryState = directoryState.copy(
                accounts = accounts,
                isLoading = false,
                errorMessage = null,
                hasLoaded = true,
            )
        } catch (error: IOException) {
            directoryState = directoryState.copy(
                isLoading = false,
                errorMessage = error.message ?: "Directory search failed",
                hasLoaded = true,
            )
        }
    }

    suspend fun createDirectMessage(targetAccountId: String) {
        directoryState = directoryState.copy(
            activeAccountId = targetAccountId,
            isSubmitting = true,
            errorMessage = null,
        )

        try {
            val result = repository.createDirectMessage(targetAccountId)
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            selectedConversationId = result.conversation.chatId
            composerDraft = ""
            detailState = ChatsDetailState(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
            directoryState = directoryState.copy(
                activeAccountId = null,
                isSubmitting = false,
                errorMessage = null,
            )
            closeDirectorySheet()
        } catch (error: IOException) {
            directoryState = directoryState.copy(
                activeAccountId = null,
                isSubmitting = false,
                errorMessage = error.message ?: "Failed to create direct message",
            )
        }
    }

    suspend fun createGroupChat() {
        directoryState = directoryState.copy(
            isSubmitting = true,
            errorMessage = null,
        )

        try {
            val result = repository.createGroupChat(
                title = groupDraftTitle,
                participantAccountIds = selectedDirectoryAccountIds.toList(),
            )
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            selectedConversationId = result.conversation.chatId
            composerDraft = ""
            detailState = ChatsDetailState(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
            closeDirectorySheet()
        } catch (error: IOException) {
            directoryState = directoryState.copy(
                isSubmitting = false,
                errorMessage = error.message ?: "Failed to create group chat",
            )
        }
    }

    suspend fun addSelectedGroupMembers() {
        val config = directorySheetConfig ?: return
        val chatId = config.chatId ?: return

        directoryState = directoryState.copy(
            isSubmitting = true,
            errorMessage = null,
        )

        try {
            val result = repository.addMembers(
                chatId = chatId,
                participantAccountIds = selectedDirectoryAccountIds.toList(),
            )
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            selectedConversationId = result.conversation.chatId
            detailState = detailState.copy(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
            groupMembershipErrorMessage = null
            closeDirectorySheet()
            isGroupMembersSheetVisible = true
        } catch (error: IOException) {
            directoryState = directoryState.copy(
                isSubmitting = false,
                errorMessage = error.message ?: "Failed to add members",
            )
        }
    }

    suspend fun removeGroupMember(accountId: String) {
        val chatId = selectedConversationId ?: return
        activeGroupMemberAccountId = accountId
        groupMembershipErrorMessage = null

        try {
            val result = repository.removeMember(
                chatId = chatId,
                accountId = accountId,
            )
            overviewState = overviewState.copy(
                overview = result.overview,
                errorMessage = null,
            )
            overviewVersion += 1
            detailState = detailState.copy(
                conversation = result.conversation,
                isLoading = false,
                errorMessage = null,
            )
        } catch (error: IOException) {
            groupMembershipErrorMessage = error.message ?: "Failed to remove member"
        } finally {
            activeGroupMemberAccountId = null
        }
    }

    suspend fun openAttachment(attachment: ChatAttachment) {
        activeAttachmentMessageId = attachment.messageId
        attachmentErrorMessage = null
        try {
            repository.openAttachment(attachment)
        } catch (error: IOException) {
            attachmentErrorMessage = error.message ?: "Failed to open attachment"
        } finally {
            activeAttachmentMessageId = null
        }
    }

    suspend fun shareAttachment(attachment: ChatAttachment) {
        activeAttachmentMessageId = attachment.messageId
        attachmentErrorMessage = null
        try {
            repository.shareAttachment(attachment)
        } catch (error: IOException) {
            attachmentErrorMessage = error.message ?: "Failed to share attachment"
        } finally {
            activeAttachmentMessageId = null
        }
    }

    val attachmentPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
        onResult = { contentUri ->
            if (contentUri != null) {
                coroutineScope.launch {
                    sendAttachment(contentUri)
                }
            }
        },
    )

    DisposableEffect(repository) {
        onDispose {
            repository.close()
        }
    }

    LaunchedEffect(repository) {
        val cachedOverview = loadCachedOverview()
        if (cachedOverview != null) {
            overviewState = overviewState.copy(
                overview = cachedOverview,
                isRefreshing = true,
            )
            overviewVersion += 1
        }
        syncChats()
    }

    LaunchedEffect(requestedConversationId) {
        val requestedChatId = requestedConversationId ?: return@LaunchedEffect
        if (selectedConversationId != requestedChatId) {
            selectedConversationId = requestedChatId
        }
        onConversationRequestConsumed(requestedChatId)
    }

    LaunchedEffect(repository, directorySheetConfig, directoryQuery) {
        if (directorySheetConfig == null) {
            return@LaunchedEffect
        }

        delay(250)
        searchDirectory()
    }

    LaunchedEffect(showTwoPane, overviewVersion) {
        val conversationIds = overviewState.overview?.conversations.orEmpty().map { it.chatId }
        if (conversationIds.isEmpty()) {
            selectedConversationId = null
            return@LaunchedEffect
        }

        if (selectedConversationId !in conversationIds) {
            selectedConversationId = null
        }

        if (showTwoPane && selectedConversationId == null) {
            selectedConversationId = conversationIds.first()
        }
    }

    LaunchedEffect(repository, selectedConversationId, overviewVersion) {
        val chatId = selectedConversationId
        if (chatId == null) {
            detailState = ChatsDetailState()
            attachmentErrorMessage = null
            return@LaunchedEffect
        }

        val currentConversation = detailState.conversation?.takeIf { it.chatId == chatId }
        detailState = detailState.copy(
            conversation = currentConversation,
            isLoading = true,
            errorMessage = null,
        )

        detailState = try {
            val conversation = loadCachedConversation(chatId)
            val loadedState = applyPassiveConversationReload(
                currentDetailState = detailState,
                currentSendState = sendState,
                conversation = conversation,
                errorMessage = null,
            )
            attachmentErrorMessage = null
            if ((overviewState.overview?.conversations?.firstOrNull { it.chatId == chatId }?.unreadCount ?: 0) > 0) {
                markConversationRead(chatId)
            }
            sendState = loadedState.sendState
            loadedState.detailState
        } catch (error: IOException) {
            applyPassiveConversationReload(
                currentDetailState = detailState,
                currentSendState = sendState,
                conversation = currentConversation,
                errorMessage = error.message ?: "Failed to load conversation",
            ).detailState
        }
    }

    LaunchedEffect(repository, realtimeChangeSignal) {
        if (realtimeChangeSignal <= 0) {
            return@LaunchedEffect
        }

        val localOverview = runCatching {
            loadCachedOverview()
        }.getOrNull()

        if (localOverview != null) {
            overviewState = overviewState.copy(
                overview = localOverview,
                errorMessage = null,
            )
            overviewVersion += 1
        }

        val selectedChatId = selectedConversationId
        if (selectedChatId != null &&
            (realtimeChangedChatIds.isEmpty() || selectedChatId in realtimeChangedChatIds)
        ) {
            val refreshedConversation = runCatching {
                loadCachedConversation(selectedChatId)
            }.getOrNull()

            if (refreshedConversation != null) {
                val loadedState = applyPassiveConversationReload(
                    currentDetailState = detailState,
                    currentSendState = sendState,
                    conversation = refreshedConversation,
                    errorMessage = null,
                )
                sendState = loadedState.sendState
                detailState = loadedState.detailState
            }
        }
    }

    LaunchedEffect(selectedConversationId, composerDraft) {
        val nextChatId = selectedConversationId
        val nextIsTyping = nextChatId != null && composerDraft.isNotBlank()
        val (previousChatId, previousIsTyping) = publishedTypingState

        if (previousChatId != null && previousChatId != nextChatId && previousIsTyping) {
            RealtimeForegroundService.sendTypingUpdate(
                context = context,
                chatId = previousChatId,
                isTyping = false,
            )
        }

        if (nextChatId != null && (previousChatId != nextChatId || previousIsTyping != nextIsTyping)) {
            RealtimeForegroundService.sendTypingUpdate(
                context = context,
                chatId = nextChatId,
                isTyping = nextIsTyping,
            )
        }

        publishedTypingState = nextChatId to nextIsTyping
    }

    val conversations = overviewState.overview?.conversations.orEmpty()
    val selectedConversationSummary = conversations.firstOrNull { it.chatId == selectedConversationId }
    val selectedConversation = detailState.conversation
        ?.takeIf { it.chatId == selectedConversationId }
    val onReactToMessage: ((ChatTimelineMessage) -> Unit)? =
        if (selectedConversation?.canSend == true && !sendState.isSending) {
            { reactionPickerMessageId = it.id }
        } else {
            null
        }
    val reactionTargetMessage = selectedConversation
        ?.messages
        ?.firstOrNull { it.id == reactionPickerMessageId }
    val activeDirectorySheetConfig = directorySheetConfig
    val directoryExistingAccountIds = if (directorySheetConfig?.mode == DirectorySheetMode.GROUP_ADD_MEMBERS) {
        selectedConversation?.members.orEmpty().map { it.accountId }.toSet()
    } else {
        emptySet()
    }
    val detailOnly = !showTwoPane && selectedConversationId != null

    BackHandler(enabled = detailOnly) {
        selectedConversationId = null
    }

    DisposableEffect(context) {
        onDispose {
            val (chatId, isTyping) = publishedTypingState
            if (chatId != null && isTyping) {
                RealtimeForegroundService.sendTypingUpdate(
                    context = context,
                    chatId = chatId,
                    isTyping = false,
                )
            }
        }
    }

    LaunchedEffect(selectedConversation?.chatId, selectedConversation?.canManageMembers) {
        if (selectedConversation?.canManageMembers != true) {
            isGroupMembersSheetVisible = false
        }
    }

    if (activeDirectorySheetConfig != null) {
        DirectoryAccountsSheet(
            config = activeDirectorySheetConfig,
            query = directoryQuery,
            onQueryChange = { directoryQuery = it },
            groupTitle = groupDraftTitle,
            onGroupTitleChange = { groupDraftTitle = it },
            state = directoryState,
            selectedAccountIds = selectedDirectoryAccountIds,
            existingAccountIds = directoryExistingAccountIds,
            onDismissRequest = { closeDirectorySheet() },
            onToggleAccountSelection = { accountId ->
                if (accountId !in directoryExistingAccountIds) {
                    selectedDirectoryAccountIds = if (accountId in selectedDirectoryAccountIds) {
                        selectedDirectoryAccountIds - accountId
                    } else {
                        selectedDirectoryAccountIds + accountId
                    }
                }
            },
            onCreateDirectMessage = { accountId ->
                coroutineScope.launch {
                    createDirectMessage(accountId)
                }
            },
            onSubmitSelection = {
                coroutineScope.launch {
                    when (directorySheetConfig?.mode) {
                        DirectorySheetMode.GROUP_CREATE -> createGroupChat()
                        DirectorySheetMode.GROUP_ADD_MEMBERS -> addSelectedGroupMembers()
                        DirectorySheetMode.DIRECT_MESSAGE,
                        null,
                        -> Unit
                    }
                }
            },
        )
    }

    if (isGroupMembersSheetVisible && selectedConversation?.chatType == FfiChatType.GROUP) {
        GroupMembersSheet(
            conversation = selectedConversation,
            isUpdatingMember = activeGroupMemberAccountId != null,
            activeMemberAccountId = activeGroupMemberAccountId,
            errorMessage = groupMembershipErrorMessage,
            onDismissRequest = { isGroupMembersSheetVisible = false },
            onAddMembers = {
                groupMembershipErrorMessage = null
                openDirectorySheet(
                    DirectorySheetConfig(
                        mode = DirectorySheetMode.GROUP_ADD_MEMBERS,
                        chatId = selectedConversation.chatId,
                    ),
                )
            },
            onRemoveMember = { accountId ->
                coroutineScope.launch {
                    removeGroupMember(accountId)
                }
            },
        )
    }

    if (reactionTargetMessage != null) {
        QuickReactionSheet(
            message = reactionTargetMessage,
            emojis = quickReactionEmojis,
            onDismissRequest = { reactionPickerMessageId = null },
            onEmojiSelected = { emoji ->
                coroutineScope.launch {
                    sendReaction(reactionTargetMessage, emoji)
                }
            },
        )
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            if (detailOnly) {
                TopAppBar(
                    title = {
                        Text(
                            text = selectedConversation?.title ?: selectedConversationSummary?.title ?: "",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = { selectedConversationId = null }) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                contentDescription = stringResource(R.string.action_back),
                            )
                        }
                    },
                    actions = {
                        NewChatActions(
                            onOpenDirectMessages = {
                                openDirectorySheet(DirectorySheetConfig(mode = DirectorySheetMode.DIRECT_MESSAGE))
                            },
                            onOpenGroupChats = {
                                openDirectorySheet(DirectorySheetConfig(mode = DirectorySheetMode.GROUP_CREATE))
                            },
                        )
                        RefreshAction(
                            isRefreshing = overviewState.isRefreshing,
                            onRefresh = { coroutineScope.launch { syncChats() } },
                        )
                    },
                )
            } else {
                CenterAlignedTopAppBar(
                    title = { Text(stringResource(R.string.screen_chats)) },
                    actions = {
                        NewChatActions(
                            onOpenDirectMessages = {
                                openDirectorySheet(DirectorySheetConfig(mode = DirectorySheetMode.DIRECT_MESSAGE))
                            },
                            onOpenGroupChats = {
                                openDirectorySheet(DirectorySheetConfig(mode = DirectorySheetMode.GROUP_CREATE))
                            },
                        )
                        RefreshAction(
                            isRefreshing = overviewState.isRefreshing,
                            onRefresh = { coroutineScope.launch { syncChats() } },
                        )
                    },
                )
            }
        },
    ) { innerPadding ->
        val contentModifier = Modifier
            .fillMaxSize()
            .padding(innerPadding)

        when {
            overviewState.overview == null && overviewState.isRefreshing -> {
                LoadingChatsPane(modifier = contentModifier)
            }

            conversations.isEmpty() -> {
                EmptyChatCachePane(
                    errorMessage = overviewState.errorMessage,
                    isRefreshing = overviewState.isRefreshing,
                    onRefresh = { coroutineScope.launch { syncChats() } },
                    modifier = contentModifier,
                )
            }

            windowInfo.foldPosture == TrixFoldPosture.Tabletop && selectedConversationId != null -> {
                TabletopConversationLayout(
                    repository = repository,
                    conversation = selectedConversation,
                    isLoading = detailState.isLoading,
                    errorMessage = detailState.errorMessage,
                    composerDraft = composerDraft,
                    onComposerDraftChange = { composerDraft = it },
                    isSending = sendState.isSending,
                    sendErrorMessage = sendState.sendErrorMessage,
                    attachmentErrorMessage = attachmentErrorMessage,
                    activeAttachmentMessageId = activeAttachmentMessageId,
                    onPickAttachment = { attachmentPickerLauncher.launch(arrayOf("*/*")) },
                    onSend = { coroutineScope.launch { sendDraftMessage() } },
                    onOpenAttachment = { attachment ->
                        coroutineScope.launch {
                            openAttachment(attachment)
                        }
                    },
                    onShareAttachment = { attachment ->
                        coroutineScope.launch {
                            shareAttachment(attachment)
                        }
                    },
                    onReactToMessage = onReactToMessage,
                    onManageMembers = {
                        isGroupMembersSheetVisible = true
                        groupMembershipErrorMessage = null
                    },
                    modifier = contentModifier,
                )
            }

            showTwoPane -> {
                WideConversationLayout(
                    overviewState = overviewState,
                    selectedConversationId = selectedConversationId,
                    selectedConversation = selectedConversation,
                    detailState = detailState,
                    onConversationClick = { selectedConversationId = it },
                    onRefresh = { coroutineScope.launch { syncChats() } },
                    composerDraft = composerDraft,
                    onComposerDraftChange = { composerDraft = it },
                    isSending = sendState.isSending,
                    sendErrorMessage = sendState.sendErrorMessage,
                    attachmentErrorMessage = attachmentErrorMessage,
                    activeAttachmentMessageId = activeAttachmentMessageId,
                    onPickAttachment = { attachmentPickerLauncher.launch(arrayOf("*/*")) },
                    onSend = { coroutineScope.launch { sendDraftMessage() } },
                    onOpenAttachment = { attachment ->
                        coroutineScope.launch {
                            openAttachment(attachment)
                        }
                    },
                    onShareAttachment = { attachment ->
                        coroutineScope.launch {
                            shareAttachment(attachment)
                        }
                    },
                    onReactToMessage = onReactToMessage,
                    onManageMembers = {
                        isGroupMembersSheetVisible = true
                        groupMembershipErrorMessage = null
                    },
                    foldPosture = windowInfo.foldPosture,
                    foldBounds = windowInfo.foldBounds,
                    modifier = contentModifier,
                )
            }

            selectedConversationId != null -> {
                ConversationDetailPane(
                    repository = repository,
                    conversation = selectedConversation,
                    isLoading = detailState.isLoading,
                    errorMessage = detailState.errorMessage,
                    composerDraft = composerDraft,
                    onComposerDraftChange = { composerDraft = it },
                    isSending = sendState.isSending,
                    sendErrorMessage = sendState.sendErrorMessage,
                    attachmentErrorMessage = attachmentErrorMessage,
                    activeAttachmentMessageId = activeAttachmentMessageId,
                    onPickAttachment = { attachmentPickerLauncher.launch(arrayOf("*/*")) },
                    onSend = { coroutineScope.launch { sendDraftMessage() } },
                    onOpenAttachment = { attachment ->
                        coroutineScope.launch {
                            openAttachment(attachment)
                        }
                    },
                    onShareAttachment = { attachment ->
                        coroutineScope.launch {
                            shareAttachment(attachment)
                        }
                    },
                    onReactToMessage = onReactToMessage,
                    onManageMembers = {
                        isGroupMembersSheetVisible = true
                        groupMembershipErrorMessage = null
                    },
                    modifier = contentModifier,
                )
            }

            else -> {
                ConversationListPane(
                    overviewState = overviewState,
                    selectedConversationId = selectedConversationId,
                    onConversationClick = { selectedConversationId = it },
                    onRefresh = { coroutineScope.launch { syncChats() } },
                    modifier = contentModifier,
                )
            }
        }
    }
}

@Composable
private fun NewChatActions(
    onOpenDirectMessages: () -> Unit,
    onOpenGroupChats: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalIconButton(onClick = onOpenDirectMessages) {
            Icon(
                imageVector = Icons.Rounded.PersonAddAlt1,
                contentDescription = "Start direct message",
            )
        }
        FilledTonalIconButton(onClick = onOpenGroupChats) {
            Icon(
                imageVector = Icons.Rounded.Groups,
                contentDescription = "Create group chat",
            )
        }
    }
}

@Composable
internal fun NewChatActionsForTesting(
    onOpenDirectMessages: () -> Unit,
    onOpenGroupChats: () -> Unit,
) {
    NewChatActions(
        onOpenDirectMessages = onOpenDirectMessages,
        onOpenGroupChats = onOpenGroupChats,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DirectoryAccountsSheet(
    config: DirectorySheetConfig,
    query: String,
    onQueryChange: (String) -> Unit,
    groupTitle: String,
    onGroupTitleChange: (String) -> Unit,
    state: ChatsDirectoryState,
    selectedAccountIds: Set<String>,
    existingAccountIds: Set<String>,
    onDismissRequest: () -> Unit,
    onToggleAccountSelection: (String) -> Unit,
    onCreateDirectMessage: (String) -> Unit,
    onSubmitSelection: () -> Unit,
) {
    val isDirectMessageMode = config.mode == DirectorySheetMode.DIRECT_MESSAGE
    val isGroupCreateMode = config.mode == DirectorySheetMode.GROUP_CREATE
    val selectedCount = selectedAccountIds.size
    val minimumSelection = if (isGroupCreateMode) 2 else 1
    val submitLabel = when (config.mode) {
        DirectorySheetMode.DIRECT_MESSAGE -> "Message"
        DirectorySheetMode.GROUP_CREATE -> "Create group"
        DirectorySheetMode.GROUP_ADD_MEMBERS -> "Add members"
    }
    val sheetTitle = when (config.mode) {
        DirectorySheetMode.DIRECT_MESSAGE -> "New direct message"
        DirectorySheetMode.GROUP_CREATE -> "Create group chat"
        DirectorySheetMode.GROUP_ADD_MEMBERS -> "Add members"
    }
    val sheetBody = when (config.mode) {
        DirectorySheetMode.DIRECT_MESSAGE -> "Search the account directory and open a DM without leaving the chats surface."
        DirectorySheetMode.GROUP_CREATE -> "Search the account directory, choose at least two people, and create a new group thread."
        DirectorySheetMode.GROUP_ADD_MEMBERS -> "Search the account directory and add more people to the current group thread."
    }

    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = sheetTitle,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = sheetBody,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (isGroupCreateMode) {
                        OutlinedTextField(
                            value = groupTitle,
                            onValueChange = onGroupTitleChange,
                            modifier = Modifier.fillMaxWidth(),
                            placeholder = { Text("Group title (optional)") },
                            singleLine = true,
                        )
                    }
                    OutlinedTextField(
                        value = query,
                        onValueChange = onQueryChange,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("Search by name or @handle") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions.Default.copy(imeAction = ImeAction.Search),
                    )
                    if (!isDirectMessageMode) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = if (isGroupCreateMode) {
                                    "$selectedCount selected, minimum $minimumSelection"
                                } else {
                                    "$selectedCount selected"
                                },
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Button(
                                onClick = onSubmitSelection,
                                enabled = !state.isSubmitting && selectedCount >= minimumSelection,
                            ) {
                                if (state.isSubmitting) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(18.dp),
                                        strokeWidth = 2.dp,
                                    )
                                } else {
                                    Text(submitLabel)
                                }
                            }
                        }
                    }
                }
            }

            when {
                state.isLoading && state.accounts.isEmpty() -> {
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 24.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator()
                        }
                    }
                }

                state.hasLoaded && state.accounts.isEmpty() && state.errorMessage == null -> {
                    item {
                        Surface(
                            shape = RoundedCornerShape(24.dp),
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(
                                modifier = Modifier.padding(horizontal = 18.dp, vertical = 16.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text(
                                    text = "No accounts found",
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Text(
                                    text = "Try a broader name fragment or handle.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }

            items(state.accounts, key = { it.accountId }) { account ->
                if (isDirectMessageMode) {
                    DirectoryAccountRow(
                        account = account,
                        isCreating = state.activeAccountId == account.accountId,
                        enabled = state.activeAccountId == null && !state.isSubmitting,
                        onCreateDirectMessage = { onCreateDirectMessage(account.accountId) },
                    )
                } else {
                    DirectorySelectionRow(
                        account = account,
                        isSelected = account.accountId in selectedAccountIds,
                        isAlreadyInChat = account.accountId in existingAccountIds,
                        enabled = !state.isSubmitting,
                        onToggleSelection = { onToggleAccountSelection(account.accountId) },
                    )
                }
            }

            if (state.errorMessage != null) {
                item {
                    Text(
                        text = state.errorMessage,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}

@Composable
private fun DirectorySelectionRow(
    account: ChatDirectoryAccount,
    isSelected: Boolean,
    isAlreadyInChat: Boolean,
    enabled: Boolean,
    onToggleSelection: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        ListItem(
            leadingContent = {
                ConversationAvatar(name = directoryAccountDisplayName(account))
            },
            headlineContent = {
                Text(
                    text = directoryAccountDisplayName(account),
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            supportingContent = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text = directoryAccountSecondaryLine(account),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    account.profileBio
                        ?.takeIf(String::isNotBlank)
                        ?.let { bio ->
                            Text(
                                text = bio,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                }
            },
            trailingContent = {
                when {
                    isAlreadyInChat -> {
                        TimelineBadge(label = "In group")
                    }

                    isSelected -> {
                        Button(
                            onClick = onToggleSelection,
                            enabled = enabled,
                        ) {
                            Text("Selected")
                        }
                    }

                    else -> {
                        OutlinedButton(
                            onClick = onToggleSelection,
                            enabled = enabled,
                        ) {
                            Text("Select")
                        }
                    }
                }
            },
        )
    }
}

@Composable
private fun DirectoryAccountRow(
    account: ChatDirectoryAccount,
    isCreating: Boolean,
    enabled: Boolean,
    onCreateDirectMessage: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        ListItem(
            leadingContent = {
                ConversationAvatar(name = directoryAccountDisplayName(account))
            },
            headlineContent = {
                Text(
                    text = directoryAccountDisplayName(account),
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            supportingContent = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text = directoryAccountSecondaryLine(account),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    account.profileBio
                        ?.takeIf(String::isNotBlank)
                        ?.let { bio ->
                            Text(
                                text = bio,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                }
            },
            trailingContent = {
                Button(
                    onClick = onCreateDirectMessage,
                    enabled = enabled && !isCreating,
                ) {
                    if (isCreating) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text("Message")
                    }
                }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GroupMembersSheet(
    conversation: ChatConversation,
    isUpdatingMember: Boolean,
    activeMemberAccountId: String?,
    errorMessage: String?,
    onDismissRequest: () -> Unit,
    onAddMembers: () -> Unit,
    onRemoveMember: (String) -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "Group members",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "${conversation.members.size} members in ${conversation.title}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(
                        onClick = onAddMembers,
                        enabled = conversation.canManageMembers && !isUpdatingMember,
                    ) {
                        Text("Add members")
                    }
                }
            }

            items(conversation.members, key = { it.accountId }) { member ->
                GroupMemberRow(
                    member = member,
                    isUpdating = activeMemberAccountId == member.accountId,
                    canRemove = conversation.canManageMembers && !member.isSelf,
                    enabled = !isUpdatingMember,
                    onRemoveMember = { onRemoveMember(member.accountId) },
                )
            }

            if (errorMessage != null) {
                item {
                    Text(
                        text = errorMessage,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}

@Composable
private fun GroupMemberRow(
    member: ChatConversationMember,
    isUpdating: Boolean,
    canRemove: Boolean,
    enabled: Boolean,
    onRemoveMember: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        ListItem(
            leadingContent = { ConversationAvatar(name = member.displayName) },
            headlineContent = {
                Text(
                    text = member.displayName,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            supportingContent = {
                Text(
                    text = "${member.role.replaceFirstChar(Char::uppercase)} · ${member.membershipStatus.replaceFirstChar(Char::uppercase)}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            trailingContent = {
                when {
                    member.isSelf -> TimelineBadge(label = "You")
                    canRemove -> {
                        OutlinedButton(
                            onClick = onRemoveMember,
                            enabled = enabled && !isUpdating,
                        ) {
                            if (isUpdating) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                )
                            } else {
                                Text("Remove")
                            }
                        }
                    }
                    else -> TimelineBadge(label = member.membershipStatus.replaceFirstChar(Char::uppercase))
                }
            },
        )
    }
}

private fun directoryAccountDisplayName(account: ChatDirectoryAccount): String {
    return account.profileName.takeIf(String::isNotBlank)
        ?: account.handle?.takeIf(String::isNotBlank)?.let { "@$it" }
        ?: account.accountId
}

private fun directoryAccountSecondaryLine(account: ChatDirectoryAccount): String {
    return buildString {
        account.handle
            ?.takeIf(String::isNotBlank)
            ?.let {
                append('@')
                append(it)
            }
        if (isNotEmpty()) {
            append(" · ")
        }
        append(
            if (account.accountId.length <= 14) {
                account.accountId
            } else {
                "${account.accountId.take(6)}…${account.accountId.takeLast(4)}"
            },
        )
    }
}

@Composable
private fun RefreshAction(
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
) {
    if (isRefreshing) {
        Box(
            modifier = Modifier
                .padding(horizontal = 12.dp)
                .size(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(strokeWidth = 2.dp)
        }
    } else {
        FilledTonalIconButton(onClick = onRefresh) {
            Icon(
                imageVector = Icons.Rounded.Sync,
                contentDescription = "Refresh chats",
            )
        }
    }
}

@Composable
private fun LoadingChatsPane(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            CircularProgressIndicator()
            Text(
                text = "Restoring local chat cache",
                style = MaterialTheme.typography.titleMedium,
            )
        }
    }
}

@Composable
private fun EmptyChatCachePane(
    errorMessage: String?,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceContainerLowest),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.widthIn(max = 420.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier.size(68.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Rounded.MarkUnreadChatAlt,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                }
            }
            Text(
                text = if (errorMessage == null) "No chats yet" else "Chat sync failed",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
            Text(
                text = errorMessage
                    ?: "Start a conversation and it will appear here.",
                style = MaterialTheme.typography.bodyMedium,
                color = if (errorMessage == null) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.error
                },
                textAlign = TextAlign.Center,
            )
            Button(
                onClick = onRefresh,
                enabled = !isRefreshing,
            ) {
                Text(if (isRefreshing) "Refreshing" else "Refresh")
            }
        }
    }
}

@Composable
private fun WideConversationLayout(
    overviewState: ChatsOverviewState,
    selectedConversationId: String?,
    selectedConversation: ChatConversation?,
    detailState: ChatsDetailState,
    onConversationClick: (String) -> Unit,
    onRefresh: () -> Unit,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    attachmentErrorMessage: String?,
    activeAttachmentMessageId: String?,
    onPickAttachment: () -> Unit,
    onSend: () -> Unit,
    onOpenAttachment: (ChatAttachment) -> Unit,
    onShareAttachment: (ChatAttachment) -> Unit,
    onReactToMessage: ((ChatTimelineMessage) -> Unit)?,
    onManageMembers: (() -> Unit)?,
    foldPosture: TrixFoldPosture,
    foldBounds: Rect?,
    modifier: Modifier = Modifier,
) {
    val foldGap = if (foldPosture == TrixFoldPosture.Book && foldBounds != null && foldBounds.width() > 0) {
        with(LocalDensity.current) { foldBounds.width().toDp() }
    } else {
        0.dp
    }

    Row(modifier = modifier) {
        Surface(
            tonalElevation = 1.dp,
            modifier = Modifier
                .width(320.dp)
                .fillMaxHeight(),
        ) {
            ConversationListPane(
                overviewState = overviewState,
                selectedConversationId = selectedConversationId,
                onConversationClick = onConversationClick,
                onRefresh = onRefresh,
            )
        }

        if (foldGap > 0.dp) {
            Spacer(modifier = Modifier.width(foldGap))
        } else {
            VerticalDivider()
        }

        if (selectedConversationId == null) {
            EmptyConversationPane(
                title = "Select a conversation",
                body = "Choose a chat to view messages.",
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
        } else {
            ConversationDetailPane(
                conversation = selectedConversation,
                isLoading = detailState.isLoading,
                errorMessage = detailState.errorMessage,
                composerDraft = composerDraft,
                onComposerDraftChange = onComposerDraftChange,
                isSending = isSending,
                sendErrorMessage = sendErrorMessage,
                attachmentErrorMessage = attachmentErrorMessage,
                activeAttachmentMessageId = activeAttachmentMessageId,
                onPickAttachment = onPickAttachment,
                onSend = onSend,
                onOpenAttachment = onOpenAttachment,
                onShareAttachment = onShareAttachment,
                onReactToMessage = onReactToMessage,
                onManageMembers = onManageMembers,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
        }
    }
}

@Composable
private fun TabletopConversationLayout(
    repository: ChatRepository,
    conversation: ChatConversation?,
    isLoading: Boolean,
    errorMessage: String?,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    attachmentErrorMessage: String?,
    activeAttachmentMessageId: String?,
    onPickAttachment: () -> Unit,
    onSend: () -> Unit,
    onOpenAttachment: (ChatAttachment) -> Unit,
    onShareAttachment: (ChatAttachment) -> Unit,
    onReactToMessage: ((ChatTimelineMessage) -> Unit)?,
    onManageMembers: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize(),
    ) {
        ConversationDetailContent(
            repository = repository,
            conversation = conversation,
            isLoading = isLoading,
            errorMessage = errorMessage,
            composerDraft = composerDraft,
            onComposerDraftChange = onComposerDraftChange,
            isSending = isSending,
            sendErrorMessage = sendErrorMessage,
            attachmentErrorMessage = attachmentErrorMessage,
            activeAttachmentMessageId = activeAttachmentMessageId,
            onPickAttachment = onPickAttachment,
            onSend = onSend,
            onOpenAttachment = onOpenAttachment,
            onShareAttachment = onShareAttachment,
            onReactToMessage = onReactToMessage,
            onManageMembers = onManageMembers,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            showComposer = false,
            compactHeader = false,
        )
        HorizontalDivider()
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            modifier = Modifier
                .weight(0.7f)
                .fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = "Tabletop posture",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = "The transcript stays above the hinge while the composer and diagnostics stay below it.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (conversation != null) {
                    ConversationComposerPane(
                        conversation = conversation,
                        draftText = composerDraft,
                        onDraftChange = onComposerDraftChange,
                        isSending = isSending,
                        sendErrorMessage = sendErrorMessage,
                        attachmentErrorMessage = attachmentErrorMessage,
                        errorMessage = errorMessage,
                        onPickAttachment = onPickAttachment,
                        onSend = onSend,
                        onOpenAttachment = onOpenAttachment,
                        onShareAttachment = onShareAttachment,
                    )
                } else if (errorMessage != null) {
                    Text(
                        text = errorMessage,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}

@Composable
private fun ConversationListPane(
    overviewState: ChatsOverviewState,
    selectedConversationId: String?,
    onConversationClick: (String) -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val overview = overviewState.overview ?: return

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(overview.conversations, key = { it.chatId }) { conversation ->
            val selected = conversation.chatId == selectedConversationId
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = if (selected) {
                    MaterialTheme.colorScheme.primaryContainer
                } else {
                    MaterialTheme.colorScheme.surfaceContainerLow
                },
                tonalElevation = if (selected) 2.dp else 0.dp,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("chat-row:${conversation.chatId}"),
                onClick = { onConversationClick(conversation.chatId) },
            ) {
                ListItem(
                    leadingContent = {
                        ConversationAvatar(name = conversation.title)
                    },
                    headlineContent = {
                        Text(
                            text = conversation.title,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                    supportingContent = {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                text = conversation.participantsLabel,
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                text = conversation.lastMessagePreview,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    },
                    trailingContent = {
                        Column(
                            horizontalAlignment = Alignment.End,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                text = conversation.timestampLabel,
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (conversation.unreadCount > 0) {
                                Badge {
                                    Text(
                                        text = if (conversation.unreadCount > 99) {
                                            "99+"
                                        } else {
                                            conversation.unreadCount.toString()
                                        },
                                    )
                                }
                            }
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun ChatCacheCard(
    diagnostics: ChatDiagnostics,
    isRefreshing: Boolean,
    lastRefreshSummary: String?,
    errorMessage: String?,
    onRefresh: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = "Local chat cache",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "${diagnostics.cachedChatCount} chats cached, ${diagnostics.cachedMessageCount} messages, ${diagnostics.projectedChatCount} projected timelines.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                    )
                }

                if (isRefreshing) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    FilledTonalIconButton(onClick = onRefresh) {
                        Icon(
                            imageVector = Icons.Rounded.Sync,
                            contentDescription = "Refresh chat cache",
                        )
                    }
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TimelineBadge(
                    label = diagnostics.lastAckedInboxId?.let { "Inbox ack #$it" } ?: "No inbox ack yet",
                )
                TimelineBadge(
                    label = "Lease ${diagnostics.leaseOwner.take(8)}",
                )
            }

            if (lastRefreshSummary != null) {
                Text(
                    text = lastRefreshSummary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }

            if (errorMessage != null) {
                Text(
                    text = errorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun TimelineBadge(label: String) {
    ElevatedAssistChip(
        onClick = {},
        label = { Text(label) },
    )
}

@Composable
private fun EmptyConversationPane(
    title: String,
    body: String,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceContainerLowest),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier.size(64.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Rounded.MarkUnreadChatAlt,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                }
            }
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = body,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ConversationDetailPane(
    repository: ChatRepository? = null,
    conversation: ChatConversation?,
    isLoading: Boolean,
    errorMessage: String?,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    attachmentErrorMessage: String?,
    activeAttachmentMessageId: String?,
    onPickAttachment: () -> Unit,
    onSend: () -> Unit,
    onOpenAttachment: (ChatAttachment) -> Unit,
    onShareAttachment: (ChatAttachment) -> Unit,
    onReactToMessage: ((ChatTimelineMessage) -> Unit)?,
    onManageMembers: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    ConversationDetailContent(
        repository = repository,
        conversation = conversation,
        isLoading = isLoading,
        errorMessage = errorMessage,
        composerDraft = composerDraft,
        onComposerDraftChange = onComposerDraftChange,
        isSending = isSending,
        sendErrorMessage = sendErrorMessage,
        attachmentErrorMessage = attachmentErrorMessage,
        activeAttachmentMessageId = activeAttachmentMessageId,
        onPickAttachment = onPickAttachment,
        onSend = onSend,
        onOpenAttachment = onOpenAttachment,
        onShareAttachment = onShareAttachment,
        onReactToMessage = onReactToMessage,
        onManageMembers = onManageMembers,
        modifier = modifier,
        showComposer = true,
        compactHeader = true,
    )
}

@Composable
private fun ConversationDetailContent(
    repository: ChatRepository? = null,
    conversation: ChatConversation?,
    isLoading: Boolean,
    errorMessage: String?,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    attachmentErrorMessage: String?,
    activeAttachmentMessageId: String?,
    onPickAttachment: () -> Unit,
    onSend: () -> Unit,
    onOpenAttachment: (ChatAttachment) -> Unit,
    onShareAttachment: (ChatAttachment) -> Unit,
    onReactToMessage: ((ChatTimelineMessage) -> Unit)?,
    onManageMembers: (() -> Unit)?,
    modifier: Modifier = Modifier,
    showComposer: Boolean,
    compactHeader: Boolean,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface),
    ) {
        if (conversation != null) {
            Surface(
                tonalElevation = 1.dp,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        text = conversation.title,
                        style = if (compactHeader) {
                            MaterialTheme.typography.headlineSmall
                        } else {
                            MaterialTheme.typography.titleLarge
                        },
                        fontWeight = FontWeight.SemiBold,
                    )
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        TimelineBadge(label = conversation.participantsLabel)
                        if (conversation.chatType == FfiChatType.GROUP) {
                            TimelineBadge(label = "${conversation.members.size} members")
                        }
                    }
                    if (conversation.canManageMembers && onManageMembers != null) {
                        TextButton(onClick = onManageMembers) {
                            Text("Manage members")
                        }
                    }
                }
            }
        }

        when {
            isLoading && conversation == null -> {
                LoadingChatsPane(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
            }

            conversation == null -> {
                EmptyConversationPane(
                    title = "Conversation unavailable",
                    body = errorMessage ?: "The local cache could not load this conversation.",
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
            }

            else -> {
                ConversationTranscript(
                    repository = repository,
                    conversation = conversation,
                    activeAttachmentMessageId = activeAttachmentMessageId,
                    onOpenAttachment = onOpenAttachment,
                    onShareAttachment = onShareAttachment,
                    onReactToMessage = onReactToMessage,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )

                if (showComposer) {
                    HorizontalDivider()

                    ConversationComposerPane(
                        conversation = conversation,
                        draftText = composerDraft,
                        onDraftChange = onComposerDraftChange,
                        isSending = isSending,
                        sendErrorMessage = sendErrorMessage,
                        attachmentErrorMessage = attachmentErrorMessage,
                        errorMessage = errorMessage,
                        onPickAttachment = onPickAttachment,
                        onSend = onSend,
                        onOpenAttachment = onOpenAttachment,
                        onShareAttachment = onShareAttachment,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

@Composable
private fun ConversationTranscript(
    repository: ChatRepository?,
    conversation: ChatConversation,
    activeAttachmentMessageId: String?,
    onOpenAttachment: (ChatAttachment) -> Unit,
    onShareAttachment: (ChatAttachment) -> Unit,
    onReactToMessage: ((ChatTimelineMessage) -> Unit)?,
    modifier: Modifier = Modifier,
) {
    if (conversation.messages.isEmpty()) {
        EmptyConversationPane(
            title = "No messages yet",
            body = "Send a message to start the conversation.",
            modifier = modifier,
        )
        return
    }

    val listState = rememberLazyListState()

    LaunchedEffect(conversation.messages.size) {
        if (conversation.messages.isNotEmpty()) {
            listState.animateScrollToItem(conversation.messages.lastIndex)
        }
    }

    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(conversation.messages, key = { it.id }) { message ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = if (message.isMine) Arrangement.End else Arrangement.Start,
            ) {
                Column(
                    modifier = Modifier
                        .widthIn(max = 420.dp)
                        .wrapContentWidth(
                            if (message.isMine) Alignment.End else Alignment.Start,
                        ),
                    horizontalAlignment = if (message.isMine) Alignment.End else Alignment.Start,
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Surface(
                        shape = RoundedCornerShape(24.dp),
                        color = if (message.isMine) {
                            MaterialTheme.colorScheme.primaryContainer
                        } else {
                            MaterialTheme.colorScheme.surfaceContainerHigh
                        },
                        tonalElevation = 1.dp,
                        modifier = Modifier
                            .combinedClickable(
                                onClick = {},
                                onLongClick = onReactToMessage?.let { callback ->
                                    { callback(message) }
                                },
                            ),
                    ) {
                        Column(
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                text = message.author,
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                text = message.body,
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            if (message.attachment != null) {
                                Column(
                                    verticalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    if (
                                        repository != null &&
                                        message.attachment.supportsLocalImagePreview()
                                    ) {
                                        InlineAttachmentPreview(
                                            attachment = message.attachment,
                                            repository = repository,
                                            enabled = activeAttachmentMessageId != message.id,
                                            onOpenAttachment = onOpenAttachment,
                                        )
                                    }

                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        TextButton(
                                            onClick = { onOpenAttachment(message.attachment) },
                                            enabled = activeAttachmentMessageId != message.id,
                                        ) {
                                            if (activeAttachmentMessageId == message.id) {
                                                CircularProgressIndicator(
                                                    modifier = Modifier.size(16.dp),
                                                    strokeWidth = 2.dp,
                                                )
                                            } else {
                                                Icon(
                                                    imageVector = Icons.Rounded.FolderOpen,
                                                    contentDescription = null,
                                                )
                                            }
                                            Spacer(Modifier.width(6.dp))
                                            Text("Open")
                                        }
                                        OutlinedButton(
                                            onClick = { onShareAttachment(message.attachment) },
                                            enabled = activeAttachmentMessageId != message.id,
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Share,
                                                contentDescription = null,
                                            )
                                            Spacer(Modifier.width(6.dp))
                                            Text("Share")
                                        }
                                    }
                                }
                            }
                            if (message.note != null) {
                                Text(
                                    text = message.note,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                }
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (message.isMine && message.receiptStatus != null) {
                                    Icon(
                                        imageVector = receiptStatusIcon(message.receiptStatus),
                                        contentDescription = null,
                                        modifier = Modifier.size(14.dp),
                                        tint = receiptStatusTint(message.receiptStatus),
                                    )
                                }
                                Text(
                                    text = message.timestampLabel,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }

                    if (message.reactions.isNotEmpty()) {
                        MessageReactionRow(
                            reactions = message.reactions,
                            isMine = message.isMine,
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QuickReactionSheet(
    message: ChatTimelineMessage,
    emojis: List<String>,
    onDismissRequest: () -> Unit,
    onEmojiSelected: (String) -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Choose reaction",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = message.body,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            emojis.chunked(4).forEach { rowEmojis ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    rowEmojis.forEach { emoji ->
                        val removeExisting = message.reactions.any {
                            it.emoji == emoji && it.includesSelf
                        }
                        ElevatedAssistChip(
                            onClick = { onEmojiSelected(emoji) },
                            label = {
                                Text(if (removeExisting) "$emoji ✓" else emoji)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MessageReactionBadge(reaction: ChatMessageReaction) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = if (reaction.includesSelf) {
            MaterialTheme.colorScheme.secondaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHighest
        },
    ) {
        Text(
            text = if (reaction.count > 1) "${reaction.emoji} ${reaction.count}" else reaction.emoji,
            style = MaterialTheme.typography.labelSmall,
            color = if (reaction.includesSelf) {
                MaterialTheme.colorScheme.onSecondaryContainer
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun MessageReactionRow(
    reactions: List<ChatMessageReaction>,
    isMine: Boolean,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = if (isMine) Arrangement.End else Arrangement.Start,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            reactions.forEach { reaction ->
                MessageReactionBadge(reaction = reaction)
            }
        }
    }
}

private fun receiptStatusIcon(status: ChatReceiptStatus) = when (status) {
    ChatReceiptStatus.DELIVERED -> Icons.Rounded.Done
    ChatReceiptStatus.READ -> Icons.Rounded.DoneAll
}

@Composable
private fun receiptStatusTint(status: ChatReceiptStatus) = when (status) {
    ChatReceiptStatus.DELIVERED -> MaterialTheme.colorScheme.onSurfaceVariant
    ChatReceiptStatus.READ -> MaterialTheme.colorScheme.primary
}

@Composable
private fun ConversationComposerPane(
    conversation: ChatConversation,
    draftText: String,
    onDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    attachmentErrorMessage: String?,
    errorMessage: String? = null,
    onPickAttachment: () -> Unit,
    onSend: () -> Unit,
    onOpenAttachment: (ChatAttachment) -> Unit,
    onShareAttachment: (ChatAttachment) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (conversation.canSend) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                FilledTonalIconButton(
                    onClick = onPickAttachment,
                    enabled = !isSending,
                    modifier = Modifier.size(56.dp),
                ) {
                    Icon(
                        imageVector = Icons.Rounded.AttachFile,
                        contentDescription = "Attach file",
                    )
                }
                OutlinedTextField(
                    value = draftText,
                    onValueChange = onDraftChange,
                    modifier = Modifier.weight(1f),
                    enabled = !isSending,
                    placeholder = { Text(conversation.composerHint) },
                    minLines = 2,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions.Default.copy(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(
                        onSend = {
                            if (draftText.isNotBlank() && !isSending) {
                                onSend()
                            }
                        },
                    ),
                )
                FilledTonalIconButton(
                    onClick = onSend,
                    enabled = !isSending && draftText.isNotBlank(),
                    modifier = Modifier.size(56.dp),
                ) {
                    if (isSending) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.Send,
                            contentDescription = "Send message",
                        )
                    }
                }
            }
        } else {
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = "Sending unavailable",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = conversation.composerHint,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        if (sendErrorMessage != null) {
            Text(
                text = sendErrorMessage,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
        if (attachmentErrorMessage != null) {
            Text(
                text = attachmentErrorMessage,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
        if (errorMessage != null) {
            Text(
                text = errorMessage,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}

@Composable
private fun ConversationAvatar(name: String) {
    val initial = name.firstOrNull()?.uppercase() ?: "T"

    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.tertiaryContainer),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = initial,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onTertiaryContainer,
        )
    }
}

private data class ChatsOverviewState(
    val overview: ChatOverview? = null,
    val isRefreshing: Boolean = false,
    val errorMessage: String? = null,
    val lastRefreshSummary: String? = null,
)

internal data class ChatsDetailState(
    val conversation: ChatConversation? = null,
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val isSending: Boolean = false,
    val sendErrorMessage: String? = null,
)

internal data class ChatSendState(
    val isSending: Boolean = false,
    val sendErrorMessage: String? = null,
)

internal data class PassiveConversationReloadState(
    val detailState: ChatsDetailState,
    val sendState: ChatSendState,
)

internal fun applyPassiveConversationReload(
    currentDetailState: ChatsDetailState,
    currentSendState: ChatSendState,
    conversation: ChatConversation?,
    errorMessage: String?,
): PassiveConversationReloadState {
    return PassiveConversationReloadState(
        detailState = currentDetailState.copy(
            conversation = conversation,
            isLoading = false,
            errorMessage = errorMessage,
        ),
        sendState = currentSendState,
    )
}

private data class ChatsDirectoryState(
    val accounts: List<ChatDirectoryAccount> = emptyList(),
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val activeAccountId: String? = null,
    val isSubmitting: Boolean = false,
    val hasLoaded: Boolean = false,
)

private data class DirectorySheetConfig(
    val mode: DirectorySheetMode,
    val chatId: String? = null,
)

private enum class DirectorySheetMode {
    DIRECT_MESSAGE,
    GROUP_CREATE,
    GROUP_ADD_MEMBERS,
}

@Composable
internal fun ConversationListPaneForTesting(
    overview: ChatOverview,
    selectedConversationId: String? = null,
    isRefreshing: Boolean = false,
    errorMessage: String? = null,
    lastRefreshSummary: String? = null,
    onConversationClick: (String) -> Unit = {},
    onRefresh: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    ConversationListPane(
        overviewState = ChatsOverviewState(
            overview = overview,
            isRefreshing = isRefreshing,
            errorMessage = errorMessage,
            lastRefreshSummary = lastRefreshSummary,
        ),
        selectedConversationId = selectedConversationId,
        onConversationClick = onConversationClick,
        onRefresh = onRefresh,
        modifier = modifier,
    )
}

@Composable
internal fun ConversationDetailPaneForTesting(
    conversation: ChatConversation?,
    isLoading: Boolean = false,
    errorMessage: String? = null,
    composerDraft: String = "",
    isSending: Boolean = false,
    sendErrorMessage: String? = null,
    attachmentErrorMessage: String? = null,
    activeAttachmentMessageId: String? = null,
    onComposerDraftChange: (String) -> Unit = {},
    onPickAttachment: () -> Unit = {},
    onSend: () -> Unit = {},
    onOpenAttachment: (ChatAttachment) -> Unit = {},
    onShareAttachment: (ChatAttachment) -> Unit = {},
    onReactToMessage: ((ChatTimelineMessage) -> Unit)? = null,
    onManageMembers: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    ConversationDetailPane(
        conversation = conversation,
        isLoading = isLoading,
        errorMessage = errorMessage,
        composerDraft = composerDraft,
        onComposerDraftChange = onComposerDraftChange,
        isSending = isSending,
        sendErrorMessage = sendErrorMessage,
        attachmentErrorMessage = attachmentErrorMessage,
        activeAttachmentMessageId = activeAttachmentMessageId,
        onPickAttachment = onPickAttachment,
        onSend = onSend,
        onOpenAttachment = onOpenAttachment,
        onShareAttachment = onShareAttachment,
        onReactToMessage = onReactToMessage,
        onManageMembers = onManageMembers,
        modifier = modifier,
    )
}

private fun ChatRefreshResult.toSummary(): String {
    return buildString {
        append("Refresh applied ")
        append(historyMessagesUpserted)
        append(" history messages, ")
        append(inboxMessagesUpserted)
        append(" inbox messages, acked ")
        append(ackedInboxCount)
        append(" inbox ids, hydrated ")
        append(hydratedChatDetails)
        append(" chat details, projected ")
        append(projectedChatTimelines)
        append(" local MLS timelines, flushed ")
        append(flushedOutboxCount)
        append(" queued outbox items.")
    }
}
