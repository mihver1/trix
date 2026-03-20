package chat.trix.android.feature.chats

import android.graphics.Rect
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.rounded.MarkUnreadChatAlt
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.chat.ChatConversation
import chat.trix.android.core.chat.ChatConversationSummary
import chat.trix.android.core.chat.ChatDiagnostics
import chat.trix.android.core.chat.ChatOverview
import chat.trix.android.core.chat.ChatRefreshResult
import chat.trix.android.core.chat.ChatRepository
import chat.trix.android.core.chat.ChatTimelineMessage
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import chat.trix.android.ui.adaptive.TrixFoldPosture
import java.io.IOException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatsScreen(
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
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
    var composerDraft by rememberSaveable(selectedConversationId) { mutableStateOf("") }

    suspend fun loadCachedOverview(): ChatOverview? {
        return try {
            repository.loadOverview()
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
        if (!conversation.canSend || detailState.isSending) {
            return
        }

        val draft = composerDraft
        if (draft.isBlank()) {
            return
        }

        detailState = detailState.copy(
            isSending = true,
            sendErrorMessage = null,
            errorMessage = null,
        )

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
                isSending = false,
                errorMessage = null,
                sendErrorMessage = null,
            )
        } catch (error: IOException) {
            detailState = detailState.copy(
                isSending = false,
                sendErrorMessage = error.message ?: "Failed to send message",
            )
        }
    }

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
            return@LaunchedEffect
        }

        val currentConversation = detailState.conversation?.takeIf { it.chatId == chatId }
        detailState = detailState.copy(
            conversation = currentConversation,
            isLoading = true,
            errorMessage = null,
            isSending = false,
            sendErrorMessage = null,
        )

        detailState = try {
            ChatsDetailState(
                conversation = repository.loadConversation(chatId),
                isLoading = false,
                errorMessage = null,
            )
        } catch (error: IOException) {
            ChatsDetailState(
                conversation = currentConversation,
                isLoading = false,
                errorMessage = error.message ?: "Failed to load conversation",
            )
        }
    }

    val conversations = overviewState.overview?.conversations.orEmpty()
    val selectedConversationSummary = conversations.firstOrNull { it.chatId == selectedConversationId }
    val selectedConversation = detailState.conversation
        ?.takeIf { it.chatId == selectedConversationId }
    val detailOnly = !showTwoPane && selectedConversationId != null

    BackHandler(enabled = detailOnly) {
        selectedConversationId = null
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
                    conversation = selectedConversation,
                    isLoading = detailState.isLoading,
                    errorMessage = detailState.errorMessage,
                    composerDraft = composerDraft,
                    onComposerDraftChange = { composerDraft = it },
                    isSending = detailState.isSending,
                    sendErrorMessage = detailState.sendErrorMessage,
                    onSend = { coroutineScope.launch { sendDraftMessage() } },
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
                    isSending = detailState.isSending,
                    sendErrorMessage = detailState.sendErrorMessage,
                    onSend = { coroutineScope.launch { sendDraftMessage() } },
                    foldPosture = windowInfo.foldPosture,
                    foldBounds = windowInfo.foldBounds,
                    modifier = contentModifier,
                )
            }

            selectedConversationId != null -> {
                ConversationDetailPane(
                    conversation = selectedConversation,
                    isLoading = detailState.isLoading,
                    errorMessage = detailState.errorMessage,
                    composerDraft = composerDraft,
                    onComposerDraftChange = { composerDraft = it },
                    isSending = detailState.isSending,
                    sendErrorMessage = detailState.sendErrorMessage,
                    onSend = { coroutineScope.launch { sendDraftMessage() } },
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
                text = if (errorMessage == null) "No chats in local cache" else "Chat sync failed",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
            Text(
                text = errorMessage
                    ?: "This Android slice now reads from the Rust local store. Once the backend has threads for this account, refresh will pull them into the on-device cache.",
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
    onSend: () -> Unit,
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
                body = "Expanded layouts keep the local thread list and the selected transcript visible together.",
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
                onSend = onSend,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
        }
    }
}

@Composable
private fun TabletopConversationLayout(
    conversation: ChatConversation?,
    isLoading: Boolean,
    errorMessage: String?,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize(),
    ) {
        ConversationDetailContent(
            conversation = conversation,
            isLoading = isLoading,
            errorMessage = errorMessage,
            composerDraft = composerDraft,
            onComposerDraftChange = onComposerDraftChange,
            isSending = isSending,
            sendErrorMessage = sendErrorMessage,
            onSend = onSend,
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
                        errorMessage = errorMessage,
                        onSend = onSend,
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
        item {
            ChatCacheCard(
                diagnostics = overview.diagnostics,
                isRefreshing = overviewState.isRefreshing,
                lastRefreshSummary = overviewState.lastRefreshSummary,
                errorMessage = overviewState.errorMessage,
                onRefresh = onRefresh,
            )
        }

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
                modifier = Modifier.fillMaxWidth(),
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
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                if (conversation.isAccountSyncChat) {
                                    TimelineBadge(label = "Account sync")
                                }
                                if (conversation.hasProjectedTimeline) {
                                    TimelineBadge(label = "Projected")
                                }
                            }
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
                            if (conversation.messageCount > 0) {
                                Badge {
                                    Text(text = conversation.messageCount.toString())
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
    conversation: ChatConversation?,
    isLoading: Boolean,
    errorMessage: String?,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ConversationDetailContent(
        conversation = conversation,
        isLoading = isLoading,
        errorMessage = errorMessage,
        composerDraft = composerDraft,
        onComposerDraftChange = onComposerDraftChange,
        isSending = isSending,
        sendErrorMessage = sendErrorMessage,
        onSend = onSend,
        modifier = modifier,
        showComposer = true,
        compactHeader = true,
    )
}

@Composable
private fun ConversationDetailContent(
    conversation: ChatConversation?,
    isLoading: Boolean,
    errorMessage: String?,
    composerDraft: String,
    onComposerDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    onSend: () -> Unit,
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
                        TimelineBadge(label = conversation.timelineLabel)
                        if (conversation.isAccountSyncChat) {
                            TimelineBadge(label = "Account sync")
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
                    conversation = conversation,
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
                        errorMessage = errorMessage,
                        onSend = onSend,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

@Composable
private fun ConversationTranscript(
    conversation: ChatConversation,
    modifier: Modifier = Modifier,
) {
    if (conversation.messages.isEmpty()) {
        EmptyConversationPane(
            title = "No local messages yet",
            body = "The chat exists in cache, but there are no synced envelopes for this thread on the device yet.",
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
                Surface(
                    shape = RoundedCornerShape(24.dp),
                    color = if (message.isMine) {
                        MaterialTheme.colorScheme.primaryContainer
                    } else {
                        MaterialTheme.colorScheme.surfaceContainerHigh
                    },
                    tonalElevation = 1.dp,
                    modifier = Modifier.widthIn(max = 420.dp),
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
                        if (message.note != null) {
                            Text(
                                text = message.note,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
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
        }
    }
}

@Composable
private fun ConversationComposerPane(
    conversation: ChatConversation,
    draftText: String,
    onDraftChange: (String) -> Unit,
    isSending: Boolean,
    sendErrorMessage: String?,
    errorMessage: String? = null,
    onSend: () -> Unit,
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

private data class ChatsDetailState(
    val conversation: ChatConversation? = null,
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val isSending: Boolean = false,
    val sendErrorMessage: String? = null,
)

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
        append(" local MLS timelines.")
    }
}
