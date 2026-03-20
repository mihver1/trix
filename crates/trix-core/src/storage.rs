use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use trix_types::{
    ChatDetailResponse, ChatDeviceSummary, ChatHistoryResponse, ChatId, ChatListResponse,
    ChatMemberSummary, ChatParticipantProfileSummary, ChatSummary, ChatType, InboxItem,
    MessageEnvelope, MessageId,
};
use uuid::Uuid;

use crate::{MessageBody, MlsConversation, MlsFacade, MlsProcessResult, decode_b64_field};

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
}

impl SyncStateStore {
    pub fn new(state_path: impl Into<PathBuf>) -> Self {
        Self {
            state_path: state_path.into(),
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
pub struct LocalOutgoingMessageApplyOutcome {
    pub report: LocalStoreApplyReport,
    pub projected_message: LocalProjectedMessage,
}

#[derive(Debug, Clone)]
pub struct LocalHistoryStore {
    state: PersistedLocalHistoryState,
    database_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedLocalHistoryState {
    version: u32,
    chats: BTreeMap<String, PersistedChatState>,
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
        }
    }

    pub fn new_persistent(database_path: impl Into<PathBuf>) -> Result<Self> {
        let database_path = database_path.into();
        if database_path.exists() {
            Ok(Self {
                state: load_state_from_path(&database_path)?,
                database_path: Some(database_path),
            })
        } else {
            let store = Self {
                state: PersistedLocalHistoryState::default(),
                database_path: Some(database_path),
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
        save_state_to_path(database_path, &self.state)
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
                    pending_message_count: chat.pending_message_count,
                    last_message: chat.last_message.clone(),
                    epoch: 0,
                    last_commit_message_id: None,
                    participant_profiles: chat.participant_profiles.clone(),
                    members: Vec::new(),
                    device_members: Vec::new(),
                    mls_group_id_b64: None,
                    messages: BTreeMap::new(),
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

    fn persist_if_needed(&self, changed: bool) -> Result<()> {
        if changed {
            self.save_state()?;
        }
        Ok(())
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

fn save_state_to_path(path: &Path, state: &PersistedLocalHistoryState) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!(
                "failed to create local history directory {}",
                parent.display()
            )
        })?;
    }

    let tmp_path = path.with_extension("tmp");
    let output_file = File::create(&tmp_path).with_context(|| {
        format!(
            "failed to create temporary local history file {}",
            tmp_path.display()
        )
    })?;
    serde_json::to_writer_pretty(output_file, state).context("failed to write local history")?;
    fs::rename(&tmp_path, path)
        .with_context(|| format!("failed to replace local history file {}", path.display()))?;
    Ok(())
}

fn load_state_from_path(path: &Path) -> Result<PersistedLocalHistoryState> {
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

fn parse_chat_id(value: &str) -> Result<ChatId> {
    Ok(ChatId(Uuid::parse_str(value).map_err(|err| {
        anyhow!("invalid chat_id in local history: {err}")
    })?))
}

#[cfg(test)]
mod tests {
    use std::{env, fs};

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
}
