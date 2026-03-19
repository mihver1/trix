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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.MarkUnreadChatAlt
import androidx.compose.material.icons.rounded.Send
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Badge
import androidx.compose.material3.CenterAlignedTopAppBar
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import chat.trix.android.ui.adaptive.TrixFoldPosture

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatsScreen(
    windowInfo: TrixAdaptiveInfo,
    modifier: Modifier = Modifier,
) {
    val conversations = remember {
        mutableStateListOf<ConversationUiModel>().apply {
            addAll(sampleConversations())
        }
    }
    var selectedConversationId by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedConversation = conversations.firstOrNull { it.id == selectedConversationId }
    val showTwoPane = windowInfo.prefersTwoPaneChat

    LaunchedEffect(showTwoPane, conversations.size) {
        if (showTwoPane && selectedConversationId == null && conversations.isNotEmpty()) {
            selectedConversationId = conversations.first().id
        }
    }

    BackHandler(enabled = !showTwoPane && selectedConversation != null) {
        selectedConversationId = null
    }

    val detailOnly = !showTwoPane && selectedConversation != null

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            if (detailOnly && selectedConversation != null) {
                TopAppBar(
                    title = {
                        Text(
                            text = selectedConversation.title,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = { selectedConversationId = null }) {
                            Icon(
                                imageVector = Icons.Rounded.ArrowBack,
                                contentDescription = stringResource(R.string.action_back),
                            )
                        }
                    },
                )
            } else {
                CenterAlignedTopAppBar(
                    title = { Text(stringResource(R.string.screen_chats)) },
                    actions = {
                        FilledTonalIconButton(onClick = {}) {
                            Icon(
                                imageVector = Icons.Rounded.Edit,
                                contentDescription = null,
                            )
                        }
                    },
                )
            }
        },
    ) { innerPadding ->
        val contentModifier = Modifier
            .fillMaxSize()
            .padding(innerPadding)

        when {
            windowInfo.foldPosture == TrixFoldPosture.Tabletop && selectedConversation != null -> {
                TabletopConversationLayout(
                    conversation = selectedConversation,
                    onSendMessage = { draft ->
                        appendOutgoingMessage(
                            conversations = conversations,
                            conversationId = selectedConversation.id,
                            draft = draft,
                        )
                    },
                    modifier = contentModifier,
                )
            }

            showTwoPane -> {
                WideConversationLayout(
                    conversations = conversations,
                    selectedConversationId = selectedConversationId,
                    onConversationClick = { selectedConversationId = it },
                    onSendMessage = { draft ->
                        selectedConversationId?.let { conversationId ->
                            appendOutgoingMessage(
                                conversations = conversations,
                                conversationId = conversationId,
                                draft = draft,
                            )
                        }
                    },
                    foldPosture = windowInfo.foldPosture,
                    foldBounds = windowInfo.foldBounds,
                    modifier = contentModifier,
                )
            }

            selectedConversation != null -> {
                ConversationDetailPane(
                    conversation = selectedConversation,
                    onSendMessage = { draft ->
                        appendOutgoingMessage(
                            conversations = conversations,
                            conversationId = selectedConversation.id,
                            draft = draft,
                        )
                    },
                    modifier = contentModifier,
                )
            }

            else -> {
                ConversationListPane(
                    conversations = conversations,
                    selectedConversationId = selectedConversationId,
                    onConversationClick = { selectedConversationId = it },
                    modifier = contentModifier,
                )
            }
        }
    }
}

@Composable
private fun WideConversationLayout(
    conversations: List<ConversationUiModel>,
    selectedConversationId: String?,
    onConversationClick: (String) -> Unit,
    onSendMessage: (String) -> Unit,
    foldPosture: TrixFoldPosture,
    foldBounds: Rect?,
    modifier: Modifier = Modifier,
) {
    val selectedConversation = conversations.firstOrNull { it.id == selectedConversationId }
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
                conversations = conversations,
                selectedConversationId = selectedConversationId,
                onConversationClick = onConversationClick,
            )
        }

        if (foldGap > 0.dp) {
            Spacer(modifier = Modifier.width(foldGap))
        } else {
            VerticalDivider()
        }

        if (selectedConversation == null) {
            EmptyConversationPane(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
        } else {
            ConversationDetailPane(
                conversation = selectedConversation,
                onSendMessage = onSendMessage,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
        }
    }
}

@Composable
private fun TabletopConversationLayout(
    conversation: ConversationUiModel,
    onSendMessage: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize(),
    ) {
        ConversationTranscript(
            conversation = conversation,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
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
                    text = "The transcript stays above the hinge while compose actions and thread context stay below it.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                ConversationComposer(
                    conversation = conversation,
                    onSendMessage = onSendMessage,
                )
            }
        }
    }
}

@Composable
private fun ConversationListPane(
    conversations: List<ConversationUiModel>,
    selectedConversationId: String?,
    onConversationClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = MaterialTheme.colorScheme.secondaryContainer,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = "Universal chat layout",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "List-detail on wide windows, full-screen detail on compact windows, and hinge-safe behavior on foldables.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                    )
                }
            }
        }

        items(conversations, key = { it.id }) { conversation ->
            val selected = conversation.id == selectedConversationId
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = if (selected) {
                    MaterialTheme.colorScheme.primaryContainer
                } else {
                    MaterialTheme.colorScheme.surfaceContainerLow
                },
                tonalElevation = if (selected) 2.dp else 0.dp,
                modifier = Modifier.fillMaxWidth(),
                onClick = { onConversationClick(conversation.id) },
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
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(
                                text = conversation.participants,
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
                                text = conversation.timestamp,
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (conversation.unreadCount > 0) {
                                Badge {
                                    Text(text = conversation.unreadCount.toString())
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
private fun EmptyConversationPane(modifier: Modifier = Modifier) {
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
                text = "Select a conversation",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Expanded layouts keep the thread list and transcript visible together.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ConversationDetailPane(
    conversation: ConversationUiModel,
    onSendMessage: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface),
    ) {
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
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    AssistChip(
                        onClick = {},
                        label = { Text(conversation.participants) },
                        colors = AssistChipDefaults.assistChipColors(),
                    )
                    AssistChip(
                        onClick = {},
                        label = { Text("E2EE draft flow") },
                    )
                }
            }
        }

        ConversationTranscript(
            conversation = conversation,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        )

        HorizontalDivider()

        ConversationComposer(
            conversation = conversation,
            onSendMessage = onSendMessage,
        )
    }
}

@Composable
private fun ConversationTranscript(
    conversation: ConversationUiModel,
    modifier: Modifier = Modifier,
) {
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
                        Text(
                            text = message.timestamp,
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
private fun ConversationComposer(
    conversation: ConversationUiModel,
    onSendMessage: (String) -> Unit,
) {
    var draft by rememberSaveable(conversation.id) { mutableStateOf("") }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            modifier = Modifier.weight(1f),
            minLines = 2,
            maxLines = 5,
            placeholder = {
                Text(text = "Write an encrypted message draft")
            },
        )
        FilledTonalIconButton(
            onClick = {
                if (draft.isNotBlank()) {
                    onSendMessage(draft.trim())
                    draft = ""
                }
            },
            enabled = draft.isNotBlank(),
            modifier = Modifier.size(56.dp),
        ) {
            Icon(
                imageVector = Icons.Rounded.Send,
                contentDescription = stringResource(R.string.action_send),
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

private fun appendOutgoingMessage(
    conversations: MutableList<ConversationUiModel>,
    conversationId: String,
    draft: String,
) {
    val index = conversations.indexOfFirst { it.id == conversationId }
    if (index == -1) {
        return
    }

    val conversation = conversations[index]
    val updated = conversation.copy(
        lastMessagePreview = "You: $draft",
        timestamp = "Now",
        unreadCount = 0,
        messages = conversation.messages + MessageUiModel(
            id = "msg-${conversation.messages.size + 1}",
            author = "You",
            body = draft,
            timestamp = "Now",
            isMine = true,
        ),
    )

    conversations.removeAt(index)
    conversations.add(0, updated)
}

private data class ConversationUiModel(
    val id: String,
    val title: String,
    val participants: String,
    val lastMessagePreview: String,
    val timestamp: String,
    val unreadCount: Int,
    val messages: List<MessageUiModel>,
)

private data class MessageUiModel(
    val id: String,
    val author: String,
    val body: String,
    val timestamp: String,
    val isMine: Boolean,
)

private fun sampleConversations(): List<ConversationUiModel> = listOf(
    ConversationUiModel(
        id = "ops",
        title = "Server PoC",
        participants = "Maks, Rita, Alex",
        lastMessagePreview = "Auth challenge path is stable. We can wire Android next.",
        timestamp = "09:42",
        unreadCount = 2,
        messages = listOf(
            MessageUiModel("1", "Rita", "Server health and version endpoints are enough for the first Android vertical slice.", "09:11", false),
            MessageUiModel("2", "Alex", "Let's keep the app Kotlin-first until the Rust core stops being a stub.", "09:16", false),
            MessageUiModel("3", "You", "Agreed. I'll shape the client around adaptive navigation and a messaging-first layout.", "09:21", true),
        ),
    ),
    ConversationUiModel(
        id = "design",
        title = "Adaptive UI",
        participants = "Product, Design",
        lastMessagePreview = "Phone gets bottom nav, tablets get rail, wide screens get permanent drawer.",
        timestamp = "Yesterday",
        unreadCount = 0,
        messages = listOf(
            MessageUiModel("4", "Design", "Messaging should always feel native, not like a responsive website wrapped into a shell.", "Yesterday", false),
            MessageUiModel("5", "You", "Using canonical Android layouts keeps the UX predictable across phone, tablet, and foldable.", "Yesterday", true),
        ),
    ),
    ConversationUiModel(
        id = "security",
        title = "Crypto backlog",
        participants = "Security",
        lastMessagePreview = "Key storage belongs in Android Keystore once device auth is wired.",
        timestamp = "Tue",
        unreadCount = 1,
        messages = listOf(
            MessageUiModel("6", "Security", "Do not back up local keys through Android cloud backup.", "Tue", false),
            MessageUiModel("7", "You", "Manifest backup stays disabled by default for the app scaffold.", "Tue", true),
        ),
    ),
)
