use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use trix_types::{
    AccountId, ChatDetailResponse, ChatDeviceSummary, ChatHistoryResponse, ChatId,
    ChatListResponse, ChatMemberSummary, ChatParticipantProfileSummary, ChatSummary, ChatType,
    ContentType, DeviceId, InboxItem, MessageEnvelope, MessageId, MessageKind,
};
use uuid::Uuid;

use crate::{
    AttachmentMessageBody, MessageBody, MlsConversation, MlsFacade, MlsProcessResult,
    control_message_ratchet_tree, decode_b64_field,
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
    pub history_recovery_pending: bool,
    pub history_recovery_from_server_seq: Option<u64>,
    pub history_recovery_through_server_seq: Option<u64>,
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
    pub receipt_status: Option<crate::ReceiptType>,
    pub reactions: Vec<LocalMessageReactionSummary>,
    pub is_visible_in_timeline: bool,
    pub merged_epoch: Option<u64>,
    pub created_at_unix: u64,
    pub recovery_state: Option<LocalMessageRecoveryState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalMessageRecoveryState {
    PendingSiblingHistory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LocalMessageRepairMailboxStatus {
    PendingWitness,
    WitnessUnavailable,
}

const MESSAGE_REPAIR_WITNESS_PENDING_TTL_SECONDS: u64 = 15 * 60;
const MESSAGE_REPAIR_WITNESS_RETRY_BACKOFF_SECONDS: u64 = 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LocalMessageRepairMailboxEntry {
    pub request_id: String,
    pub message_id: MessageId,
    pub ciphertext_sha256_b64: String,
    pub witness_account_id: trix_types::AccountId,
    pub witness_device_id: trix_types::DeviceId,
    pub unavailable_reason: Option<String>,
    pub status: LocalMessageRepairMailboxStatus,
    pub updated_at_unix: u64,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LocalMessageRepairWitnessCandidate {
    pub binding: trix_types::MessageRepairBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalHistoryRepairReason {
    ProjectedGap,
    UnmaterializedProjection,
    ProjectionFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalHistoryRepairWindow {
    pub from_server_seq: u64,
    pub through_server_seq: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalHistoryRepairCandidate {
    pub chat_id: ChatId,
    pub window: LocalHistoryRepairWindow,
    pub reason: LocalHistoryRepairReason,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalMessageReactionSummary {
    pub emoji: String,
    pub reactor_account_ids: Vec<trix_types::AccountId>,
    pub count: u64,
    pub includes_self: bool,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreparedLocalOutboxSend {
    pub epoch: u64,
    pub ciphertext_b64: String,
    pub aad_json_string: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LocalOutboxPayload {
    Body {
        body: MessageBody,
    },
    AttachmentDraft {
        attachment: LocalOutboxAttachmentDraft,
    },
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
    #[serde(default)]
    pub prepared_send: Option<PreparedLocalOutboxSend>,
}

#[derive(Debug, Clone)]
pub struct LocalHistoryStore {
    state: PersistedLocalHistoryState,
    database_path: Option<PathBuf>,
    database_key: Option<Vec<u8>>,
    #[cfg(test)]
    fail_save_after: std::cell::Cell<Option<usize>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedLocalHistoryState {
    version: u32,
    chats: BTreeMap<String, PersistedChatState>,
    #[serde(default)]
    attachment_refs: BTreeMap<String, PersistedAttachmentRef>,
    #[serde(default)]
    attachment_ref_index: BTreeMap<String, String>,
    #[serde(default)]
    outbox: BTreeMap<String, LocalOutboxMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedChatState {
    #[serde(default = "default_chat_is_active")]
    is_active: bool,
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
    #[serde(default)]
    pending_history_repair_from_server_seq: Option<u64>,
    #[serde(default)]
    pending_history_repair_through_server_seq: Option<u64>,
    #[serde(default)]
    message_repair_mailbox: BTreeMap<u64, PersistedMessageRepairMailboxEntry>,
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
    #[serde(default, alias = "payload_b64")]
    materialized_body_b64: Option<String>,
    #[serde(default)]
    witness_repair: Option<PersistedWitnessRepairProvenance>,
    merged_epoch: Option<u64>,
    created_at_unix: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum PersistedMessageRepairMailboxStatus {
    PendingWitness,
    WitnessUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PersistedMessageRepairMailboxEntry {
    request_id: String,
    message_id: MessageId,
    ciphertext_sha256_b64: String,
    witness_account_id: trix_types::AccountId,
    witness_device_id: trix_types::DeviceId,
    #[serde(default)]
    unavailable_reason: Option<String>,
    status: PersistedMessageRepairMailboxStatus,
    updated_at_unix: u64,
    #[serde(default)]
    expires_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PersistedWitnessRepairProvenance {
    request_id: String,
    witness_account_id: trix_types::AccountId,
    witness_device_id: trix_types::DeviceId,
    ciphertext_sha256_b64: String,
    repaired_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PersistedAttachmentRef {
    body: AttachmentMessageBody,
    created_at_unix: u64,
}

#[derive(Debug, Clone)]
struct ProjectionGapRepairBackup {
    chat_id: ChatId,
    gap_start_server_seq: u64,
    previous_cursor_server_seq: u64,
    removed_projected_messages: BTreeMap<u64, PersistedProjectedMessage>,
}

fn default_chat_is_active() -> bool {
    true
}

impl Default for PersistedLocalHistoryState {
    fn default() -> Self {
        Self {
            version: 1,
            chats: BTreeMap::new(),
            attachment_refs: BTreeMap::new(),
            attachment_ref_index: BTreeMap::new(),
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
            #[cfg(test)]
            fail_save_after: std::cell::Cell::new(None),
        }
    }

    pub fn new_persistent(database_path: impl Into<PathBuf>) -> Result<Self> {
        let database_path = database_path.into();
        if database_path.exists() {
            let mut store = Self {
                state: load_state_from_path(&database_path)?,
                database_path: Some(database_path),
                database_key: None,
                #[cfg(test)]
                fail_save_after: std::cell::Cell::new(None),
            };
            if !deduplicate_direct_chats_in_state(&mut store.state).is_empty() {
                store.save_state()?;
            }
            Ok(store)
        } else {
            let store = Self {
                state: PersistedLocalHistoryState::default(),
                database_path: Some(database_path),
                database_key: None,
                #[cfg(test)]
                fail_save_after: std::cell::Cell::new(None),
            };
            store.save_state()?;
            Ok(store)
        }
    }

    pub fn new_encrypted(database_path: impl Into<PathBuf>, database_key: Vec<u8>) -> Result<Self> {
        let database_path = database_path.into();
        if database_path.exists() {
            let mut store = Self {
                state: load_state_from_encrypted_path(&database_path, &database_key)?,
                database_path: Some(database_path),
                database_key: Some(database_key),
                #[cfg(test)]
                fail_save_after: std::cell::Cell::new(None),
            };
            if !deduplicate_direct_chats_in_state(&mut store.state).is_empty() {
                store.save_state()?;
            }
            Ok(store)
        } else {
            let store = Self {
                state: PersistedLocalHistoryState::default(),
                database_path: Some(database_path),
                database_key: Some(database_key),
                #[cfg(test)]
                fail_save_after: std::cell::Cell::new(None),
            };
            store.save_state()?;
            Ok(store)
        }
    }

    pub fn database_path(&self) -> Option<&Path> {
        self.database_path.as_deref()
    }

    pub fn save_state(&self) -> Result<()> {
        #[cfg(test)]
        if let Some(remaining_successful_saves) = self.fail_save_after.get() {
            if remaining_successful_saves == 0 {
                self.fail_save_after.set(None);
                return Err(anyhow!("injected local history save failure"));
            }
            self.fail_save_after
                .set(Some(remaining_successful_saves.saturating_sub(1)));
        }
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
        chats.sort_by(compare_chat_summaries_by_recent_activity);
        chats
    }

    pub(crate) fn find_active_direct_chat(
        &self,
        first_account_id: trix_types::AccountId,
        second_account_id: trix_types::AccountId,
    ) -> Option<ChatId> {
        let target_pair_key =
            direct_chat_pair_key_for_account_ids(&[first_account_id, second_account_id]);
        self.state
            .chats
            .iter()
            .filter_map(|(chat_id, state)| {
                if !state.is_active {
                    return None;
                }
                let pair_key = direct_chat_pair_key_from_state(state)?;
                if pair_key != target_pair_key {
                    return None;
                }
                Some((chat_id.as_str(), state))
            })
            .max_by(|(left_chat_id, left_state), (right_chat_id, right_state)| {
                compare_direct_chat_state_preference(
                    left_chat_id,
                    left_state,
                    right_chat_id,
                    right_state,
                )
            })
            .and_then(|(chat_id, _)| parse_chat_id(chat_id).ok())
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
                if !state.is_active {
                    return None;
                }
                Some(local_chat_list_item_from(
                    parse_chat_id(chat_id).ok()?,
                    state,
                    self_account_id,
                ))
            })
            .collect::<Vec<_>>();
        chats.sort_by(compare_local_chat_list_items_by_recent_activity);
        chats
    }

    pub fn get_local_chat_list_item(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Option<LocalChatListItem> {
        let state = self.state.chats.get(&chat_id.0.to_string())?;
        if !state.is_active {
            return None;
        }
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

    pub fn attachment_ref(&self, attachment_ref: &str) -> Option<AttachmentMessageBody> {
        self.state
            .attachment_refs
            .get(attachment_ref)
            .map(|value| value.body.clone())
    }

    pub fn attachment_ref_for_fingerprint(&self, fingerprint: &str) -> Option<String> {
        self.state.attachment_ref_index.get(fingerprint).cloned()
    }

    pub fn persist_attachment_ref(
        &mut self,
        attachment_ref: String,
        fingerprint: String,
        body: AttachmentMessageBody,
        created_at_unix: u64,
    ) -> Result<bool> {
        let entry = PersistedAttachmentRef {
            body,
            created_at_unix,
        };
        let ref_changed = match self.state.attachment_refs.get(&attachment_ref) {
            Some(existing) => existing != &entry,
            None => true,
        };
        if ref_changed {
            self.state
                .attachment_refs
                .insert(attachment_ref.clone(), entry);
        }
        let index_changed = self
            .state
            .attachment_ref_index
            .get(&fingerprint)
            .map(|existing| existing != &attachment_ref)
            .unwrap_or(true);
        if index_changed {
            self.state
                .attachment_ref_index
                .insert(fingerprint, attachment_ref);
        }
        let changed = ref_changed || index_changed;
        self.persist_if_needed(changed)?;
        Ok(changed)
    }

    fn restore_chat_snapshot(&mut self, chat_key: &str, previous_chat: Option<PersistedChatState>) {
        match previous_chat {
            Some(chat) => {
                self.state.chats.insert(chat_key.to_owned(), chat);
            }
            None => {
                self.state.chats.remove(chat_key);
            }
        }
    }

    fn rollback_chat_snapshot(
        &mut self,
        chat_key: &str,
        previous_chat: Option<PersistedChatState>,
    ) -> Result<()> {
        self.restore_chat_snapshot(chat_key, previous_chat);
        self.save_state()
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

    pub fn outbox_message(&self, message_id: MessageId) -> Option<LocalOutboxMessage> {
        self.state.outbox.get(&message_id.0.to_string()).cloned()
    }

    pub fn prepared_outbox_send(&self, message_id: MessageId) -> Option<PreparedLocalOutboxSend> {
        self.state
            .outbox
            .get(&message_id.0.to_string())
            .and_then(|message| message.prepared_send.clone())
    }

    pub fn find_matching_outbox_message(
        &self,
        chat_id: ChatId,
        sender_account_id: trix_types::AccountId,
        sender_device_id: trix_types::DeviceId,
        body: &MessageBody,
    ) -> Option<LocalOutboxMessage> {
        self.state
            .outbox
            .values()
            .find(|message| {
                message.chat_id == chat_id
                    && message.sender_account_id == sender_account_id
                    && message.sender_device_id == sender_device_id
                    && matches!(
                        &message.payload,
                        LocalOutboxPayload::Body { body: queued_body } if queued_body == body
                    )
            })
            .cloned()
    }

    pub fn ensure_outbox_message(
        &mut self,
        chat_id: ChatId,
        sender_account_id: trix_types::AccountId,
        sender_device_id: trix_types::DeviceId,
        message_id: MessageId,
        body: MessageBody,
        queued_at_unix: u64,
    ) -> Result<LocalOutboxMessage> {
        self.ensure_chat_exists(chat_id);
        if let Some(existing) = self.state.outbox.get_mut(&message_id.0.to_string()) {
            let existing_matches = existing.chat_id == chat_id
                && existing.sender_account_id == sender_account_id
                && existing.sender_device_id == sender_device_id
                && matches!(
                    &existing.payload,
                    LocalOutboxPayload::Body { body: queued_body } if queued_body == &body
                );
            if !existing_matches {
                return Err(anyhow!(
                    "outbox message {} already exists with different payload",
                    message_id.0
                ));
            }

            let changed =
                existing.status != LocalOutboxStatus::Pending || existing.failure_message.is_some();
            existing.status = LocalOutboxStatus::Pending;
            existing.failure_message = None;
            let queued = existing.clone();
            let _ = existing;
            self.persist_if_needed(changed)?;
            return Ok(queued);
        }

        self.enqueue_outbox_message(
            chat_id,
            sender_account_id,
            sender_device_id,
            message_id,
            body,
            queued_at_unix,
        )
    }

    pub fn prepare_outbox_message_send(
        &mut self,
        message_id: MessageId,
        prepared_send: PreparedLocalOutboxSend,
    ) -> Result<LocalOutboxMessage> {
        let message = self
            .state
            .outbox
            .get_mut(&message_id.0.to_string())
            .ok_or_else(|| anyhow!("outbox message {} is missing", message_id.0))?;
        if let Some(existing) = message.prepared_send.as_ref() {
            if existing != &prepared_send {
                return Err(anyhow!(
                    "outbox message {} already has different prepared send material",
                    message_id.0
                ));
            }
            return Ok(message.clone());
        }

        message.prepared_send = Some(prepared_send);
        let queued = message.clone();
        let _ = message;
        self.save_state()?;
        Ok(queued)
    }

    pub fn set_chat_mls_group_id(&mut self, chat_id: ChatId, group_id: &[u8]) -> Result<bool> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let entry =
            self.state
                .chats
                .entry(chat_key.clone())
                .or_insert_with(|| PersistedChatState {
                    is_active: true,
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
                    pending_history_repair_from_server_seq: None,
                    pending_history_repair_through_server_seq: None,
                    message_repair_mailbox: BTreeMap::new(),
                });
        let group_id_b64 = crate::encode_b64(group_id);
        if entry.mls_group_id_b64.as_deref() == Some(group_id_b64.as_str()) {
            return Ok(false);
        }
        entry.mls_group_id_b64 = Some(group_id_b64);
        if let Err(error) = self.save_state() {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
        Ok(true)
    }

    pub fn load_or_bootstrap_chat_mls_conversation(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
    ) -> Result<Option<MlsConversation>> {
        let bootstraps = self.find_welcome_bootstraps(chat_id)?;
        let mapped_group_id = self.chat_mls_group_id(chat_id);
        let has_explicit_group_mapping = mapped_group_id.is_some();
        let mut candidate_group_ids = mapped_group_id.into_iter().collect::<Vec<_>>();
        let deterministic_group_id = chat_id.0.as_bytes().to_vec();
        if candidate_group_ids
            .iter()
            .all(|group_id| group_id != &deterministic_group_id)
        {
            candidate_group_ids.push(deterministic_group_id);
        }

        for group_id in &candidate_group_ids {
            let probe_facade = facade
                .clone_detached()
                .with_context(|| format!("failed to probe MLS state for chat {}", chat_id.0))?;
            let Some(mut conversation) = probe_facade.load_group(group_id).map_err(|err| {
                anyhow!(
                    "failed to load MLS group {} for chat {}: {err}",
                    crate::encode_b64(group_id),
                    chat_id.0
                )
            })?
            else {
                continue;
            };

            if !self.persisted_group_matches_chat(
                chat_id,
                &probe_facade,
                &mut conversation,
                &bootstraps,
            )? {
                continue;
            }

            let conversation = facade
                .load_group(group_id)
                .map_err(|err| {
                    anyhow!(
                        "failed to load validated MLS group {} for chat {}: {err}",
                        crate::encode_b64(group_id),
                        chat_id.0
                    )
                })?
                .ok_or_else(|| {
                    anyhow!(
                        "validated MLS group {} for chat {} disappeared from active facade",
                        crate::encode_b64(group_id),
                        chat_id.0
                    )
                })?;
            self.set_chat_mls_group_id(chat_id, group_id)?;
            if let Some(bootstrap) = bootstraps.first() {
                self.apply_projected_messages(chat_id, &bootstrap.synthetic_projections)?;
            }
            return Ok(Some(conversation));
        }

        if !has_explicit_group_mapping {
            if let Ok(Some(conversation)) =
                self.bootstrap_chat_from_welcome(chat_id, facade, &bootstraps)
            {
                return Ok(Some(conversation));
            }
        }

        if let Some(group_id) = self.recover_persisted_group_mapping(
            chat_id,
            facade,
            &bootstraps,
            &candidate_group_ids,
        )? {
            if let Some(conversation) = facade.load_group(&group_id).map_err(|err| {
                anyhow!(
                    "failed to load recovered MLS group {} for chat {}: {err}",
                    crate::encode_b64(&group_id),
                    chat_id.0
                )
            })? {
                self.set_chat_mls_group_id(chat_id, &group_id)?;
                if let Some(bootstrap) = bootstraps.first() {
                    self.apply_projected_messages(chat_id, &bootstrap.synthetic_projections)?;
                }
                return Ok(Some(conversation));
            }
        }

        self.bootstrap_chat_from_welcome(chat_id, facade, &bootstraps)
    }

    fn recover_persisted_group_mapping(
        &self,
        chat_id: ChatId,
        facade: &MlsFacade,
        bootstraps: &[WelcomeBootstrapMaterial],
        attempted_group_ids: &[Vec<u8>],
    ) -> Result<Option<Vec<u8>>> {
        let Some(storage_root) = facade.storage_root() else {
            return Ok(None);
        };

        for group_id in persisted_group_ids_from_storage_root(storage_root)? {
            if attempted_group_ids
                .iter()
                .any(|attempted| attempted == &group_id)
            {
                continue;
            }

            let probe_facade = MlsFacade::load_persistent(storage_root.to_path_buf())
                .with_context(|| {
                    format!(
                        "failed to reload MLS facade from {}",
                        storage_root.display()
                    )
                })?;
            let Some(mut conversation) = probe_facade.load_group(&group_id).map_err(|err| {
                anyhow!(
                    "failed to load persisted MLS group {} while recovering chat {}: {err}",
                    crate::encode_b64(&group_id),
                    chat_id.0
                )
            })?
            else {
                continue;
            };

            if self.persisted_group_matches_chat(
                chat_id,
                &probe_facade,
                &mut conversation,
                bootstraps,
            )? {
                return Ok(Some(group_id));
            }
        }

        Ok(None)
    }

    fn persisted_group_matches_chat(
        &self,
        chat_id: ChatId,
        facade: &MlsFacade,
        conversation: &mut MlsConversation,
        bootstraps: &[WelcomeBootstrapMaterial],
    ) -> Result<bool> {
        if let Some(chat) = self.state.chats.get(&chat_id.0.to_string()) {
            if !chat.device_members.is_empty() {
                let expected_credentials = chat
                    .device_members
                    .iter()
                    .map(|member| {
                        decode_b64_field("credential_identity_b64", &member.credential_identity_b64)
                            .map_err(anyhow::Error::from)
                    })
                    .collect::<Result<BTreeSet<_>>>()?;
                let actual_credentials = facade
                    .members(conversation)?
                    .into_iter()
                    .map(|member| member.credential_identity)
                    .collect::<BTreeSet<_>>();
                if expected_credentials != actual_credentials {
                    return Ok(false);
                }
            }
        }

        let mut probe_store = self.clone();
        probe_store.database_path = None;
        probe_store.database_key = None;

        if let Some(bootstrap) = bootstraps.first() {
            probe_store.apply_projected_messages(chat_id, &bootstrap.synthetic_projections)?;
        }

        match probe_store.project_chat_messages(chat_id, facade, conversation, Some(1)) {
            Ok(report) if report.processed_messages > 0 => Ok(true),
            Ok(_) => Ok(!probe_store.chat_has_unprojected_messages(chat_id)),
            Err(_) => Ok(false),
        }
    }

    fn bootstrap_chat_from_welcome(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        bootstraps: &[WelcomeBootstrapMaterial],
    ) -> Result<Option<MlsConversation>> {
        if bootstraps.is_empty() {
            return Ok(None);
        }

        let mut newest_error = None;
        for bootstrap in bootstraps {
            match facade
                .join_group_from_welcome(
                    &bootstrap.welcome_payload,
                    bootstrap.ratchet_tree.as_deref(),
                )
                .with_context(|| {
                    format!(
                        "failed to bootstrap MLS conversation for chat {} from welcome {}",
                        chat_id.0, bootstrap.welcome_message_id.0
                    )
                }) {
                Ok(conversation) => {
                    self.set_chat_mls_group_id(chat_id, &conversation.group_id())?;
                    self.apply_projected_messages(chat_id, &bootstrap.synthetic_projections)?;
                    return Ok(Some(conversation));
                }
                Err(error) => {
                    if newest_error.is_none() {
                        newest_error = Some(error);
                    }
                }
            }
        }

        Err(newest_error.expect("welcome bootstrap candidates should yield an error"))
    }

    fn recover_conversation_after_group_id_mismatch(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        bootstraps: &[WelcomeBootstrapMaterial],
        attempted_group_ids: &[Vec<u8>],
        context_label: &str,
    ) -> Result<Option<MlsConversation>> {
        if let Some(group_id) =
            self.recover_persisted_group_mapping(chat_id, facade, bootstraps, attempted_group_ids)?
        {
            if let Some(conversation) = facade.load_group(&group_id).map_err(|err| {
                anyhow!(
                    "failed to load recovered MLS group {} for chat {} after {}: {err}",
                    crate::encode_b64(&group_id),
                    chat_id.0,
                    context_label
                )
            })? {
                self.set_chat_mls_group_id(chat_id, &group_id)?;
                if let Some(bootstrap) = bootstraps.first() {
                    self.apply_projected_messages(chat_id, &bootstrap.synthetic_projections)?;
                }
                return Ok(Some(conversation));
            }
        }

        self.bootstrap_chat_from_welcome(chat_id, facade, bootstraps)
    }

    fn chat_has_unprojected_messages(&self, chat_id: ChatId) -> bool {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .map(|chat| {
                chat.messages.values().any(|message| {
                    message.server_seq > chat.projected_cursor_server_seq
                        && !chat.projected_messages.contains_key(&message.server_seq)
                })
            })
            .unwrap_or(false)
    }

    fn chat_has_unmaterialized_application_messages(&self, chat_id: ChatId) -> bool {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .map(chat_has_unmaterialized_application_messages)
            .unwrap_or(false)
    }

    pub fn needs_projection(&self, chat_id: ChatId) -> bool {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .map(|chat| {
                first_projection_gap_with_projected_tail(chat).is_some()
                    || first_unmaterialized_application_projection(chat).is_some()
                    || chat.messages.values().any(|message| {
                        message.server_seq > chat.projected_cursor_server_seq
                            && !chat.projected_messages.contains_key(&message.server_seq)
                    })
            })
            .unwrap_or(false)
    }

    pub fn history_repair_candidate(&self, chat_id: ChatId) -> Option<LocalHistoryRepairCandidate> {
        let chat = self.state.chats.get(&chat_id.0.to_string())?;
        projected_gap_after_cursor(chat)
            .filter(|window| !history_repair_window_is_suppressed(chat, *window))
            .map(|window| LocalHistoryRepairCandidate {
                chat_id,
                window,
                reason: LocalHistoryRepairReason::ProjectedGap,
            })
            .or_else(|| {
                unmaterialized_application_window(chat)
                    .filter(|window| !history_repair_window_is_suppressed(chat, *window))
                    .map(|window| LocalHistoryRepairCandidate {
                        chat_id,
                        window,
                        reason: LocalHistoryRepairReason::UnmaterializedProjection,
                    })
            })
    }

    pub fn history_repair_candidate_after_projection_failure(
        &self,
        chat_id: ChatId,
    ) -> Option<LocalHistoryRepairCandidate> {
        self.history_repair_candidate(chat_id).or_else(|| {
            let chat = self.state.chats.get(&chat_id.0.to_string())?;
            unprojected_tail_window(chat)
                .filter(|window| !history_repair_window_is_suppressed(chat, *window))
                .map(|window| LocalHistoryRepairCandidate {
                    chat_id,
                    window,
                    reason: LocalHistoryRepairReason::ProjectionFailure,
                })
        })
    }

    pub(crate) fn message_repair_witness_candidates_in_window(
        &self,
        chat_id: ChatId,
        window: LocalHistoryRepairWindow,
    ) -> Vec<LocalMessageRepairWitnessCandidate> {
        let Some(chat) = self.state.chats.get(&chat_id.0.to_string()) else {
            return Vec::new();
        };
        let now_unix = current_unix_seconds_for_mailbox_retry();
        chat.messages
            .range(window.from_server_seq..=window.through_server_seq)
            .filter_map(|(server_seq, message)| {
                let binding = unresolved_message_repair_binding(chat, *server_seq, message)?;
                let suppressed = chat
                    .message_repair_mailbox
                    .get(server_seq)
                    .is_some_and(|entry| {
                        message_repair_mailbox_entry_suppresses_retry(entry, now_unix)
                    });
                (!suppressed).then_some(LocalMessageRepairWitnessCandidate { binding })
            })
            .collect::<Vec<_>>()
    }

    pub(crate) fn set_message_repair_mailbox_entry(
        &mut self,
        chat_id: ChatId,
        server_seq: u64,
        entry: LocalMessageRepairMailboxEntry,
    ) -> Result<bool> {
        self.ensure_chat_exists(chat_id);
        let Some(chat) = self.state.chats.get_mut(&chat_id.0.to_string()) else {
            return Ok(false);
        };
        let persisted = PersistedMessageRepairMailboxEntry::from(entry);
        let changed = chat
            .message_repair_mailbox
            .get(&server_seq)
            .map(|existing| existing != &persisted)
            .unwrap_or(true);
        if !changed {
            return Ok(false);
        }
        chat.message_repair_mailbox.insert(server_seq, persisted);
        self.save_state()?;
        Ok(true)
    }

    pub(crate) fn materialized_body_for_message_repair(
        &self,
        binding: &trix_types::MessageRepairBinding,
    ) -> Option<Vec<u8>> {
        let chat = self.state.chats.get(&binding.chat_id.0.to_string())?;
        let message = chat.messages.get(&binding.server_seq)?;
        if !binding_matches_message(message, binding).ok()? {
            return None;
        }
        let projected = chat.projected_messages.get(&binding.server_seq)?;
        if projected.projection_kind != LocalProjectionKind::ApplicationMessage {
            return None;
        }
        let payload_b64 = projected.materialized_body_b64.as_ref()?;
        let payload = decode_b64_field("materialized_body_b64", payload_b64).ok()?;
        MessageBody::from_bytes(binding.content_type, &payload).ok()?;
        Some(payload)
    }

    pub(crate) fn apply_message_repair_witness_payload(
        &mut self,
        request_id: &str,
        binding: &trix_types::MessageRepairBinding,
        witness_account_id: trix_types::AccountId,
        witness_device_id: trix_types::DeviceId,
        repaired_body: &[u8],
        repaired_at_unix: u64,
    ) -> Result<bool> {
        MessageBody::from_bytes(binding.content_type, repaired_body).with_context(|| {
            format!(
                "repaired witness payload for message {} is not valid {:?}",
                binding.message_id.0, binding.content_type
            )
        })?;

        let chat_key = binding.chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let result =
            (|| -> Result<bool> {
                let chat = self.state.chats.get_mut(&chat_key).ok_or_else(|| {
                    anyhow!("chat {} is missing from local store", binding.chat_id.0)
                })?;
                let message = chat.messages.get(&binding.server_seq).ok_or_else(|| {
                    anyhow!("message server_seq {} is missing", binding.server_seq)
                })?;
                if !binding_matches_message(message, binding)? {
                    return Err(anyhow!(
                        "message repair binding mismatch for {}",
                        binding.message_id.0
                    ));
                }

                let mut persisted = PersistedProjectedMessage {
                    server_seq: message.server_seq,
                    message_id: message.message_id,
                    sender_account_id: message.sender_account_id,
                    sender_device_id: message.sender_device_id,
                    epoch: message.epoch,
                    message_kind: message.message_kind,
                    content_type: message.content_type,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: Some(crate::encode_b64(repaired_body)),
                    witness_repair: Some(PersistedWitnessRepairProvenance {
                        request_id: request_id.to_owned(),
                        witness_account_id,
                        witness_device_id,
                        ciphertext_sha256_b64: binding.ciphertext_sha256_b64.clone(),
                        repaired_at_unix,
                    }),
                    merged_epoch: None,
                    created_at_unix: message.created_at_unix,
                };
                let changed = match chat.projected_messages.get(&binding.server_seq) {
                    Some(existing) if existing == &persisted => false,
                    Some(existing)
                        if existing
                            .witness_repair
                            .as_ref()
                            .map(|value| value.request_id.as_str())
                            == Some(request_id) =>
                    {
                        persisted.merged_epoch = existing.merged_epoch;
                        false
                    }
                    Some(existing) => {
                        persisted.merged_epoch = existing.merged_epoch;
                        chat.projected_messages
                            .insert(binding.server_seq, persisted);
                        true
                    }
                    None => {
                        chat.projected_messages
                            .insert(binding.server_seq, persisted);
                        true
                    }
                };

                let cursor_advanced = advance_projected_cursor(chat);
                let pending_repair_changed = reconcile_pending_history_repair_in_chat(chat);
                let mailbox_changed = chat
                    .message_repair_mailbox
                    .remove(&binding.server_seq)
                    .is_some();
                let reconciled_mailbox = reconcile_message_repair_mailbox_in_chat(chat);

                Ok(changed
                    || cursor_advanced
                    || pending_repair_changed
                    || mailbox_changed
                    || reconciled_mailbox)
            })();

        match result {
            Ok(changed) => {
                if let Err(error) = self.persist_if_needed(changed) {
                    self.restore_chat_snapshot(&chat_key, previous_chat);
                    return Err(error);
                }
                Ok(changed)
            }
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                Err(error)
            }
        }
    }

    pub fn pending_history_repair_window(
        &self,
        chat_id: ChatId,
    ) -> Option<LocalHistoryRepairWindow> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(pending_history_repair_window_from)
    }

    pub fn set_pending_history_repair_window(
        &mut self,
        chat_id: ChatId,
        window: LocalHistoryRepairWindow,
    ) -> Result<bool> {
        self.ensure_chat_exists(chat_id);
        let Some(chat) = self.state.chats.get_mut(&chat_id.0.to_string()) else {
            return Ok(false);
        };
        let changed = chat.pending_history_repair_from_server_seq != Some(window.from_server_seq)
            || chat.pending_history_repair_through_server_seq != Some(window.through_server_seq);
        if !changed {
            return Ok(false);
        }
        chat.pending_history_repair_from_server_seq = Some(window.from_server_seq);
        chat.pending_history_repair_through_server_seq = Some(window.through_server_seq);
        self.save_state()?;
        Ok(true)
    }

    pub fn clear_pending_history_repair_window(&mut self, chat_id: ChatId) -> Result<bool> {
        let Some(chat) = self.state.chats.get_mut(&chat_id.0.to_string()) else {
            return Ok(false);
        };
        let changed = chat.pending_history_repair_from_server_seq.take().is_some()
            || chat
                .pending_history_repair_through_server_seq
                .take()
                .is_some();
        if !changed {
            return Ok(false);
        }
        self.save_state()?;
        Ok(true)
    }

    pub fn refresh_pending_history_repair_window(
        &mut self,
        chat_id: ChatId,
    ) -> Result<Option<LocalHistoryRepairWindow>> {
        let had_pending = self.pending_history_repair_window(chat_id).is_some();
        if !had_pending {
            return Ok(None);
        }

        if let Some(next_window) = self
            .state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(next_pending_history_repair_window)
        {
            self.set_pending_history_repair_window(chat_id, next_window)?;
            return Ok(Some(next_window));
        }

        self.clear_pending_history_repair_window(chat_id)?;
        Ok(None)
    }
    pub fn chats_with_unavailable_messages(&self) -> Vec<ChatId> {
        self.state
            .chats
            .iter()
            .filter_map(|(key, chat)| {
                let has_unavailable = chat.projected_messages.values().any(|msg| {
                    msg.projection_kind == LocalProjectionKind::ApplicationMessage
                        && msg.materialized_body_b64.is_none()
                        && msg.message_kind == trix_types::MessageKind::Application
                });
                if has_unavailable {
                    uuid::Uuid::parse_str(key).ok().map(ChatId)
                } else {
                    None
                }
            })
            .collect()
    }

    fn prepare_projection_tail_rebuild(
        &mut self,
        chat_id: ChatId,
        start_server_seq: u64,
    ) -> Result<Option<ProjectionGapRepairBackup>> {
        let Some(chat) = self.state.chats.get_mut(&chat_id.0.to_string()) else {
            return Ok(None);
        };

        let removed_projected_messages = chat
            .projected_messages
            .range(start_server_seq..)
            .map(|(server_seq, message)| (*server_seq, message.clone()))
            .collect::<BTreeMap<_, _>>();
        let previous_cursor_server_seq = chat.projected_cursor_server_seq;
        let original_len = chat.projected_messages.len();
        chat.projected_messages
            .retain(|server_seq, _| *server_seq < start_server_seq);
        let removed_entries = chat.projected_messages.len() != original_len;
        let new_cursor = start_server_seq.saturating_sub(1);
        let cursor_changed = chat.projected_cursor_server_seq != new_cursor;
        if cursor_changed {
            chat.projected_cursor_server_seq = new_cursor;
        }

        let changed = removed_entries || cursor_changed;
        self.persist_if_needed(changed)?;
        Ok(Some(ProjectionGapRepairBackup {
            chat_id,
            gap_start_server_seq: start_server_seq,
            previous_cursor_server_seq,
            removed_projected_messages,
        }))
    }

    fn prepare_projection_gap_repair(
        &mut self,
        chat_id: ChatId,
    ) -> Result<Option<ProjectionGapRepairBackup>> {
        let Some(gap_start) = self
            .state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(first_projection_gap_with_projected_tail)
        else {
            return Ok(None);
        };
        self.prepare_projection_tail_rebuild(chat_id, gap_start)
    }

    fn prepare_legacy_materialization_repair(
        &mut self,
        chat_id: ChatId,
    ) -> Result<Option<ProjectionGapRepairBackup>> {
        let Some(server_seq) = self
            .state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(first_unmaterialized_application_projection)
        else {
            return Ok(None);
        };
        self.prepare_projection_tail_rebuild(chat_id, server_seq)
    }

    fn restore_projection_gap_repair(&mut self, backup: ProjectionGapRepairBackup) -> Result<()> {
        let Some(chat) = self.state.chats.get_mut(&backup.chat_id.0.to_string()) else {
            return Ok(());
        };
        chat.projected_messages
            .retain(|server_seq, _| *server_seq < backup.gap_start_server_seq);
        chat.projected_messages
            .extend(backup.removed_projected_messages);
        chat.projected_cursor_server_seq = backup.previous_cursor_server_seq;
        self.save_state()
    }

    fn restore_materialized_projection_tail(
        &mut self,
        backup: &ProjectionGapRepairBackup,
    ) -> Result<()> {
        let Some(chat) = self.state.chats.get_mut(&backup.chat_id.0.to_string()) else {
            return Ok(());
        };

        let mut changed = false;
        for (server_seq, removed) in &backup.removed_projected_messages {
            let Some(removed_body_b64) = removed.materialized_body_b64.as_ref() else {
                continue;
            };
            let Some(current) = chat.projected_messages.get_mut(server_seq) else {
                continue;
            };
            if current.projection_kind != LocalProjectionKind::ApplicationMessage
                || current.message_kind != trix_types::MessageKind::Application
                || current.materialized_body_b64.is_some()
                || current.message_id != removed.message_id
                || current.content_type != removed.content_type
            {
                continue;
            }

            current.materialized_body_b64 = Some(removed_body_b64.clone());
            changed = true;
        }

        self.persist_if_needed(changed)
    }

    pub fn project_chat_with_facade(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        limit: Option<usize>,
    ) -> Result<LocalProjectionApplyReport> {
        self.project_chat_with_facade_for_device(chat_id, facade, limit, None)
    }

    pub(crate) fn project_chat_with_facade_for_device(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        limit: Option<usize>,
        current_device_id: Option<trix_types::DeviceId>,
    ) -> Result<LocalProjectionApplyReport> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let result = (|| {
            let repair_backup = self.prepare_projection_gap_repair(chat_id)?;
            let had_legacy_unmaterialized =
                self.chat_has_unmaterialized_application_messages(chat_id);
            let mut conversation = self
                .load_or_bootstrap_chat_mls_conversation(chat_id, facade)?
                .ok_or_else(|| anyhow!("chat {} has no bootstrappable MLS state", chat_id.0))?;
            let report = match self.project_chat_messages_for_device(
                chat_id,
                facade,
                &mut conversation,
                limit,
                current_device_id.clone(),
            ) {
                Ok(mut report) => {
                    if let Some(backup) = repair_backup.as_ref() {
                        self.restore_materialized_projection_tail(backup)?;
                    }
                    if repair_backup.is_some() && report.processed_messages == 0 {
                        report.advanced_to_server_seq = self.projected_cursor(chat_id);
                    }
                    report
                }
                Err(error) if is_group_id_mismatch_projection_error(&error) => {
                    let mut attempted_group_ids = vec![conversation.group_id()];
                    if let Some(mapped_group_id) = self.chat_mls_group_id(chat_id) {
                        if attempted_group_ids
                            .iter()
                            .all(|candidate| candidate != &mapped_group_id)
                        {
                            attempted_group_ids.push(mapped_group_id);
                        }
                    }
                    let bootstraps = self.find_welcome_bootstraps(chat_id)?;
                    let Some(mut recovered_conversation) = self
                        .recover_conversation_after_group_id_mismatch(
                            chat_id,
                            facade,
                            &bootstraps,
                            &attempted_group_ids,
                            "projection mismatch",
                        )?
                    else {
                        return Err(error);
                    };
                    match self.project_chat_messages_for_device(
                        chat_id,
                        facade,
                        &mut recovered_conversation,
                        limit,
                        current_device_id.clone(),
                    ) {
                        Ok(report) => {
                            if let Some(backup) = repair_backup.as_ref() {
                                self.restore_materialized_projection_tail(backup)?;
                            }
                            report
                        }
                        Err(retry_error) => {
                            if let Some(backup) = repair_backup {
                                self.restore_projection_gap_repair(backup)?;
                            }
                            return Err(retry_error);
                        }
                    }
                }
                Err(error) => {
                    if let Some(backup) = repair_backup {
                        self.restore_projection_gap_repair(backup)?;
                    }
                    return Err(error);
                }
            };

            if had_legacy_unmaterialized
                && self.chat_has_unmaterialized_application_messages(chat_id)
            {
                let _ = self.best_effort_recover_legacy_materialized_messages(
                    chat_id,
                    facade,
                    limit,
                    current_device_id.clone(),
                );
            }

            Ok(report)
        })();

        match result {
            Ok(report) => Ok(report),
            Err(error) => {
                let error_text = error.to_string();
                if let Err(rollback_error) = self.rollback_chat_snapshot(&chat_key, previous_chat) {
                    return Err(rollback_error.context(format!(
                        "failed to rollback chat {} after projection error: {}",
                        chat_id.0, error_text
                    )));
                }
                Err(error)
            }
        }
    }

    fn best_effort_recover_legacy_materialized_messages(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        limit: Option<usize>,
        current_device_id: Option<trix_types::DeviceId>,
    ) -> Result<()> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let result = (|| {
            let Some(backup) = self.prepare_legacy_materialization_repair(chat_id)? else {
                return Ok(());
            };
            let Some(mut conversation) =
                self.load_or_bootstrap_chat_mls_conversation(chat_id, facade)?
            else {
                self.restore_projection_gap_repair(backup)?;
                return Ok(());
            };
            let result = match self.project_chat_messages_for_device(
                chat_id,
                facade,
                &mut conversation,
                limit,
                current_device_id.clone(),
            ) {
                Ok(_) => Ok(()),
                Err(error) if is_group_id_mismatch_projection_error(&error) => {
                    let mut attempted_group_ids = vec![conversation.group_id()];
                    if let Some(mapped_group_id) = self.chat_mls_group_id(chat_id) {
                        if attempted_group_ids
                            .iter()
                            .all(|candidate| candidate != &mapped_group_id)
                        {
                            attempted_group_ids.push(mapped_group_id);
                        }
                    }
                    let bootstraps = self.find_welcome_bootstraps(chat_id)?;
                    let Some(mut recovered_conversation) = self
                        .recover_conversation_after_group_id_mismatch(
                            chat_id,
                            facade,
                            &bootstraps,
                            &attempted_group_ids,
                            "legacy recovery mismatch",
                        )?
                    else {
                        return Err(error);
                    };
                    self.project_chat_messages_for_device(
                        chat_id,
                        facade,
                        &mut recovered_conversation,
                        limit,
                        current_device_id.clone(),
                    )
                    .map(|_| ())
                }
                Err(error) => Err(error),
            };

            if result.is_ok() {
                self.restore_materialized_projection_tail(&backup)?;
            } else {
                self.restore_projection_gap_repair(backup)?;
            }
            Ok(())
        })();

        match result {
            Ok(()) => Ok(()),
            Err(error) => {
                let error_text = error.to_string();
                if let Err(rollback_error) = self.rollback_chat_snapshot(&chat_key, previous_chat) {
                    return Err(rollback_error.context(format!(
                        "failed to rollback chat {} after legacy projection recovery error: {}",
                        chat_id.0, error_text
                    )));
                }
                Err(error)
            }
        }
    }

    pub fn needs_history_refresh(&self, chat_id: ChatId) -> bool {
        let Some(chat) = self.state.chats.get(&chat_id.0.to_string()) else {
            return false;
        };
        chat.projected_cursor_server_seq < chat.last_server_seq
    }

    pub fn align_chat_device_members_with_conversation(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        conversation: &MlsConversation,
    ) -> Result<bool> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let changed = match self.align_chat_device_members_with_conversation_in_memory(
            chat_id,
            facade,
            conversation,
        ) {
            Ok(changed) => changed,
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                return Err(error);
            }
        };
        if let Err(error) = self.persist_if_needed(changed) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
        Ok(changed)
    }

    fn align_chat_device_members_with_conversation_in_memory(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        conversation: &MlsConversation,
    ) -> Result<bool> {
        let chat = self
            .state
            .chats
            .get_mut(&chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
        let leaf_index_by_credential = facade
            .members(conversation)?
            .into_iter()
            .map(|member| (member.credential_identity, member.leaf_index))
            .collect::<BTreeMap<_, _>>();

        let mut changed = false;
        for member in &mut chat.device_members {
            let credential_identity =
                decode_b64_field("credential_identity_b64", &member.credential_identity_b64)?;
            if let Some(&leaf_index) = leaf_index_by_credential.get(&credential_identity) {
                if member.leaf_index != leaf_index {
                    member.leaf_index = leaf_index;
                    changed = true;
                }
            }
        }
        if changed {
            chat.device_members.sort_by(|left, right| {
                left.leaf_index
                    .cmp(&right.leaf_index)
                    .then_with(|| left.device_id.0.cmp(&right.device_id.0))
            });
        }
        Ok(changed)
    }

    pub fn chat_read_cursor(&self, chat_id: ChatId) -> Option<u64> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(|state| state.is_active.then_some(state.read_cursor_server_seq))
    }

    pub fn chat_unread_count(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Option<u64> {
        self.state
            .chats
            .get(&chat_id.0.to_string())
            .and_then(|state| {
                state
                    .is_active
                    .then_some(unread_count_for_chat(state, self_account_id))
            })
    }

    pub fn get_chat_read_state(
        &self,
        chat_id: ChatId,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Option<LocalChatReadState> {
        let state = self.state.chats.get(&chat_id.0.to_string())?;
        if !state.is_active {
            return None;
        }
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
                if !state.is_active {
                    return None;
                }
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
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let state = self
            .state
            .chats
            .get_mut(&chat_key)
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
        let target = through_server_seq
            .unwrap_or(state.projected_cursor_server_seq)
            .min(state.projected_cursor_server_seq);
        let changed = state.read_cursor_server_seq != target;
        state.read_cursor_server_seq = target;
        let read_state = local_chat_read_state_from(chat_id, state, self_account_id);
        if let Err(error) = self.persist_if_needed(changed) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
        Ok(read_state)
    }

    pub fn set_chat_read_cursor(
        &mut self,
        chat_id: ChatId,
        read_cursor_server_seq: Option<u64>,
        self_account_id: Option<trix_types::AccountId>,
    ) -> Result<LocalChatReadState> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let state = self
            .state
            .chats
            .get_mut(&chat_key)
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
        let target = read_cursor_server_seq
            .unwrap_or(state.projected_cursor_server_seq)
            .min(state.projected_cursor_server_seq);
        let changed = state.read_cursor_server_seq != target;
        state.read_cursor_server_seq = target;
        let read_state = local_chat_read_state_from(chat_id, state, self_account_id);
        if let Err(error) = self.persist_if_needed(changed) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
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
                let decorations = local_timeline_decorations(state, self_account_id);
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
                    .map(|message| {
                        local_timeline_item_from(message, state, self_account_id, &decorations)
                    })
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
            .filter(|message| {
                chat_id
                    .map(|value| value == message.chat_id)
                    .unwrap_or(true)
            })
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
            prepared_send: None,
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
            prepared_send: None,
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

    pub fn clear_outbox_prepared_send(&mut self, message_id: MessageId) -> Result<()> {
        let message = self
            .state
            .outbox
            .get_mut(&message_id.0.to_string())
            .ok_or_else(|| anyhow!("outbox message {} is missing", message_id.0))?;
        if message.prepared_send.is_some() {
            message.prepared_send = None;
            self.persist_if_needed(true)
        } else {
            Ok(())
        }
    }

    pub fn remove_outbox_message(&mut self, message_id: MessageId) -> Result<()> {
        let removed = self
            .state
            .outbox
            .remove(&message_id.0.to_string())
            .is_some();
        self.persist_if_needed(removed)
    }

    pub fn project_chat_messages(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        conversation: &mut MlsConversation,
        limit: Option<usize>,
    ) -> Result<LocalProjectionApplyReport> {
        self.project_chat_messages_for_device(chat_id, facade, conversation, limit, None)
    }

    fn project_chat_messages_for_device(
        &mut self,
        chat_id: ChatId,
        facade: &MlsFacade,
        conversation: &mut MlsConversation,
        limit: Option<usize>,
        current_device_id: Option<trix_types::DeviceId>,
    ) -> Result<LocalProjectionApplyReport> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let result = (|| {
            let mut changed = self.align_chat_device_members_with_conversation_in_memory(
                chat_id,
                facade,
                conversation,
            )?;
            let chat = self
                .state
                .chats
                .get_mut(&chat_key)
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
            for envelope in envelopes {
                let projected = project_envelope(facade, conversation, &envelope)?;
                if current_device_replay_would_drop_body(
                    &envelope,
                    &projected,
                    current_device_id.as_ref(),
                ) {
                    return Err(anyhow!(
                        "current device replay for message {} in chat {} would discard its durable body",
                        envelope.message_id.0,
                        chat_id.0
                    ));
                }
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
                    advanced_to_server_seq = Some(chat.projected_cursor_server_seq);
                }
            }
            if reconcile_pending_history_repair_in_chat(chat)
                || reconcile_message_repair_mailbox_in_chat(chat)
            {
                changed = true;
            }

            Ok::<_, anyhow::Error>((
                LocalProjectionApplyReport {
                    chat_id,
                    processed_messages,
                    projected_messages_upserted,
                    advanced_to_server_seq,
                },
                changed,
            ))
        })();

        match result {
            Ok((report, changed)) => {
                if let Err(error) = self.persist_if_needed(changed) {
                    self.restore_chat_snapshot(&chat_key, previous_chat);
                    return Err(error);
                }
                Ok(report)
            }
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                Err(error)
            }
        }
    }

    pub fn apply_projected_messages(
        &mut self,
        chat_id: ChatId,
        projected_messages: &[LocalProjectedMessage],
    ) -> Result<LocalProjectionApplyReport> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let (report, changed) =
            match self.apply_projected_messages_in_memory(chat_id, projected_messages) {
                Ok(result) => result,
                Err(error) => {
                    self.restore_chat_snapshot(&chat_key, previous_chat);
                    return Err(error);
                }
            };
        if let Err(error) = self.persist_if_needed(changed) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
        Ok(report)
    }

    pub(crate) fn apply_projected_messages_in_memory(
        &mut self,
        chat_id: ChatId,
        projected_messages: &[LocalProjectedMessage],
    ) -> Result<(LocalProjectionApplyReport, bool)> {
        self.ensure_chat_exists(chat_id);
        let chat = self
            .state
            .chats
            .get_mut(&chat_id.0.to_string())
            .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;

        let mut projected_messages_upserted = 0usize;
        let mut changed = false;

        for projected in projected_messages {
            ensure_application_message_is_materialized(projected)?;
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

        let cursor_advanced = advance_projected_cursor(chat);
        if cursor_advanced {
            changed = true;
        }

        let pending_repair_changed = reconcile_pending_history_repair_in_chat(chat);
        let mailbox_changed = reconcile_message_repair_mailbox_in_chat(chat);
        if pending_repair_changed || mailbox_changed {
            changed = true;
        }

        let advanced_to_server_seq = cursor_advanced.then_some(chat.projected_cursor_server_seq);

        Ok((
            LocalProjectionApplyReport {
                chat_id,
                processed_messages: projected_messages.len(),
                projected_messages_upserted,
                advanced_to_server_seq,
            },
            changed,
        ))
    }

    pub(crate) fn allocate_synthetic_commit_server_seq(
        &self,
        chat_id: ChatId,
        baseline_last_server_seq: u64,
    ) -> u64 {
        let chat_key = chat_id.0.to_string();
        let Some(chat) = self.state.chats.get(&chat_key) else {
            return baseline_last_server_seq.saturating_add(1).max(1);
        };
        let mut next = baseline_last_server_seq.saturating_add(1).max(1);
        while chat.messages.contains_key(&next) || chat.projected_messages.contains_key(&next) {
            next = next.saturating_add(1);
        }
        next
    }

    /// After server-side leave or DM global delete, this device can no longer fetch chat detail/history.
    /// Records synthetic commit projection, advances the projected cursor, clears MLS mapping, and marks the chat inactive.
    pub(crate) fn finalize_chat_after_terminal_control(
        &mut self,
        chat_id: ChatId,
        actor_account_id: AccountId,
        actor_device_id: DeviceId,
        server_epoch: u64,
        commit_message_id: MessageId,
        mls_merged_epoch: u64,
        commit_server_seq: u64,
    ) -> Result<(LocalStoreApplyReport, LocalProjectedMessage)> {
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        self.ensure_chat_exists(chat_id);
        {
            let chat = self
                .state
                .chats
                .get_mut(&chat_key)
                .ok_or_else(|| anyhow!("chat {} is missing from local store", chat_id.0))?;
            chat.is_active = false;
            chat.epoch = server_epoch;
            chat.last_server_seq = chat.last_server_seq.max(commit_server_seq);
            chat.last_commit_message_id = Some(commit_message_id);
            chat.mls_group_id_b64 = None;
        }
        let created_at_unix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let projected = LocalProjectedMessage {
            server_seq: commit_server_seq,
            message_id: commit_message_id,
            sender_account_id: actor_account_id,
            sender_device_id: actor_device_id,
            epoch: server_epoch,
            message_kind: MessageKind::Commit,
            content_type: ContentType::ChatEvent,
            projection_kind: LocalProjectionKind::CommitMerged,
            payload: None,
            merged_epoch: Some(mls_merged_epoch),
            created_at_unix,
        };
        let (_projection_report, _) =
            match self.apply_projected_messages_in_memory(chat_id, &[projected.clone()]) {
                Ok(result) => result,
                Err(error) => {
                    self.restore_chat_snapshot(&chat_key, previous_chat);
                    return Err(error);
                }
            };
        if let Err(error) = self.persist_if_needed(true) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
        Ok((
            LocalStoreApplyReport {
                chats_upserted: 1,
                messages_upserted: 0,
                changed_chat_ids: vec![chat_id],
            },
            projected,
        ))
    }

    fn ensure_chat_exists(&mut self, chat_id: ChatId) {
        self.state
            .chats
            .entry(chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                is_active: true,
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
                pending_history_repair_from_server_seq: None,
                pending_history_repair_through_server_seq: None,
                message_repair_mailbox: BTreeMap::new(),
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
                    is_active: true,
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
                    pending_history_repair_from_server_seq: None,
                    pending_history_repair_through_server_seq: None,
                    message_repair_mailbox: BTreeMap::new(),
                });

            let mut changed = false;
            if !entry.is_active {
                entry.is_active = true;
                changed = true;
            }
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

        let listed_chat_ids = response
            .chats
            .iter()
            .map(|chat| chat.chat_id.0.to_string())
            .collect::<BTreeSet<_>>();
        for (chat_id, chat_state) in &mut self.state.chats {
            if chat_state.chat_type == ChatType::AccountSync || !chat_state.is_active {
                continue;
            }
            if !listed_chat_ids.contains(chat_id) {
                chat_state.is_active = false;
                chats_upserted += 1;
                changed_chat_ids.insert(chat_id.clone());
            }
        }

        let removed_duplicate_chat_ids = deduplicate_direct_chats_in_state(&mut self.state);
        if !removed_duplicate_chat_ids.is_empty() {
            chats_upserted += removed_duplicate_chat_ids.len();
            changed_chat_ids.extend(removed_duplicate_chat_ids);
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
        let chat_key = detail.chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let (report, changed) = match self.apply_chat_detail_in_memory(detail) {
            Ok(result) => result,
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                return Err(error);
            }
        };
        if let Err(error) = self.persist_if_needed(changed) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            return Err(error);
        }
        Ok(report)
    }

    fn apply_chat_detail_in_memory(
        &mut self,
        detail: &ChatDetailResponse,
    ) -> Result<(LocalStoreApplyReport, bool)> {
        let entry = self
            .state
            .chats
            .entry(detail.chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                is_active: true,
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
                pending_history_repair_from_server_seq: None,
                pending_history_repair_through_server_seq: None,
                message_repair_mailbox: BTreeMap::new(),
            });

        let mut changed = false;
        if !entry.is_active {
            entry.is_active = true;
            changed = true;
        }
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

        Ok((
            LocalStoreApplyReport {
                chats_upserted: usize::from(changed),
                messages_upserted: 0,
                changed_chat_ids: if changed {
                    vec![detail.chat_id]
                } else {
                    Vec::new()
                },
            },
            changed,
        ))
    }

    pub fn apply_chat_history(
        &mut self,
        history: &ChatHistoryResponse,
    ) -> Result<LocalStoreApplyReport> {
        let chat_key = history.chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let previous_outbox = self.state.outbox.clone();
        let (report, changed) = match self.apply_chat_history_in_memory(history) {
            Ok(result) => result,
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                self.state.outbox = previous_outbox;
                return Err(error);
            }
        };
        if let Err(error) = self.persist_if_needed(changed) {
            self.restore_chat_snapshot(&chat_key, previous_chat);
            self.state.outbox = previous_outbox;
            return Err(error);
        }
        Ok(report)
    }

    fn apply_chat_history_in_memory(
        &mut self,
        history: &ChatHistoryResponse,
    ) -> Result<(LocalStoreApplyReport, bool)> {
        let mut changed_chat_ids = BTreeSet::new();
        let mut messages_upserted = 0usize;
        let chat_id = history.chat_id;
        let entry = self
            .state
            .chats
            .entry(chat_id.0.to_string())
            .or_insert_with(|| PersistedChatState {
                is_active: true,
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
                pending_history_repair_from_server_seq: None,
                pending_history_repair_through_server_seq: None,
                message_repair_mailbox: BTreeMap::new(),
            });

        let mut chat_changed = false;
        let mut outbox_changed = false;
        if !entry.is_active {
            entry.is_active = true;
            chat_changed = true;
        }
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
            outbox_changed |= self
                .state
                .outbox
                .remove(&message.message_id.0.to_string())
                .is_some();
        }

        if chat_changed {
            changed_chat_ids.insert(chat_id.0.to_string());
        }
        Ok((
            LocalStoreApplyReport {
                chats_upserted: usize::from(chat_changed),
                messages_upserted,
                changed_chat_ids: changed_chat_ids
                    .into_iter()
                    .filter_map(|chat_id| parse_chat_id(&chat_id).ok())
                    .collect(),
            },
            chat_changed || outbox_changed,
        ))
    }

    pub fn apply_inbox_items(&mut self, items: &[InboxItem]) -> Result<LocalStoreApplyReport> {
        let mut combined = LocalStoreApplyReport {
            chats_upserted: 0,
            messages_upserted: 0,
            changed_chat_ids: Vec::new(),
        };
        let mut changed_chat_ids = BTreeSet::new();
        let mut changed = false;
        let mut previous_chats = BTreeMap::new();
        let previous_outbox = self.state.outbox.clone();

        for item in items {
            let chat_id = item.message.chat_id;
            let chat_key = chat_id.0.to_string();
            previous_chats
                .entry(chat_key.clone())
                .or_insert_with(|| self.state.chats.get(&chat_key).cloned());
            let (report, history_changed) =
                match self.apply_chat_history_in_memory(&ChatHistoryResponse {
                    chat_id,
                    messages: vec![item.message.clone()],
                }) {
                    Ok(result) => result,
                    Err(error) => {
                        for (chat_key, snapshot) in previous_chats {
                            self.restore_chat_snapshot(&chat_key, snapshot);
                        }
                        self.state.outbox = previous_outbox;
                        return Err(error);
                    }
                };
            combined.chats_upserted += report.chats_upserted;
            combined.messages_upserted += report.messages_upserted;
            changed_chat_ids.extend(
                report
                    .changed_chat_ids
                    .into_iter()
                    .map(|chat_id| chat_id.0.to_string()),
            );
            changed |= history_changed;

            if let Some(chat) = self.state.chats.get_mut(&chat_key) {
                let previous_pending = chat.pending_message_count;
                chat.pending_message_count = chat.pending_message_count.saturating_sub(1);
                if chat.pending_message_count != previous_pending {
                    changed = true;
                    changed_chat_ids.insert(chat_key);
                }
            }
        }

        if let Err(error) = self.persist_if_needed(changed) {
            for (chat_key, snapshot) in previous_chats {
                self.restore_chat_snapshot(&chat_key, snapshot);
            }
            self.state.outbox = previous_outbox;
            return Err(error);
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
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let previous_outbox = self.state.outbox.clone();
        let result = (|| {
            let (mut report, history_changed) =
                self.apply_chat_history_in_memory(&ChatHistoryResponse {
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
            let (projection_report, projection_changed) =
                self.apply_projected_messages_in_memory(chat_id, &[projected_message.clone()])?;
            if projection_report.projected_messages_upserted > 0
                && !report.changed_chat_ids.contains(&chat_id)
            {
                report.changed_chat_ids.push(chat_id);
            }

            Ok::<_, anyhow::Error>((
                LocalOutgoingMessageApplyOutcome {
                    report,
                    projected_message,
                },
                history_changed || projection_changed,
            ))
        })();

        match result {
            Ok((outcome, changed)) => {
                if let Err(error) = self.persist_if_needed(changed) {
                    self.restore_chat_snapshot(&chat_key, previous_chat);
                    self.state.outbox = previous_outbox;
                    return Err(error);
                }
                Ok(outcome)
            }
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                self.state.outbox = previous_outbox;
                Err(error)
            }
        }
    }

    pub fn apply_local_projection(
        &mut self,
        envelope: &MessageEnvelope,
        projection_kind: LocalProjectionKind,
        payload: Option<Vec<u8>>,
        merged_epoch: Option<u64>,
    ) -> Result<LocalStoreApplyReport> {
        let chat_id = envelope.chat_id;
        let chat_key = chat_id.0.to_string();
        let previous_chat = self.state.chats.get(&chat_key).cloned();
        let previous_outbox = self.state.outbox.clone();
        let result = (|| {
            let (mut report, history_changed) =
                self.apply_chat_history_in_memory(&ChatHistoryResponse {
                    chat_id,
                    messages: vec![envelope.clone()],
                })?;

            let chat = self.state.chats.get_mut(&chat_key).ok_or_else(|| {
                anyhow!("chat {} is missing from local store", envelope.chat_id.0)
            })?;
            let projected = LocalProjectedMessage {
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
            };
            ensure_application_message_is_materialized(&projected)?;
            let projected = persisted_projected_message_from(projected);

            let mut changed = false;
            let entry_changed = match chat.projected_messages.get(&envelope.server_seq) {
                Some(existing) => existing != &projected,
                None => true,
            };
            if entry_changed {
                chat.projected_messages
                    .insert(envelope.server_seq, projected);
                changed = true;
            }
            if envelope.server_seq > chat.projected_cursor_server_seq {
                chat.projected_cursor_server_seq = envelope.server_seq;
                changed = true;
            }

            if changed && !report.changed_chat_ids.contains(&envelope.chat_id) {
                report.changed_chat_ids.push(envelope.chat_id);
            }
            Ok::<_, anyhow::Error>((report, history_changed || changed))
        })();

        match result {
            Ok((report, changed)) => {
                if let Err(error) = self.persist_if_needed(changed) {
                    self.restore_chat_snapshot(&chat_key, previous_chat);
                    self.state.outbox = previous_outbox;
                    return Err(error);
                }
                Ok(report)
            }
            Err(error) => {
                self.restore_chat_snapshot(&chat_key, previous_chat);
                self.state.outbox = previous_outbox;
                Err(error)
            }
        }
    }

    fn persist_if_needed(&self, changed: bool) -> Result<()> {
        if changed {
            self.save_state()?;
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn inject_save_failure_after(&mut self, successful_saves_before_failure: usize) {
        self.fail_save_after
            .set(Some(successful_saves_before_failure));
    }

    fn find_welcome_bootstraps(&self, chat_id: ChatId) -> Result<Vec<WelcomeBootstrapMaterial>> {
        let Some(chat) = self.state.chats.get(&chat_id.0.to_string()) else {
            return Ok(Vec::new());
        };

        chat.messages
            .values()
            .rev()
            .filter(|message| matches!(message.message_kind, trix_types::MessageKind::WelcomeRef))
            .map(|welcome| {
                let welcome_payload = decode_b64_field("ciphertext_b64", &welcome.ciphertext_b64)
                    .map_err(|err| {
                    anyhow!(
                        "failed to decode welcome payload {}: {err}",
                        welcome.message_id.0
                    )
                })?;
                let ratchet_tree =
                    control_message_ratchet_tree(&welcome.aad_json).map_err(|err| {
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
                                trix_types::MessageKind::Commit
                                    | trix_types::MessageKind::WelcomeRef
                            )
                    })
                    .map(synthetic_control_projection_from)
                    .collect::<Result<Vec<_>>>()?;

                Ok(WelcomeBootstrapMaterial {
                    welcome_message_id: welcome.message_id,
                    welcome_payload,
                    ratchet_tree,
                    synthetic_projections,
                })
            })
            .collect()
    }
}

fn persisted_group_ids_from_storage_root(storage_root: &Path) -> Result<Vec<Vec<u8>>> {
    let storage_file = storage_root.join("storage.json");
    if !storage_file.exists() {
        return Ok(Vec::new());
    }

    let mut input = File::open(&storage_file).with_context(|| {
        format!(
            "failed to open persisted MLS storage snapshot {}",
            storage_file.display()
        )
    })?;
    let mut content = String::new();
    input.read_to_string(&mut content).with_context(|| {
        format!(
            "failed to read persisted MLS storage snapshot {}",
            storage_file.display()
        )
    })?;

    let snapshot: PersistedMlsStorageSnapshot =
        serde_json::from_str(&content).with_context(|| {
            format!(
                "failed to parse persisted MLS storage snapshot {}",
                storage_file.display()
            )
        })?;

    let mut group_ids = Vec::new();
    let mut seen = BTreeSet::new();
    for (key_b64, value_b64) in snapshot.values {
        let key = decode_b64_field("persisted_mls_key_b64", &key_b64)?;
        if !key
            .windows(b"GroupContext".len())
            .any(|window| window == b"GroupContext")
        {
            continue;
        }

        let value = decode_b64_field("persisted_mls_value_b64", &value_b64)?;
        let context: PersistedMlsGroupContext = serde_json::from_slice(&value)
            .context("failed to decode persisted MLS group context")?;
        let group_id = context.group_id.value.vec;
        let marker = crate::encode_b64(&group_id);
        if seen.insert(marker) {
            group_ids.push(group_id);
        }
    }

    Ok(group_ids)
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
        trix_types::MessageKind::Application => {
            match facade.process_message(conversation, &payload) {
                Ok(MlsProcessResult::ApplicationMessage(plaintext)) => (
                    LocalProjectionKind::ApplicationMessage,
                    Some(plaintext),
                    None,
                ),
                Ok(MlsProcessResult::ProposalQueued) => {
                    (LocalProjectionKind::ProposalQueued, None, None)
                }
                Ok(MlsProcessResult::CommitMerged { epoch }) => {
                    (LocalProjectionKind::CommitMerged, None, Some(epoch))
                }
                Err(error) if is_tolerable_application_replay_error(&error) => {
                    (LocalProjectionKind::ApplicationMessage, None, None)
                }
                Err(error) => return Err(error),
            }
        }
        trix_types::MessageKind::Commit => match facade.process_message(conversation, &payload) {
            Ok(MlsProcessResult::ApplicationMessage(plaintext)) => (
                LocalProjectionKind::ApplicationMessage,
                Some(plaintext),
                None,
            ),
            Ok(MlsProcessResult::ProposalQueued) => {
                (LocalProjectionKind::ProposalQueued, None, None)
            }
            Ok(MlsProcessResult::CommitMerged { epoch }) => {
                (LocalProjectionKind::CommitMerged, None, Some(epoch))
            }
            Err(error) => return Err(error),
        },
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

fn is_tolerable_application_replay_error(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let message = cause.to_string();
        message.contains("Cannot decrypt own messages")
            || message.contains("requested secret was deleted to preserve forward secrecy")
            || message.contains("Generation is too old to be processed")
    })
}

fn is_group_id_mismatch_projection_error(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .to_string()
            .contains("Message group ID differs from the group's group ID")
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
            .materialized_body_b64
            .and_then(|payload_b64| decode_b64_field("materialized_body_b64", &payload_b64).ok()),
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

#[derive(Debug, Deserialize)]
struct PersistedMlsStorageSnapshot {
    values: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct PersistedMlsGroupContext {
    group_id: PersistedMlsByteVecWrapper,
}

#[derive(Debug, Deserialize)]
struct PersistedMlsByteVecWrapper {
    value: PersistedMlsByteVec,
}

#[derive(Debug, Deserialize)]
struct PersistedMlsByteVec {
    vec: Vec<u8>,
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
        materialized_body_b64: value.payload.map(|payload| crate::encode_b64(&payload)),
        witness_repair: None,
        merged_epoch: value.merged_epoch,
        created_at_unix: value.created_at_unix,
    }
}

impl From<LocalMessageRepairMailboxEntry> for PersistedMessageRepairMailboxEntry {
    fn from(value: LocalMessageRepairMailboxEntry) -> Self {
        Self {
            request_id: value.request_id,
            message_id: value.message_id,
            ciphertext_sha256_b64: value.ciphertext_sha256_b64,
            witness_account_id: value.witness_account_id,
            witness_device_id: value.witness_device_id,
            unavailable_reason: value.unavailable_reason,
            status: match value.status {
                LocalMessageRepairMailboxStatus::PendingWitness => {
                    PersistedMessageRepairMailboxStatus::PendingWitness
                }
                LocalMessageRepairMailboxStatus::WitnessUnavailable => {
                    PersistedMessageRepairMailboxStatus::WitnessUnavailable
                }
            },
            updated_at_unix: value.updated_at_unix,
            expires_at_unix: value.expires_at_unix,
        }
    }
}

fn history_repair_window_is_suppressed(
    chat: &PersistedChatState,
    window: LocalHistoryRepairWindow,
) -> bool {
    let now_unix = current_unix_seconds_for_mailbox_retry();
    chat.message_repair_mailbox
        .get(&window.from_server_seq)
        .is_some_and(|entry| pending_message_repair_mailbox_entry_is_active(entry, now_unix))
}

fn pending_message_repair_mailbox_entry_is_active(
    entry: &PersistedMessageRepairMailboxEntry,
    now_unix: u64,
) -> bool {
    if !matches!(
        entry.status,
        PersistedMessageRepairMailboxStatus::PendingWitness
    ) {
        return false;
    }
    let suppress_until = if entry.expires_at_unix > 0 {
        entry.expires_at_unix
    } else {
        entry
            .updated_at_unix
            .saturating_add(MESSAGE_REPAIR_WITNESS_PENDING_TTL_SECONDS)
    };
    now_unix < suppress_until
}

fn message_repair_mailbox_entry_suppresses_retry(
    entry: &PersistedMessageRepairMailboxEntry,
    now_unix: u64,
) -> bool {
    match entry.status {
        PersistedMessageRepairMailboxStatus::PendingWitness => {
            pending_message_repair_mailbox_entry_is_active(entry, now_unix)
        }
        PersistedMessageRepairMailboxStatus::WitnessUnavailable => {
            now_unix.saturating_sub(entry.updated_at_unix)
                < MESSAGE_REPAIR_WITNESS_RETRY_BACKOFF_SECONDS
        }
    }
}

fn current_unix_seconds_for_mailbox_retry() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn reconcile_message_repair_mailbox_in_chat(chat: &mut PersistedChatState) -> bool {
    let stale_server_seqs = chat
        .message_repair_mailbox
        .iter()
        .filter_map(|(server_seq, _)| {
            let message = chat.messages.get(server_seq)?;
            (!message_still_requires_witness_repair(chat, *server_seq, message))
                .then_some(*server_seq)
        })
        .collect::<Vec<_>>();
    if stale_server_seqs.is_empty() {
        return false;
    }
    for server_seq in stale_server_seqs {
        chat.message_repair_mailbox.remove(&server_seq);
    }
    true
}

fn unresolved_message_repair_binding(
    chat: &PersistedChatState,
    server_seq: u64,
    message: &MessageEnvelope,
) -> Option<trix_types::MessageRepairBinding> {
    if !message_still_requires_witness_repair(chat, server_seq, message) {
        return None;
    }
    Some(message_repair_binding_from_message(message).ok()?)
}

fn message_still_requires_witness_repair(
    chat: &PersistedChatState,
    server_seq: u64,
    message: &MessageEnvelope,
) -> bool {
    if message.message_kind != MessageKind::Application {
        return false;
    }
    match chat.projected_messages.get(&server_seq) {
        Some(projected) => {
            if projected.message_id != message.message_id
                || projected.sender_account_id != message.sender_account_id
                || projected.sender_device_id != message.sender_device_id
                || projected.epoch != message.epoch
                || projected.message_kind != message.message_kind
                || projected.content_type != message.content_type
            {
                return true;
            }
            if projected.projection_kind != LocalProjectionKind::ApplicationMessage {
                return true;
            }
            let Some(payload_b64) = projected.materialized_body_b64.as_ref() else {
                return true;
            };
            let Ok(payload) = decode_b64_field("materialized_body_b64", payload_b64) else {
                return true;
            };
            MessageBody::from_bytes(message.content_type, &payload).is_err()
        }
        None => true,
    }
}

fn message_repair_binding_from_message(
    message: &MessageEnvelope,
) -> Result<trix_types::MessageRepairBinding> {
    let ciphertext = decode_b64_field("ciphertext_b64", &message.ciphertext_b64)?;
    Ok(trix_types::MessageRepairBinding {
        chat_id: message.chat_id,
        message_id: message.message_id,
        server_seq: message.server_seq,
        epoch: message.epoch,
        sender_account_id: message.sender_account_id,
        sender_device_id: message.sender_device_id,
        message_kind: message.message_kind,
        content_type: message.content_type,
        ciphertext_sha256_b64: crate::encode_b64(Sha256::digest(ciphertext).as_slice()),
    })
}

fn binding_matches_message(
    message: &MessageEnvelope,
    binding: &trix_types::MessageRepairBinding,
) -> Result<bool> {
    Ok(binding.chat_id == message.chat_id
        && binding.message_id == message.message_id
        && binding.server_seq == message.server_seq
        && binding.epoch == message.epoch
        && binding.sender_account_id == message.sender_account_id
        && binding.sender_device_id == message.sender_device_id
        && binding.message_kind == message.message_kind
        && binding.content_type == message.content_type
        && binding.ciphertext_sha256_b64
            == message_repair_binding_from_message(message)?.ciphertext_sha256_b64)
}

fn ensure_application_message_is_materialized(message: &LocalProjectedMessage) -> Result<()> {
    if message.projection_kind == LocalProjectionKind::ApplicationMessage
        && message.payload.is_none()
    {
        return Err(anyhow!(
            "application message {} for chat message seq {} is missing durable body",
            message.message_id.0,
            message.server_seq,
        ));
    }
    Ok(())
}

fn current_device_replay_would_drop_body(
    envelope: &MessageEnvelope,
    projected: &LocalProjectedMessage,
    current_device_id: Option<&trix_types::DeviceId>,
) -> bool {
    current_device_id
        .map(|device_id| *device_id == envelope.sender_device_id)
        .unwrap_or(false)
        && envelope.message_kind == trix_types::MessageKind::Application
        && projected.projection_kind == LocalProjectionKind::ApplicationMessage
        && projected.payload.is_none()
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

fn first_projection_gap_with_projected_tail(chat: &PersistedChatState) -> Option<u64> {
    let max_projected_seq = chat.projected_messages.keys().next_back().copied()?;
    chat.messages.keys().copied().find(|server_seq| {
        *server_seq <= max_projected_seq && !chat.projected_messages.contains_key(server_seq)
    })
}

fn projected_gap_after_cursor(chat: &PersistedChatState) -> Option<LocalHistoryRepairWindow> {
    let next_expected = chat.projected_cursor_server_seq.checked_add(1)?;
    let first_projected_after_cursor = chat
        .projected_messages
        .range(next_expected..)
        .next()
        .map(|(server_seq, _)| *server_seq)?;
    if first_projected_after_cursor <= next_expected {
        return None;
    }
    Some(LocalHistoryRepairWindow {
        from_server_seq: next_expected,
        through_server_seq: first_projected_after_cursor.saturating_sub(1),
    })
}

fn first_unmaterialized_application_projection(chat: &PersistedChatState) -> Option<u64> {
    chat.projected_messages
        .iter()
        .find_map(|(server_seq, message)| {
            ((message.projection_kind == LocalProjectionKind::ApplicationMessage)
                && message.materialized_body_b64.is_none())
            .then_some(*server_seq)
        })
}

fn unmaterialized_application_window(
    chat: &PersistedChatState,
) -> Option<LocalHistoryRepairWindow> {
    let start = first_unmaterialized_application_projection(chat)?;
    let mut through = start;
    for (server_seq, message) in chat.projected_messages.range(start..) {
        if *server_seq == start {
            continue;
        }
        if *server_seq != through.saturating_add(1)
            || message.projection_kind != LocalProjectionKind::ApplicationMessage
            || message.materialized_body_b64.is_some()
        {
            break;
        }
        through = *server_seq;
    }
    Some(LocalHistoryRepairWindow {
        from_server_seq: start,
        through_server_seq: through,
    })
}

fn unprojected_tail_window(chat: &PersistedChatState) -> Option<LocalHistoryRepairWindow> {
    let start = chat.messages.keys().copied().find(|server_seq| {
        *server_seq > chat.projected_cursor_server_seq
            && !chat.projected_messages.contains_key(server_seq)
    })?;
    let mut through = start;
    for server_seq in chat
        .messages
        .keys()
        .copied()
        .filter(|server_seq| *server_seq >= start)
    {
        if server_seq != through && server_seq != through.saturating_add(1) {
            break;
        }
        if chat.projected_messages.contains_key(&server_seq) {
            break;
        }
        through = server_seq;
    }
    Some(LocalHistoryRepairWindow {
        from_server_seq: start,
        through_server_seq: through,
    })
}

fn next_pending_history_repair_window(
    chat: &PersistedChatState,
) -> Option<LocalHistoryRepairWindow> {
    projected_gap_after_cursor(chat)
        .or_else(|| unmaterialized_application_window(chat))
        .or_else(|| unprojected_tail_window(chat))
}

fn chat_has_unmaterialized_application_messages(chat: &PersistedChatState) -> bool {
    first_unmaterialized_application_projection(chat).is_some()
}

fn pending_history_repair_window_from(
    chat: &PersistedChatState,
) -> Option<LocalHistoryRepairWindow> {
    Some(LocalHistoryRepairWindow {
        from_server_seq: chat.pending_history_repair_from_server_seq?,
        through_server_seq: chat.pending_history_repair_through_server_seq?,
    })
}

fn reconcile_pending_history_repair_in_chat(chat: &mut PersistedChatState) -> bool {
    let next_window = next_pending_history_repair_window(chat);
    let current_window = pending_history_repair_window_from(chat);
    if next_window == current_window {
        return false;
    }
    if let Some(next_window) = next_window {
        chat.pending_history_repair_from_server_seq = Some(next_window.from_server_seq);
        chat.pending_history_repair_through_server_seq = Some(next_window.through_server_seq);
    } else {
        chat.pending_history_repair_from_server_seq = None;
        chat.pending_history_repair_through_server_seq = None;
    }
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
    let pending_window = pending_history_repair_window_from(state);
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
        history_recovery_pending: pending_window.is_some(),
        history_recovery_from_server_seq: pending_window.map(|window| window.from_server_seq),
        history_recovery_through_server_seq: pending_window.map(|window| window.through_server_seq),
    }
}

fn compare_chat_summaries_by_recent_activity(left: &ChatSummary, right: &ChatSummary) -> Ordering {
    right
        .last_message
        .as_ref()
        .map(|message| message.created_at_unix)
        .cmp(
            &left
                .last_message
                .as_ref()
                .map(|message| message.created_at_unix),
        )
        .then_with(|| right.last_server_seq.cmp(&left.last_server_seq))
        .then_with(|| left.chat_id.0.cmp(&right.chat_id.0))
}

fn compare_local_chat_list_items_by_recent_activity(
    left: &LocalChatListItem,
    right: &LocalChatListItem,
) -> Ordering {
    right
        .preview_created_at_unix
        .cmp(&left.preview_created_at_unix)
        .then_with(|| right.preview_server_seq.cmp(&left.preview_server_seq))
        .then_with(|| right.last_server_seq.cmp(&left.last_server_seq))
        .then_with(|| left.chat_id.0.cmp(&right.chat_id.0))
}

fn local_timeline_item_from(
    message: LocalProjectedMessage,
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
    decorations: &LocalTimelineDecorations,
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
    let recovery_state = pending_history_repair_window_from(state).and_then(|window| {
        body.is_none()
            .then_some(message.server_seq)
            .filter(|server_seq| {
                *server_seq >= window.from_server_seq && *server_seq <= window.through_server_seq
            })
            .map(|_| LocalMessageRecoveryState::PendingSiblingHistory)
    });
    let is_visible_in_timeline = !decorations.hidden_message_ids.contains(&message.message_id);
    let receipt_status = decorations
        .receipt_status_by_message_id
        .get(&message.message_id)
        .copied()
        .or_else(|| default_outgoing_receipt_status(is_outgoing, &message, is_visible_in_timeline));
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
        receipt_status,
        reactions: local_message_reaction_summaries(
            decorations,
            message.message_id,
            self_account_id,
        ),
        is_visible_in_timeline,
        merged_epoch: message.merged_epoch,
        created_at_unix: message.created_at_unix,
        recovery_state,
    }
}

#[derive(Debug, Default)]
struct LocalTimelineDecorations {
    receipt_status_by_message_id: HashMap<MessageId, crate::ReceiptType>,
    reaction_account_ids_by_message_id:
        HashMap<MessageId, HashMap<String, HashSet<trix_types::AccountId>>>,
    hidden_message_ids: HashSet<MessageId>,
}

fn local_timeline_decorations(
    state: &PersistedChatState,
    self_account_id: Option<trix_types::AccountId>,
) -> LocalTimelineDecorations {
    let mut decorations = LocalTimelineDecorations::default();

    for message in state.projected_messages.values() {
        let Ok(Some(body)) = projected_message_from_persisted(message.clone()).parse_body() else {
            continue;
        };

        match body {
            MessageBody::Receipt(receipt) => {
                if let Some(receipt_status) = receipt_status_from_hidden_receipt(
                    self_account_id,
                    message.sender_account_id,
                    receipt.receipt_type,
                ) {
                    let current = decorations
                        .receipt_status_by_message_id
                        .get(&receipt.target_message_id)
                        .copied();
                    decorations.receipt_status_by_message_id.insert(
                        receipt.target_message_id,
                        merge_receipt_status(current, receipt_status),
                    );
                }
                decorations.hidden_message_ids.insert(message.message_id);
            }
            MessageBody::Reaction(reaction) => {
                let should_remove_target = {
                    let emoji_map = decorations
                        .reaction_account_ids_by_message_id
                        .entry(reaction.target_message_id)
                        .or_default();
                    let reactor_ids = emoji_map.entry(reaction.emoji).or_default();
                    match reaction.action {
                        crate::ReactionAction::Add => {
                            reactor_ids.insert(message.sender_account_id);
                        }
                        crate::ReactionAction::Remove => {
                            reactor_ids.remove(&message.sender_account_id);
                        }
                    }
                    emoji_map.retain(|_, account_ids| !account_ids.is_empty());
                    emoji_map.is_empty()
                };
                if should_remove_target {
                    decorations
                        .reaction_account_ids_by_message_id
                        .remove(&reaction.target_message_id);
                }
                decorations.hidden_message_ids.insert(message.message_id);
            }
            _ => {}
        }
    }

    decorations
}

fn default_outgoing_receipt_status(
    is_outgoing: bool,
    message: &LocalProjectedMessage,
    is_visible_in_timeline: bool,
) -> Option<crate::ReceiptType> {
    if is_outgoing
        && is_visible_in_timeline
        && !matches!(
            message.content_type,
            trix_types::ContentType::Reaction | trix_types::ContentType::Receipt
        )
    {
        Some(crate::ReceiptType::Delivered)
    } else {
        None
    }
}

fn receipt_status_from_hidden_receipt(
    self_account_id: Option<trix_types::AccountId>,
    sender_account_id: trix_types::AccountId,
    receipt_type: crate::ReceiptType,
) -> Option<crate::ReceiptType> {
    if self_account_id == Some(sender_account_id) {
        None
    } else {
        Some(receipt_type)
    }
}

fn merge_receipt_status(
    current: Option<crate::ReceiptType>,
    next: crate::ReceiptType,
) -> crate::ReceiptType {
    match (current, next) {
        (Some(crate::ReceiptType::Read), _) | (_, crate::ReceiptType::Read) => {
            crate::ReceiptType::Read
        }
        _ => crate::ReceiptType::Delivered,
    }
}

fn local_message_reaction_summaries(
    decorations: &LocalTimelineDecorations,
    message_id: MessageId,
    self_account_id: Option<trix_types::AccountId>,
) -> Vec<LocalMessageReactionSummary> {
    let Some(emoji_map) = decorations
        .reaction_account_ids_by_message_id
        .get(&message_id)
    else {
        return Vec::new();
    };

    let mut reactions = emoji_map
        .iter()
        .map(|(emoji, account_ids)| {
            let mut reactor_account_ids = account_ids.iter().copied().collect::<Vec<_>>();
            reactor_account_ids.sort_by_key(|account_id| account_id.0);
            LocalMessageReactionSummary {
                emoji: emoji.clone(),
                count: reactor_account_ids.len() as u64,
                includes_self: self_account_id
                    .map(|account_id| account_ids.contains(&account_id))
                    .unwrap_or(false),
                reactor_account_ids,
            }
        })
        .collect::<Vec<_>>();
    reactions.sort_by(|left, right| left.emoji.cmp(&right.emoji));
    reactions
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
    let projected = latest_visible_projected_message(state);
    let raw = latest_visible_raw_message(state);

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

fn latest_visible_projected_message(
    state: &PersistedChatState,
) -> Option<&PersistedProjectedMessage> {
    state
        .projected_messages
        .values()
        .rev()
        .find(|message| persisted_projected_message_is_visible_in_timeline(message))
}

fn latest_visible_raw_message(state: &PersistedChatState) -> Option<&MessageEnvelope> {
    state
        .messages
        .values()
        .rev()
        .find(|message| raw_message_is_visible_in_timeline(message))
        .or_else(|| {
            state
                .last_message
                .as_ref()
                .filter(|message| raw_message_is_visible_in_timeline(message))
        })
}

fn raw_message_is_visible_in_timeline(message: &MessageEnvelope) -> bool {
    !matches!(
        message.content_type,
        trix_types::ContentType::Reaction | trix_types::ContentType::Receipt
    )
}

fn persisted_projected_message_is_visible_in_timeline(message: &PersistedProjectedMessage) -> bool {
    if !matches!(
        message.content_type,
        trix_types::ContentType::Reaction | trix_types::ContentType::Receipt
    ) {
        return true;
    }

    !matches!(
        projected_message_from_persisted(message.clone()).parse_body(),
        Ok(Some(MessageBody::Reaction(_) | MessageBody::Receipt(_)))
    )
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
            if body_parse_error.is_some() {
                return fallback_preview_for_content_type(message.content_type, true);
            }
            unavailable_preview_for_content_type(message.content_type)
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
                unavailable_preview_for_content_type(trix_types::ContentType::Text)
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
    match content_type {
        trix_types::ContentType::Text => {
            if had_parse_error {
                "Unreadable message content".to_owned()
            } else {
                unavailable_preview_for_content_type(content_type)
            }
        }
        trix_types::ContentType::Reaction => {
            if had_parse_error {
                "Unreadable reaction content".to_owned()
            } else {
                "Reaction".to_owned()
            }
        }
        trix_types::ContentType::Receipt => "Receipt".to_owned(),
        trix_types::ContentType::Attachment => {
            if had_parse_error {
                "Unreadable attachment content".to_owned()
            } else {
                "Attachment".to_owned()
            }
        }
        trix_types::ContentType::ChatEvent => {
            if had_parse_error {
                "Unreadable chat event content".to_owned()
            } else {
                "Chat event".to_owned()
            }
        }
    }
}

fn unavailable_preview_for_content_type(content_type: trix_types::ContentType) -> String {
    match content_type {
        trix_types::ContentType::Text => {
            "Message content is unavailable on this device.".to_owned()
        }
        trix_types::ContentType::Reaction => {
            "Reaction content is unavailable on this device.".to_owned()
        }
        trix_types::ContentType::Receipt => "Receipt".to_owned(),
        trix_types::ContentType::Attachment => {
            "Attachment content is unavailable on this device.".to_owned()
        }
        trix_types::ContentType::ChatEvent => {
            "Chat event content is unavailable on this device.".to_owned()
        }
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
    if !persisted_projected_message_is_visible_in_timeline(message) {
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
        DELETE FROM local_history_attachment_refs;
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
            is_active,
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
            projected_cursor_server_seq,
            pending_history_repair_from_server_seq,
            pending_history_repair_through_server_seq,
            message_repair_mailbox_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
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
    let mut attachment_ref_statement = transaction.prepare(
        r#"
        INSERT INTO local_history_attachment_refs (attachment_ref, fingerprint, attachment_json)
        VALUES (?1, ?2, ?3)
        "#,
    )?;

    for (chat_id, chat) in &state.chats {
        chat_statement.execute(params![
            chat_id,
            if chat.is_active { 1_i64 } else { 0_i64 },
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
            chat.pending_history_repair_from_server_seq
                .map(|value| u64_to_i64(value, "pending_history_repair_from_server_seq"))
                .transpose()?,
            chat.pending_history_repair_through_server_seq
                .map(|value| u64_to_i64(value, "pending_history_repair_through_server_seq"))
                .transpose()?,
            serde_json::to_string(&chat.message_repair_mailbox)?,
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

    for (attachment_ref, attachment) in &state.attachment_refs {
        let fingerprint =
            state
                .attachment_ref_index
                .iter()
                .find_map(|(fingerprint, indexed_ref)| {
                    (indexed_ref == attachment_ref).then(|| fingerprint.as_str())
                });
        attachment_ref_statement.execute(params![
            attachment_ref,
            fingerprint,
            serde_json::to_string(attachment)?,
        ])?;
    }

    drop(attachment_ref_statement);
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

fn load_state_from_encrypted_path(
    path: &Path,
    database_key: &[u8],
) -> Result<PersistedLocalHistoryState> {
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
        attachment_refs: BTreeMap::new(),
        attachment_ref_index: BTreeMap::new(),
        outbox: BTreeMap::new(),
    };

    let mut chats_statement = connection.prepare(
        r#"
        SELECT
            chat_id,
            is_active,
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
            projected_cursor_server_seq,
            pending_history_repair_from_server_seq,
            pending_history_repair_through_server_seq,
            message_repair_mailbox_json
        FROM local_history_chats
        ORDER BY chat_id
        "#,
    )?;
    let chat_rows = chats_statement.query_map([], |row| {
        let chat_id: String = row.get(0)?;
        let is_active: i64 = row.get(1)?;
        let chat_type_json: String = row.get(2)?;
        let title: Option<String> = row.get(3)?;
        let last_server_seq: i64 = row.get(4)?;
        let pending_message_count: i64 = row.get(5)?;
        let last_message_json: Option<String> = row.get(6)?;
        let epoch: i64 = row.get(7)?;
        let last_commit_message_id: Option<String> = row.get(8)?;
        let participant_profiles_json: String = row.get(9)?;
        let members_json: String = row.get(10)?;
        let device_members_json: String = row.get(11)?;
        let mls_group_id_b64: Option<String> = row.get(12)?;
        let read_cursor_server_seq: i64 = row.get(13)?;
        let projected_cursor_server_seq: i64 = row.get(14)?;
        let pending_history_repair_from_server_seq: Option<i64> = row.get(15)?;
        let pending_history_repair_through_server_seq: Option<i64> = row.get(16)?;
        let message_repair_mailbox_json: Option<String> = row.get(17)?;
        let message_repair_mailbox =
            serde_json::from_str(message_repair_mailbox_json.as_deref().unwrap_or("{}"))
                .map_err(sqlite_serde_error)?;

        Ok((
            chat_id,
            PersistedChatState {
                is_active: is_active != 0,
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
                pending_history_repair_from_server_seq: pending_history_repair_from_server_seq
                    .map(|value| {
                        i64_to_u64(value, "pending_history_repair_from_server_seq")
                            .map_err(sqlite_anyhow_error)
                    })
                    .transpose()?,
                pending_history_repair_through_server_seq:
                    pending_history_repair_through_server_seq
                        .map(|value| {
                            i64_to_u64(value, "pending_history_repair_through_server_seq")
                                .map_err(sqlite_anyhow_error)
                        })
                        .transpose()?,
                message_repair_mailbox,
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
    drop(projected_statement);

    let mut attachment_ref_statement = connection.prepare(
        r#"
        SELECT attachment_ref, fingerprint, attachment_json
        FROM local_history_attachment_refs
        ORDER BY attachment_ref
        "#,
    )?;
    let attachment_ref_rows = attachment_ref_statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    for row in attachment_ref_rows {
        let (attachment_ref, fingerprint, attachment_json) = row?;
        state.attachment_refs.insert(
            attachment_ref.clone(),
            serde_json::from_str(&attachment_json)
                .context("failed to parse local attachment ref")?,
        );
        if let Some(fingerprint) = fingerprint {
            state
                .attachment_ref_index
                .insert(fingerprint, attachment_ref.clone());
        }
    }
    drop(attachment_ref_statement);

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
        configure_sqlcipher_connection(&connection, path, database_key, "local history")?;
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
            is_active INTEGER NOT NULL DEFAULT 1,
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
            projected_cursor_server_seq INTEGER NOT NULL,
            pending_history_repair_from_server_seq INTEGER,
            pending_history_repair_through_server_seq INTEGER,
            message_repair_mailbox_json TEXT NOT NULL DEFAULT '{}'
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
        CREATE TABLE IF NOT EXISTS local_history_attachment_refs (
            attachment_ref TEXT PRIMARY KEY,
            fingerprint TEXT,
            attachment_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS local_history_outbox (
            message_id TEXT PRIMARY KEY,
            outbox_json TEXT NOT NULL
        );
        "#,
    )?;
    ensure_sqlite_column(
        &connection,
        "local_history_chats",
        "is_active",
        "INTEGER NOT NULL DEFAULT 1",
    )?;
    ensure_sqlite_column(
        &connection,
        "local_history_chats",
        "pending_history_repair_from_server_seq",
        "INTEGER",
    )?;
    ensure_sqlite_column(
        &connection,
        "local_history_chats",
        "pending_history_repair_through_server_seq",
        "INTEGER",
    )?;
    ensure_sqlite_column(
        &connection,
        "local_history_chats",
        "message_repair_mailbox_json",
        "TEXT NOT NULL DEFAULT '{}'",
    )?;
    Ok(connection)
}

fn ensure_sqlite_column(
    connection: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let column_names = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    drop(statement);
    if column_names.iter().any(|existing| existing == column) {
        return Ok(());
    }
    connection.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
        [],
    )?;
    Ok(())
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
        .with_context(|| {
            format!(
                "failed to configure SQLCipher for {label} {}",
                path.display()
            )
        })?;
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        })
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

fn direct_chat_pair_key_from_state(state: &PersistedChatState) -> Option<String> {
    if state.chat_type != ChatType::Dm {
        return None;
    }

    let mut account_ids = state
        .members
        .iter()
        .filter(|member| member.membership_status == "active")
        .map(|member| member.account_id)
        .collect::<Vec<_>>();
    account_ids.sort_by_key(|account_id| account_id.0);
    account_ids.dedup();
    if account_ids.len() == 2 {
        return Some(direct_chat_pair_key_for_account_ids(&account_ids));
    }

    let mut participant_account_ids = state
        .participant_profiles
        .iter()
        .map(|profile| profile.account_id)
        .collect::<Vec<_>>();
    participant_account_ids.sort_by_key(|account_id| account_id.0);
    participant_account_ids.dedup();
    if participant_account_ids.len() != 2 {
        return None;
    }

    Some(direct_chat_pair_key_for_account_ids(
        &participant_account_ids,
    ))
}

fn direct_chat_pair_key_for_account_ids(account_ids: &[trix_types::AccountId]) -> String {
    let mut normalized = account_ids
        .iter()
        .map(|account_id| account_id.0.to_string())
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized.join(":")
}

fn compare_direct_chat_state_preference(
    left_chat_id: &str,
    left: &PersistedChatState,
    right_chat_id: &str,
    right: &PersistedChatState,
) -> Ordering {
    left.is_active
        .cmp(&right.is_active)
        .then_with(|| left.last_server_seq.cmp(&right.last_server_seq))
        .then_with(|| {
            left.last_message
                .as_ref()
                .map(|message| message.created_at_unix)
                .unwrap_or_default()
                .cmp(
                    &right
                        .last_message
                        .as_ref()
                        .map(|message| message.created_at_unix)
                        .unwrap_or_default(),
                )
        })
        .then_with(|| left.epoch.cmp(&right.epoch))
        .then_with(|| {
            left.projected_cursor_server_seq
                .cmp(&right.projected_cursor_server_seq)
        })
        .then_with(|| {
            left.read_cursor_server_seq
                .cmp(&right.read_cursor_server_seq)
        })
        .then_with(|| left_chat_id.cmp(right_chat_id))
}

fn deduplicate_direct_chats_in_state(state: &mut PersistedLocalHistoryState) -> Vec<String> {
    let chat_ids = state.chats.keys().cloned().collect::<Vec<_>>();
    let mut canonical_chat_ids_by_pair = BTreeMap::<String, String>::new();

    for chat_id in &chat_ids {
        let Some(chat_state) = state.chats.get(chat_id) else {
            continue;
        };
        let Some(pair_key) = direct_chat_pair_key_from_state(chat_state) else {
            continue;
        };

        let should_replace = canonical_chat_ids_by_pair
            .get(&pair_key)
            .and_then(|existing_chat_id| {
                state.chats.get(existing_chat_id).map(|existing_state| {
                    compare_direct_chat_state_preference(
                        chat_id,
                        chat_state,
                        existing_chat_id,
                        existing_state,
                    ) == Ordering::Greater
                })
            })
            .unwrap_or(true);

        if should_replace {
            canonical_chat_ids_by_pair.insert(pair_key, chat_id.clone());
        }
    }

    let canonical_chat_ids = canonical_chat_ids_by_pair
        .into_values()
        .collect::<BTreeSet<_>>();
    let removed_chat_ids = chat_ids
        .into_iter()
        .filter(|chat_id| {
            state
                .chats
                .get(chat_id)
                .and_then(direct_chat_pair_key_from_state)
                .is_some()
                && !canonical_chat_ids.contains(chat_id)
        })
        .collect::<Vec<_>>();

    if removed_chat_ids.is_empty() {
        return removed_chat_ids;
    }

    let removed_chat_id_set = removed_chat_ids.iter().cloned().collect::<BTreeSet<_>>();
    for chat_id in &removed_chat_ids {
        state.chats.remove(chat_id);
    }
    state
        .outbox
        .retain(|_, message| !removed_chat_id_set.contains(&message.chat_id.0.to_string()));

    removed_chat_ids
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, env, fs, path::Path};

    use anyhow::anyhow;
    use serde_json::json;
    use trix_types::{AccountId, ContentType, DeviceId, InboxItem, MessageKind};

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
    fn apply_chat_detail_rehydrates_history_first_group_metadata() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let bob_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());

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
                    ciphertext_b64: crate::encode_b64(b"hello"),
                    aad_json: json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap();

        let placeholder = store.get_chat(chat_id).unwrap();
        assert_eq!(placeholder.chat_type, ChatType::Dm);
        assert!(placeholder.members.is_empty());

        store
            .apply_chat_detail(&ChatDetailResponse {
                chat_id,
                chat_type: ChatType::Group,
                title: Some("Alpha Squad".to_owned()),
                last_server_seq: 1,
                pending_message_count: 0,
                epoch: 7,
                last_commit_message_id: None,
                last_message: placeholder.last_message.clone(),
                participant_profiles: vec![
                    ChatParticipantProfileSummary {
                        account_id: alice_account,
                        handle: Some("alice".to_owned()),
                        profile_name: "Alice".to_owned(),
                        profile_bio: None,
                    },
                    ChatParticipantProfileSummary {
                        account_id: bob_account,
                        handle: Some("bob".to_owned()),
                        profile_name: "Bob".to_owned(),
                        profile_bio: None,
                    },
                ],
                members: vec![
                    ChatMemberSummary {
                        account_id: alice_account,
                        role: "owner".to_owned(),
                        membership_status: "active".to_owned(),
                    },
                    ChatMemberSummary {
                        account_id: bob_account,
                        role: "member".to_owned(),
                        membership_status: "active".to_owned(),
                    },
                ],
                device_members: Vec::new(),
            })
            .unwrap();

        let hydrated = store.get_chat(chat_id).unwrap();
        assert_eq!(hydrated.chat_type, ChatType::Group);
        assert_eq!(hydrated.title.as_deref(), Some("Alpha Squad"));
        assert_eq!(hydrated.members.len(), 2);

        let item = store
            .get_local_chat_list_item(chat_id, Some(bob_account))
            .unwrap();
        assert_eq!(item.chat_type, ChatType::Group);
        assert_eq!(item.display_title, "Alpha Squad");
        assert_eq!(item.participant_profiles.len(), 2);
    }

    #[test]
    fn apply_chat_list_hides_missing_chats_without_dropping_local_history() {
        let mut store = LocalHistoryStore::new();
        let visible_chat_id = ChatId(Uuid::new_v4());
        let hidden_chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![
                    ChatSummary {
                        chat_id: visible_chat_id,
                        chat_type: ChatType::Dm,
                        title: Some("Visible".to_owned()),
                        last_server_seq: 0,
                        epoch: 1,
                        pending_message_count: 0,
                        last_message: None,
                        participant_profiles: Vec::new(),
                    },
                    ChatSummary {
                        chat_id: hidden_chat_id,
                        chat_type: ChatType::Dm,
                        title: Some("Hidden".to_owned()),
                        last_server_seq: 1,
                        epoch: 1,
                        pending_message_count: 0,
                        last_message: None,
                        participant_profiles: Vec::new(),
                    },
                ],
            })
            .unwrap();
        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id: hidden_chat_id,
                messages: vec![MessageEnvelope {
                    message_id: MessageId(Uuid::new_v4()),
                    chat_id: hidden_chat_id,
                    server_seq: 1,
                    sender_account_id: self_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(b"hidden-message"),
                    aad_json: json!({}),
                    created_at_unix: 10,
                }],
            })
            .unwrap();

        assert_eq!(
            store
                .list_local_chat_list_items(Some(self_account_id))
                .len(),
            2
        );
        assert!(store.get_chat(hidden_chat_id).is_some());

        let hide_report = store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id: visible_chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Visible".to_owned()),
                    last_server_seq: 0,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();
        assert!(hide_report.changed_chat_ids.contains(&hidden_chat_id));

        let visible = store.list_local_chat_list_items(Some(self_account_id));
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].chat_id, visible_chat_id);
        assert!(
            store
                .get_local_chat_list_item(hidden_chat_id, Some(self_account_id))
                .is_none()
        );
        assert!(store.get_chat(hidden_chat_id).is_some());
        assert_eq!(
            store
                .get_chat_history(hidden_chat_id, None, Some(10))
                .messages
                .len(),
            1
        );

        store
            .apply_chat_detail(&ChatDetailResponse {
                chat_id: hidden_chat_id,
                chat_type: ChatType::Group,
                title: Some("Reactivated".to_owned()),
                last_server_seq: 1,
                pending_message_count: 0,
                epoch: 2,
                last_commit_message_id: None,
                last_message: store
                    .get_chat(hidden_chat_id)
                    .and_then(|chat| chat.last_message),
                participant_profiles: Vec::new(),
                members: Vec::new(),
                device_members: Vec::new(),
            })
            .unwrap();

        assert!(
            store
                .get_local_chat_list_item(hidden_chat_id, Some(self_account_id))
                .is_some()
        );
    }

    #[test]
    fn hidden_chats_do_not_expose_read_state_helpers() {
        let mut store = LocalHistoryStore::new();
        let visible_chat_id = ChatId(Uuid::new_v4());
        let hidden_chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![
                    ChatSummary {
                        chat_id: visible_chat_id,
                        chat_type: ChatType::Dm,
                        title: Some("Visible".to_owned()),
                        last_server_seq: 0,
                        epoch: 1,
                        pending_message_count: 0,
                        last_message: None,
                        participant_profiles: Vec::new(),
                    },
                    ChatSummary {
                        chat_id: hidden_chat_id,
                        chat_type: ChatType::Dm,
                        title: Some("Hidden".to_owned()),
                        last_server_seq: 0,
                        epoch: 1,
                        pending_message_count: 0,
                        last_message: None,
                        participant_profiles: Vec::new(),
                    },
                ],
            })
            .unwrap();

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id: visible_chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Visible".to_owned()),
                    last_server_seq: 0,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();

        assert_eq!(store.chat_read_cursor(hidden_chat_id), None);
        assert_eq!(
            store.chat_unread_count(hidden_chat_id, Some(self_account_id)),
            None
        );
        assert_eq!(
            store.get_chat_read_state(hidden_chat_id, Some(self_account_id)),
            None
        );
    }

    #[test]
    fn apply_chat_history_restores_in_memory_state_when_save_fails() {
        let database_path =
            env::temp_dir().join(format!("trix-history-rollback-{}.db", Uuid::new_v4()));
        let mut store = LocalHistoryStore::new_persistent(&database_path).unwrap();
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_detail(&ChatDetailResponse {
                chat_id,
                chat_type: ChatType::Dm,
                title: Some("Rollback".to_owned()),
                last_server_seq: 0,
                pending_message_count: 0,
                epoch: 1,
                last_commit_message_id: None,
                last_message: None,
                participant_profiles: Vec::new(),
                members: Vec::new(),
                device_members: Vec::new(),
            })
            .unwrap();

        store.inject_save_failure_after(0);
        let error = store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id: MessageId(Uuid::new_v4()),
                    chat_id,
                    server_seq: 1,
                    sender_account_id: account_id,
                    sender_device_id: device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(b"rollback"),
                    aad_json: json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("injected local history save failure")
        );
        assert_eq!(store.get_chat(chat_id).unwrap().last_server_seq, 0,);
        assert!(
            store
                .get_chat_history(chat_id, None, Some(10))
                .messages
                .is_empty()
        );
        assert!(
            store
                .get_projected_messages(chat_id, None, Some(10))
                .is_empty()
        );

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn encrypted_local_history_store_round_trips_with_same_key() {
        let database_path =
            env::temp_dir().join(format!("trix-history-encrypted-{}.db", Uuid::new_v4()));
        let database_key = vec![7u8; 32];
        let chat_id = ChatId(Uuid::new_v4());
        let mut store =
            LocalHistoryStore::new_encrypted(&database_path, database_key.clone()).unwrap();

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
        assert_eq!(
            restored.get_chat(chat_id).and_then(|chat| chat.title),
            Some("Encrypted".to_owned())
        );

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn encrypted_local_history_store_persists_pending_history_repair_window() {
        let database_path =
            env::temp_dir().join(format!("trix-history-repair-window-{}.db", Uuid::new_v4()));
        let database_key = vec![17u8; 32];
        let chat_id = ChatId(Uuid::new_v4());
        let mut store =
            LocalHistoryStore::new_encrypted(&database_path, database_key.clone()).unwrap();

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Repair".to_owned()),
                    last_server_seq: 8,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();
        store
            .set_pending_history_repair_window(
                chat_id,
                LocalHistoryRepairWindow {
                    from_server_seq: 3,
                    through_server_seq: 6,
                },
            )
            .unwrap();
        drop(store);

        let restored = LocalHistoryStore::new_encrypted(&database_path, database_key).unwrap();
        assert_eq!(
            restored.pending_history_repair_window(chat_id),
            Some(LocalHistoryRepairWindow {
                from_server_seq: 3,
                through_server_seq: 6,
            })
        );

        let summary = restored.get_local_chat_list_item(chat_id, None).unwrap();
        assert!(summary.history_recovery_pending);
        assert_eq!(summary.history_recovery_from_server_seq, Some(3));
        assert_eq!(summary.history_recovery_through_server_seq, Some(6));

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn encrypted_local_history_store_persists_attachment_refs() {
        let database_path =
            env::temp_dir().join(format!("trix-history-attachments-{}.db", Uuid::new_v4()));
        let database_key = vec![6u8; 32];
        let attachment = AttachmentMessageBody {
            blob_id: "blob-1".to_owned(),
            mime_type: "text/plain".to_owned(),
            size_bytes: 7,
            sha256: vec![1, 2, 3, 4],
            file_name: Some("note.txt".to_owned()),
            width_px: None,
            height_px: None,
            file_key: vec![9u8; 32],
            nonce: vec![7u8; 24],
        };
        let mut store =
            LocalHistoryStore::new_encrypted(&database_path, database_key.clone()).unwrap();

        store
            .persist_attachment_ref(
                "attachment-ref-1".to_owned(),
                "fingerprint-1".to_owned(),
                attachment.clone(),
                42,
            )
            .unwrap();

        let restored = LocalHistoryStore::new_encrypted(&database_path, database_key).unwrap();
        assert_eq!(
            restored.attachment_ref("attachment-ref-1"),
            Some(attachment)
        );
        assert_eq!(
            restored.attachment_ref_for_fingerprint("fingerprint-1"),
            Some("attachment-ref-1".to_owned())
        );

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn encrypted_local_history_store_rejects_wrong_key() {
        let database_path =
            env::temp_dir().join(format!("trix-history-wrong-key-{}.db", Uuid::new_v4()));
        LocalHistoryStore::new_encrypted(&database_path, vec![1u8; 32]).unwrap();

        let error = LocalHistoryStore::new_encrypted(&database_path, vec![2u8; 32]).unwrap_err();
        assert!(
            error.to_string().contains("database key rejected")
                || error.to_string().contains("corrupted")
        );

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn local_history_store_persists_outbox_messages() {
        let database_path =
            env::temp_dir().join(format!("trix-history-outbox-{}.db", Uuid::new_v4()));
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
        store.mark_outbox_failure(message_id, "offline").unwrap();

        let restored = LocalHistoryStore::new_encrypted(&database_path, vec![5u8; 32]).unwrap();
        let queued = restored.list_outbox_messages(Some(chat_id));
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].message_id, message_id);
        assert_eq!(queued[0].status, LocalOutboxStatus::Failed);
        assert_eq!(queued[0].failure_message.as_deref(), Some("offline"));

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn local_history_store_persists_message_repair_mailbox_entries_across_sqlite_reload() {
        let database_path =
            env::temp_dir().join(format!("trix-history-mailbox-{}.db", Uuid::new_v4()));
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());
        let message_id = MessageId(Uuid::new_v4());
        let mut store = LocalHistoryStore::new_persistent(&database_path).unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id,
                    chat_id,
                    server_seq: 1,
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(b"broken"),
                    aad_json: json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap();
        store
            .set_message_repair_mailbox_entry(
                chat_id,
                1,
                LocalMessageRepairMailboxEntry {
                    request_id: "repair-req-persisted".to_owned(),
                    message_id,
                    ciphertext_sha256_b64: crate::encode_b64(b"hash"),
                    witness_account_id: sender_account_id,
                    witness_device_id: sender_device_id,
                    unavailable_reason: Some("temporarily_unavailable".to_owned()),
                    status: LocalMessageRepairMailboxStatus::WitnessUnavailable,
                    updated_at_unix: current_unix_seconds_for_mailbox_retry(),
                    expires_at_unix: 0,
                },
            )
            .unwrap();

        let restored = LocalHistoryStore::new_persistent(&database_path).unwrap();
        let chat = restored
            .state
            .chats
            .get(&chat_id.0.to_string())
            .expect("chat should survive reload");
        let mailbox_entry = chat
            .message_repair_mailbox
            .get(&1)
            .expect("mailbox entry should survive reload");
        assert_eq!(mailbox_entry.request_id, "repair-req-persisted");
        assert_eq!(
            mailbox_entry.status,
            PersistedMessageRepairMailboxStatus::WitnessUnavailable
        );

        let candidates = restored.message_repair_witness_candidates_in_window(
            chat_id,
            LocalHistoryRepairWindow {
                from_server_seq: 1,
                through_server_seq: 1,
            },
        );
        assert!(
            candidates.is_empty(),
            "persisted unavailable mailbox entry should preserve retry backoff after restart"
        );

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
                    is_active: true,
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
                    pending_history_repair_from_server_seq: None,
                    pending_history_repair_through_server_seq: None,
                    message_repair_mailbox: BTreeMap::new(),
                },
            )]),
            attachment_refs: BTreeMap::new(),
            attachment_ref_index: BTreeMap::new(),
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
    fn local_history_store_deduplicates_direct_messages_on_load() {
        let database_path =
            env::temp_dir().join(format!("trix-history-dm-dedupe-{}.db", Uuid::new_v4()));
        let self_account_id = AccountId(Uuid::new_v4());
        let peer_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let older_chat_id = ChatId(Uuid::new_v4());
        let newer_chat_id = ChatId(Uuid::new_v4());

        let duplicate_dm_state = PersistedLocalHistoryState {
            version: 1,
            chats: BTreeMap::from([
                (
                    older_chat_id.0.to_string(),
                    PersistedChatState {
                        is_active: true,
                        chat_type: ChatType::Dm,
                        title: None,
                        last_server_seq: 2,
                        pending_message_count: 0,
                        last_message: None,
                        epoch: 1,
                        last_commit_message_id: None,
                        participant_profiles: vec![
                            ChatParticipantProfileSummary {
                                account_id: self_account_id,
                                handle: Some("alice".to_owned()),
                                profile_name: "Alice".to_owned(),
                                profile_bio: None,
                            },
                            ChatParticipantProfileSummary {
                                account_id: peer_account_id,
                                handle: Some("bob".to_owned()),
                                profile_name: "Bob".to_owned(),
                                profile_bio: None,
                            },
                        ],
                        members: Vec::new(),
                        device_members: Vec::new(),
                        mls_group_id_b64: None,
                        messages: BTreeMap::new(),
                        read_cursor_server_seq: 1,
                        projected_cursor_server_seq: 1,
                        projected_messages: BTreeMap::new(),
                        pending_history_repair_from_server_seq: None,
                        pending_history_repair_through_server_seq: None,
                        message_repair_mailbox: BTreeMap::new(),
                    },
                ),
                (
                    newer_chat_id.0.to_string(),
                    PersistedChatState {
                        is_active: true,
                        chat_type: ChatType::Dm,
                        title: None,
                        last_server_seq: 5,
                        pending_message_count: 0,
                        last_message: None,
                        epoch: 3,
                        last_commit_message_id: None,
                        participant_profiles: vec![
                            ChatParticipantProfileSummary {
                                account_id: self_account_id,
                                handle: Some("alice".to_owned()),
                                profile_name: "Alice".to_owned(),
                                profile_bio: None,
                            },
                            ChatParticipantProfileSummary {
                                account_id: peer_account_id,
                                handle: Some("bob".to_owned()),
                                profile_name: "Bob".to_owned(),
                                profile_bio: None,
                            },
                        ],
                        members: Vec::new(),
                        device_members: Vec::new(),
                        mls_group_id_b64: None,
                        messages: BTreeMap::new(),
                        read_cursor_server_seq: 4,
                        projected_cursor_server_seq: 4,
                        projected_messages: BTreeMap::new(),
                        pending_history_repair_from_server_seq: None,
                        pending_history_repair_through_server_seq: None,
                        message_repair_mailbox: BTreeMap::new(),
                    },
                ),
            ]),
            attachment_refs: BTreeMap::new(),
            attachment_ref_index: BTreeMap::new(),
            outbox: BTreeMap::from([
                (
                    MessageId(Uuid::new_v4()).0.to_string(),
                    LocalOutboxMessage {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id: older_chat_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        payload: LocalOutboxPayload::Body {
                            body: MessageBody::Text(crate::TextMessageBody {
                                text: "older".to_owned(),
                            }),
                        },
                        queued_at_unix: 10,
                        status: LocalOutboxStatus::Pending,
                        failure_message: None,
                        prepared_send: None,
                    },
                ),
                (
                    MessageId(Uuid::new_v4()).0.to_string(),
                    LocalOutboxMessage {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id: newer_chat_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        payload: LocalOutboxPayload::Body {
                            body: MessageBody::Text(crate::TextMessageBody {
                                text: "newer".to_owned(),
                            }),
                        },
                        queued_at_unix: 11,
                        status: LocalOutboxStatus::Pending,
                        failure_message: None,
                        prepared_send: None,
                    },
                ),
            ]),
        };

        save_state_to_path(&database_path, None, &duplicate_dm_state).unwrap();

        let restored = LocalHistoryStore::new_persistent(&database_path).unwrap();
        let chats = restored.list_chats();
        assert_eq!(chats.len(), 1);
        assert_eq!(chats[0].chat_id, newer_chat_id);
        assert!(restored.get_chat(older_chat_id).is_none());
        assert_eq!(
            restored
                .list_outbox_messages(None)
                .into_iter()
                .map(|message| message.chat_id)
                .collect::<Vec<_>>(),
            vec![newer_chat_id]
        );

        cleanup_sqlite_test_path(&database_path);
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
    fn project_chat_messages_restores_projection_state_when_save_fails() {
        let database_path = env::temp_dir().join(format!(
            "trix-history-project-rollback-{}.db",
            Uuid::new_v4()
        ));
        let mut store = LocalHistoryStore::new_persistent(&database_path).unwrap();
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
            .create_application_message(&mut alice_group, b"projection rollback")
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
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();

        store.inject_save_failure_after(0);
        let error = store
            .project_chat_messages(chat_id, &bob, &mut bob_group, None)
            .unwrap_err();
        let error_text = error.to_string();
        assert!(error_text.contains("injected local history save failure"));
        assert_eq!(store.projected_cursor(chat_id), Some(0));
        assert!(
            store
                .get_projected_messages(chat_id, None, Some(10))
                .is_empty()
        );

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn encrypted_local_history_store_retains_materialized_body_across_restart() {
        let database_path =
            env::temp_dir().join(format!("trix-history-materialized-{}.db", Uuid::new_v4()));
        let database_key = vec![8u8; 32];
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let mut store =
            LocalHistoryStore::new_encrypted(&database_path, database_key.clone()).unwrap();

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
            .create_application_message(&mut alice_group, b"persisted encrypted body")
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

        store
            .project_chat_messages(chat_id, &bob, &mut bob_group, None)
            .unwrap();
        drop(store);

        let restored = LocalHistoryStore::new_encrypted(&database_path, database_key).unwrap();
        let timeline = restored.get_local_timeline_items(chat_id, None, None, Some(10));
        assert_eq!(timeline.len(), 1);
        assert_eq!(
            timeline[0].body.as_ref().and_then(|body| match body {
                MessageBody::Text(body) => Some(body.text.as_str()),
                _ => None,
            }),
            Some("persisted encrypted body")
        );

        cleanup_sqlite_test_path(&database_path);
    }

    #[test]
    fn project_chat_with_facade_best_effort_recovers_legacy_unmaterialized_application_message() {
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
        let bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let message_id = MessageId(Uuid::new_v4());
        let ciphertext = alice
            .create_application_message(&mut alice_group, b"legacy repaired body")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id,
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
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();
        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.insert(
                1,
                PersistedProjectedMessage {
                    server_seq: 1,
                    message_id,
                    sender_account_id: alice_account,
                    sender_device_id: alice_device,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: None,
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 10,
                },
            );
            chat.projected_cursor_server_seq = 1;
        }

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 0);
        assert_eq!(store.projected_cursor(chat_id), Some(1));

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 1);
        assert_eq!(
            projected[0].payload.as_deref(),
            Some(b"legacy repaired body".as_slice())
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
    fn set_chat_read_cursor_none_defaults_to_projected_cursor() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Chat".to_owned()),
                    last_server_seq: 3,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
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
                        sender_account_id: self_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Text(crate::TextMessageBody {
                                text: "one".to_owned(),
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 1,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: self_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Text(crate::TextMessageBody {
                                text: "two".to_owned(),
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 2,
                    },
                    LocalProjectedMessage {
                        server_seq: 3,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: self_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Text(crate::TextMessageBody {
                                text: "three".to_owned(),
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

        let read_state = store
            .set_chat_read_cursor(chat_id, None, Some(self_account_id))
            .unwrap();

        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_eq!(read_state.read_cursor_server_seq, 3);
        assert_eq!(store.chat_read_cursor(chat_id), Some(3));
    }

    #[test]
    fn apply_projected_messages_reports_none_when_cursor_does_not_move() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        let projected_messages = vec![
            LocalProjectedMessage {
                server_seq: 1,
                message_id: MessageId(Uuid::new_v4()),
                sender_account_id,
                sender_device_id,
                epoch: 1,
                message_kind: MessageKind::Application,
                content_type: ContentType::Text,
                projection_kind: LocalProjectionKind::ApplicationMessage,
                payload: Some(
                    MessageBody::Text(crate::TextMessageBody {
                        text: "one".to_owned(),
                    })
                    .to_bytes()
                    .unwrap(),
                ),
                merged_epoch: None,
                created_at_unix: 1,
            },
            LocalProjectedMessage {
                server_seq: 2,
                message_id: MessageId(Uuid::new_v4()),
                sender_account_id,
                sender_device_id,
                epoch: 1,
                message_kind: MessageKind::Application,
                content_type: ContentType::Text,
                projection_kind: LocalProjectionKind::ApplicationMessage,
                payload: Some(
                    MessageBody::Text(crate::TextMessageBody {
                        text: "two".to_owned(),
                    })
                    .to_bytes()
                    .unwrap(),
                ),
                merged_epoch: None,
                created_at_unix: 2,
            },
            LocalProjectedMessage {
                server_seq: 3,
                message_id: MessageId(Uuid::new_v4()),
                sender_account_id,
                sender_device_id,
                epoch: 1,
                message_kind: MessageKind::Application,
                content_type: ContentType::Text,
                projection_kind: LocalProjectionKind::ApplicationMessage,
                payload: Some(
                    MessageBody::Text(crate::TextMessageBody {
                        text: "three".to_owned(),
                    })
                    .to_bytes()
                    .unwrap(),
                ),
                merged_epoch: None,
                created_at_unix: 3,
            },
        ];

        store.state.chats.insert(
            chat_id.0.to_string(),
            PersistedChatState {
                is_active: true,
                chat_type: ChatType::Dm,
                title: Some("Chat".to_owned()),
                last_server_seq: 3,
                pending_message_count: 0,
                last_message: None,
                epoch: 1,
                last_commit_message_id: None,
                participant_profiles: Vec::new(),
                members: Vec::new(),
                device_members: Vec::new(),
                mls_group_id_b64: None,
                messages: BTreeMap::new(),
                read_cursor_server_seq: 0,
                projected_cursor_server_seq: 3,
                projected_messages: projected_messages
                    .iter()
                    .cloned()
                    .map(persisted_projected_message_from)
                    .map(|message| (message.server_seq, message))
                    .collect(),
                pending_history_repair_from_server_seq: None,
                pending_history_repair_through_server_seq: None,
                message_repair_mailbox: BTreeMap::new(),
            },
        );

        let report = store
            .apply_projected_messages(chat_id, &projected_messages)
            .unwrap();

        assert_eq!(report.projected_messages_upserted, 0);
        assert_eq!(report.advanced_to_server_seq, None);
        assert_eq!(store.projected_cursor(chat_id), Some(3));
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
    fn apply_inbox_items_decrements_pending_message_count_for_delivered_messages() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());
        let first_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            chat_id,
            server_seq: 1,
            sender_account_id,
            sender_device_id,
            epoch: 1,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: crate::encode_b64(b"hello one"),
            aad_json: json!({}),
            created_at_unix: 1,
        };
        let second_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            server_seq: 2,
            created_at_unix: 2,
            ciphertext_b64: crate::encode_b64(b"hello two"),
            ..first_message.clone()
        };

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: None,
                    last_server_seq: 2,
                    epoch: 1,
                    pending_message_count: 2,
                    last_message: Some(second_message.clone()),
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();

        let report = store
            .apply_inbox_items(&[
                InboxItem {
                    inbox_id: 1,
                    message: first_message,
                },
                InboxItem {
                    inbox_id: 2,
                    message: second_message,
                },
            ])
            .unwrap();

        assert!(report.changed_chat_ids.contains(&chat_id));
        assert_eq!(store.get_chat(chat_id).unwrap().pending_message_count, 0);
    }

    #[test]
    fn chat_lists_sort_by_recent_activity_before_server_seq() {
        let mut store = LocalHistoryStore::new();
        let self_account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());
        let older_chat_id = ChatId(Uuid::new_v4());
        let newer_chat_id = ChatId(Uuid::new_v4());

        let older_last_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            chat_id: older_chat_id,
            server_seq: 8,
            sender_account_id: AccountId(Uuid::new_v4()),
            sender_device_id: device_id,
            epoch: 1,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: "YQ==".to_owned(),
            aad_json: json!({}),
            created_at_unix: 10,
        };
        let newer_last_message = MessageEnvelope {
            message_id: MessageId(Uuid::new_v4()),
            chat_id: newer_chat_id,
            server_seq: 1,
            sender_account_id: AccountId(Uuid::new_v4()),
            sender_device_id: device_id,
            epoch: 1,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: "Yg==".to_owned(),
            aad_json: json!({}),
            created_at_unix: 20,
        };

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![
                    ChatSummary {
                        chat_id: older_chat_id,
                        chat_type: ChatType::Dm,
                        title: Some("Older".to_owned()),
                        last_server_seq: 8,
                        epoch: 1,
                        pending_message_count: 0,
                        last_message: Some(older_last_message),
                        participant_profiles: Vec::new(),
                    },
                    ChatSummary {
                        chat_id: newer_chat_id,
                        chat_type: ChatType::Dm,
                        title: Some("Newer".to_owned()),
                        last_server_seq: 1,
                        epoch: 1,
                        pending_message_count: 0,
                        last_message: Some(newer_last_message),
                        participant_profiles: Vec::new(),
                    },
                ],
            })
            .unwrap();

        let summary_order = store
            .list_chats()
            .into_iter()
            .map(|chat| chat.chat_id)
            .collect::<Vec<_>>();
        assert_eq!(summary_order, vec![newer_chat_id, older_chat_id]);

        let local_order = store
            .list_local_chat_list_items(Some(self_account_id))
            .into_iter()
            .map(|chat| chat.chat_id)
            .collect::<Vec<_>>();
        assert_eq!(local_order, vec![newer_chat_id, older_chat_id]);
    }

    #[test]
    fn local_chat_list_preview_ignores_receipt_messages() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let other_device_id = DeviceId(Uuid::new_v4());
        let first_message_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: None,
                    last_server_seq: 2,
                    epoch: 1,
                    pending_message_count: 0,
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
                        message_id: first_message_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"hello".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 10,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: MessageId(Uuid::new_v4()),
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Receipt,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Receipt(crate::ReceiptMessageBody {
                                target_message_id: first_message_id,
                                receipt_type: crate::ReceiptType::Read,
                                at_unix: Some(20),
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
        assert_eq!(item.preview_text.as_deref(), Some("hello"));
        assert_eq!(item.preview_is_outgoing, Some(true));
        assert_eq!(item.preview_server_seq, Some(1));
        assert_eq!(item.preview_created_at_unix, Some(10));
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

    #[test]
    fn local_timeline_items_mark_confirmed_outgoing_messages_delivered() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let other_device_id = DeviceId(Uuid::new_v4());
        let outgoing_message_id = MessageId(Uuid::new_v4());
        let incoming_message_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: None,
                    last_server_seq: 2,
                    epoch: 1,
                    pending_message_count: 0,
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
                &[
                    LocalProjectedMessage {
                        server_seq: 1,
                        message_id: outgoing_message_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"hello".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 1,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: incoming_message_id,
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"hi".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 2,
                    },
                ],
            )
            .unwrap();

        let timeline = store.get_local_timeline_items(chat_id, Some(self_account_id), None, None);
        let outgoing = timeline
            .iter()
            .find(|item| item.message_id == outgoing_message_id)
            .unwrap();
        let incoming = timeline
            .iter()
            .find(|item| item.message_id == incoming_message_id)
            .unwrap();

        assert_eq!(outgoing.receipt_status, Some(crate::ReceiptType::Delivered));
        assert_eq!(incoming.receipt_status, None);
    }

    #[test]
    fn local_timeline_items_ignore_self_receipts_for_read_status() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let other_device_id = DeviceId(Uuid::new_v4());
        let target_message_id = MessageId(Uuid::new_v4());
        let self_read_receipt_id = MessageId(Uuid::new_v4());
        let other_read_receipt_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Group,
                    title: Some("Receipts".to_owned()),
                    last_server_seq: 3,
                    epoch: 1,
                    pending_message_count: 0,
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
                &[
                    LocalProjectedMessage {
                        server_seq: 1,
                        message_id: target_message_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"hello".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 1,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: self_read_receipt_id,
                        sender_account_id: self_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Receipt,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Receipt(crate::ReceiptMessageBody {
                                target_message_id,
                                receipt_type: crate::ReceiptType::Read,
                                at_unix: Some(2),
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 2,
                    },
                ],
            )
            .unwrap();

        let timeline = store.get_local_timeline_items(chat_id, Some(self_account_id), None, None);
        let target = timeline
            .iter()
            .find(|item| item.message_id == target_message_id)
            .unwrap();
        assert_eq!(target.receipt_status, Some(crate::ReceiptType::Delivered));

        store
            .apply_projected_messages(
                chat_id,
                &[LocalProjectedMessage {
                    server_seq: 3,
                    message_id: other_read_receipt_id,
                    sender_account_id: other_account_id,
                    sender_device_id: other_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Receipt,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    payload: Some(
                        MessageBody::Receipt(crate::ReceiptMessageBody {
                            target_message_id,
                            receipt_type: crate::ReceiptType::Read,
                            at_unix: Some(3),
                        })
                        .to_bytes()
                        .unwrap(),
                    ),
                    merged_epoch: None,
                    created_at_unix: 3,
                }],
            )
            .unwrap();

        let timeline_with_other_reader =
            store.get_local_timeline_items(chat_id, Some(self_account_id), None, None);
        let upgraded_target = timeline_with_other_reader
            .iter()
            .find(|item| item.message_id == target_message_id)
            .unwrap();
        assert_eq!(
            upgraded_target.receipt_status,
            Some(crate::ReceiptType::Read)
        );
    }

    #[test]
    fn local_timeline_items_merge_receipts_and_reactions_into_message_decorations() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let other_account_id = AccountId(Uuid::new_v4());
        let third_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let other_device_id = DeviceId(Uuid::new_v4());
        let third_device_id = DeviceId(Uuid::new_v4());
        let target_message_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Group,
                    title: Some("Decorations".to_owned()),
                    last_server_seq: 7,
                    epoch: 1,
                    pending_message_count: 0,
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
                        ChatParticipantProfileSummary {
                            account_id: third_account_id,
                            handle: Some("bob".to_owned()),
                            profile_name: "Bob".to_owned(),
                            profile_bio: None,
                        },
                    ],
                }],
            })
            .unwrap();

        let delivered_receipt_id = MessageId(Uuid::new_v4());
        let read_receipt_id = MessageId(Uuid::new_v4());
        let other_reaction_id = MessageId(Uuid::new_v4());
        let self_reaction_id = MessageId(Uuid::new_v4());
        let removed_reaction_id = MessageId(Uuid::new_v4());
        let third_reaction_id = MessageId(Uuid::new_v4());

        store
            .apply_projected_messages(
                chat_id,
                &[
                    LocalProjectedMessage {
                        server_seq: 1,
                        message_id: target_message_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(b"hello".to_vec()),
                        merged_epoch: None,
                        created_at_unix: 1,
                    },
                    LocalProjectedMessage {
                        server_seq: 2,
                        message_id: delivered_receipt_id,
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Receipt,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Receipt(crate::ReceiptMessageBody {
                                target_message_id,
                                receipt_type: crate::ReceiptType::Delivered,
                                at_unix: Some(2),
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 2,
                    },
                    LocalProjectedMessage {
                        server_seq: 3,
                        message_id: read_receipt_id,
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Receipt,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Receipt(crate::ReceiptMessageBody {
                                target_message_id,
                                receipt_type: crate::ReceiptType::Read,
                                at_unix: Some(3),
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 3,
                    },
                    LocalProjectedMessage {
                        server_seq: 4,
                        message_id: other_reaction_id,
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Reaction,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Reaction(crate::ReactionMessageBody {
                                target_message_id,
                                emoji: "👍".to_owned(),
                                action: crate::ReactionAction::Add,
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 4,
                    },
                    LocalProjectedMessage {
                        server_seq: 5,
                        message_id: self_reaction_id,
                        sender_account_id: self_account_id,
                        sender_device_id: self_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Reaction,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Reaction(crate::ReactionMessageBody {
                                target_message_id,
                                emoji: "👍".to_owned(),
                                action: crate::ReactionAction::Add,
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 5,
                    },
                    LocalProjectedMessage {
                        server_seq: 6,
                        message_id: removed_reaction_id,
                        sender_account_id: other_account_id,
                        sender_device_id: other_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Reaction,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Reaction(crate::ReactionMessageBody {
                                target_message_id,
                                emoji: "👍".to_owned(),
                                action: crate::ReactionAction::Remove,
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 6,
                    },
                    LocalProjectedMessage {
                        server_seq: 7,
                        message_id: third_reaction_id,
                        sender_account_id: third_account_id,
                        sender_device_id: third_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Reaction,
                        projection_kind: LocalProjectionKind::ApplicationMessage,
                        payload: Some(
                            MessageBody::Reaction(crate::ReactionMessageBody {
                                target_message_id,
                                emoji: "🔥".to_owned(),
                                action: crate::ReactionAction::Add,
                            })
                            .to_bytes()
                            .unwrap(),
                        ),
                        merged_epoch: None,
                        created_at_unix: 7,
                    },
                ],
            )
            .unwrap();

        let timeline = store.get_local_timeline_items(chat_id, Some(self_account_id), None, None);

        let target = timeline
            .iter()
            .find(|item| item.message_id == target_message_id)
            .unwrap();
        assert!(target.is_visible_in_timeline);
        assert_eq!(target.receipt_status, Some(crate::ReceiptType::Read));
        assert_eq!(target.reactions.len(), 2);

        let thumbs_up = target
            .reactions
            .iter()
            .find(|reaction| reaction.emoji == "👍")
            .unwrap();
        assert_eq!(thumbs_up.count, 1);
        assert!(thumbs_up.includes_self);
        assert_eq!(thumbs_up.reactor_account_ids, vec![self_account_id]);

        let fire = target
            .reactions
            .iter()
            .find(|reaction| reaction.emoji == "🔥")
            .unwrap();
        assert_eq!(fire.count, 1);
        assert!(!fire.includes_self);
        assert_eq!(fire.reactor_account_ids, vec![third_account_id]);

        for hidden_id in [
            delivered_receipt_id,
            read_receipt_id,
            other_reaction_id,
            self_reaction_id,
            removed_reaction_id,
            third_reaction_id,
        ] {
            let item = timeline
                .iter()
                .find(|item| item.message_id == hidden_id)
                .unwrap();
            assert!(!item.is_visible_in_timeline);
        }
    }

    #[test]
    fn project_chat_with_facade_applies_welcome_bootstrap_projections_for_existing_group() {
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
        let bob_group = bob
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
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(3));
        assert_eq!(store.projected_cursor(chat_id), Some(3));

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 3);
        assert_eq!(projected[0].server_seq, 1);
        assert_eq!(
            projected[0].projection_kind,
            LocalProjectionKind::CommitMerged
        );
        assert_eq!(projected[1].server_seq, 2);
        assert_eq!(
            projected[1].projection_kind,
            LocalProjectionKind::WelcomeRef
        );
        assert_eq!(projected[2].server_seq, 3);
        assert_eq!(
            projected[2].projection_kind,
            LocalProjectionKind::ApplicationMessage
        );
        assert_eq!(
            projected[2].payload.as_deref(),
            Some(b"hello from alice".as_slice())
        );
    }

    #[test]
    fn project_chat_with_facade_loads_deterministic_group_when_mapping_is_missing() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new_persistent(
            b"bob-device".to_vec(),
            env::temp_dir().join(format!("trix-storage-deterministic-{}", Uuid::new_v4())),
        )
        .unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let bob_group = bob
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
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(3));
        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(bob_group.group_id().as_slice())
        );

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 3);
        assert_eq!(
            projected[2].payload.as_deref(),
            Some(b"hello from alice".as_slice())
        );

        fs::remove_dir_all(
            bob.storage_root()
                .expect("persistent bob facade should expose storage root"),
        )
        .ok();
    }

    #[test]
    fn project_chat_with_facade_recovers_persisted_group_when_mapping_is_missing() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-orphan-group-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        // Persist an unrelated group first so recovery has to validate candidate groups
        // against the chat transcript instead of picking the first one it can load.
        bob.create_group(b"unrelated-group").unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();
        assert_ne!(bob_group.group_id(), chat_id.0.as_bytes());

        let ciphertext = alice
            .create_application_message(&mut alice_group, b"hello from alice")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(3));
        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(bob_group.group_id().as_slice())
        );

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 3);
        assert_eq!(
            projected[2].payload.as_deref(),
            Some(b"hello from alice".as_slice())
        );

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn project_chat_with_facade_recovers_when_persisted_mapping_points_to_wrong_group() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-stale-group-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let unrelated_group = bob.create_group(b"stale-group-id").unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();
        assert_ne!(unrelated_group.group_id(), bob_group.group_id());

        let ciphertext = alice
            .create_application_message(&mut alice_group, b"hello from alice")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &unrelated_group.group_id())
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(3));
        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(bob_group.group_id().as_slice())
        );

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 3);
        assert_eq!(
            projected[2].payload.as_deref(),
            Some(b"hello from alice".as_slice())
        );

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn load_or_bootstrap_chat_mls_conversation_prefers_welcome_over_unrelated_persisted_group() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-welcome-first-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let unrelated_group = bob.create_group(b"unrelated-group").unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                ],
            })
            .unwrap();

        let conversation = store
            .load_or_bootstrap_chat_mls_conversation(chat_id, &bob)
            .unwrap()
            .unwrap();
        assert_ne!(conversation.group_id(), unrelated_group.group_id());
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(conversation.group_id().as_slice())
        );

        let ciphertext = alice
            .create_application_message(&mut alice_group, b"hello from alice")
            .unwrap();
        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id: MessageId(Uuid::new_v4()),
                    chat_id,
                    server_seq: 3,
                    sender_account_id: alice_account,
                    sender_device_id: alice_device,
                    epoch: add_bundle.epoch,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(&ciphertext),
                    aad_json: json!({}),
                    created_at_unix: 3,
                }],
            })
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(3));
        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_eq!(
            store
                .get_projected_messages(chat_id, None, Some(10))
                .last()
                .and_then(|message| message.payload.clone()),
            Some(b"hello from alice".to_vec())
        );

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn project_chat_with_facade_bootstraps_from_welcome_when_stale_mapping_has_no_real_group() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-welcome-repair-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let unrelated_group = bob.create_group(b"stale-group-id").unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let ciphertext = alice
            .create_application_message(&mut alice_group, b"hello from alice")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &unrelated_group.group_id())
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 1);
        assert_eq!(report.projected_messages_upserted, 1);
        assert_eq!(report.advanced_to_server_seq, Some(3));
        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert_ne!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(unrelated_group.group_id().as_slice())
        );
        assert_eq!(
            store
                .get_projected_messages(chat_id, None, Some(10))
                .last()
                .and_then(|message| message.payload.clone()),
            Some(b"hello from alice".to_vec())
        );

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn project_chat_with_facade_tolerates_unreadable_own_application_replay() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let bob_account = AccountId(Uuid::new_v4());
        let bob_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-own-replay-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();
        assert_ne!(bob_group.group_id(), chat_id.0.as_bytes());

        let first_bob_ciphertext = bob
            .create_application_message(&mut bob_group, b"hello from bob")
            .unwrap();
        let second_bob_ciphertext = bob
            .create_application_message(&mut bob_group, b"second hello from bob")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: bob_account,
                        sender_device_id: bob_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&first_bob_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 4,
                        sender_account_id: bob_account,
                        sender_device_id: bob_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&second_bob_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 4,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 2);
        assert_eq!(report.projected_messages_upserted, 2);
        assert_eq!(report.advanced_to_server_seq, Some(4));
        assert_eq!(store.projected_cursor(chat_id), Some(4));
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(bob_group.group_id().as_slice())
        );

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 4);
        assert_eq!(projected[2].server_seq, 3);
        assert_eq!(projected[2].payload, None);
        assert_eq!(projected[3].server_seq, 4);
        assert_eq!(projected[3].payload, None);

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn project_chat_with_facade_for_device_rejects_unreadable_current_device_replay() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let bob_account = AccountId(Uuid::new_v4());
        let bob_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root = env::temp_dir().join(format!(
            "trix-storage-own-replay-current-{}",
            Uuid::new_v4()
        ));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let first_bob_ciphertext = bob
            .create_application_message(&mut bob_group, b"hello from bob")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: bob_account,
                        sender_device_id: bob_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&first_bob_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();

        let error = store
            .project_chat_with_facade_for_device(chat_id, &bob, None, Some(bob_device))
            .unwrap_err();
        assert!(error.to_string().contains("would discard its durable body"));
        assert_eq!(store.projected_cursor(chat_id), Some(0));
        assert!(
            store
                .get_projected_messages(chat_id, None, Some(10))
                .is_empty()
        );
        assert!(!store.chats_with_unavailable_messages().contains(&chat_id));

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn legacy_projection_repair_preserves_materialized_tail_for_own_messages() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let bob_account = AccountId(Uuid::new_v4());
        let bob_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-own-tail-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let first_bob_ciphertext = bob
            .create_application_message(&mut bob_group, b"hello from bob")
            .unwrap();
        let second_bob_ciphertext = bob
            .create_application_message(&mut bob_group, b"second hello from bob")
            .unwrap();
        let first_message_id = MessageId(Uuid::new_v4());
        let second_message_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: first_message_id,
                        chat_id,
                        server_seq: 3,
                        sender_account_id: bob_account,
                        sender_device_id: bob_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&first_bob_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                    MessageEnvelope {
                        message_id: second_message_id,
                        chat_id,
                        server_seq: 4,
                        sender_account_id: bob_account,
                        sender_device_id: bob_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&second_bob_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 4,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();

        let second_body = MessageBody::Text(crate::TextMessageBody {
            text: "second hello from bob".to_owned(),
        });
        let second_body_b64 = crate::encode_b64(&second_body.to_bytes().unwrap());
        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.insert(
                3,
                PersistedProjectedMessage {
                    server_seq: 3,
                    message_id: first_message_id,
                    sender_account_id: bob_account,
                    sender_device_id: bob_device,
                    epoch: add_bundle.epoch,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: None,
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 3,
                },
            );
            chat.projected_messages.insert(
                4,
                PersistedProjectedMessage {
                    server_seq: 4,
                    message_id: second_message_id,
                    sender_account_id: bob_account,
                    sender_device_id: bob_device,
                    epoch: add_bundle.epoch,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: Some(second_body_b64.clone()),
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 4,
                },
            );
            chat.projected_cursor_server_seq = 4;
        }

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.advanced_to_server_seq, Some(4));

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 4);
        assert_eq!(projected[2].server_seq, 3);
        assert_eq!(projected[2].payload, None);
        assert_eq!(projected[3].server_seq, 4);
        assert_eq!(
            projected[3].parse_body().unwrap(),
            Some(second_body.clone())
        );

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn local_timeline_items_use_unavailable_preview_for_unmaterialized_application_message() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Group,
                    title: Some("Group".to_owned()),
                    last_server_seq: 1,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: vec![ChatParticipantProfileSummary {
                        account_id: sender_account_id,
                        handle: Some("alice".to_owned()),
                        profile_name: "Alice".to_owned(),
                        profile_bio: None,
                    }],
                }],
            })
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id: MessageId(Uuid::new_v4()),
                    chat_id,
                    server_seq: 1,
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: "YQ==".to_owned(),
                    aad_json: json!({}),
                    created_at_unix: 10,
                }],
            })
            .unwrap();

        store
            .apply_projected_messages(
                chat_id,
                &[LocalProjectedMessage {
                    server_seq: 1,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    payload: None,
                    merged_epoch: None,
                    created_at_unix: 10,
                }],
            )
            .unwrap_err();

        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.insert(
                1,
                PersistedProjectedMessage {
                    server_seq: 1,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: None,
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 10,
                },
            );
            chat.projected_cursor_server_seq = 1;
        }

        let timeline = store.get_local_timeline_items(chat_id, None, None, None);
        assert_eq!(timeline.len(), 1);
        assert_eq!(
            timeline[0].preview_text,
            "Message content is unavailable on this device."
        );
        assert_eq!(timeline[0].body, None);
        assert_eq!(timeline[0].body_parse_error, None);
    }

    #[test]
    fn local_timeline_items_mark_pending_sibling_history_inside_pending_window() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Repair".to_owned()),
                    last_server_seq: 2,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();

        let materialized_body = MessageBody::Text(crate::TextMessageBody {
            text: "available".to_owned(),
        })
        .to_bytes()
        .unwrap();

        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.insert(
                1,
                PersistedProjectedMessage {
                    server_seq: 1,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: None,
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 10,
                },
            );
            chat.projected_messages.insert(
                2,
                PersistedProjectedMessage {
                    server_seq: 2,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: Some(crate::encode_b64(&materialized_body)),
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 11,
                },
            );
            chat.projected_cursor_server_seq = 2;
        }

        store
            .set_pending_history_repair_window(
                chat_id,
                LocalHistoryRepairWindow {
                    from_server_seq: 1,
                    through_server_seq: 1,
                },
            )
            .unwrap();

        let timeline = store.get_local_timeline_items(chat_id, None, None, Some(10));
        assert_eq!(timeline.len(), 2);
        assert_eq!(
            timeline[0].recovery_state,
            Some(LocalMessageRecoveryState::PendingSiblingHistory)
        );
        assert_eq!(timeline[1].recovery_state, None);
    }

    #[test]
    fn local_chat_list_item_marks_pending_history_for_pure_gap_without_placeholder_message() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());
        let body = MessageBody::Text(crate::TextMessageBody {
            text: "visible tail".to_owned(),
        })
        .to_bytes()
        .unwrap();

        store
            .apply_chat_list(&ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id,
                    chat_type: ChatType::Dm,
                    title: Some("Gap".to_owned()),
                    last_server_seq: 3,
                    epoch: 1,
                    pending_message_count: 0,
                    last_message: None,
                    participant_profiles: Vec::new(),
                }],
            })
            .unwrap();

        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.insert(
                3,
                PersistedProjectedMessage {
                    server_seq: 3,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: Some(crate::encode_b64(&body)),
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 10,
                },
            );
        }

        store
            .set_pending_history_repair_window(
                chat_id,
                LocalHistoryRepairWindow {
                    from_server_seq: 2,
                    through_server_seq: 2,
                },
            )
            .unwrap();

        let summary = store.get_local_chat_list_item(chat_id, None).unwrap();
        assert!(summary.history_recovery_pending);
        assert_eq!(summary.history_recovery_from_server_seq, Some(2));
        assert_eq!(summary.history_recovery_through_server_seq, Some(2));

        let timeline = store.get_local_timeline_items(chat_id, None, None, Some(10));
        assert_eq!(timeline.len(), 1);
        assert_eq!(timeline[0].server_seq, 3);
        assert_eq!(timeline[0].recovery_state, None);
    }

    #[test]
    fn refresh_pending_history_repair_window_keeps_unprojected_tail_gap() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(b"first"),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(b"second"),
                        aad_json: json!({}),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(b"third"),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                ],
            })
            .unwrap();

        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.insert(
                1,
                PersistedProjectedMessage {
                    server_seq: 1,
                    message_id: MessageId(Uuid::new_v4()),
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    projection_kind: LocalProjectionKind::ApplicationMessage,
                    materialized_body_b64: Some(crate::encode_b64(
                        &MessageBody::Text(crate::TextMessageBody {
                            text: "first".to_owned(),
                        })
                        .to_bytes()
                        .unwrap(),
                    )),
                    witness_repair: None,
                    merged_epoch: None,
                    created_at_unix: 1,
                },
            );
            chat.projected_cursor_server_seq = 1;
        }

        store
            .set_pending_history_repair_window(
                chat_id,
                LocalHistoryRepairWindow {
                    from_server_seq: 2,
                    through_server_seq: 2,
                },
            )
            .unwrap();

        let refreshed = store
            .refresh_pending_history_repair_window(chat_id)
            .unwrap();
        assert_eq!(
            refreshed,
            Some(LocalHistoryRepairWindow {
                from_server_seq: 2,
                through_server_seq: 3,
            })
        );
        assert_eq!(
            store.pending_history_repair_window(chat_id),
            Some(LocalHistoryRepairWindow {
                from_server_seq: 2,
                through_server_seq: 3,
            })
        );
    }

    #[test]
    fn unavailable_witness_mailbox_entry_does_not_block_future_history_repair_candidates() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());
        let message_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id,
                    chat_id,
                    server_seq: 1,
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(b"broken"),
                    aad_json: json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap();

        store
            .set_message_repair_mailbox_entry(
                chat_id,
                1,
                LocalMessageRepairMailboxEntry {
                    request_id: "repair-req-1".to_owned(),
                    message_id,
                    ciphertext_sha256_b64: crate::encode_b64(b"hash"),
                    witness_account_id: sender_account_id,
                    witness_device_id: sender_device_id,
                    unavailable_reason: Some("no_eligible_witness".to_owned()),
                    status: LocalMessageRepairMailboxStatus::WitnessUnavailable,
                    updated_at_unix: 42,
                    expires_at_unix: 0,
                },
            )
            .unwrap();

        assert_eq!(
            store.history_repair_candidate_after_projection_failure(chat_id),
            Some(LocalHistoryRepairCandidate {
                chat_id,
                window: LocalHistoryRepairWindow {
                    from_server_seq: 1,
                    through_server_seq: 1,
                },
                reason: LocalHistoryRepairReason::ProjectionFailure,
            })
        );
    }

    #[test]
    fn message_repair_witness_candidates_include_multiple_unresolved_messages() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(b"broken-1"),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id,
                        sender_device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(b"broken-2"),
                        aad_json: json!({}),
                        created_at_unix: 2,
                    },
                ],
            })
            .unwrap();

        let candidates = store.message_repair_witness_candidates_in_window(
            chat_id,
            LocalHistoryRepairWindow {
                from_server_seq: 1,
                through_server_seq: 2,
            },
        );
        assert_eq!(candidates.len(), 2);
        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.binding.server_seq)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
    }

    #[test]
    fn recent_unavailable_message_repair_mailbox_entry_delays_retry_candidates() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());
        let message_id = MessageId(Uuid::new_v4());

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id,
                    chat_id,
                    server_seq: 1,
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(b"broken"),
                    aad_json: json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap();

        store
            .set_message_repair_mailbox_entry(
                chat_id,
                1,
                LocalMessageRepairMailboxEntry {
                    request_id: "repair-req-recent".to_owned(),
                    message_id,
                    ciphertext_sha256_b64: crate::encode_b64(b"hash"),
                    witness_account_id: sender_account_id,
                    witness_device_id: sender_device_id,
                    unavailable_reason: Some("temporarily_unavailable".to_owned()),
                    status: LocalMessageRepairMailboxStatus::WitnessUnavailable,
                    updated_at_unix: current_unix_seconds_for_mailbox_retry(),
                    expires_at_unix: 0,
                },
            )
            .unwrap();

        let candidates = store.message_repair_witness_candidates_in_window(
            chat_id,
            LocalHistoryRepairWindow {
                from_server_seq: 1,
                through_server_seq: 1,
            },
        );
        assert!(candidates.is_empty());
    }

    #[test]
    fn expired_pending_witness_mailbox_entry_allows_retry_candidates_again() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let sender_account_id = AccountId(Uuid::new_v4());
        let sender_device_id = DeviceId(Uuid::new_v4());
        let message_id = MessageId(Uuid::new_v4());
        let now_unix = current_unix_seconds_for_mailbox_retry();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id,
                    chat_id,
                    server_seq: 1,
                    sender_account_id,
                    sender_device_id,
                    epoch: 1,
                    message_kind: MessageKind::Application,
                    content_type: ContentType::Text,
                    ciphertext_b64: crate::encode_b64(b"broken"),
                    aad_json: json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap();

        store
            .set_message_repair_mailbox_entry(
                chat_id,
                1,
                LocalMessageRepairMailboxEntry {
                    request_id: "repair-req-expired".to_owned(),
                    message_id,
                    ciphertext_sha256_b64: crate::encode_b64(b"hash"),
                    witness_account_id: sender_account_id,
                    witness_device_id: sender_device_id,
                    unavailable_reason: None,
                    status: LocalMessageRepairMailboxStatus::PendingWitness,
                    updated_at_unix: now_unix
                        .saturating_sub(MESSAGE_REPAIR_WITNESS_PENDING_TTL_SECONDS + 1),
                    expires_at_unix: now_unix.saturating_sub(1),
                },
            )
            .unwrap();

        assert_eq!(
            store.history_repair_candidate_after_projection_failure(chat_id),
            Some(LocalHistoryRepairCandidate {
                chat_id,
                window: LocalHistoryRepairWindow {
                    from_server_seq: 1,
                    through_server_seq: 1,
                },
                reason: LocalHistoryRepairReason::ProjectionFailure,
            })
        );

        let candidates = store.message_repair_witness_candidates_in_window(
            chat_id,
            LocalHistoryRepairWindow {
                from_server_seq: 1,
                through_server_seq: 1,
            },
        );
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].binding.server_seq, 1);
    }

    #[test]
    fn project_chat_with_facade_restores_materialized_tail_after_gap_repair_replay() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob_storage_root =
            env::temp_dir().join(format!("trix-storage-projection-gap-{}", Uuid::new_v4()));
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &bob_storage_root).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"server-generated-group-id").unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let first_ciphertext = alice
            .create_application_message(&mut alice_group, b"first")
            .unwrap();
        let second_ciphertext = alice
            .create_application_message(&mut alice_group, b"second")
            .unwrap();
        let third_ciphertext = alice
            .create_application_message(&mut alice_group, b"third")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&first_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 4,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&second_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 4,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 5,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&third_ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 5,
                    },
                ],
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, &bob_group.group_id())
            .unwrap();
        store.project_chat_with_facade(chat_id, &bob, None).unwrap();

        {
            let chat = store.state.chats.get_mut(&chat_id.0.to_string()).unwrap();
            chat.projected_messages.remove(&3);
        }

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.advanced_to_server_seq, Some(5));
        assert_eq!(store.projected_cursor(chat_id), Some(5));

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 5);
        assert_eq!(
            projected
                .iter()
                .map(|message| message.server_seq)
                .collect::<Vec<_>>(),
            vec![1, 2, 3, 4, 5]
        );
        assert_eq!(projected[2].payload, None);
        assert_eq!(projected[3].payload.as_deref(), Some(b"second".as_slice()));
        assert_eq!(projected[4].payload.as_deref(), Some(b"third".as_slice()));
        assert_eq!(
            store.pending_history_repair_window(chat_id),
            Some(LocalHistoryRepairWindow {
                from_server_seq: 3,
                through_server_seq: 5,
            })
        );

        fs::remove_dir_all(&bob_storage_root).ok();
    }

    #[test]
    fn project_chat_with_facade_bootstraps_from_older_welcome_when_latest_is_for_another_member() {
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();
        let charlie = MlsFacade::new(b"charlie-device".to_vec()).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let charlie_key_package = charlie.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();

        let add_bob_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let add_charlie_bundle = alice
            .add_members(&mut alice_group, &[charlie_key_package])
            .unwrap();
        let ciphertext = alice
            .create_application_message(&mut alice_group, b"hello after charlie joined")
            .unwrap();

        store
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 1,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bob_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_bob_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 1,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_bob_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_bob_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_bob_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 2,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 3,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_charlie_bundle.epoch,
                        message_kind: MessageKind::Commit,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(&add_charlie_bundle.commit_message),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 4,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_charlie_bundle.epoch,
                        message_kind: MessageKind::WelcomeRef,
                        content_type: ContentType::ChatEvent,
                        ciphertext_b64: crate::encode_b64(
                            add_charlie_bundle.welcome_message.as_ref().unwrap(),
                        ),
                        aad_json: json!({
                            "_trix": {
                                "ratchet_tree_b64": crate::encode_b64(
                                    add_charlie_bundle.ratchet_tree.as_ref().unwrap()
                                )
                            }
                        }),
                        created_at_unix: 4,
                    },
                    MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 5,
                        sender_account_id: alice_account,
                        sender_device_id: alice_device,
                        epoch: add_charlie_bundle.epoch,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(&ciphertext),
                        aad_json: json!({}),
                        created_at_unix: 5,
                    },
                ],
            })
            .unwrap();

        let report = store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(report.processed_messages, 3);
        assert_eq!(report.projected_messages_upserted, 3);
        assert_eq!(report.advanced_to_server_seq, Some(5));
        assert_eq!(store.projected_cursor(chat_id), Some(5));

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 5);
        assert_eq!(projected[0].server_seq, 1);
        assert_eq!(
            projected[0].projection_kind,
            LocalProjectionKind::CommitMerged
        );
        assert_eq!(projected[1].server_seq, 2);
        assert_eq!(
            projected[1].projection_kind,
            LocalProjectionKind::WelcomeRef
        );
        assert_eq!(projected[2].server_seq, 3);
        assert_eq!(
            projected[2].projection_kind,
            LocalProjectionKind::CommitMerged
        );
        assert_eq!(projected[3].server_seq, 4);
        assert_eq!(
            projected[3].projection_kind,
            LocalProjectionKind::WelcomeRef
        );
        assert_eq!(projected[4].server_seq, 5);
        assert_eq!(
            projected[4].projection_kind,
            LocalProjectionKind::ApplicationMessage
        );
        assert_eq!(
            projected[4].payload.as_deref(),
            Some(b"hello after charlie joined".as_slice())
        );
    }

    fn cleanup_sqlite_test_path(path: &Path) {
        fs::remove_file(path).ok();
        fs::remove_file(format!("{}-wal", path.display())).ok();
        fs::remove_file(format!("{}-shm", path.display())).ok();
    }

    #[test]
    fn tolerable_application_replay_errors_include_stale_generation() {
        assert!(is_tolerable_application_replay_error(&anyhow!(
            "Generation is too old to be processed."
        )));
        assert!(is_tolerable_application_replay_error(&anyhow!(
            "Cannot decrypt own messages"
        )));
        assert!(!is_tolerable_application_replay_error(&anyhow!(
            "some other MLS failure"
        )));
    }
}
