use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use trix_types::{
    ChatDetailResponse, ChatDeviceSummary, ChatHistoryResponse, ChatId, ChatListResponse,
    ChatMemberSummary, ChatParticipantProfileSummary, ChatSummary, ChatType, InboxItem,
    MessageEnvelope, MessageId,
};
use uuid::Uuid;

use crate::{
    MessageBody, MlsConversation, MlsFacade, MlsProcessResult, control_message_ratchet_tree,
    decode_b64_field,
};

#[derive(Debug, Clone)]
pub struct AttachmentStore {
    pub root: PathBuf,
}

impl AttachmentStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
}

#[derive(Debug, Clone)]
pub struct MlsStateStore {
    pub root: PathBuf,
}

impl MlsStateStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
}

#[derive(Debug, Clone)]
pub struct SyncStateStore {
    pub state_path: PathBuf,
    pub database_key: Option<Vec<u8>>,
}

impl SyncStateStore {
    pub fn new(state_path: impl Into<PathBuf>) -> Self {
        Self {
            state_path: state_path.into(),
            database_key: None,
        }
    }

    pub fn new_encrypted(state_path: impl Into<PathBuf>, database_key: Vec<u8>) -> Self {
        Self {
            state_path: state_path.into(),
            database_key: Some(database_key),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalStoreApplyReport {
    pub chats_upserted: usize,
    pub messages_upserted: usize,
    pub changed_chat_ids: Vec<ChatId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalProjectionKind {
    ApplicationMessage,
    ProposalQueued,
    CommitMerged,
    WelcomeRef,
    System,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalProjectedMessage {
    pub server_seq: u64,
    pub message_id: MessageId,
    pub sender_account_id: trix_types::AccountId,
    pub sender_device_id: trix_types::DeviceId,
    pub epoch: u64,
    pub message_kind: trix_types::MessageKind,
    pub content_type: trix_types::ContentType,
    pub projection_kind: LocalProjectionKind,
    pub payload: Option<Vec<u8>>,
    pub merged_epoch: Option<u64>,
    pub created_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalProjectionApplyReport {
    pub chat_id: ChatId,
    pub processed_messages: usize,
    pub projected_messages_upserted: usize,
    pub advanced_to_server_seq: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalChatReadState {
    pub chat_id: ChatId,
    pub read_cursor_server_seq: u64,
    pub unread_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalChatListItem {
    pub chat_id: ChatId,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub display_title: String,
    pub last_server_seq: u64,
    pub epoch: u64,
    pub pending_message_count: u64,
    pub unread_count: u64,
    pub preview_text: Option<String>,
    pub preview_sender_account_id: Option<trix_types::AccountId>,
    pub preview_sender_display_name: Option<String>,
    pub preview_is_outgoing: Option<bool>,
    pub preview_server_seq: Option<u64>,
    pub preview_created_at_unix: Option<u64>,
    pub participant_profiles: Vec<ChatParticipantProfileSummary>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LocalTimelineItem {
    pub server_seq: u64,
    pub message_id: MessageId,
    pub sender_account_id: trix_types::AccountId,
    pub sender_device_id: trix_types::DeviceId,
    pub sender_display_name: String,
    pub is_outgoing: bool,
    pub epoch: u64,
    pub message_kind: trix_types::MessageKind,
    pub content_type: trix_types::ContentType,
    pub projection_kind: LocalProjectionKind,
    pub body: Option<MessageBody>,
    pub body_parse_error: Option<String>,
    pub preview_text: String,
    pub merged_epoch: Option<u64>,
    pub created_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalOutgoingMessageApplyOutcome {
    pub report: LocalStoreApplyReport,
    pub projected_message: LocalProjectedMessage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalOutboxStatus {
    Pending,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalOutboxAttachmentDraft {
    pub local_path: String,
    pub mime_type: String,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LocalOutboxPayload {
    Body { body: MessageBody },
    AttachmentDraft { attachment: LocalOutboxAttachmentDraft },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LocalOutboxMessage {
    pub message_id: MessageId,
    pub chat_id: ChatId,
    pub sender_account_id: trix_types::AccountId,
    pub sender_device_id: trix_types::DeviceId,
    pub payload: LocalOutboxPayload,
    pub queued_at_unix: u64,
    pub status: LocalOutboxStatus,
    pub failure_message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct LocalHistoryStore {
    state: PersistedLocalHistoryState,
    database_path: Option<PathBuf>,
    database_key: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedLocalHistoryState {
    version: u32,
    chats: BTreeMap<String, PersistedChatState>,
    #[serde(default)]
    outbox: BTreeMap<String, LocalOutboxMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedChatState {
    chat_type: ChatType,
    title: Option<String>,
    last_server_seq: u64,
    #[serde(default)]
    pending_message_count: u64,
    last_message: Option<MessageEnvelope>,
    epoch: u64,
    last_commit_message_id: Option<MessageId>,
    #[serde(default)]
    participant_profiles: Vec<ChatParticipantProfileSummary>,
    members: Vec<ChatMemberSummary>,
    #[serde(default)]
    device_members: Vec<ChatDeviceSummary>,
    #[serde(default)]
    mls_group_id_b64: Option<String>,
    messages: BTreeMap<u64, MessageEnvelope>,
    #[serde(default)]
    read_cursor_server_seq: u64,
    #[serde(default)]
    projected_cursor_server_seq: u64,
    #[serde(default)]
    projected_messages: BTreeMap<u64, PersistedProjectedMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PersistedProjectedMessage {
    server_seq: u64,
    message_id: MessageId,
    sender_account_id: trix_types::AccountId,
    sender_device_id: trix_types::DeviceId,
    epoch: u64,
    message_kind: trix_types::MessageKind,
    content_type: trix_types::ContentType,
    projection_kind: LocalProjectionKind,
    payload_b64: Option<String>,
    merged_epoch: Option<u64>,
    created_at_unix: u64,
}

impl Default for PersistedLocalHistoryState {
    fn default() -> Self {
        Self {
            version: 1,
            chats: BTreeMap::new(),
            outbox: BTreeMap::new(),
        }
    }
}

impl Default for LocalHistoryStore {
    fn default() -> Self {
        Self::new()
    }
}

impl LocalHistoryStore {
    pub fn new() -> Self {
        Self {
            state: PersistedLocalHistoryState::default(),
            database_path: None,
            database_key: None,
        }
    }

    pub fn new_persistent(database_path: impl Into<PathBuf>) -> Result<Self> {
        let database_path = database_path.into();
        if database_path.exists() {
            Ok(Self {
                state: load_state_from_path(&database_path)?,
                database_path: Some(database_path),
                database_key: None,
            })
        } else {
            let store = Self {
                state: PersistedLocalHistoryState::default(),
                database_path: Some(database_path),
                database_key: None,
            };
            store.save_state()?;
            Ok(store)
        }
    }

    pub fn new_encrypted(database_path: impl Into<PathBuf>, database_key: Vec<u8>) -> Result<Self> {
        let database_path = database_path.into();
        if database_path.exists() {
            Ok(Self {
                state: load_state_from_encrypted_path(&database_path, &database_key)?,
                database_path: Some(database_path),
                database_key: Some(database_key),
            })
        } else {
            let store = Self {
                state: PersistedLocalHistoryState::default(),
                database_path: Some(database_path),
                database_key: Some(database_key),
            };
            store.save_state()?;
            Ok(store)
        }
    }

    pub fn database_path(&self) -> Option<&Path> {
        self.database_path.as_deref()
    }

    pub fn save_state(&self) -> Result<()> {
        let Some(database_path) = &self.database_path else {
            return Ok(());
        };
        save_state_to_path(database_path, self.database_key.as_deref(), &self.state)
    }

    pub(crate) fn replace_with(&mut self, other: &Self) -> Result<()> {
        self.state = other.state.clone();
        self.save_state()
    }

    pub fn list_chats(&self) -> Vec<ChatSummary> {
        let mut chats = self
            .state
            .chats
            .iter()
            .filter_map(|(chat_id, state)| {
                Some(ChatSummary {
                    chat_id: parse_chat_id(chat_id).ok()?,
                    chat_type: state.chat_type,
                    title: state.title.clone(),
                    last_server_seq: state.last_server_seq,
                    epoch: state.epoch,
                    pending_message_count: state.pending_message_count,
                    last_message: state.last_message.clone(),
                    participant_profiles: state.participant_profiles.clone(),
                })
            })
            .collect::<Vec<_>>();
        chats.sort_by(|left, right| {
            right
                .last_server_seq
                .cmp(&left.last_server_seq)
                .then_with(|| left.chat_id.0.cmp(&right.chat_id.0))
        });
        chats
    }

    pub fn list_local_chat_list_items(
        &self,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Vec<LocalChatListItem> {
        let mut chats = self
            .state
            .chats
            .iter()
            .filter_map(|(chat_id, state)| {
                Some(local_chat_list_item_from(
                    parse_chat_id(chat_id).ok()?,
                    state,
                    self_account_id,
                ))
            })
            .collect::<Vec<_>>();
        chats.sort_by(|left, right| {
            right
                .last_server_seq
                .cmp(&left.last_server_seq)
                .then_with(|| left.chat_id.0.cmp(&right.chat_id.0))
        });
        chats
    }

    pub fn get_local_chat_list_item(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Option<LocalChatListItem> {
        let state = self.state.chats.get(&chat_id.0.to_string())?;
        Some(local_chat_list_item_from(chat_id, state, self_account_id))
    }

    pub fn get_chat(&self, chat_id: ChatId) -> Option<ChatDetailResponse> {
        let state = self.state.chats.get(&chat_id.0.to_string())?;
        Some(ChatDetailResponse {
            chat_id,
            chat_type: state.chat_type,
            title: state.title.clone(),
            last_server_seq: state.last_server_seq,
            pending_message_count: state.pending_message_count,
            epoch: state.epoch,
            last_commit_message_id: state.last_commit_message_id,
            last_message: state.last_message.clone(),
            participant_profiles: state.participant_profiles.clone(),
            members: state.members.clone(),
            device_members: state.device_members.clone(),
        })
    }

    pub fn get_chat_history(
        &self,
        chat_id: ChatId,
        after_server_seq: Option<u64>,
        limit: Option<usize>,
    ) -> ChatHistoryResponse {
        let mut messages = self
            .state
            .chats
            .get(&chat_id.0.to_string())
            .map(|state| {
                state
                    .messages
                    .values()
                    .filter(|message| {
                        after_server_seq
                            .map(|last_seq| message.server_seq > last_seq)
                            .unwrap_or(true)
                    })
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if let Some(limit) = limit {
            messages.truncate(limit);
        }
        ChatHistoryResponse { chat_id, messages }
    }

    pub fn projected_cursor(&self, chat_id: ChatId) -> Option<u64> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .map(|state| state.projected_cursor_server_seq)
    }

    pub fn chat_mls_group_id(&self, chat_id: ChatId) -> Option<Vec<u8>> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(|state| state.mls_group_id_b64.as_deref())
            .and_then(|value| decode_b64_field("mls_group_id_b64", value).ok())
    }

    pub fn set_chat_mls_group_id(&mut self, chat_id: ChatId, group_id: &[u8]) -> Result<bool> {
        let entry = self
            .state
            .chats
            .entry(chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                chat_type: ChatType::Dm,
                title: None,
                last_server_seq: 0,
                pending_message_count: 0,
                last_message: None,
                epoch: 0,
                last_commit_message_id: None,
                participant_profiles: Vec::new(),
                members: Vec::new(),
                device_members: Vec::new(),
                mls_group_id_b64: None,
                messages: BTreeMap::new(),
                read_cursor_server_seq: 0,
                projected_cursor_server_seq: 0,
                projected_messages: BTreeMap::new(),
            });
        let group_id_b64 = crate::encode_b64(group_id);
        if entry.mls_group_id_b64.as_deref() == Some(group_id_b64.as_str()) {
            return Ok(false);
        }
        entry.mls_group_id_b64 = Some(group_id_b64);
        self.save_state()?;
        Ok(true)
    }

    pub fn load_or_bootstrap_chat_mls_conversation(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
    ) -> Result<Option<MlsConversation>> {
        if let Some(group_id) = self.chat_mls_group_id(chat_id) {
            return facade.load_group(&group_id).map_err(|err| {
                anyhow!(
                    "failed to load MLS group {} for chat {}: {err}",
                    crate::encode_b64(&group_id),
                    chat_id.0
                )
            });
        }

        let Some(bootstrap) = self.find_welcome_bootstrap(chat_id)? else {
            return Ok(None);
        };

        let conversation = facade
            .join_group_from_welcome(
                &bootstrap.welcome_payload,
                bootstrap.ratchet_tree.as_deref(),
            )
            .with_context(|| {
                format!(
                    "failed to bootstrap MLS conversation for chat {} from welcome {}",
                    chat_id.0, bootstrap.welcome_message_id.0
                )
            })?;
        self.set_chat_mls_group_id(chat_id, &conversation.group_id())?;
        self.apply_projected_messages(chat_id, &bootstrap.synthetic_projections)?;
        Ok(Some(conversation))
    }

    pub fn project_chat_with_facade(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        limit: Option<usize>,
    ) -> Result<LocalProjectionApplyReport> {
        let mut conversation = self
            .load_or_bootstrap_chat_mls_conversation(chat_id, facade)?
            .ok_or_else(|| anyhow!("chat {} has no bootstrappable MLS state", chat_id.0))?;
        self.project_chat_messages(chat_id, facade, &mut conversation, limit)
    }

    pub fn chat_read_cursor(&self, chat_id: ChatId) -> Option<u64> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .map(|state| state.read_cursor_server_seq)
    }

    pub fn chat_unread_count(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Option<u64> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .map(|state| unread_count_for_chat(state, self_account_id))
    }

    pub fn get_chat_read_state(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Option<LocalChatReadState> {
        let state = self.state.chats.get(&chat_id.0.to_string())?;
        Some(local_chat_read_state_from(chat_id, state, self_account_id))
    }

    pub fn list_chat_read_states(
        &self,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Vec<LocalChatReadState> {
        let mut states = self
            .state
            .chats
            .iter()
            .filter_map(|(chat_id, state)| {
                Some(local_chat_read_state_from(
                    parse_chat_id(chat_id).ok()?,
                    state,
                    self_account_id,
                ))
            })
            .collect::<Vec<_>>();
        states.sort_by(|left, right| {
            self.state.chats[&right.chat_id.0.to_string()]
                .last_server_seq
                .cmp(&self.state.chats[&left.chat_id.0.to_string()].last_server_seq)
                .then_with(|| left.chat_id.0.cmp(&right.chat_id.0))
        });
        states
    }

    pub fn mark_chat_read(
        &mut self,
        chat_id: ChatId,
        through_server_seq: Option<u64>,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Result<LocalChatReadState> {
        let state = self
            .state
            .chats
            .get_mut(&chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
        let target = through_server_seq
            .unwrap_or(state.projected_cursor_server_seq)
            .min(state.projected_cursor_server_seq);
        let changed = state.read_cursor_server_seq != target;
        state.read_cursor_server_seq = target;
        let read_state = local_chat_read_state_from(chat_id, state, self_account_id);
        self.persist_if_needed(changed)?;
        Ok(read_state)
    }

    pub fn set_chat_read_cursor(
        &mut self,
        chat_id: ChatId,
        read_cursor_server_seq: Option<u64>,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Result<LocalChatReadState> {
        let state = self
            .state
            .chats
            .get_mut(&chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
        let target = read_cursor_server_seq
            .unwrap_or_default()
            .min(state.projected_cursor_server_seq);
        let changed = state.read_cursor_server_seq != target;
        state.read_cursor_server_seq = target;
        let read_state = local_chat_read_state_from(chat_id, state, self_account_id);
        self.persist_if_needed(changed)?;
        Ok(read_state)
    }

    pub fn get_projected_messages(
        &self,
        chat_id: ChatId,
        after_server_seq: Option<u64>,
        limit: Option<usize>,
    ) -> Vec<LocalProjectedMessage> {
        let mut messages = self
            .state
            .chats
            .get(&chat_id.0.to_string())
            .map(|state| {
                state
                    .projected_messages
                    .values()
                    .filter(|message| {
                        after_server_seq
                            .map(|last_seq| message.server_seq > last_seq)
                            .unwrap_or(true)
                    })
                    .cloned()
                    .map(projected_message_from_persisted)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if let Some(limit) = limit {
            messages.truncate(limit);
        }
        messages
    }

    pub fn get_local_timeline_items(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
        after_server_seq: Option<u64>,
        limit: Option<usize>,
    ) -> Vec<LocalTimelineItem> {
        let mut messages = self
            .state
            .chats
            .get(&chat_id.0.to_string())
            .map(|state| {
                state
                    .projected_messages
                    .values()
                    .filter(|message| {
                        after_server_seq
                            .map(|last_seq| message.server_seq > last_seq)
                            .unwrap_or(true)
                    })
                    .cloned()
                    .map(projected_message_from_persisted)
                    .map(|message| local_timeline_item_from(message, state, self_account_id))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if let Some(limit) = limit {
            messages.truncate(limit);
        }
        messages
    }

    pub fn list_outbox_messages(&self, chat_id: Option<ChatId>) -> Vec<LocalOutboxMessage> {
        let mut messages = self
            .state
            .outbox
            .values()
            .filter(|message| chat_id.map(|value| value == message.chat_id).unwrap_or(true))
            .cloned()
            .collect::<Vec<_>>();
        messages.sort_by(|left, right| {
            left.queued_at_unix
                .cmp(&right.queued_at_unix)
                .then_with(|| left.message_id.0.cmp(&right.message_id.0))
        });
        messages
    }

    pub fn enqueue_outbox_message(
        &mut self,
        chat_id: ChatId,
        sender_account_id: trix_types::AccountId,
        sender_device_id: trix_types::DeviceId,
        message_id: MessageId,
        body: MessageBody,
        queued_at_unix: u64,
    ) -> Result<LocalOutboxMessage> {
        self.ensure_chat_exists(chat_id);
        let queued = LocalOutboxMessage {
            message_id,
            chat_id,
            sender_account_id,
            sender_device_id,
            payload: LocalOutboxPayload::Body { body },
            queued_at_unix,
            status: LocalOutboxStatus::Pending,
            failure_message: None,
        };
        self.state
            .outbox
            .insert(message_id.0.to_string(), queued.clone());
        self.save_state()?;
        Ok(queued)
    }

    pub fn enqueue_outbox_attachment(
        &mut self,
        chat_id: ChatId,
        sender_account_id: trix_types::AccountId,
        sender_device_id: trix_types::DeviceId,
        message_id: MessageId,
        attachment: LocalOutboxAttachmentDraft,
        queued_at_unix: u64,
    ) -> Result<LocalOutboxMessage> {
        self.ensure_chat_exists(chat_id);
        let queued = LocalOutboxMessage {
            message_id,
            chat_id,
            sender_account_id,
            sender_device_id,
            payload: LocalOutboxPayload::AttachmentDraft { attachment },
            queued_at_unix,
            status: LocalOutboxStatus::Pending,
            failure_message: None,
        };
        self.state
            .outbox
            .insert(message_id.0.to_string(), queued.clone());
        self.save_state()?;
        Ok(queued)
    }

    pub fn clear_outbox_failure(&mut self, message_id: MessageId) -> Result<()> {
        let Some(message) = self.state.outbox.get_mut(&message_id.0.to_string()) else {
            return Ok(());
        };
        let changed =
            message.status != LocalOutboxStatus::Pending || message.failure_message.is_some();
        message.status = LocalOutboxStatus::Pending;
        message.failure_message = None;
        self.persist_if_needed(changed)
    }

    pub fn mark_outbox_failure(
        &mut self,
        message_id: MessageId,
        failure_message: impl Into<String>,
    ) -> Result<()> {
        let message = self
            .state
            .outbox
            .get_mut(&message_id.0.to_string())
            .ok_or_else(|| anyhow!("outbox message {} is missing", message_id.0))?;
        let failure_message = failure_message.into();
        let changed = message.status != LocalOutboxStatus::Failed
            || message.failure_message.as_deref() != Some(failure_message.as_str());
        message.status = LocalOutboxStatus::Failed;
        message.failure_message = Some(failure_message);
        self.persist_if_needed(changed)
    }

    pub fn remove_outbox_message(&mut self, message_id: MessageId) -> Result<()> {
        let removed = self.state.outbox.remove(&message_id.0.to_string()).is_some();
        self.persist_if_needed(removed)
    }

    pub fn project_chat_messages(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        conversation: &mut MlsConversation,
        limit: Option<usize>,
    ) -> Result<LocalProjectionApplyReport> {
        let chat = self
            .state
            .chats
            .get_mut(&chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
        let envelopes = chat
            .messages
            .values()
            .filter(|message| {
                message.server_seq > chat.projected_cursor_server_seq
                    && !chat.projected_messages.contains_key(&message.server_seq)
            })
            .take(limit.unwrap_or(usize::MAX))
            .cloned()
            .collect::<Vec<_>>();

        let mut processed_messages = 0usize;
        let mut projected_messages_upserted = 0usize;
        let mut advanced_to_server_seq = None;
        let mut changed = false;

        for envelope in envelopes {
            let projected = project_envelope(facade, conversation, &envelope)?;
            let persisted = persisted_projected_message_from(projected);
            let entry_changed = match chat.projected_messages.get(&envelope.server_seq) {
                Some(existing) => existing != &persisted,
                None => true,
            };
            if entry_changed {
                chat.projected_messages
                    .insert(envelope.server_seq, persisted);
                projected_messages_upserted += 1;
                changed = true;
            }
            processed_messages += 1;
            if advance_projected_cursor(chat) {
                changed = true;
            }
            advanced_to_server_seq = Some(envelope.server_seq);
        }

        self.persist_if_needed(changed)?;
        Ok(LocalProjectionApplyReport {
            chat_id,
            processed_messages,
            projected_messages_upserted,
            advanced_to_server_seq,
        })
    }

    pub fn apply_projected_messages(
        &mut self,
        chat_id: ChatId,
        projected_messages: &[LocalProjectedMessage],
    ) -> Result<LocalProjectionApplyReport> {
        let chat = self
            .state
            .chats
            .get_mut(&chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;

        let mut projected_messages_upserted = 0usize;
        let mut changed = false;

        for projected in projected_messages {
            let persisted = persisted_projected_message_from(projected.clone());
            let entry_changed = match chat.projected_messages.get(&projected.server_seq) {
                Some(existing) => existing != &persisted,
                None => true,
            };
            if entry_changed {
                chat.projected_messages
                    .insert(projected.server_seq, persisted);
                projected_messages_upserted += 1;
                changed = true;
            }
        }

        if advance_projected_cursor(chat) {
            changed = true;
        }

        let advanced_to_server_seq = if chat.projected_cursor_server_seq == 0 {
            None
        } else {
            Some(chat.projected_cursor_server_seq)
        };

        self.persist_if_needed(changed)?;
        Ok(LocalProjectionApplyReport {
            chat_id,
            processed_messages: projected_messages.len(),
            projected_messages_upserted,
            advanced_to_server_seq,
        })
    }

    fn ensure_chat_exists(&mut self, chat_id: ChatId) {
        self.state
            .chats
            .entry(chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                chat_type: ChatType::Dm,
                title: None,
                last_server_seq: 0,
                pending_message_count: 0,
                last_message: None,
                epoch: 0,
                last_commit_message_id: None,
                participant_profiles: Vec::new(),
                members: Vec::new(),
                device_members: Vec::new(),
                mls_group_id_b64: None,
                messages: BTreeMap::new(),
                read_cursor_server_seq: 0,
                projected_cursor_server_seq: 0,
                projected_messages: BTreeMap::new(),
            });
    }

    pub fn apply_chat_list(
        &mut self,
        response: &ChatListResponse,
    ) -> Result<LocalStoreApplyReport> {
        let mut changed_chat_ids = BTreeSet::new();
        let mut chats_upserted = 0usize;

        for chat in &response.chats {
            let entry = self
                .state
                .chats
                .entry(chat.chat_id.0.to_string())
                .or_insert_with(|| PersistedChatState {
                    chat_type: chat.chat_type,
                    title: chat.title.clone(),
                    last_server_seq: 0,
                    epoch: 0,
                    pending_message_count: chat.pending_message_count,
                    last_message: chat.last_message.clone(),
                    last_commit_message_id: None,
                    participant_profiles: chat.participant_profiles.clone(),
                    members: Vec::new(),
                    device_members: Vec::new(),
                    mls_group_id_b64: None,
                    messages: BTreeMap::new(),
                    read_cursor_server_seq: 0,
                    projected_cursor_server_seq: 0,
                    projected_messages: BTreeMap::new(),
                });

            let mut changed = false;
            if entry.chat_type != chat.chat_type {
                entry.chat_type = chat.chat_type;
                changed = true;
            }
            if entry.title != chat.title {
                entry.title = chat.title.clone();
                changed = true;
            }
            if chat.last_server_seq > entry.last_server_seq {
                entry.last_server_seq = chat.last_server_seq;
                changed = true;
            }
            if entry.epoch != chat.epoch {
                entry.epoch = chat.epoch;
                changed = true;
            }
            if entry.pending_message_count != chat.pending_message_count {
                entry.pending_message_count = chat.pending_message_count;
                changed = true;
            }
            if entry.last_message != chat.last_message {
                entry.last_message = chat.last_message.clone();
                changed = true;
            }
            if entry.participant_profiles != chat.participant_profiles {
                entry.participant_profiles = chat.participant_profiles.clone();
                changed = true;
            }

            if changed {
                chats_upserted += 1;
                changed_chat_ids.insert(chat.chat_id.0.to_string());
            }
        }

        self.persist_if_needed(chats_upserted > 0)?;
        Ok(LocalStoreApplyReport {
            chats_upserted,
            messages_upserted: 0,
            changed_chat_ids: changed_chat_ids
                .into_iter()
                .filter_map(|chat_id| parse_chat_id(&chat_id).ok())
                .collect(),
        })
    }

    pub fn apply_chat_detail(
        &mut self,
        detail: &ChatDetailResponse,
    ) -> Result<LocalStoreApplyReport> {
        let entry = self
            .state
            .chats
            .entry(detail.chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                chat_type: detail.chat_type,
                title: detail.title.clone(),
                last_server_seq: detail.last_server_seq,
                pending_message_count: detail.pending_message_count,
                last_message: detail.last_message.clone(),
                epoch: detail.epoch,
                last_commit_message_id: detail.last_commit_message_id,
                participant_profiles: detail.participant_profiles.clone(),
                members: detail.members.clone(),
                device_members: detail.device_members.clone(),
                mls_group_id_b64: None,
                messages: BTreeMap::new(),
                read_cursor_server_seq: 0,
                projected_cursor_server_seq: 0,
                projected_messages: BTreeMap::new(),
            });

        let mut changed = false;
        if entry.chat_type != detail.chat_type {
            entry.chat_type = detail.chat_type;
            changed = true;
        }
        if entry.title != detail.title {
            entry.title = detail.title.clone();
            changed = true;
        }
        if detail.last_server_seq > entry.last_server_seq {
            entry.last_server_seq = detail.last_server_seq;
            changed = true;
        }
        if entry.pending_message_count != detail.pending_message_count {
            entry.pending_message_count = detail.pending_message_count;
            changed = true;
        }
        if entry.epoch != detail.epoch {
            entry.epoch = detail.epoch;
            changed = true;
        }
        if entry.last_commit_message_id != detail.last_commit_message_id {
            entry.last_commit_message_id = detail.last_commit_message_id;
            changed = true;
        }
        if entry.last_message != detail.last_message {
            entry.last_message = detail.last_message.clone();
            changed = true;
        }
        if entry.participant_profiles != detail.participant_profiles {
            entry.participant_profiles = detail.participant_profiles.clone();
            changed = true;
        }
        if entry.members != detail.members {
            entry.members = detail.members.clone();
            changed = true;
        }
        if entry.device_members != detail.device_members {
            entry.device_members = detail.device_members.clone();
            changed = true;
        }

        self.persist_if_needed(changed)?;
        Ok(LocalStoreApplyReport {
            chats_upserted: usize::from(changed),
            messages_upserted: 0,
            changed_chat_ids: if changed {
                vec![detail.chat_id]
            } else {
                Vec::new()
            },
        })
    }

    pub fn apply_chat_history(
        &mut self,
        history: &ChatHistoryResponse,
    ) -> Result<LocalStoreApplyReport> {
        let mut changed_chat_ids = BTreeSet::new();
        let mut messages_upserted = 0usize;
        let chat_id = history.chat_id;
        let entry = self
            .state
            .chats
            .entry(chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                chat_type: ChatType::Dm,
                title: None,
                last_server_seq: 0,
                pending_message_count: 0,
                last_message: None,
                epoch: 0,
                last_commit_message_id: None,
                participant_profiles: Vec::new(),
                members: Vec::new(),
                device_members: Vec::new(),
                mls_group_id_b64: None,
                messages: BTreeMap::new(),
                read_cursor_server_seq: 0,
                projected_cursor_server_seq: 0,
                projected_messages: BTreeMap::new(),
            });

        let mut chat_changed = false;
        for message in &history.messages {
            if message.chat_id != chat_id {
                return Err(anyhow!(
                    "message {} belongs to chat {}, not {}",
                    message.message_id.0,
                    message.chat_id.0,
                    chat_id.0
                ));
            }
            let entry_changed = match entry.messages.get(&message.server_seq) {
                Some(existing) => existing != message,
                None => true,
            };
            if entry_changed {
                entry.messages.insert(message.server_seq, message.clone());
                messages_upserted += 1;
                chat_changed = true;
            }
            if message.server_seq > entry.last_server_seq {
                entry.last_server_seq = message.server_seq;
                chat_changed = true;
            }
            if entry
                .last_message
                .as_ref()
                .map(|last_message| message.server_seq >= last_message.server_seq)
                .unwrap_or(true)
                && entry.last_message.as_ref() != Some(message)
            {
                entry.last_message = Some(message.clone());
                chat_changed = true;
            }
            if message.epoch > entry.epoch {
                entry.epoch = message.epoch;
                chat_changed = true;
            }
            if matches!(message.message_kind, trix_types::MessageKind::Commit)
                && entry.last_commit_message_id != Some(message.message_id)
            {
                entry.last_commit_message_id = Some(message.message_id);
                chat_changed = true;
            }
        }

        if chat_changed {
            changed_chat_ids.insert(chat_id.0.to_string());
        }
        self.persist_if_needed(chat_changed)?;
        Ok(LocalStoreApplyReport {
            chats_upserted: usize::from(chat_changed),
            messages_upserted,
            changed_chat_ids: changed_chat_ids
                .into_iter()
                .filter_map(|chat_id| parse_chat_id(&chat_id).ok())
                .collect(),
        })
    }

    pub fn apply_inbox_items(&mut self, items: &[InboxItem]) -> Result<LocalStoreApplyReport> {
        let mut combined = LocalStoreApplyReport {
            chats_upserted: 0,
            messages_upserted: 0,
            changed_chat_ids: Vec::new(),
        };
        let mut changed_chat_ids = BTreeSet::new();

        for item in items {
            let report = self.apply_chat_history(&ChatHistoryResponse {
                chat_id: item.message.chat_id,
                messages: vec![item.message.clone()],
            })?;
            combined.chats_upserted += report.chats_upserted;
            combined.messages_upserted += report.messages_upserted;
            changed_chat_ids.extend(
                report
                    .changed_chat_ids
                    .into_iter()
                    .map(|chat_id| chat_id.0.to_string()),
            );
        }

        combined.changed_chat_ids = changed_chat_ids
            .into_iter()
            .filter_map(|chat_id| parse_chat_id(&chat_id).ok())
            .collect();
        Ok(combined)
    }

    pub fn apply_outgoing_message(
        &mut self,
        envelope: &MessageEnvelope,
        body: &MessageBody,
    ) -> Result<LocalOutgoingMessageApplyOutcome> {
        let chat_id = envelope.chat_id;
        let mut report = self.apply_chat_history(&ChatHistoryResponse {
            chat_id,
            messages: vec![envelope.clone()],
        })?;

        let projected_message = LocalProjectedMessage {
            server_seq: envelope.server_seq,
            message_id: envelope.message_id,
            sender_account_id: envelope.sender_account_id,
            sender_device_id: envelope.sender_device_id,
            epoch: envelope.epoch,
            message_kind: envelope.message_kind,
            content_type: envelope.content_type,
            projection_kind: LocalProjectionKind::ApplicationMessage,
            payload: Some(body.to_bytes()?),
            merged_epoch: None,
            created_at_unix: envelope.created_at_unix,
        };
        let projection_report =
            self.apply_projected_messages(chat_id, &[projected_message.clone()])?;
        if projection_report.projected_messages_upserted > 0
            && !report.changed_chat_ids.contains(&chat_id)
        {
            report.changed_chat_ids.push(chat_id);
        }

        Ok(LocalOutgoingMessageApplyOutcome {
            report,
            projected_message,
        })
    }

    pub fn apply_local_projection(
        &mut self,
        envelope: &MessageEnvelope,
        projection_kind: LocalProjectionKind,
        payload: Option<Vec<u8>>,
        merged_epoch: Option<u64>,
    ) -> Result<LocalStoreApplyReport> {
        let mut report = self.apply_chat_history(&ChatHistoryResponse {
            chat_id: envelope.chat_id,
            messages: vec![envelope.clone()],
        })?;

        let chat = self
            .state
            .chats
            .get_mut(&envelope.chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", envelope.chat_id.0))?;
        let projected = persisted_projected_message_from(LocalProjectedMessage {
            server_seq: envelope.server_seq,
            message_id: envelope.message_id,
            sender_account_id: envelope.sender_account_id,
            sender_device_id: envelope.sender_device_id,
            epoch: envelope.epoch,
            message_kind: envelope.message_kind,
            content_type: envelope.content_type,
            projection_kind,
            payload,
            merged_epoch,
            created_at_unix: envelope.created_at_unix,
        });

        let mut changed = false;
        let entry_changed = match chat.projected_messages.get(&envelope.server_seq) {
            Some(existing) => existing != &projected,
            None => true,
        };
        if entry_changed {
            chat.projected_messages.insert(envelope.server_seq, projected);
            changed = true;
        }
        if envelope.server_seq > chat.projected_cursor_server_seq {
            chat.projected_cursor_server_seq = envelope.server_seq;
            changed = true;
        }

        self.persist_if_needed(changed)?;
        if changed && !report.changed_chat_ids.contains(&envelope.chat_id) {
            report.changed_chat_ids.push(envelope.chat_id);
        }
        Ok(report)
    }

    fn persist_if_needed(&self, changed: bool) -> Result<()> {
        if changed {
            self.save_state()?;
        }
        Ok(())
    }

    fn find_welcome_bootstrap(&self, chat_id: ChatId) -> Result<Option<WelcomeBootstrapMaterial>> {
        let Some(chat) = self.state.chats.get(&chat_id.0.to_string()) else {
            return Ok(None);
        };

        let Some(welcome) =
            chat.messages.values().rev().find(|message| {
                matches!(message.message_kind, trix_types::MessageKind::WelcomeRef)
            })
        else {
            return Ok(None);
        };

        let welcome_payload =
            decode_b64_field("ciphertext_b64", &welcome.ciphertext_b64).map_err(|err| {
                anyhow!(
                    "failed to decode welcome payload {}: {err}",
                    welcome.message_id.0
                )
            })?;
        let ratchet_tree = control_message_ratchet_tree(&welcome.aad_json).map_err(|err| {
            anyhow!(
                "failed to decode welcome ratchet tree {}: {err}",
                welcome.message_id.0
            )
        })?;

        let synthetic_projections = chat
            .messages
            .values()
            .filter(|message| {
                message.server_seq <= welcome.server_seq
                    && matches!(
                        message.message_kind,
                        trix_types::MessageKind::Commit | trix_types::MessageKind::WelcomeRef
                    )
            })
            .map(synthetic_control_projection_from)
            .collect::<Result<Vec<_>>>()?;

        Ok(Some(WelcomeBootstrapMaterial {
            welcome_message_id: welcome.message_id,
            welcome_payload,
            ratchet_tree,
            synthetic_projections,
        }))
    }
}

impl LocalProjectedMessage {
    pub fn parse_body(&self) -> Result<Option<MessageBody>> {
        let Some(payload) = &self.payload else {
            return Ok(None);
        };
        if self.projection_kind != LocalProjectionKind::ApplicationMessage {
            return Ok(None);
        }
        Ok(Some(MessageBody::from_bytes(self.content_type, payload)?))
    }
}

fn project_envelope(
    facade: &MlsFacade,
    conversation: &mut MlsConversation,
    envelope: &MessageEnvelope,
) -> Result<LocalProjectedMessage> {
    let payload = decode_b64_field("ciphertext_b64", &envelope.ciphertext_b64).map_err(|err| {
        anyhow!(
            "failed to decode ciphertext for {}: {err}",
            envelope.message_id.0
        )
    })?;

    let (projection_kind, projected_payload, merged_epoch) = match envelope.message_kind {
        trix_types::MessageKind::Application | trix_types::MessageKind::Commit => {
            match facade.process_message(conversation, &payload)? {
                MlsProcessResult::ApplicationMessage(plaintext) => (
                    LocalProjectionKind::ApplicationMessage,
                    Some(plaintext),
                    None,
                ),
                MlsProcessResult::ProposalQueued => {
                    (LocalProjectionKind::ProposalQueued, None, None)
                }
                MlsProcessResult::CommitMerged { epoch } => {
                    (LocalProjectionKind::CommitMerged, None, Some(epoch))
                }
            }
        }
        trix_types::MessageKind::WelcomeRef => {
            (LocalProjectionKind::WelcomeRef, Some(payload), None)
        }
        trix_types::MessageKind::System => (LocalProjectionKind::System, Some(payload), None),
    };

    Ok(LocalProjectedMessage {
        server_seq: envelope.server_seq,
        message_id: envelope.message_id,
        sender_account_id: envelope.sender_account_id,
        sender_device_id: envelope.sender_device_id,
        epoch: envelope.epoch,
        message_kind: envelope.message_kind,
        content_type: envelope.content_type,
        projection_kind,
        payload: projected_payload,
        merged_epoch,
        created_at_unix: envelope.created_at_unix,
    })
}

fn projected_message_from_persisted(value: PersistedProjectedMessage) -> LocalProjectedMessage {
    LocalProjectedMessage {
        server_seq: value.server_seq,
        message_id: value.message_id,
        sender_account_id: value.sender_account_id,
        sender_device_id: value.sender_device_id,
        epoch: value.epoch,
        message_kind: value.message_kind,
        content_type: value.content_type,
        projection_kind: value.projection_kind,
        payload: value
            .payload_b64
            .and_then(|payload_b64| decode_b64_field("payload_b64", &payload_b64).ok()),
        merged_epoch: value.merged_epoch,
        created_at_unix: value.created_at_unix,
    }
}

#[derive(Debug)]
struct WelcomeBootstrapMaterial {
    welcome_message_id: MessageId,
    welcome_payload: Vec<u8>,
    ratchet_tree: Option<Vec<u8>>,
    synthetic_projections: Vec<LocalProjectedMessage>,
}

fn synthetic_control_projection_from(envelope: &MessageEnvelope) -> Result<LocalProjectedMessage> {
    let (projection_kind, payload, merged_epoch) = match envelope.message_kind {
        trix_types::MessageKind::Commit => (
            LocalProjectionKind::CommitMerged,
            None,
            Some(envelope.epoch),
        ),
        trix_types::MessageKind::WelcomeRef => (
            LocalProjectionKind::WelcomeRef,
            Some(
                decode_b64_field("ciphertext_b64", &envelope.ciphertext_b64).map_err(|err| {
                    anyhow!(
                        "failed to decode control payload for {}: {err}",
                        envelope.message_id.0
                    )
                })?,
            ),
            None,
        ),
        _ => {
            return Err(anyhow!(
                "message {} is not a synthetic control message",
                envelope.message_id.0
            ));
        }
    };

    Ok(LocalProjectedMessage {
        server_seq: envelope.server_seq,
        message_id: envelope.message_id,
        sender_account_id: envelope.sender_account_id,
        sender_device_id: envelope.sender_device_id,
        epoch: envelope.epoch,
        message_kind: envelope.message_kind,
        content_type: envelope.content_type,
        projection_kind,
        payload,
        merged_epoch,
        created_at_unix: envelope.created_at_unix,
    })
}

fn persisted_projected_message_from(value: LocalProjectedMessage) -> PersistedProjectedMessage {
    PersistedProjectedMessage {
        server_seq: value.server_seq,
        message_id: value.message_id,
        sender_account_id: value.sender_account_id,
        sender_device_id: value.sender_device_id,
        epoch: value.epoch,
        message_kind: value.message_kind,
        content_type: value.content_type,
        projection_kind: value.projection_kind,
        payload_b64: value.payload.map(|payload| crate::encode_b64(&payload)),
        merged_epoch: value.merged_epoch,
        created_at_unix: value.created_at_unix,
    }
}

fn advance_projected_cursor(chat: &mut PersistedChatState) -> bool {
    let mut next_cursor = chat.projected_cursor_server_seq;
    while chat.projected_messages.contains_key(&(next_cursor + 1)) {
        next_cursor += 1;
    }
    if next_cursor == chat.projected_cursor_server_seq {
        return false;
    }
    chat.projected_cursor_server_seq = next_cursor;
    true
}

fn local_chat_read_state_from(
    chat_id: ChatId,
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> LocalChatReadState {
    LocalChatReadState {
        chat_id,
        read_cursor_server_seq: state.read_cursor_server_seq,
        unread_count: unread_count_for_chat(state, self_account_id),
    }
}

fn local_chat_list_item_from(
    chat_id: ChatId,
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> LocalChatListItem {
    let preview = latest_preview_from_chat(state, self_account_id);
    LocalChatListItem {
        chat_id,
        chat_type: state.chat_type,
        title: state.title.clone(),
        display_title: chat_display_title(state, self_account_id),
        last_server_seq: state.last_server_seq,
        epoch: state.epoch,
        pending_message_count: state.pending_message_count,
        unread_count: unread_count_for_chat(state, self_account_id),
        preview_text: preview.as_ref().map(|preview| preview.preview_text.clone()),
        preview_sender_account_id: preview.as_ref().map(|preview| preview.sender_account_id),
        preview_sender_display_name: preview
            .as_ref()
            .map(|preview| preview.sender_display_name.clone()),
        preview_is_outgoing: preview.as_ref().map(|preview| preview.is_outgoing),
        preview_server_seq: preview.as_ref().map(|preview| preview.server_seq),
        preview_created_at_unix: preview.as_ref().map(|preview| preview.created_at_unix),
        participant_profiles: state.participant_profiles.clone(),
    }
}

fn local_timeline_item_from(
    message: LocalProjectedMessage,
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> LocalTimelineItem {
    let sender_display_name =
        resolve_account_display_name(&state.participant_profiles, message.sender_account_id);
    let is_outgoing = self_account_id
        .map(|account_id| account_id == message.sender_account_id)
        .unwrap_or(false);
    let (body, body_parse_error) = match message.parse_body() {
        Ok(body) => (body, None),
        Err(err) => (None, Some(err.to_string())),
    };
    let preview_text =
        preview_text_for_projected_message(&message, body.as_ref(), body_parse_error.as_deref());
    LocalTimelineItem {
        server_seq: message.server_seq,
        message_id: message.message_id,
        sender_account_id: message.sender_account_id,
        sender_device_id: message.sender_device_id,
        sender_display_name,
        is_outgoing,
        epoch: message.epoch,
        message_kind: message.message_kind,
        content_type: message.content_type,
        projection_kind: message.projection_kind,
        body,
        body_parse_error,
        preview_text,
        merged_epoch: message.merged_epoch,
        created_at_unix: message.created_at_unix,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LocalChatPreview {
    preview_text: String,
    sender_account_id: trix_types::AccountId,
    sender_display_name: String,
    is_outgoing: bool,
    server_seq: u64,
    created_at_unix: u64,
}

fn latest_preview_from_chat(
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> Option<LocalChatPreview> {
    let projected = state
        .projected_messages
        .iter()
        .next_back()
        .map(|(_, message)| message);
    let raw = state.last_message.as_ref();

    match (projected, raw) {
        (Some(projected), Some(raw)) if raw.server_seq > projected.server_seq => {
            Some(preview_from_envelope(raw, state, self_account_id))
        }
        (Some(projected), _) => Some(preview_from_projected_message(
            projected,
            state,
            self_account_id,
        )),
        (None, Some(raw)) => Some(preview_from_envelope(raw, state, self_account_id)),
        (None, None) => None,
    }
}

fn preview_from_projected_message(
    projected: &PersistedProjectedMessage,
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> LocalChatPreview {
    let sender_display_name =
        resolve_account_display_name(&state.participant_profiles, projected.sender_account_id);
    let is_outgoing = self_account_id
        .map(|account_id| account_id == projected.sender_account_id)
        .unwrap_or(false);
    let message = projected_message_from_persisted(projected.clone());
    let (body, body_parse_error) = match message.parse_body() {
        Ok(body) => (body, None),
        Err(err) => (None, Some(err.to_string())),
    };
    LocalChatPreview {
        preview_text: preview_text_for_projected_message(
            &message,
            body.as_ref(),
            body_parse_error.as_deref(),
        ),
        sender_account_id: projected.sender_account_id,
        sender_display_name,
        is_outgoing,
        server_seq: projected.server_seq,
        created_at_unix: projected.created_at_unix,
    }
}

fn preview_from_envelope(
    envelope: &MessageEnvelope,
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> LocalChatPreview {
    let sender_display_name =
        resolve_account_display_name(&state.participant_profiles, envelope.sender_account_id);
    let is_outgoing = self_account_id
        .map(|account_id| account_id == envelope.sender_account_id)
        .unwrap_or(false);
    LocalChatPreview {
        preview_text: fallback_preview_for_envelope(envelope),
        sender_account_id: envelope.sender_account_id,
        sender_display_name,
        is_outgoing,
        server_seq: envelope.server_seq,
        created_at_unix: envelope.created_at_unix,
    }
}

fn chat_display_title(
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> String {
    if let Some(title) = state
        .title
        .as_ref()
        .map(|title| title.trim())
        .filter(|title| !title.is_empty())
    {
        return title.to_owned();
    }

    match state.chat_type {
        ChatType::AccountSync => "My Devices".to_owned(),
        ChatType::Dm => state
            .participant_profiles
            .iter()
            .find(|profile| Some(profile.account_id) != self_account_id)
            .or_else(|| state.participant_profiles.first())
            .map(profile_display_name)
            .unwrap_or_else(|| "Direct Message".to_owned()),
        ChatType::Group => {
            let names = state
                .participant_profiles
                .iter()
                .filter(|profile| Some(profile.account_id) != self_account_id)
                .map(profile_display_name)
                .take(3)
                .collect::<Vec<_>>();
            if names.is_empty() {
                "Group Chat".to_owned()
            } else {
                names.join(", ")
            }
        }
    }
}

fn resolve_account_display_name(
    participant_profiles: &[ChatParticipantProfileSummary],
    account_id: trix_types::AccountId,
) -> String {
    participant_profiles
        .iter()
        .find(|profile| profile.account_id == account_id)
        .map(profile_display_name)
        .unwrap_or_else(|| account_id.0.to_string())
}

fn profile_display_name(profile: &ChatParticipantProfileSummary) -> String {
    let profile_name = profile.profile_name.trim();
    if !profile_name.is_empty() {
        return profile_name.to_owned();
    }
    profile
        .handle
        .as_deref()
        .map(str::trim)
        .filter(|handle| !handle.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| profile.account_id.0.to_string())
}

fn preview_text_for_projected_message(
    message: &LocalProjectedMessage,
    body: Option<&MessageBody>,
    body_parse_error: Option<&str>,
) -> String {
    match message.projection_kind {
        LocalProjectionKind::ApplicationMessage => {
            if let Some(body) = body {
                return preview_text_for_body(body);
            }
            fallback_preview_for_content_type(message.content_type, body_parse_error.is_some())
        }
        LocalProjectionKind::ProposalQueued => "Pending update".to_owned(),
        LocalProjectionKind::CommitMerged => "Updated chat".to_owned(),
        LocalProjectionKind::WelcomeRef => "Invited device".to_owned(),
        LocalProjectionKind::System => "System message".to_owned(),
    }
}

fn preview_text_for_body(body: &MessageBody) -> String {
    match body {
        MessageBody::Text(body) => {
            let text = body.text.trim();
            if text.is_empty() {
                "Text message".to_owned()
            } else {
                text.to_owned()
            }
        }
        MessageBody::Reaction(body) => format!("Reaction {}", body.emoji),
        MessageBody::Receipt(_) => "Receipt".to_owned(),
        MessageBody::Attachment(body) => {
            if body.mime_type.starts_with("image/") {
                body.file_name.clone().unwrap_or_else(|| "Photo".to_owned())
            } else {
                body.file_name
                    .clone()
                    .unwrap_or_else(|| "Attachment".to_owned())
            }
        }
        MessageBody::ChatEvent(body) => body.event_type.replace('_', " "),
    }
}

fn fallback_preview_for_envelope(message: &MessageEnvelope) -> String {
    match message.message_kind {
        trix_types::MessageKind::Application => {
            fallback_preview_for_content_type(message.content_type, false)
        }
        trix_types::MessageKind::Commit => "Updated chat".to_owned(),
        trix_types::MessageKind::WelcomeRef => "Invited device".to_owned(),
        trix_types::MessageKind::System => "System message".to_owned(),
    }
}

fn fallback_preview_for_content_type(
    content_type: trix_types::ContentType,
    had_parse_error: bool,
) -> String {
    let base = match content_type {
        trix_types::ContentType::Text => "Text message",
        trix_types::ContentType::Reaction => "Reaction",
        trix_types::ContentType::Receipt => "Receipt",
        trix_types::ContentType::Attachment => "Attachment",
        trix_types::ContentType::ChatEvent => "Chat event",
    };
    if had_parse_error {
        format!("Unreadable {base}")
    } else {
        base.to_owned()
    }
}

fn unread_count_for_chat(
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> u64 {
    state
        .projected_messages
        .values()
        .filter(|message| message.server_seq > state.read_cursor_server_seq)
        .filter(|message| projected_message_counts_as_unread(message, self_account_id))
        .count() as u64
}

fn projected_message_counts_as_unread(
    message: &PersistedProjectedMessage,
    self_account_id: Option<trix_types::AccountId>,
) -> bool {
    if message.projection_kind != LocalProjectionKind::ApplicationMessage {
        return false;
    }
    if matches!(message.content_type, trix_types::ContentType::Receipt) {
        return false;
    }
    if let Some(self_account_id) = self_account_id {
        if message.sender_account_id == self_account_id {
            return false;
        }
    }
    true
}

const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";

fn save_state_to_path(
    path: &Path,
    database_key: Option<&[u8]>,
    state: &PersistedLocalHistoryState,
) -> Result<()> {
    let mut connection = open_history_sqlite(path, database_key)?;
    let transaction = connection
        .transaction()
        .context("failed to start local history transaction")?;

    transaction.execute_batch(
        r#"
        DELETE FROM local_history_metadata;
        DELETE FROM local_history_chats;
        DELETE FROM local_history_messages;
        DELETE FROM local_history_projected_messages;
        DELETE FROM local_history_outbox;
        "#,
    )?;

    transaction.execute(
        r#"
        INSERT INTO local_history_metadata (key, value)
        VALUES ('version', ?1)
        "#,
        params![state.version.to_string()],
    )?;

    let mut chat_statement = transaction.prepare(
        r#"
        INSERT INTO local_history_chats (
            chat_id,
            chat_type_json,
            title,
            last_server_seq,
            pending_message_count,
            last_message_json,
            epoch,
            last_commit_message_id,
            participant_profiles_json,
            members_json,
            device_members_json,
            mls_group_id_b64,
            read_cursor_server_seq,
            projected_cursor_server_seq
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
        "#,
    )?;
    let mut message_statement = transaction.prepare(
        r#"
        INSERT INTO local_history_messages (chat_id, server_seq, envelope_json)
        VALUES (?1, ?2, ?3)
        "#,
    )?;
    let mut projected_statement = transaction.prepare(
        r#"
        INSERT INTO local_history_projected_messages (chat_id, server_seq, projected_json)
        VALUES (?1, ?2, ?3)
        "#,
    )?;
    let mut outbox_statement = transaction.prepare(
        r#"
        INSERT INTO local_history_outbox (message_id, outbox_json)
        VALUES (?1, ?2)
        "#,
    )?;

    for (chat_id, chat) in &state.chats {
        chat_statement.execute(params![
            chat_id,
            serde_json::to_string(&chat.chat_type)?,
            chat.title,
            u64_to_i64(chat.last_server_seq, "last_server_seq")?,
            u64_to_i64(chat.pending_message_count, "pending_message_count")?,
            chat.last_message
                .as_ref()
                .map(serde_json::to_string)
                .transpose()?,
            u64_to_i64(chat.epoch, "epoch")?,
            chat.last_commit_message_id
                .map(|message_id| message_id.0.to_string()),
            serde_json::to_string(&chat.participant_profiles)?,
            serde_json::to_string(&chat.members)?,
            serde_json::to_string(&chat.device_members)?,
            chat.mls_group_id_b64,
            u64_to_i64(chat.read_cursor_server_seq, "read_cursor_server_seq")?,
            u64_to_i64(
                chat.projected_cursor_server_seq,
                "projected_cursor_server_seq"
            )?,
        ])?;

        for (server_seq, message) in &chat.messages {
            message_statement.execute(params![
                chat_id,
                u64_to_i64(*server_seq, "message server_seq")?,
                serde_json::to_string(message)?,
            ])?;
        }

        for (server_seq, projected_message) in &chat.projected_messages {
            projected_statement.execute(params![
                chat_id,
                u64_to_i64(*server_seq, "projected server_seq")?,
                serde_json::to_string(projected_message)?,
            ])?;
        }
    }

    for (message_id, outbox_message) in &state.outbox {
        outbox_statement.execute(params![message_id, serde_json::to_string(outbox_message)?])?;
    }

    drop(outbox_statement);
    drop(projected_statement);
    drop(message_statement);
    drop(chat_statement);
    transaction
        .commit()
        .context("failed to commit local history transaction")?;
    Ok(())
}

fn load_state_from_path(path: &Path) -> Result<PersistedLocalHistoryState> {
    if !is_sqlite_database(path)? {
        let state = load_legacy_json_state_from_path(path)?;
        save_state_to_path(path, None, &state)?;
        return Ok(state);
    }

    load_state_from_sqlite(path, None)
}

fn load_state_from_encrypted_path(path: &Path, database_key: &[u8]) -> Result<PersistedLocalHistoryState> {
    load_state_from_sqlite(path, Some(database_key))
}

fn load_state_from_sqlite(
    path: &Path,
    database_key: Option<&[u8]>,
) -> Result<PersistedLocalHistoryState> {
    let connection = open_history_sqlite(path, database_key)?;
    let version = connection
        .query_row(
            r#"
            SELECT value
            FROM local_history_metadata
            WHERE key = 'version'
            "#,
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_else(|| "1".to_owned())
        .parse::<u32>()
        .context("failed to parse local history version")?;
    if version != 1 {
        return Err(anyhow!(
            "unsupported local history version {} in {}",
            version,
            path.display()
        ));
    }

    let mut state = PersistedLocalHistoryState {
        version,
        chats: BTreeMap::new(),
        outbox: BTreeMap::new(),
    };

    let mut chats_statement = connection.prepare(
        r#"
        SELECT
            chat_id,
            chat_type_json,
            title,
            last_server_seq,
            pending_message_count,
            last_message_json,
            epoch,
            last_commit_message_id,
            participant_profiles_json,
            members_json,
            device_members_json,
            mls_group_id_b64,
            read_cursor_server_seq,
            projected_cursor_server_seq
        FROM local_history_chats
        ORDER BY chat_id
        "#,
    )?;
    let chat_rows = chats_statement.query_map([], |row| {
        let chat_id: String = row.get(0)?;
        let chat_type_json: String = row.get(1)?;
        let title: Option<String> = row.get(2)?;
        let last_server_seq: i64 = row.get(3)?;
        let pending_message_count: i64 = row.get(4)?;
        let last_message_json: Option<String> = row.get(5)?;
        let epoch: i64 = row.get(6)?;
        let last_commit_message_id: Option<String> = row.get(7)?;
        let participant_profiles_json: String = row.get(8)?;
        let members_json: String = row.get(9)?;
        let device_members_json: String = row.get(10)?;
        let mls_group_id_b64: Option<String> = row.get(11)?;
        let read_cursor_server_seq: i64 = row.get(12)?;
        let projected_cursor_server_seq: i64 = row.get(13)?;

        Ok((
            chat_id,
            PersistedChatState {
                chat_type: serde_json::from_str(&chat_type_json).map_err(sqlite_serde_error)?,
                title,
                last_server_seq: i64_to_u64(last_server_seq, "last_server_seq")
                    .map_err(sqlite_anyhow_error)?,
                pending_message_count: i64_to_u64(pending_message_count, "pending_message_count")
                    .map_err(sqlite_anyhow_error)?,
                last_message: last_message_json
                    .map(|value| serde_json::from_str(&value).map_err(sqlite_serde_error))
                    .transpose()?,
                epoch: i64_to_u64(epoch, "epoch").map_err(sqlite_anyhow_error)?,
                last_commit_message_id: last_commit_message_id
                    .map(|value| parse_message_id_string(&value).map_err(sqlite_anyhow_error))
                    .transpose()?,
                participant_profiles: serde_json::from_str(&participant_profiles_json)
                    .map_err(sqlite_serde_error)?,
                members: serde_json::from_str(&members_json).map_err(sqlite_serde_error)?,
                device_members: serde_json::from_str(&device_members_json)
                    .map_err(sqlite_serde_error)?,
                mls_group_id_b64,
                messages: BTreeMap::new(),
                read_cursor_server_seq: i64_to_u64(
                    read_cursor_server_seq,
                    "read_cursor_server_seq",
                )
                .map_err(sqlite_anyhow_error)?,
                projected_cursor_server_seq: i64_to_u64(
                    projected_cursor_server_seq,
                    "projected_cursor_server_seq",
                )
                .map_err(sqlite_anyhow_error)?,
                projected_messages: BTreeMap::new(),
            },
        ))
    })?;
    for row in chat_rows {
        let (chat_id, chat_state) = row?;
        state.chats.insert(chat_id, chat_state);
    }
    drop(chats_statement);

    let mut messages_statement = connection.prepare(
        r#"
        SELECT chat_id, server_seq, envelope_json
        FROM local_history_messages
        ORDER BY chat_id, server_seq
        "#,
    )?;
    let message_rows = messages_statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    for row in message_rows {
        let (chat_id, server_seq, envelope_json) = row?;
        let chat = state
            .chats
            .get_mut(&chat_id)
            .ok_or_else(|| anyhow!("local history messages contain unknown chat {chat_id}"))?;
        chat.messages.insert(
            i64_to_u64(server_seq, "message server_seq")?,
            serde_json::from_str(&envelope_json).context("failed to parse message envelope")?,
        );
    }
    drop(messages_statement);

    let mut projected_statement = connection.prepare(
        r#"
        SELECT chat_id, server_seq, projected_json
        FROM local_history_projected_messages
        ORDER BY chat_id, server_seq
        "#,
    )?;
    let projected_rows = projected_statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    for row in projected_rows {
        let (chat_id, server_seq, projected_json) = row?;
        let chat = state
            .chats
            .get_mut(&chat_id)
            .ok_or_else(|| anyhow!("local projected messages contain unknown chat {chat_id}"))?;
        chat.projected_messages.insert(
            i64_to_u64(server_seq, "projected server_seq")?,
            serde_json::from_str(&projected_json).context("failed to parse projected message")?,
        );
    }

    let mut outbox_statement = connection.prepare(
        r#"
        SELECT message_id, outbox_json
        FROM local_history_outbox
        ORDER BY message_id
        "#,
    )?;
    let outbox_rows = outbox_statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in outbox_rows {
        let (message_id, outbox_json) = row?;
        state.outbox.insert(
            message_id,
            serde_json::from_str(&outbox_json).context("failed to parse local outbox message")?,
        );
    }

    Ok(state)
}

fn load_legacy_json_state_from_path(path: &Path) -> Result<PersistedLocalHistoryState> {
    let input_file = File::open(path)
        .with_context(|| format!("failed to open local history file {}", path.display()))?;
    let state: PersistedLocalHistoryState =
        serde_json::from_reader(input_file).context("failed to parse local history file")?;
    if state.version != 1 {
        return Err(anyhow!(
            "unsupported local history version {} in {}",
            state.version,
            path.display()
        ));
    }
    Ok(state)
}

fn open_history_sqlite(path: &Path, database_key: Option<&[u8]>) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!(
                "failed to create local history directory {}",
                parent.display()
            )
        })?;
    }
    if database_key.is_none() && path.exists() && !is_sqlite_database(path)? {
        fs::remove_file(path).with_context(|| {
            format!("failed to replace legacy local history {}", path.display())
        })?;
    }

    let connection = Connection::open(path)
        .with_context(|| format!("failed to open local history database {}", path.display()))?;
    if let Some(database_key) = database_key {
        configure_sqlcipher_connection(
            &connection,
            path,
            database_key,
            "local history",
        )?;
    }
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS local_history_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS local_history_chats (
            chat_id TEXT PRIMARY KEY,
            chat_type_json TEXT NOT NULL,
            title TEXT,
            last_server_seq INTEGER NOT NULL,
            pending_message_count INTEGER NOT NULL,
            last_message_json TEXT,
            epoch INTEGER NOT NULL,
            last_commit_message_id TEXT,
            participant_profiles_json TEXT NOT NULL,
            members_json TEXT NOT NULL,
            device_members_json TEXT NOT NULL,
            mls_group_id_b64 TEXT,
            read_cursor_server_seq INTEGER NOT NULL,
            projected_cursor_server_seq INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS local_history_messages (
            chat_id TEXT NOT NULL,
            server_seq INTEGER NOT NULL,
            envelope_json TEXT NOT NULL,
            PRIMARY KEY (chat_id, server_seq)
        );
        CREATE TABLE IF NOT EXISTS local_history_projected_messages (
            chat_id TEXT NOT NULL,
            server_seq INTEGER NOT NULL,
            projected_json TEXT NOT NULL,
            PRIMARY KEY (chat_id, server_seq)
        );
        CREATE TABLE IF NOT EXISTS local_history_outbox (
            message_id TEXT PRIMARY KEY,
            outbox_json TEXT NOT NULL
        );
        "#,
    )?;
    Ok(connection)
}

fn configure_sqlcipher_connection(
    connection: &Connection,
    path: &Path,
    database_key: &[u8],
    label: &str,
) -> Result<()> {
    let encoded_key = encode_hex(database_key);
    connection
        .execute_batch(&format!(
            "PRAGMA key = \"x'{encoded_key}'\"; PRAGMA cipher_compatibility = 4;"
        ))
        .with_context(|| format!("failed to configure SQLCipher for {label} {}", path.display()))?;
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get::<_, i64>(0))
        .map(|_| ())
        .with_context(|| {
            format!(
                "{label} database key rejected or database is corrupted: {}",
                path.display()
            )
        })?;
    Ok(())
}

fn is_sqlite_database(path: &Path) -> Result<bool> {
    if !path.exists() {
        return Ok(false);
    }

    let mut file = File::open(path)
        .with_context(|| format!("failed to inspect local history file {}", path.display()))?;
    let mut header = [0u8; 16];
    let bytes_read = file
        .read(&mut header)
        .with_context(|| format!("failed to read local history file {}", path.display()))?;
    Ok(bytes_read == SQLITE_HEADER.len() && &header == SQLITE_HEADER)
}

fn sqlite_serde_error(err: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
}

fn sqlite_anyhow_error(err: anyhow::Error) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        0,
        rusqlite::types::Type::Text,
        Box::new(std::io::Error::other(err.to_string())),
    )
}

fn encode_hex(input: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(input.len() * 2);
    for byte in input {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn parse_message_id_string(value: &str) -> Result<MessageId> {
    Ok(MessageId(Uuid::parse_str(value).with_context(|| {
        format!("invalid message id `{value}`")
    })?))
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64> {
    i64::try_from(value).with_context(|| format!("{field} exceeds SQLite integer range"))
}

fn i64_to_u64(value: i64, field: &str) -> Result<u64> {
    u64::try_from(value).with_context(|| format!("{field} must not be negative"))
}

fn parse_chat_id(value: &str) -> Result<ChatId> {
    Ok(ChatId(Uuid::parse_str(value).map_err(|err| {
        anyhow!("invalid chat_id in local history: {err}")
    })?))
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, env, fs, path::Path};

    use serde_json::json;
    use trix_types::{AccountId, ContentType, DeviceId, MessageKind};

    use super::*;

    #[test]
    fn local_history_store_persists_and_queries_messages() {
        let database_path = env::temp_dir().join(format!("trix-history-{}.json", Uuid::new_v4()));
        let mut store = LocalHistoryStore::new_persistent(&database_path).unwrap();
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());
        let first_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            chat_id,
            server_seq: 1,
            sender_account_id: account_id,
            sender_device_id: device_id,
            epoch: 1,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: "YQ==".to_owned(),
            aad_json: json!({"k":"v"}),
            created_at_unix: 1,
        };
        let second_message = MessageEnvelope {
            server_seq: 2,
            message_id: MessageId(Uuid::new_v4()),
            created_at_unix: 2,
            ..first_message.clone()
        };

        let summary_report = store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Group,
                    title: Some("chat".to_owned()),
                    last_server_seq: 2,
                    epoch: 2,
                    pending_message_count: 1,
                    last_message: Some(second_message.clone()),
                    participant_profiles: vec![ChatParticipantProfileSummary {
                        account_id: AccountId(Uuid::new_v4()),
                        handle: Some("alice".to_owned()),
                        profile_name: "Alice".to_owned(),
                        profile_bio: Some("bio".to_owned()),
                    }],
                }],
            })
            .unwrap();
        assert_eq!(summary_report.chats_upserted, 1);

        let report = store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![first_message.clone(), second_message.clone()],
            })
            .unwrap();
        assert_eq!(report.messages_upserted, 2);

        let restored = LocalHistoryStore::new_persistent(&database_path).unwrap();
        let chat = restored.get_chat(chat_id).unwrap();
        assert_eq!(chat.chat_type, ChatType::Group);
        assert_eq!(chat.last_server_seq, 2);
        assert_eq!(chat.pending_message_count, 1);
        assert_eq!(chat.participant_profiles.len(), 1);
        assert_eq!(
            chat.participant_profiles[0].handle.as_deref(),
            Some("alice")
        );
        assert_eq!(
            chat.last_message.as_ref().map(|message| message.server_seq),
            Some(2)
        );

        let history = restored.get_chat_history(chat_id, Some(1), Some(10));
        assert_eq!(history.messages, vec![second_message]);

        fs::remove_file(database_path).ok();
    }

    #[test]
    fn encrypted_local_history_store_round_trips_with_same_key() {
        let database_path = env::temp_dir().join(format!("trix-history-encrypted-{}.db", Uuid::new_v4()));
        let database_key = vec![7u8; 32];
        let chat_id = ChatId(Uuid::new_v4());
        let mut store = LocalHistoryStore::new_encrypted(&database_path, database_key.clone()).unwrap();

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Encrypted".to_owned()),
                    last_server_seq: 0,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();

        let restored = LocalHistoryStore::new_encrypted(&database_path, database_key).unwrap();
        assert_eq!(restored.get_chat(chat_id).and_then(|chat| chat.title), Some("Encrypted".to_owned()));

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn encrypted_local_history_store_rejects_wrong_key() {
        let database_path = env::temp_dir().join(format!("trix-history-wrong-key-{}.db", Uuid::new_v4()));
        LocalHistoryStore::new_encrypted(&database_path, vec![1u8; 32]).unwrap();

        let error = LocalHistoryStore::new_encrypted(&database_path, vec![2u8; 32]).unwrap_err();
        assert!(error.to_string().contains("database key rejected") || error.to_string().contains("corrupted"));

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn local_history_store_persists_outbox_messages() {
        let database_path = env::temp_dir().join(format!("trix-history-outbox-{}.db", Uuid::new_v4()));
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());
        let message_id = MessageId(Uuid::new_v4());
        let mut store = LocalHistoryStore::new_encrypted(&database_path, vec![5u8; 32]).unwrap();

        store
            .enqueue_outbox_message(
                chat_id,
                account_id,
                device_id,
                message_id,
                MessageBody::Text(crate::TextMessageBody {
                    text: "queued".to_owned(),
                }),
                42,
            )
            .unwrap();
        store
            .mark_outbox_failure(message_id, "offline")
            .unwrap();

        let restored = LocalHistoryStore::new_encrypted(&database_path, vec![5u8; 32]).unwrap();
        let queued = restored.list_outbox_messages(Some(chat_id));
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].message_id, message_id);
        assert_eq!(queued[0].status, LocalOutboxStatus::Failed);
        assert_eq!(queued[0].failure_message.as_deref(), Some("offline"));

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn local_history_store_migrates_legacy_json_state_to_sqlite() {
        let database_path =
            env::temp_dir().join(format!("trix-history-legacy-{}.json", Uuid::new_v4()));
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());
        let state = PersistedLocalHistoryState {
            version: 1,
            chats: BTreeMap::from([(
                chat_id.0.to_string(),
                PersistedChatState {
                    chat_type: ChatType::Dm,
                    title: Some("Legacy Chat".to_owned()),
                    last_server_seq: 1,
                    pending_message_count: 0,
                    last_message: Some(MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: "YQ==".to_owned(),
                        aad_json: json!({}),
                        created_at_unix: 10,
                    }),
                    epoch: 1,
                    last_commit_message_id: None,
                    participant_profiles: Vec::new(),
                    members: Vec::new(),
                    device_members: Vec::new(),
                    mls_group_id_b64: None,
                    messages: BTreeMap::new(),
                    read_cursor_server_seq: 0,
                    projected_cursor_server_seq: 0,
                    projected_messages: BTreeMap::new(),
                },
            )]),
            outbox: BTreeMap::new(),
        };
        let file = File::create(&database_path).unwrap();
        serde_json::to_writer_pretty(file, &state).unwrap();

        let restored = LocalHistoryStore::new_persistent(&database_path).unwrap();
        assert_eq!(
            restored.get_chat(chat_id).unwrap().title.as_deref(),
            Some("Legacy Chat")
        );
        assert!(is_sqlite_database(&database_path).unwrap());

        fs::remove_file(&database_path).ok();
        let wal_path = PathBuf::from(format!("{}-wal", database_path.display()));
        let shm_path = PathBuf::from(format!("{}-shm", database_path.display()));
        fs::remove_file(wal_path).ok();
        fs::remove_file(shm_path).ok();
    }

    #[test]
    fn local_history_store_projects_application_messages_with_mls() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());

        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let ciphertext = alice
            .create_application_message(&mut alice_group, b"hello from alice")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id: MessageId(Uuid::new_v4()),
                    chat_id,
                    server_seq: 1,
                    sender_account_id: alice_account,
                    sender_device_id: alice_device,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(&ciphertext),
                    aad_json: json!({}),
                    created_at_unix: 10,
                }],
            })
            .unwrap();

        let report = store
            .project_chat_messages(chat_id, &bob, &mut bob_group, None)
            .unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(1));
        assert_eq!(store.projected_cursor(chat_id), Some(1));

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 1);
        assert_eq!(
            projected[0].payload.as_deref(),
            Some(b"hello from alice".as_slice())
        );
        assert_eq!(
            projected[0].projection_kind,
            LocalProjectionKind::ApplicationMessage
        );
    }

    #[test]
    fn synthetic_projections_do_not_skip_unprojected_gaps() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 0,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: "YQ==".to_owned(),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: "Yg==".to_owned(),
                        aad_json: json!({}),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: "Yw==".to_owned(),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();

        let sparse_report = store
            .apply_projected_messages(
                chat_id,
                &[
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        projection_kind: LocalProjectionKind::CommitMerged,
                        payload: None,
                        merged_epoch: Some(1),
                        created_at_unix: 2,
                    },
                    LocalProjectedMessage {
                        server_seq: 3,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        projection_kind: LocalProjectionKind::WelcomeRef,
                        payload: Some(b"welcome".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 3,
                    },
                ],
            )
            .unwrap();
        assert_eq!(sparse_report.projected_messages_upserted, 2);
        assert_eq!(store.projected_cursor(chat_id), Some(0));

        let final_report = store
            .apply_projected_messages(
                chat_id,
                &[LocalProjectedMessage {
                    server_seq: 1,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id: account_id,
                    sender_device_id: device_id,
                    epoch: 0,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    payload: Some(b"hello".to_vec()),
                    merged_epoch: None,
                    created_at_unix: 1,
                }],
            )
            .unwrap();
        assert_eq!(final_report.projected_messages_upserted, 1);
        assert_eq!(store.projected_cursor(chat_id), Some(3));
    }

    #[test]
    fn local_history_store_persists_read_state_and_excludes_own_messages_from_unread() {
        let database_path =
            env::temp_dir().join(format!("trix-history-read-state-{}.json", Uuid::new_v4()));
        let mut store = LocalHistoryStore::new_persistent(&database_path).unwrap();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());

        let first_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            chat_id,
            server_seq: 1,
            sender_account_id: self_account_id,
            sender_device_id: device_id,
            epoch: 1,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: "YQ==".to_owned(),
            aad_json: json!({}),
            created_at_unix: 1,
        };
        let second_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            server_seq: 2,
            sender_account_id: other_account_id,
            created_at_unix: 2,
            ..first_message.clone()
        };
        let third_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            server_seq: 3,
            sender_account_id: other_account_id,
            content_type: ContentType::Receipt,
            created_at_unix: 3,
            ..first_message.clone()
        };

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    first_message.clone(),
                    second_message.clone(),
                    third_message.clone(),
                ],
            })
            .unwrap();
        store
            .apply_projected_messages(
                chat_id,
                &[
                    LocalProjectedMessage {
                        server_seq: 1,
                        message_id: first_message.message_id,
                        sender_account_id: self_account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"self".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 1,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: second_message.message_id,
                        sender_account_id: other_account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"other".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 2,
                    },
                    LocalProjectedMessage {
                        server_seq: 3,
                        message_id: third_message.message_id,
                        sender_account_id: other_account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Receipt,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Receipt(crate::ReceiptMessageBody {
                                target_message_id: second_message.message_id,
                                receipt_type: crate::ReceiptType::Delivered,
                                at_unix: Some(3),
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 3,
                    },
                ],
            )
            .unwrap();

        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_eq!(store.chat_read_cursor(chat_id), Some(0));
        assert_eq!(
            store.chat_unread_count(chat_id, Some(self_account_id)),
            Some(1)
        );
        assert_eq!(store.chat_unread_count(chat_id, None), Some(2));

        let partial = store
            .set_chat_read_cursor(chat_id, Some(1), Some(self_account_id))
            .unwrap();
        assert_eq!(partial.read_cursor_server_seq, 1);
        assert_eq!(partial.unread_count, 1);

        let read_all = store
            .mark_chat_read(chat_id, None, Some(self_account_id))
            .unwrap();
        assert_eq!(read_all.read_cursor_server_seq, 3);
        assert_eq!(read_all.unread_count, 0);

        let restored = LocalHistoryStore::new_persistent(&database_path).unwrap();
        assert_eq!(restored.chat_read_cursor(chat_id), Some(3));
        assert_eq!(
            restored.get_chat_read_state(chat_id, Some(self_account_id)),
            Some(LocalChatReadState {
                chat_id,
                read_cursor_server_seq: 3,
                unread_count: 0,
            })
        );

        fs::remove_file(database_path).ok();
    }

    #[test]
    fn local_chat_list_items_merge_display_title_preview_and_unread() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let other_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: None,
                    last_server_seq: 2,
                    epoch: 1,
                    pending_message_count: 1,
                    last_message: None,
                    participant_profiles: vec![
                        ChatParticipantProfileSummary {
                            account_id: self_account_id,
                            handle: Some("me".to_owned()),
                            profile_name: "Me".to_owned(),
                            profile_bio: None,
                        },
                        ChatParticipantProfileSummary {
                            account_id: other_account_id,
                            handle: Some("bob".to_owned()),
                            profile_name: "Bob".to_owned(),
                            profile_bio: None,
                        },
                    ],
                }],
            })
            .unwrap();

        store
            .apply_projected_messages(
                chat_id,
                &[
                    LocalProjectedMessage {
                        server_seq: 1,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"hello from bob".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 10,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Attachment,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Attachment(crate::AttachmentMessageBody {
                                blob_id: "blob-1".to_owned(),
                                mime_type: "image/jpeg".to_owned(),
                                size_bytes: 42,
                                sha256: vec![1, 2, 3],
                                file_name: Some("photo.jpg".to_owned()),
                                width_px: Some(320),
                                height_px: Some(240),
                                file_key: vec![4, 5, 6],
                                nonce: vec![7, 8, 9],
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 20,
                    },
                ],
            )
            .unwrap();

        let item = store
            .get_local_chat_list_item(chat_id, Some(self_account_id))
            .unwrap();
        assert_eq!(item.display_title, "Bob");
        assert_eq!(item.unread_count, 1);
        assert_eq!(item.preview_text.as_deref(), Some("photo.jpg"));
        assert_eq!(item.preview_sender_account_id, Some(self_account_id));
        assert_eq!(item.preview_sender_display_name.as_deref(), Some("Me"));
        assert_eq!(item.preview_is_outgoing, Some(true));
        assert_eq!(item.preview_server_seq, Some(2));
    }

    #[test]
    fn local_timeline_items_include_sender_display_name_preview_and_body() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let other_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Group,
                    title: Some("Group".to_owned()),
                    last_server_seq: 1,
                    epoch: 1,
                    pending_message_count: 1,
                    last_message: None,
                    participant_profiles: vec![
                        ChatParticipantProfileSummary {
                            account_id: self_account_id,
                            handle: Some("me".to_owned()),
                            profile_name: "Me".to_owned(),
                            profile_bio: None,
                        },
                        ChatParticipantProfileSummary {
                            account_id: other_account_id,
                            handle: Some("alice".to_owned()),
                            profile_name: "Alice".to_owned(),
                            profile_bio: None,
                        },
                    ],
                }],
            })
            .unwrap();

        store
            .apply_projected_messages(
                chat_id,
                &[LocalProjectedMessage {
                    server_seq: 1,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id: other_account_id,
                    sender_device_id: other_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    payload: Some(b"hello team".to_vec()),
                    merged_epoch: None,
                    created_at_unix: 11,
                }],
            )
            .unwrap();

        let timeline = store.get_local_timeline_items(chat_id, Some(self_account_id), None, None);
        assert_eq!(timeline.len(), 1);
        let item = &timeline[0];
        assert_eq!(item.sender_display_name, "Alice");
        assert!(!item.is_outgoing);
        assert_eq!(item.preview_text, "hello team");
        assert_eq!(
            item.body,
            Some(MessageBody::Text(crate::TextMessageBody {
                text: "hello team".to_owned()
            }))
        );
        assert_eq!(item.body_parse_error, None);
    }

    fn cleanup_sqlite_test_path(path: &Path) {
        fs::remove_file(path).ok();
        fs::remove_file(format!("{}-wal", path.display())).ok();
        fs::remove_file(format!("{}-shm", path.display())).ok();
    }
}
