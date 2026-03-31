use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use trix_types::{
    AccountId, AckInboxResponse, ChatDetailResponse, ChatDeviceSummary, ChatHistoryResponse,
    ChatId, ChatType, CreateChatRequest, DeviceId, HistorySyncJobStatus, HistorySyncJobType,
    LeaseInboxRequest, LeaseInboxResponse, MessageEnvelope, MessageId, MessageKind,
    ModifyChatDevicesRequest, ModifyChatMembersRequest,
};
use uuid::Uuid;

use crate::{
    DeviceKeyMaterial, LocalHistoryStore, LocalOutgoingMessageApplyOutcome, LocalProjectedMessage,
    LocalProjectionKind, LocalStoreApplyReport, MessageBody, MlsConversation, MlsFacade,
    PreparedLocalOutboxSend, ServerApiClient, ServerApiError, SyncStateStore, decode_b64_field,
    encode_b64,
    history_sync_payload::{
        HistorySyncChatMetadata, HistorySyncExportMetadata, decrypt_projected_message_chunk,
        encrypt_projected_message_chunk, parse_chat_metadata, parse_export_metadata,
        with_chat_metadata, with_export_metadata,
    },
    make_control_message_input_with_ratchet_tree, make_create_message_request,
};

fn empty_json_object() -> Value {
    Value::Object(Default::default())
}

const SERVER_RESTORE_KEY_PACKAGE_COUNT: usize = 12;
const HISTORY_SYNC_JOB_FETCH_LIMIT: usize = 200;
const HISTORY_SYNC_CHUNK_MESSAGE_LIMIT: usize = 200;

#[derive(Debug, Clone)]
pub enum CoreEvent {
    Started,
    Stopped,
    SyncTick,
    ChatsSynced { chats: usize, messages: usize },
    InboxLeased { items: usize },
    InboxAcked { items: usize },
    StateSaved,
}

pub trait CoreEventSink: Send + Sync + 'static {
    fn publish(&self, event: CoreEvent);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncChatCursor {
    pub chat_id: ChatId,
    pub last_server_seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncStateSnapshot {
    pub lease_owner: String,
    pub last_acked_inbox_id: Option<u64>,
    pub chat_cursors: Vec<SyncChatCursor>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxApplyOutcome {
    pub lease_owner: String,
    pub lease_expires_at_unix: u64,
    pub acked_inbox_ids: Vec<u64>,
    pub report: LocalStoreApplyReport,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistorySyncProcessReport {
    pub source_jobs_processed: usize,
    pub target_jobs_processed: usize,
    pub changed_chat_ids: Vec<ChatId>,
}

#[derive(Debug, Clone)]
pub struct SendMessageOutcome {
    pub chat_id: ChatId,
    pub message_id: MessageId,
    pub server_seq: u64,
    pub report: LocalStoreApplyReport,
    pub projected_message: LocalProjectedMessage,
}

#[derive(Debug, Clone)]
pub struct CreateChatControlInput {
    pub creator_account_id: AccountId,
    pub creator_device_id: DeviceId,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub participant_account_ids: Vec<AccountId>,
    pub group_id: Option<Vec<u8>>,
    pub commit_aad_json: Option<Value>,
    pub welcome_aad_json: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct CreateChatControlOutcome {
    pub chat_id: ChatId,
    pub chat_type: ChatType,
    pub epoch: u64,
    pub mls_group_id: Vec<u8>,
    pub report: LocalStoreApplyReport,
    pub projected_messages: Vec<LocalProjectedMessage>,
}

#[derive(Debug, Clone)]
pub struct ModifyChatMembersControlInput {
    pub actor_account_id: AccountId,
    pub actor_device_id: DeviceId,
    pub chat_id: ChatId,
    pub participant_account_ids: Vec<AccountId>,
    pub commit_aad_json: Option<Value>,
    pub welcome_aad_json: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct ModifyChatMembersControlOutcome {
    pub chat_id: ChatId,
    pub epoch: u64,
    pub changed_account_ids: Vec<AccountId>,
    pub report: LocalStoreApplyReport,
    pub projected_messages: Vec<LocalProjectedMessage>,
}

#[derive(Debug, Clone)]
pub struct ModifyChatDevicesControlInput {
    pub actor_account_id: AccountId,
    pub actor_device_id: DeviceId,
    pub chat_id: ChatId,
    pub device_ids: Vec<DeviceId>,
    pub commit_aad_json: Option<Value>,
    pub welcome_aad_json: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct ModifyChatDevicesControlOutcome {
    pub chat_id: ChatId,
    pub epoch: u64,
    pub changed_device_ids: Vec<DeviceId>,
    pub report: LocalStoreApplyReport,
    pub projected_messages: Vec<LocalProjectedMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedSyncState {
    version: u32,
    lease_owner: String,
    last_acked_inbox_id: Option<u64>,
    #[serde(default)]
    pending_acked_inbox_ids: BTreeSet<u64>,
    chat_cursors: BTreeMap<String, u64>,
    #[serde(default)]
    pending_chat_server_seqs: BTreeMap<String, BTreeSet<u64>>,
    #[serde(default)]
    history_sync_target_jobs: BTreeMap<String, PersistedTargetHistorySyncJobState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
struct PersistedTargetHistorySyncJobState {
    #[serde(default)]
    last_applied_sequence_no: u64,
    #[serde(default)]
    applied_final_chunk: bool,
}

impl Default for PersistedSyncState {
    fn default() -> Self {
        Self {
            version: 3,
            lease_owner: Uuid::new_v4().to_string(),
            last_acked_inbox_id: None,
            pending_acked_inbox_ids: BTreeSet::new(),
            chat_cursors: BTreeMap::new(),
            pending_chat_server_seqs: BTreeMap::new(),
            history_sync_target_jobs: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SyncCoordinator {
    state: PersistedSyncState,
    store: Option<SyncStateStore>,
}

impl Default for SyncCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl SyncCoordinator {
    pub fn new() -> Self {
        Self {
            state: PersistedSyncState::default(),
            store: None,
        }
    }

    pub fn new_persistent(state_path: impl Into<PathBuf>) -> Result<Self> {
        let store = SyncStateStore::new(state_path);
        if store.state_path.exists() {
            let state = load_state_from_path(&store.state_path)?;
            Ok(Self {
                state,
                store: Some(store),
            })
        } else {
            let coordinator = Self {
                state: PersistedSyncState::default(),
                store: Some(store),
            };
            coordinator.save_state()?;
            Ok(coordinator)
        }
    }

    pub fn new_encrypted(state_path: impl Into<PathBuf>, database_key: Vec<u8>) -> Result<Self> {
        let store = SyncStateStore::new_encrypted(state_path, database_key);
        if store.state_path.exists() {
            let state = load_state_from_encrypted_path(
                &store.state_path,
                store.database_key.as_deref().unwrap_or_default(),
            )?;
            Ok(Self {
                state,
                store: Some(store),
            })
        } else {
            let coordinator = Self {
                state: PersistedSyncState::default(),
                store: Some(store),
            };
            coordinator.save_state()?;
            Ok(coordinator)
        }
    }

    pub fn save_state(&self) -> Result<()> {
        let Some(store) = &self.store else {
            return Ok(());
        };
        save_state_to_path(
            &store.state_path,
            store.database_key.as_deref(),
            &self.state,
        )
    }

    pub fn state_path(&self) -> Option<&Path> {
        self.store.as_ref().map(|store| store.state_path.as_path())
    }

    pub(crate) fn replace_with(&mut self, other: &Self) -> Result<()> {
        self.state = other.state.clone();
        self.save_state()
    }

    pub fn snapshot(&self) -> Result<SyncStateSnapshot> {
        let mut chat_cursors = Vec::with_capacity(self.state.chat_cursors.len());
        for (chat_id, last_server_seq) in &self.state.chat_cursors {
            chat_cursors.push(SyncChatCursor {
                chat_id: parse_chat_id(chat_id)?,
                last_server_seq: *last_server_seq,
            });
        }

        Ok(SyncStateSnapshot {
            lease_owner: self.state.lease_owner.clone(),
            last_acked_inbox_id: self.state.last_acked_inbox_id,
            chat_cursors,
        })
    }

    pub fn lease_owner(&self) -> &str {
        &self.state.lease_owner
    }

    pub fn last_acked_inbox_id(&self) -> Option<u64> {
        self.state.last_acked_inbox_id
    }

    pub fn chat_cursor(&self, chat_id: ChatId) -> Option<u64> {
        self.state.chat_cursors.get(&chat_id.0.to_string()).copied()
    }

    fn record_observed_chat_server_seqs<I>(&mut self, updates: I) -> Result<bool>
    where
        I: IntoIterator<Item = (ChatId, u64)>,
    {
        let previous_state = self.state.clone();
        let mut changed = false;

        for (chat_id, server_seq) in updates {
            let chat_key = chat_id.0.to_string();
            let current = self
                .state
                .chat_cursors
                .get(&chat_key)
                .copied()
                .unwrap_or_default();
            if server_seq <= current {
                continue;
            }

            let should_remove_pending = {
                let pending = self
                    .state
                    .pending_chat_server_seqs
                    .entry(chat_key.clone())
                    .or_default();
                changed |= pending.insert(server_seq);
                changed |= advance_sparse_prefix(
                    self.state.chat_cursors.entry(chat_key.clone()).or_default(),
                    pending,
                );
                pending.is_empty()
            };
            if should_remove_pending {
                self.state.pending_chat_server_seqs.remove(&chat_key);
            }
        }

        if !changed {
            return Ok(false);
        }

        if let Err(error) = self.save_state() {
            self.state = previous_state;
            return Err(error);
        }

        Ok(true)
    }

    pub fn record_chat_server_seq(&mut self, chat_id: ChatId, server_seq: u64) -> Result<bool> {
        let previous_state = self.state.clone();
        let chat_key = chat_id.0.to_string();
        let current = self
            .state
            .chat_cursors
            .get(&chat_key)
            .copied()
            .unwrap_or_default();
        if server_seq <= current {
            return Ok(false);
        }

        self.state.chat_cursors.insert(chat_key.clone(), server_seq);
        let should_remove_pending =
            if let Some(pending) = self.state.pending_chat_server_seqs.get_mut(&chat_key) {
                pending.retain(|pending_seq| *pending_seq > server_seq);
                pending.is_empty()
            } else {
                false
            };
        if should_remove_pending {
            self.state.pending_chat_server_seqs.remove(&chat_key);
        }

        if let Err(error) = self.save_state() {
            self.state = previous_state;
            return Err(error);
        }

        Ok(true)
    }

    pub fn record_chat_server_seqs<I>(&mut self, chat_id: ChatId, server_seqs: I) -> Result<bool>
    where
        I: IntoIterator<Item = u64>,
    {
        let Some(max_server_seq) = server_seqs.into_iter().max() else {
            return Ok(false);
        };
        self.record_chat_server_seq(chat_id, max_server_seq)
    }

    pub fn record_projected_chat_cursor(
        &mut self,
        store: &LocalHistoryStore,
        chat_id: ChatId,
    ) -> Result<bool> {
        let Some(server_seq) = store.projected_cursor(chat_id) else {
            return Ok(false);
        };
        self.record_chat_server_seq(chat_id, server_seq)
    }

    fn target_history_sync_job_state(&self, job_id: &str) -> PersistedTargetHistorySyncJobState {
        self.state
            .history_sync_target_jobs
            .get(job_id)
            .cloned()
            .unwrap_or_default()
    }

    fn record_target_history_sync_progress(
        &mut self,
        job_id: &str,
        sequence_no: u64,
        is_final: bool,
    ) -> Result<bool> {
        let previous_state = self.state.clone();
        let state = self
            .state
            .history_sync_target_jobs
            .entry(job_id.to_owned())
            .or_default();
        if sequence_no < state.last_applied_sequence_no {
            return Ok(false);
        }
        let changed = sequence_no != state.last_applied_sequence_no
            || (is_final && !state.applied_final_chunk);
        if !changed {
            return Ok(false);
        }
        state.last_applied_sequence_no = sequence_no;
        state.applied_final_chunk |= is_final;
        if let Err(error) = self.save_state() {
            self.state = previous_state;
            return Err(error);
        }
        Ok(true)
    }

    pub async fn sync_chat_histories(
        &mut self,
        client: &ServerApiClient,
        limit_per_chat: usize,
    ) -> Result<Vec<ChatHistoryResponse>> {
        let chats = client.list_chats().await?;
        let mut updated_histories = Vec::new();
        let mut cursor_updates = Vec::new();

        for chat in chats.chats {
            let history = client
                .get_chat_history(
                    chat.chat_id,
                    self.chat_cursor(chat.chat_id),
                    Some(limit_per_chat),
                )
                .await?;

            for message in &history.messages {
                cursor_updates.push((history.chat_id, message.server_seq));
            }

            if !history.messages.is_empty() {
                updated_histories.push(history);
            }
        }

        self.record_observed_chat_server_seqs(cursor_updates)?;

        Ok(updated_histories)
    }

    pub async fn sync_chat_histories_into_store(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        limit_per_chat: usize,
    ) -> Result<LocalStoreApplyReport> {
        let chats = client.list_chats().await?;
        let mut combined = store.apply_chat_list(&chats)?;
        let mut changed_chat_ids = combined.changed_chat_ids.clone();
        let mut cursor_updates = Vec::new();

        for chat in chats.chats {
            let history = client
                .get_chat_history(
                    chat.chat_id,
                    self.chat_cursor(chat.chat_id),
                    Some(limit_per_chat),
                )
                .await?;
            let report = store.apply_chat_history(&history)?;
            for message in &history.messages {
                cursor_updates.push((history.chat_id, message.server_seq));
            }
            combined.chats_upserted += report.chats_upserted;
            combined.messages_upserted += report.messages_upserted;
            changed_chat_ids.extend(report.changed_chat_ids);
        }

        self.record_observed_chat_server_seqs(cursor_updates)?;
        changed_chat_ids.sort_by_key(|chat_id| chat_id.0);
        changed_chat_ids.dedup();
        combined.changed_chat_ids = changed_chat_ids;
        Ok(combined)
    }

    pub async fn process_history_sync_jobs(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        device_keys: &DeviceKeyMaterial,
    ) -> Result<HistorySyncProcessReport> {
        let source_jobs = client
            .list_history_sync_jobs(
                Some(trix_types::HistorySyncJobRole::Source),
                None,
                Some(HISTORY_SYNC_JOB_FETCH_LIMIT),
            )
            .await?
            .jobs;
        let target_jobs = client
            .list_history_sync_jobs(
                Some(trix_types::HistorySyncJobRole::Target),
                None,
                Some(HISTORY_SYNC_JOB_FETCH_LIMIT),
            )
            .await?
            .jobs;

        let mut cached_transport_keys = BTreeMap::<String, Vec<u8>>::new();
        let mut changed_chat_ids = HashSet::new();
        let mut source_jobs_processed = 0usize;
        let mut target_jobs_processed = 0usize;

        for job in source_jobs {
            if !should_process_source_history_sync_job(&job) {
                continue;
            }
            if self
                .process_source_history_sync_job(
                    client,
                    store,
                    device_keys,
                    &job,
                    &mut cached_transport_keys,
                )
                .await?
            {
                source_jobs_processed += 1;
            }
        }

        for job in target_jobs {
            if !should_process_target_history_sync_job(&job) {
                continue;
            }
            if self
                .process_target_history_sync_job(
                    client,
                    store,
                    device_keys,
                    &job,
                    &mut changed_chat_ids,
                )
                .await?
            {
                target_jobs_processed += 1;
            }
        }

        let mut changed_chat_ids = changed_chat_ids.into_iter().collect::<Vec<_>>();
        changed_chat_ids.sort_by_key(|chat_id| chat_id.0);

        Ok(HistorySyncProcessReport {
            source_jobs_processed,
            target_jobs_processed,
            changed_chat_ids,
        })
    }

    async fn process_source_history_sync_job(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        device_keys: &DeviceKeyMaterial,
        job: &trix_types::HistorySyncJobSummary,
        cached_transport_keys: &mut BTreeMap<String, Vec<u8>>,
    ) -> Result<bool> {
        let Some(chat_id) = job.chat_id else {
            return Ok(false);
        };
        let target_device_key = if let Some(existing) =
            cached_transport_keys.get(&job.target_device_id.0.to_string())
        {
            existing.clone()
        } else {
            let transport_key = client
                .get_device_transport_key(job.target_device_id)
                .await?
                .transport_pubkey;
            cached_transport_keys.insert(job.target_device_id.0.to_string(), transport_key.clone());
            transport_key
        };

        let mut cursor_json = job.cursor_json.clone();
        if let Some(chat) = store.get_chat(chat_id) {
            cursor_json = with_chat_metadata(
                &cursor_json,
                &HistorySyncChatMetadata {
                    chat_type: chat.chat_type,
                    title: chat.title,
                    participant_profiles: chat.participant_profiles,
                    epoch: chat.epoch,
                },
            );
        }
        let export_metadata = parse_export_metadata(&cursor_json);
        let after_server_seq = export_metadata
            .as_ref()
            .map(|metadata| metadata.exported_through_server_seq);
        let projected_messages = store.get_projected_messages(chat_id, after_server_seq, None);
        let mut next_sequence_no = next_history_sync_sequence_no(export_metadata.as_ref());
        let mut exported_message_count = export_metadata
            .as_ref()
            .map(|metadata| metadata.projected_message_count)
            .unwrap_or_default();

        for (chunk_index, projected_chunk) in projected_messages
            .chunks(HISTORY_SYNC_CHUNK_MESSAGE_LIMIT)
            .enumerate()
        {
            let Some(last_projected) = projected_chunk.last() else {
                continue;
            };
            exported_message_count += projected_chunk.len();
            let metadata = HistorySyncExportMetadata {
                version: 1,
                format: "projected_messages".to_owned(),
                exported_through_server_seq: last_projected.server_seq,
                projected_message_count: exported_message_count,
                chunk_message_limit: HISTORY_SYNC_CHUNK_MESSAGE_LIMIT,
            };
            cursor_json = with_export_metadata(&cursor_json, &metadata);
            let payload = encrypt_projected_message_chunk(
                &job.job_id,
                &chat_id.0.to_string(),
                projected_chunk,
                device_keys,
                &target_device_key,
            )?;
            let is_final = chunk_index + 1
                == projected_messages
                    .chunks(HISTORY_SYNC_CHUNK_MESSAGE_LIMIT)
                    .len();
            client
                .append_history_sync_chunk(
                    &job.job_id,
                    next_sequence_no,
                    &payload,
                    Some(cursor_json.clone()),
                    is_final,
                )
                .await?;
            next_sequence_no += 1;
        }

        client
            .complete_history_sync_job(&job.job_id, Some(cursor_json))
            .await?;
        Ok(true)
    }

    async fn process_target_history_sync_job(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        device_keys: &DeviceKeyMaterial,
        job: &trix_types::HistorySyncJobSummary,
        changed_chat_ids: &mut HashSet<ChatId>,
    ) -> Result<bool> {
        let Some(chat_id) = job.chat_id else {
            return Ok(false);
        };
        let progress = self.target_history_sync_job_state(&job.job_id);
        if progress.applied_final_chunk && matches!(job.job_status, HistorySyncJobStatus::Completed)
        {
            return Ok(false);
        }

        let chunks = client.get_history_sync_chunks(&job.job_id).await?;
        let mut processed_any_chunk = false;
        for chunk in chunks
            .into_iter()
            .filter(|chunk| chunk.sequence_no > progress.last_applied_sequence_no)
        {
            let decrypted = decrypt_projected_message_chunk(&chunk.payload, device_keys)?;
            if decrypted.job_id != job.job_id {
                return Err(anyhow!(
                    "history sync chunk job mismatch: expected {}, got {}",
                    job.job_id,
                    decrypted.job_id
                ));
            }
            let decrypted_chat_id = parse_chat_id(&decrypted.chat_id)?;
            if decrypted_chat_id != chat_id {
                return Err(anyhow!(
                    "history sync chunk chat mismatch: expected {}, got {}",
                    chat_id.0,
                    decrypted.chat_id
                ));
            }
            self.bootstrap_history_sync_chat_if_needed(client, store, job, chat_id)
                .await?;
            let report = store.apply_projected_messages(chat_id, &decrypted.projected_messages)?;
            if let Some(server_seq) = report.advanced_to_server_seq {
                self.record_chat_server_seq(chat_id, server_seq)?;
            }
            if report.projected_messages_upserted > 0 || report.advanced_to_server_seq.is_some() {
                changed_chat_ids.insert(chat_id);
            }
            self.record_target_history_sync_progress(
                &job.job_id,
                chunk.sequence_no,
                chunk.is_final,
            )?;
            processed_any_chunk = true;
        }

        Ok(processed_any_chunk)
    }

    async fn bootstrap_history_sync_chat_if_needed(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        job: &trix_types::HistorySyncJobSummary,
        chat_id: ChatId,
    ) -> Result<()> {
        if store.get_chat(chat_id).is_some() {
            return Ok(());
        }
        let detail = match client.get_chat(chat_id).await {
            Ok(detail) => detail,
            Err(ServerApiError::Api { status: 404, .. }) => {
                if let Some(chat_metadata) = parse_chat_metadata(&job.cursor_json) {
                    store.apply_chat_detail(&trix_types::ChatDetailResponse {
                        chat_id,
                        chat_type: chat_metadata.chat_type,
                        title: chat_metadata.title,
                        last_server_seq: parse_export_metadata(&job.cursor_json)
                            .map(|metadata| metadata.exported_through_server_seq)
                            .unwrap_or_default(),
                        pending_message_count: 0,
                        epoch: chat_metadata.epoch,
                        last_commit_message_id: None,
                        last_message: None,
                        participant_profiles: chat_metadata.participant_profiles,
                        members: Vec::new(),
                        device_members: Vec::new(),
                    })?;
                }
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        };
        store.apply_chat_detail(&detail)?;
        let history = client.get_chat_history(chat_id, None, None).await?;
        store.apply_chat_history(&history)?;
        self.record_observed_chat_server_seqs(
            history
                .messages
                .iter()
                .map(|message| (chat_id, message.server_seq)),
        )?;
        Ok(())
    }

    pub async fn lease_inbox(
        &self,
        client: &ServerApiClient,
        limit: Option<usize>,
        lease_ttl_seconds: Option<u64>,
    ) -> Result<LeaseInboxResponse> {
        client
            .lease_inbox(LeaseInboxRequest {
                lease_owner: Some(self.state.lease_owner.clone()),
                limit,
                after_inbox_id: self.state.last_acked_inbox_id,
                lease_ttl_seconds,
            })
            .await
            .map_err(Into::into)
    }

    pub async fn ack_inbox(
        &mut self,
        client: &ServerApiClient,
        inbox_ids: Vec<u64>,
    ) -> Result<AckInboxResponse> {
        let response = client.ack_inbox(inbox_ids).await?;
        self.record_acked_inbox_ids(&response.acked_inbox_ids)?;
        Ok(response)
    }

    pub fn record_acked_inbox_ids(&mut self, acked_inbox_ids: &[u64]) -> Result<()> {
        let current = self.state.last_acked_inbox_id.unwrap_or_default();
        let previous_state = self.state.clone();
        let mut changed = false;

        for inbox_id in acked_inbox_ids.iter().copied() {
            if inbox_id <= current {
                continue;
            }
            changed |= self.state.pending_acked_inbox_ids.insert(inbox_id);
        }

        let last_acked = self.state.last_acked_inbox_id.get_or_insert(0);
        changed |= advance_sparse_prefix(last_acked, &mut self.state.pending_acked_inbox_ids);
        if *last_acked == 0 {
            self.state.last_acked_inbox_id = None;
        }

        if !changed {
            return Ok(());
        }

        if let Err(error) = self.save_state() {
            self.state = previous_state;
            return Err(error);
        }

        Ok(())
    }

    pub fn apply_inbox_items_into_store(
        &mut self,
        store: &mut LocalHistoryStore,
        items: &[trix_types::InboxItem],
    ) -> Result<LocalStoreApplyReport> {
        let report = store.apply_inbox_items(items)?;
        self.record_observed_chat_server_seqs(
            items
                .iter()
                .map(|item| (item.message.chat_id, item.message.server_seq)),
        )?;
        Ok(report)
    }

    pub async fn lease_inbox_into_store(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        limit: Option<usize>,
        lease_ttl_seconds: Option<u64>,
    ) -> Result<InboxApplyOutcome> {
        let lease = self.lease_inbox(client, limit, lease_ttl_seconds).await?;
        let report = self.apply_inbox_items_into_store(store, &lease.items)?;
        let inbox_ids = lease
            .items
            .iter()
            .map(|item| item.inbox_id)
            .collect::<Vec<_>>();
        let acked = if inbox_ids.is_empty() {
            Vec::new()
        } else {
            self.ack_inbox(client, inbox_ids).await?.acked_inbox_ids
        };

        Ok(InboxApplyOutcome {
            lease_owner: lease.lease_owner,
            lease_expires_at_unix: lease.lease_expires_at_unix,
            acked_inbox_ids: acked,
            report,
        })
    }

    pub async fn send_message_body(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        conversation: &mut MlsConversation,
        sender_account_id: trix_types::AccountId,
        sender_device_id: trix_types::DeviceId,
        chat_id: ChatId,
        message_id: Option<MessageId>,
        body: &MessageBody,
        aad_json: Option<Value>,
    ) -> Result<SendMessageOutcome> {
        let existing_outbox = message_id.and_then(|message_id| store.outbox_message(message_id));
        let prepared_conversation = self
            .prepare_chat_mutation_conversation(client, store, facade, chat_id)
            .await?;
        *conversation = prepared_conversation;

        let queued_at_unix = current_unix_seconds()?;
        let message_id = message_id.unwrap_or_default();
        store.ensure_outbox_message(
            chat_id,
            sender_account_id,
            sender_device_id,
            message_id,
            body.clone(),
            queued_at_unix,
        )?;
        if let Some(prepared_send) = existing_outbox
            .as_ref()
            .and_then(|message| message.prepared_send.clone())
        {
            store.prepare_outbox_message_send(message_id, prepared_send)?;
        }

        let normalized_aad_json = aad_json.unwrap_or_else(empty_json_object);
        let normalized_aad_string = serde_json::to_string(&normalized_aad_json)?;
        let mut prepared_send = if let Some(existing) = store.prepared_outbox_send(message_id) {
            if existing.aad_json_string != normalized_aad_string {
                let error = anyhow!(
                    "outbox message {} already exists with different AAD",
                    message_id.0
                );
                let _ = store.mark_outbox_failure(message_id, error.to_string());
                return Err(error);
            }
            existing
        } else {
            let snapshot = facade.snapshot_state()?;
            let plaintext = body.to_bytes()?;
            let epoch = conversation.epoch();
            let ciphertext = match facade.create_application_message(conversation, &plaintext) {
                Ok(ciphertext) => ciphertext,
                Err(error) => {
                    let _ = store.mark_outbox_failure(message_id, error.to_string());
                    return Err(error);
                }
            };
            let prepared_send = PreparedLocalOutboxSend {
                epoch,
                ciphertext_b64: encode_b64(&ciphertext),
                aad_json_string: normalized_aad_string.clone(),
            };
            if let Err(error) = store.prepare_outbox_message_send(message_id, prepared_send.clone())
            {
                facade.restore_snapshot(&snapshot).with_context(|| {
                    format!(
                        "failed to rollback MLS state after persisting prepared outbox {}",
                        message_id.0
                    )
                })?;
                *conversation = self
                    .prepare_chat_mutation_conversation(client, store, facade, chat_id)
                    .await?;
                let _ = store.mark_outbox_failure(message_id, error.to_string());
                return Err(error);
            }
            prepared_send
        };
        let ciphertext =
            decode_b64_field("prepared outbox ciphertext", &prepared_send.ciphertext_b64)
                .map_err(|error| anyhow!("failed to decode prepared outbox ciphertext: {error}"))?;
        let response = match client
            .create_message(
                chat_id,
                make_create_message_request(
                    message_id,
                    prepared_send.epoch,
                    MessageKind::Application,
                    body.content_type(),
                    &ciphertext,
                    Some(normalized_aad_json.clone()),
                ),
            )
            .await
        {
            Ok(response) => response,
            Err(ref error) if is_epoch_mismatch_error(error) => {
                let _ = store.clear_outbox_prepared_send(message_id);

                let refresh_result: Result<()> = (async {
                    let detail = client.get_chat(chat_id).await?;
                    store.apply_chat_detail(&detail)?;
                    let history = client.get_chat_history(chat_id, None, None).await?;
                    store.apply_chat_history(&history)?;
                    self.record_chat_server_seqs(
                        chat_id,
                        history.messages.iter().map(|m| m.server_seq),
                    )?;
                    store.project_chat_with_facade(chat_id, facade, None)?;
                    self.record_projected_chat_cursor(store, chat_id)?;
                    Ok(())
                })
                .await;
                if let Err(error) = refresh_result {
                    let _ = store.mark_outbox_failure(message_id, error.to_string());
                    return Err(error);
                }

                let refreshed_conversation = match store
                    .load_or_bootstrap_chat_mls_conversation(chat_id, facade)
                {
                    Ok(Some(conv)) => conv,
                    Ok(None) => {
                        let error = anyhow!("chat {} has no bootstrappable MLS state after epoch refresh", chat_id.0);
                        let _ = store.mark_outbox_failure(message_id, error.to_string());
                        return Err(error);
                    }
                    Err(error) => {
                        let _ = store.mark_outbox_failure(message_id, error.to_string());
                        return Err(error);
                    }
                };
                *conversation = refreshed_conversation;

                let retry_snapshot = facade.snapshot_state()?;
                let plaintext = body.to_bytes()?;
                let epoch = conversation.epoch();
                let retry_ciphertext =
                    match facade.create_application_message(conversation, &plaintext) {
                        Ok(ct) => ct,
                        Err(error) => {
                            let _ = store.mark_outbox_failure(message_id, error.to_string());
                            return Err(error);
                        }
                    };
                let retry_prepared = PreparedLocalOutboxSend {
                    epoch,
                    ciphertext_b64: encode_b64(&retry_ciphertext),
                    aad_json_string: normalized_aad_string.clone(),
                };
                if let Err(error) = store.prepare_outbox_message_send(message_id, retry_prepared.clone()) {
                    facade.restore_snapshot(&retry_snapshot).with_context(|| {
                        format!(
                            "failed to rollback MLS state after persisting retry outbox {}",
                            message_id.0
                        )
                    })?;
                    let _ = store.mark_outbox_failure(message_id, error.to_string());
                    return Err(error);
                }

                let retry_ct = decode_b64_field(
                    "retry outbox ciphertext",
                    &retry_prepared.ciphertext_b64,
                )
                .map_err(|e| anyhow!("failed to decode retry outbox ciphertext: {e}"))?;
                match client
                    .create_message(
                        chat_id,
                        make_create_message_request(
                            message_id,
                            retry_prepared.epoch,
                            MessageKind::Application,
                            body.content_type(),
                            &retry_ct,
                            Some(normalized_aad_json.clone()),
                        ),
                    )
                    .await
                {
                    Ok(response) => {
                        prepared_send = retry_prepared;
                        response
                    }
                    Err(error) => {
                        let _ = store.mark_outbox_failure(message_id, error.to_string());
                        return Err(error.into());
                    }
                }
            }
            Err(error) => {
                let _ = store.mark_outbox_failure(message_id, error.to_string());
                return Err(error.into());
            }
        };

        let envelope = MessageEnvelope {
            message_id: response.message_id,
            chat_id,
            server_seq: response.server_seq,
            sender_account_id,
            sender_device_id,
            epoch: prepared_send.epoch,
            message_kind: MessageKind::Application,
            content_type: body.content_type(),
            ciphertext_b64: prepared_send.ciphertext_b64.clone(),
            aad_json: normalized_aad_json,
            created_at_unix: current_unix_seconds()?,
        };
        let LocalOutgoingMessageApplyOutcome {
            report,
            projected_message,
        } = match store.apply_outgoing_message(&envelope, body) {
            Ok(outcome) => outcome,
            Err(error) => {
                restore_failed_outbox_send(
                    store,
                    chat_id,
                    sender_account_id,
                    sender_device_id,
                    message_id,
                    body,
                    queued_at_unix,
                    &prepared_send,
                    &error.to_string(),
                );
                return Err(error);
            }
        };
        if let Err(error) = self.record_chat_server_seq(chat_id, response.server_seq) {
            restore_failed_outbox_send(
                store,
                chat_id,
                sender_account_id,
                sender_device_id,
                message_id,
                body,
                queued_at_unix,
                &prepared_send,
                &error.to_string(),
            );
            return Err(error);
        }

        Ok(SendMessageOutcome {
            chat_id,
            message_id: response.message_id,
            server_seq: response.server_seq,
            report,
            projected_message,
        })
    }

    pub async fn create_chat_control(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        input: CreateChatControlInput,
    ) -> Result<CreateChatControlOutcome> {
        let participant_account_ids =
            normalize_account_ids(input.participant_account_ids, input.creator_account_id);
        let direct_message_peer_account_id = match input.chat_type {
            ChatType::Dm => Some(
                participant_account_ids
                    .first()
                    .copied()
                    .filter(|_| participant_account_ids.len() == 1)
                    .ok_or_else(|| anyhow!("dm chats require exactly one peer account"))?,
            ),
            ChatType::Group => None,
            ChatType::AccountSync => {
                return Err(anyhow!("account sync chats are created internally"));
            }
        };
        if let Some(peer_account_id) = direct_message_peer_account_id {
            if let Some(existing) = self
                .resolve_existing_direct_chat(
                    client,
                    store,
                    input.creator_account_id,
                    peer_account_id,
                )
                .await?
            {
                return Ok(existing);
            }
        }
        let group_id = input
            .group_id
            .unwrap_or_else(|| Uuid::new_v4().as_bytes().to_vec());

        let mut reserved_packages = reserve_initial_chat_packages(
            client,
            input.creator_account_id,
            input.creator_device_id,
            &participant_account_ids,
        )
        .await?;
        if reserved_packages.is_empty() {
            return Err(anyhow!(
                "create_chat_control requires at least one target device key package"
            ));
        }
        reserved_packages.sort_by(|left, right| left.device_id.0.cmp(&right.device_id.0));

        let snapshot = facade.snapshot_state()?;
        let mut conversation = match facade.create_group(&group_id) {
            Ok(conversation) => conversation,
            Err(err) => {
                facade.restore_snapshot(&snapshot)?;
                return Err(err);
            }
        };
        let add_bundle = match facade.add_members(
            &mut conversation,
            &reserved_packages
                .iter()
                .map(|package| package.key_package.clone())
                .collect::<Vec<_>>(),
        ) {
            Ok(bundle) => bundle,
            Err(err) => {
                facade.restore_snapshot(&snapshot)?;
                return Err(err);
            }
        };
        let commit_message_id = MessageId::default();
        let welcome_message_id = MessageId::default();

        let response = match client
            .create_chat(CreateChatRequest {
                chat_type: input.chat_type,
                title: input.title,
                participant_account_ids,
                reserved_key_package_ids: reserved_packages
                    .iter()
                    .map(|package| package.key_package_id.clone())
                    .collect(),
                initial_commit: Some(crate::make_control_message_input(
                    commit_message_id,
                    &add_bundle.commit_message,
                    input.commit_aad_json,
                )),
                welcome_message: add_bundle.welcome_message.as_ref().map(|welcome| {
                    make_control_message_input_with_ratchet_tree(
                        welcome_message_id,
                        welcome,
                        input.welcome_aad_json,
                        add_bundle.ratchet_tree.as_deref(),
                    )
                }),
            })
            .await
        {
            Ok(response) => response,
            Err(err) => {
                facade.restore_snapshot(&snapshot).with_context(|| {
                    format!("failed to rollback MLS state after server rejected create_chat: {err}")
                })?;
                if let Some(peer_account_id) = direct_message_peer_account_id
                    && is_existing_direct_chat_conflict(&err)
                    && let Some(existing) = self
                        .resolve_existing_direct_chat(
                            client,
                            store,
                            input.creator_account_id,
                            peer_account_id,
                        )
                        .await?
                {
                    return Ok(existing);
                }
                return Err(err.into());
            }
        };

        let (report, projected_messages) = async {
            let (_detail, history, mut report) = self
                .refresh_chat_state(client, store, response.chat_id, None)
                .await?;
            store.set_chat_mls_group_id(response.chat_id, &group_id)?;
            store.align_chat_device_members_with_conversation(
                response.chat_id,
                facade,
                &conversation,
            )?;
            let projected_messages = synthesize_control_messages(
                &history,
                Some((commit_message_id, add_bundle.epoch)),
                add_bundle
                    .welcome_message
                    .as_ref()
                    .map(|_| welcome_message_id),
            )?;
            let projection_report =
                store.apply_projected_messages(response.chat_id, &projected_messages)?;
            merge_store_report(
                &mut report,
                LocalStoreApplyReport {
                    chats_upserted: usize::from(projection_report_changed_chat(&projection_report)),
                    messages_upserted: 0,
                    changed_chat_ids: if projection_report_changed_chat(&projection_report) {
                        vec![response.chat_id]
                    } else {
                        Vec::new()
                    },
                },
            );
            self.record_projected_chat_cursor(store, response.chat_id)?;
            Ok::<_, anyhow::Error>((report, projected_messages))
        }
        .await
        .map_err(|error| {
            control_mutation_requires_resync("create_chat_control", response.chat_id, error)
        })?;

        Ok(CreateChatControlOutcome {
            chat_id: response.chat_id,
            chat_type: response.chat_type,
            epoch: response.epoch,
            mls_group_id: group_id,
            report,
            projected_messages,
        })
    }

    pub async fn add_chat_members_control(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        input: ModifyChatMembersControlInput,
    ) -> Result<ModifyChatMembersControlOutcome> {
        let participant_account_ids =
            normalize_account_ids(input.participant_account_ids, input.actor_account_id);
        if participant_account_ids.is_empty() {
            return Err(anyhow!("at least one participant account is required"));
        }

        let (chat_detail, mut conversation) = self
            .prepare_chat_control_context(client, store, facade, input.chat_id)
            .await?;
        let after_server_seq = self.chat_cursor(input.chat_id);
        let mut reserved_packages = Vec::new();
        for account_id in &participant_account_ids {
            reserved_packages.extend(client.get_account_key_packages(*account_id).await?);
        }
        if reserved_packages.is_empty() {
            return Err(anyhow!(
                "no reserved key packages available for target accounts"
            ));
        }
        reserved_packages.sort_by(|left, right| left.device_id.0.cmp(&right.device_id.0));
        let snapshot = facade.snapshot_state()?;
        let add_bundle = match facade.add_members(
            &mut conversation,
            &reserved_packages
                .iter()
                .map(|package| package.key_package.clone())
                .collect::<Vec<_>>(),
        ) {
            Ok(bundle) => bundle,
            Err(err) => {
                facade.restore_snapshot(&snapshot)?;
                return Err(err);
            }
        };
        let commit_message_id = MessageId::default();
        let welcome_message_id = MessageId::default();

        let response = match client
            .add_chat_members(
                input.chat_id,
                ModifyChatMembersRequest {
                    epoch: chat_detail.epoch,
                    participant_account_ids,
                    reserved_key_package_ids: reserved_packages
                        .iter()
                        .map(|package| package.key_package_id.clone())
                        .collect(),
                    commit_message: Some(crate::make_control_message_input(
                        commit_message_id,
                        &add_bundle.commit_message,
                        input.commit_aad_json,
                    )),
                    welcome_message: add_bundle.welcome_message.as_ref().map(|welcome| {
                        make_control_message_input_with_ratchet_tree(
                            welcome_message_id,
                            welcome,
                            input.welcome_aad_json,
                            add_bundle.ratchet_tree.as_deref(),
                        )
                    }),
                },
            )
            .await
        {
            Ok(response) => response,
            Err(err) => {
                facade.restore_snapshot(&snapshot).with_context(|| {
                    format!("failed to rollback MLS state after server rejected members:add: {err}")
                })?;
                return Err(err.into());
            }
        };

        let (report, projected_messages) = async {
            let (_, history, mut report) = self
                .refresh_chat_state(client, store, input.chat_id, after_server_seq)
                .await?;
            store.align_chat_device_members_with_conversation(
                input.chat_id,
                facade,
                &conversation,
            )?;
            let projected_messages = synthesize_control_messages(
                &history,
                Some((commit_message_id, add_bundle.epoch)),
                add_bundle
                    .welcome_message
                    .as_ref()
                    .map(|_| welcome_message_id),
            )?;
            let projection_report =
                store.apply_projected_messages(input.chat_id, &projected_messages)?;
            merge_projection_report(&mut report, input.chat_id, &projection_report);
            self.record_projected_chat_cursor(store, input.chat_id)?;
            Ok::<_, anyhow::Error>((report, projected_messages))
        }
        .await
        .map_err(|error| {
            control_mutation_requires_resync("add_chat_members_control", input.chat_id, error)
        })?;

        Ok(ModifyChatMembersControlOutcome {
            chat_id: response.chat_id,
            epoch: response.epoch,
            changed_account_ids: response.changed_account_ids,
            report,
            projected_messages,
        })
    }

    pub async fn remove_chat_members_control(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        input: ModifyChatMembersControlInput,
    ) -> Result<ModifyChatMembersControlOutcome> {
        let participant_account_ids =
            normalize_account_ids(input.participant_account_ids, input.actor_account_id);
        if participant_account_ids.is_empty() {
            return Err(anyhow!("at least one participant account is required"));
        }

        let (chat_detail, mut conversation) = self
            .prepare_chat_control_context(client, store, facade, input.chat_id)
            .await?;
        let after_server_seq = self.chat_cursor(input.chat_id);
        let leaf_indices = collect_leaf_indices_for_accounts(
            &chat_detail.device_members,
            &participant_account_ids,
        )?;
        let snapshot = facade.snapshot_state()?;
        let remove_bundle = match facade.remove_members(&mut conversation, &leaf_indices) {
            Ok(bundle) => bundle,
            Err(err) => {
                facade.restore_snapshot(&snapshot)?;
                return Err(err);
            }
        };
        let commit_message_id = MessageId::default();

        let response = match client
            .remove_chat_members(
                input.chat_id,
                ModifyChatMembersRequest {
                    epoch: chat_detail.epoch,
                    participant_account_ids,
                    reserved_key_package_ids: Vec::new(),
                    commit_message: Some(crate::make_control_message_input(
                        commit_message_id,
                        &remove_bundle.commit_message,
                        input.commit_aad_json,
                    )),
                    welcome_message: None,
                },
            )
            .await
        {
            Ok(response) => response,
            Err(err) => {
                facade.restore_snapshot(&snapshot).with_context(|| {
                    format!(
                        "failed to rollback MLS state after server rejected members:remove: {err}"
                    )
                })?;
                return Err(err.into());
            }
        };

        let (report, projected_messages) = async {
            let (_, history, mut report) = self
                .refresh_chat_state(client, store, input.chat_id, after_server_seq)
                .await?;
            store.align_chat_device_members_with_conversation(
                input.chat_id,
                facade,
                &conversation,
            )?;
            let projected_messages = synthesize_control_messages(
                &history,
                Some((commit_message_id, remove_bundle.epoch)),
                None,
            )?;
            let projection_report =
                store.apply_projected_messages(input.chat_id, &projected_messages)?;
            merge_projection_report(&mut report, input.chat_id, &projection_report);
            self.record_projected_chat_cursor(store, input.chat_id)?;
            Ok::<_, anyhow::Error>((report, projected_messages))
        }
        .await
        .map_err(|error| {
            control_mutation_requires_resync("remove_chat_members_control", input.chat_id, error)
        })?;

        Ok(ModifyChatMembersControlOutcome {
            chat_id: response.chat_id,
            epoch: response.epoch,
            changed_account_ids: response.changed_account_ids,
            report,
            projected_messages,
        })
    }

    pub async fn add_chat_devices_control(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        input: ModifyChatDevicesControlInput,
    ) -> Result<ModifyChatDevicesControlOutcome> {
        let device_ids = normalize_device_ids(input.device_ids, input.actor_device_id);
        if device_ids.is_empty() {
            return Err(anyhow!("at least one device id is required"));
        }

        let (chat_detail, mut conversation) = self
            .prepare_chat_control_context(client, store, facade, input.chat_id)
            .await?;
        let after_server_seq = self.chat_cursor(input.chat_id);
        let mut reserved_packages = client
            .reserve_key_packages(input.actor_account_id, device_ids.clone())
            .await?;
        if reserved_packages.is_empty() {
            return Err(anyhow!(
                "no reserved key packages available for target devices"
            ));
        }
        reserved_packages.sort_by(|left, right| left.device_id.0.cmp(&right.device_id.0));
        let snapshot = facade.snapshot_state()?;
        let add_bundle = match facade.add_members(
            &mut conversation,
            &reserved_packages
                .iter()
                .map(|package| package.key_package.clone())
                .collect::<Vec<_>>(),
        ) {
            Ok(bundle) => bundle,
            Err(err) => {
                facade.restore_snapshot(&snapshot)?;
                return Err(err);
            }
        };
        let commit_message_id = MessageId::default();
        let welcome_message_id = MessageId::default();

        let response = match client
            .add_chat_devices(
                input.chat_id,
                ModifyChatDevicesRequest {
                    epoch: chat_detail.epoch,
                    device_ids,
                    reserved_key_package_ids: reserved_packages
                        .iter()
                        .map(|package| package.key_package_id.clone())
                        .collect(),
                    commit_message: Some(crate::make_control_message_input(
                        commit_message_id,
                        &add_bundle.commit_message,
                        input.commit_aad_json,
                    )),
                    welcome_message: add_bundle.welcome_message.as_ref().map(|welcome| {
                        make_control_message_input_with_ratchet_tree(
                            welcome_message_id,
                            welcome,
                            input.welcome_aad_json,
                            add_bundle.ratchet_tree.as_deref(),
                        )
                    }),
                },
            )
            .await
        {
            Ok(response) => response,
            Err(err) => {
                facade.restore_snapshot(&snapshot).with_context(|| {
                    format!("failed to rollback MLS state after server rejected devices:add: {err}")
                })?;
                return Err(err.into());
            }
        };

        let (report, projected_messages) = async {
            let (_, history, mut report) = self
                .refresh_chat_state(client, store, input.chat_id, after_server_seq)
                .await?;
            store.align_chat_device_members_with_conversation(
                input.chat_id,
                facade,
                &conversation,
            )?;
            let projected_messages = synthesize_control_messages(
                &history,
                Some((commit_message_id, add_bundle.epoch)),
                add_bundle
                    .welcome_message
                    .as_ref()
                    .map(|_| welcome_message_id),
            )?;
            let projection_report =
                store.apply_projected_messages(input.chat_id, &projected_messages)?;
            merge_projection_report(&mut report, input.chat_id, &projection_report);
            self.record_projected_chat_cursor(store, input.chat_id)?;
            Ok::<_, anyhow::Error>((report, projected_messages))
        }
        .await
        .map_err(|error| {
            control_mutation_requires_resync("add_chat_devices_control", input.chat_id, error)
        })?;

        Ok(ModifyChatDevicesControlOutcome {
            chat_id: response.chat_id,
            epoch: response.epoch,
            changed_device_ids: response.changed_device_ids,
            report,
            projected_messages,
        })
    }

    pub async fn remove_chat_devices_control(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        input: ModifyChatDevicesControlInput,
    ) -> Result<ModifyChatDevicesControlOutcome> {
        let device_ids = normalize_device_ids(input.device_ids, input.actor_device_id);
        if device_ids.is_empty() {
            return Err(anyhow!("at least one device id is required"));
        }

        let (chat_detail, mut conversation) = self
            .prepare_chat_control_context(client, store, facade, input.chat_id)
            .await?;
        let after_server_seq = self.chat_cursor(input.chat_id);
        let leaf_indices =
            collect_leaf_indices_for_devices(&chat_detail.device_members, &device_ids)?;
        let snapshot = facade.snapshot_state()?;
        let remove_bundle = match facade.remove_members(&mut conversation, &leaf_indices) {
            Ok(bundle) => bundle,
            Err(err) => {
                facade.restore_snapshot(&snapshot)?;
                return Err(err);
            }
        };
        let commit_message_id = MessageId::default();

        let response = match client
            .remove_chat_devices(
                input.chat_id,
                ModifyChatDevicesRequest {
                    epoch: chat_detail.epoch,
                    device_ids,
                    reserved_key_package_ids: Vec::new(),
                    commit_message: Some(crate::make_control_message_input(
                        commit_message_id,
                        &remove_bundle.commit_message,
                        input.commit_aad_json,
                    )),
                    welcome_message: None,
                },
            )
            .await
        {
            Ok(response) => response,
            Err(err) => {
                facade.restore_snapshot(&snapshot).with_context(|| {
                    format!(
                        "failed to rollback MLS state after server rejected devices:remove: {err}"
                    )
                })?;
                return Err(err.into());
            }
        };

        let (report, projected_messages) = async {
            let (_, history, mut report) = self
                .refresh_chat_state(client, store, input.chat_id, after_server_seq)
                .await?;
            store.align_chat_device_members_with_conversation(
                input.chat_id,
                facade,
                &conversation,
            )?;
            let projected_messages = synthesize_control_messages(
                &history,
                Some((commit_message_id, remove_bundle.epoch)),
                None,
            )?;
            let projection_report =
                store.apply_projected_messages(input.chat_id, &projected_messages)?;
            merge_projection_report(&mut report, input.chat_id, &projection_report);
            self.record_projected_chat_cursor(store, input.chat_id)?;
            Ok::<_, anyhow::Error>((report, projected_messages))
        }
        .await
        .map_err(|error| {
            control_mutation_requires_resync("remove_chat_devices_control", input.chat_id, error)
        })?;

        Ok(ModifyChatDevicesControlOutcome {
            chat_id: response.chat_id,
            epoch: response.epoch,
            changed_device_ids: response.changed_device_ids,
            report,
            projected_messages,
        })
    }

    async fn prepare_chat_mutation_conversation(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &MlsFacade,
        chat_id: ChatId,
    ) -> Result<MlsConversation> {
        let mut refreshed_full_history = false;
        let needs_bootstrap =
            store.get_chat(chat_id).is_none() || store.chat_mls_group_id(chat_id).is_none();
        if needs_bootstrap {
            let detail = client.get_chat(chat_id).await?;
            store.apply_chat_detail(&detail)?;
            let history = client.get_chat_history(chat_id, None, None).await?;
            store.apply_chat_history(&history)?;
            self.record_chat_server_seqs(
                chat_id,
                history.messages.iter().map(|message| message.server_seq),
            )?;
            refreshed_full_history = true;
        }

        if store.needs_history_refresh(chat_id) {
            let detail = client.get_chat(chat_id).await?;
            store.apply_chat_detail(&detail)?;
            let history = client.get_chat_history(chat_id, None, None).await?;
            store.apply_chat_history(&history)?;
            self.record_chat_server_seqs(
                chat_id,
                history.messages.iter().map(|message| message.server_seq),
            )?;
            refreshed_full_history = true;
        }

        match self.try_prepare_chat_mutation_conversation_once(store, facade, chat_id) {
            Ok(conversation) => Ok(conversation),
            Err(error)
                if is_chat_bootstrap_recovery_candidate(&error) && !refreshed_full_history =>
            {
                let detail = client.get_chat(chat_id).await?;
                store.apply_chat_detail(&detail)?;
                let history = client.get_chat_history(chat_id, None, None).await?;
                store.apply_chat_history(&history)?;
                self.record_chat_server_seqs(
                    chat_id,
                    history.messages.iter().map(|message| message.server_seq),
                )?;

                match self.try_prepare_chat_mutation_conversation_once(store, facade, chat_id) {
                    Ok(conversation) => Ok(conversation),
                    Err(retry_error) if is_missing_key_package_bootstrap_error(&retry_error) => {
                        let _ = restore_current_device_key_packages(client, facade).await;
                        Err(chat_rebootstrap_required_error())
                    }
                    Err(retry_error) => Err(retry_error),
                }
            }
            Err(error) if is_missing_key_package_bootstrap_error(&error) => {
                let _ = restore_current_device_key_packages(client, facade).await;
                Err(chat_rebootstrap_required_error())
            }
            Err(error) => Err(error),
        }
    }

    fn try_prepare_chat_mutation_conversation_once(
        &mut self,
        store: &mut LocalHistoryStore,
        facade: &MlsFacade,
        chat_id: ChatId,
    ) -> Result<MlsConversation> {
        if store.needs_projection(chat_id) {
            store.project_chat_with_facade(chat_id, facade, None)?;
            self.record_projected_chat_cursor(store, chat_id)?;
        }

        store
            .load_or_bootstrap_chat_mls_conversation(chat_id, facade)?
            .ok_or_else(|| anyhow!("chat {} has no bootstrappable MLS state", chat_id.0))
    }

    async fn prepare_chat_control_context(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &MlsFacade,
        chat_id: ChatId,
    ) -> Result<(ChatDetailResponse, MlsConversation)> {
        let conversation = self
            .prepare_chat_mutation_conversation(client, store, facade, chat_id)
            .await?;
        let mut detail = client.get_chat(chat_id).await?;
        align_chat_detail_device_members_with_conversation(&mut detail, facade, &conversation)?;
        store.apply_chat_detail(&detail)?;
        store.align_chat_device_members_with_conversation(chat_id, facade, &conversation)?;
        Ok((detail, conversation))
    }

    async fn refresh_chat_state(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        chat_id: ChatId,
        after_server_seq: Option<u64>,
    ) -> Result<(
        ChatDetailResponse,
        ChatHistoryResponse,
        LocalStoreApplyReport,
    )> {
        let detail = client.get_chat(chat_id).await?;
        let mut report = store.apply_chat_detail(&detail)?;
        let history = client
            .get_chat_history(chat_id, after_server_seq, None)
            .await?;
        merge_store_report(&mut report, store.apply_chat_history(&history)?);
        self.record_chat_server_seqs(
            chat_id,
            history.messages.iter().map(|message| message.server_seq),
        )?;
        Ok((detail, history, report))
    }

    async fn resolve_existing_direct_chat(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        self_account_id: AccountId,
        peer_account_id: AccountId,
    ) -> Result<Option<CreateChatControlOutcome>> {
        if let Some(chat_id) = store.find_active_direct_chat(self_account_id, peer_account_id) {
            return self
                .existing_chat_control_outcome_from_store(
                    store,
                    chat_id,
                    LocalStoreApplyReport {
                        chats_upserted: 0,
                        messages_upserted: 0,
                        changed_chat_ids: Vec::new(),
                    },
                )
                .map(Some);
        }

        let chats = client.list_chats().await?;
        let mut report = store.apply_chat_list(&chats)?;
        let Some(chat_id) = store.find_active_direct_chat(self_account_id, peer_account_id) else {
            return Ok(None);
        };

        let (detail, _history, refresh_report) = self
            .refresh_chat_state(client, store, chat_id, None)
            .await?;
        merge_store_report(&mut report, refresh_report);
        Ok(Some(self.existing_chat_control_outcome_from_detail(
            store, detail, report,
        )?))
    }

    fn existing_chat_control_outcome_from_store(
        &self,
        store: &LocalHistoryStore,
        chat_id: ChatId,
        report: LocalStoreApplyReport,
    ) -> Result<CreateChatControlOutcome> {
        let detail = store
            .get_chat(chat_id)
            .ok_or_else(|| anyhow!("existing chat {} is missing from local store", chat_id.0))?;
        self.existing_chat_control_outcome_from_detail(store, detail, report)
    }

    fn existing_chat_control_outcome_from_detail(
        &self,
        store: &LocalHistoryStore,
        detail: ChatDetailResponse,
        report: LocalStoreApplyReport,
    ) -> Result<CreateChatControlOutcome> {
        Ok(CreateChatControlOutcome {
            chat_id: detail.chat_id,
            chat_type: detail.chat_type,
            epoch: detail.epoch,
            mls_group_id: store.chat_mls_group_id(detail.chat_id).unwrap_or_default(),
            report,
            projected_messages: store.get_projected_messages(detail.chat_id, None, None),
        })
    }
}

async fn reserve_initial_chat_packages(
    client: &ServerApiClient,
    creator_account_id: AccountId,
    creator_device_id: DeviceId,
    participant_account_ids: &[AccountId],
) -> Result<Vec<crate::ReservedKeyPackageMaterial>> {
    let own_device_ids = client
        .list_devices()
        .await?
        .devices
        .into_iter()
        .filter(|device| {
            device.device_status == trix_types::DeviceStatus::Active
                && device.device_id != creator_device_id
        })
        .map(|device| device.device_id)
        .collect::<Vec<_>>();

    let mut reserved = Vec::new();
    if !own_device_ids.is_empty() {
        reserved.extend(
            client
                .reserve_key_packages(creator_account_id, own_device_ids)
                .await?,
        );
    }
    for account_id in participant_account_ids {
        reserved.extend(client.get_account_key_packages(*account_id).await?);
    }
    Ok(reserved)
}

fn normalize_account_ids(account_ids: Vec<AccountId>, exclude: AccountId) -> Vec<AccountId> {
    let mut unique = HashSet::new();
    for account_id in account_ids {
        if account_id != exclude {
            unique.insert(account_id);
        }
    }
    let mut normalized = unique.into_iter().collect::<Vec<_>>();
    normalized.sort_by_key(|account_id| account_id.0);
    normalized
}

fn normalize_device_ids(device_ids: Vec<DeviceId>, exclude: DeviceId) -> Vec<DeviceId> {
    let mut unique = HashSet::new();
    for device_id in device_ids {
        if device_id != exclude {
            unique.insert(device_id);
        }
    }
    let mut normalized = unique.into_iter().collect::<Vec<_>>();
    normalized.sort_by_key(|device_id| device_id.0);
    normalized
}

fn is_epoch_mismatch_error(error: &ServerApiError) -> bool {
    matches!(error, ServerApiError::Api { status: 409, message, .. } if message.contains("epoch"))
}

fn is_existing_direct_chat_conflict(error: &ServerApiError) -> bool {
    matches!(
        error,
        ServerApiError::Api {
            status: 409,
            message,
            ..
        } if message == "dm chat already exists"
    )
}

fn is_chat_bootstrap_recovery_candidate(error: &anyhow::Error) -> bool {
    is_missing_key_package_bootstrap_error(error)
        || error
            .chain()
            .any(|cause| cause.to_string().contains("no bootstrappable MLS state"))
}

fn is_missing_key_package_bootstrap_error(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .to_string()
            .contains(crate::crypto::MISSING_WELCOME_KEY_PACKAGE_ERROR_MARKER)
            || cause
                .to_string()
                .contains("No matching key package was found in the key store")
    })
}

async fn restore_current_device_key_packages(
    client: &ServerApiClient,
    facade: &MlsFacade,
) -> Result<()> {
    client.reset_key_packages().await?;
    let cipher_suite = facade.ciphersuite_label();
    let packages = facade
        .generate_key_packages(SERVER_RESTORE_KEY_PACKAGE_COUNT)?
        .into_iter()
        .map(|key_package| crate::PublishKeyPackageMaterial {
            cipher_suite: cipher_suite.clone(),
            key_package,
        })
        .collect();
    client.publish_key_packages(packages).await?;
    facade.save_state()?;
    Ok(())
}

fn chat_rebootstrap_required_error() -> anyhow::Error {
    anyhow!(
        "This chat can't be opened on this device because its local bootstrap keys were lost. Open it on another active device and add this device to the chat again, then try again here."
    )
}

fn collect_leaf_indices_for_accounts(
    device_members: &[ChatDeviceSummary],
    account_ids: &[AccountId],
) -> Result<Vec<u32>> {
    let wanted = account_ids.iter().copied().collect::<HashSet<_>>();
    let mut found_accounts = HashSet::new();
    let mut leaf_indices = Vec::new();
    for member in device_members {
        if wanted.contains(&member.account_id) {
            found_accounts.insert(member.account_id);
            leaf_indices.push(member.leaf_index);
        }
    }
    if found_accounts.len() != wanted.len() {
        return Err(anyhow!(
            "one or more target accounts are missing from active chat device membership"
        ));
    }
    leaf_indices.sort_unstable();
    Ok(leaf_indices)
}

fn align_chat_detail_device_members_with_conversation(
    detail: &mut ChatDetailResponse,
    facade: &MlsFacade,
    conversation: &MlsConversation,
) -> Result<()> {
    let leaf_index_by_credential = facade
        .members(conversation)?
        .into_iter()
        .map(|member| (encode_b64(&member.credential_identity), member.leaf_index))
        .collect::<BTreeMap<_, _>>();

    for member in &mut detail.device_members {
        if let Some(&leaf_index) = leaf_index_by_credential.get(&member.credential_identity_b64) {
            member.leaf_index = leaf_index;
        }
    }
    detail.device_members.sort_by(|left, right| {
        left.leaf_index
            .cmp(&right.leaf_index)
            .then_with(|| left.device_id.0.cmp(&right.device_id.0))
    });
    Ok(())
}

fn collect_leaf_indices_for_devices(
    device_members: &[ChatDeviceSummary],
    device_ids: &[DeviceId],
) -> Result<Vec<u32>> {
    let wanted = device_ids.iter().copied().collect::<HashSet<_>>();
    let mut found_devices = HashSet::new();
    let mut leaf_indices = Vec::new();
    for member in device_members {
        if wanted.contains(&member.device_id) {
            found_devices.insert(member.device_id);
            leaf_indices.push(member.leaf_index);
        }
    }
    if found_devices.len() != wanted.len() {
        return Err(anyhow!(
            "one or more target devices are missing from active chat device membership"
        ));
    }
    leaf_indices.sort_unstable();
    Ok(leaf_indices)
}

fn synthesize_control_messages(
    history: &ChatHistoryResponse,
    commit: Option<(MessageId, u64)>,
    welcome_message_id: Option<MessageId>,
) -> Result<Vec<LocalProjectedMessage>> {
    let commit_id = commit.map(|(message_id, _)| message_id);
    let commit_epoch = commit.map(|(_, epoch)| epoch);
    let mut projected_messages = Vec::new();

    for envelope in &history.messages {
        let payload =
            decode_b64_field("ciphertext_b64", &envelope.ciphertext_b64).map_err(|err| {
                anyhow!(
                    "failed to decode control ciphertext {}: {err}",
                    envelope.message_id.0
                )
            })?;
        if Some(envelope.message_id) == commit_id {
            projected_messages.push(LocalProjectedMessage {
                server_seq: envelope.server_seq,
                message_id: envelope.message_id,
                sender_account_id: envelope.sender_account_id,
                sender_device_id: envelope.sender_device_id,
                epoch: envelope.epoch,
                message_kind: envelope.message_kind,
                content_type: envelope.content_type,
                projection_kind: LocalProjectionKind::CommitMerged,
                payload: None,
                merged_epoch: commit_epoch,
                created_at_unix: envelope.created_at_unix,
            });
            continue;
        }
        if Some(envelope.message_id) == welcome_message_id {
            projected_messages.push(LocalProjectedMessage {
                server_seq: envelope.server_seq,
                message_id: envelope.message_id,
                sender_account_id: envelope.sender_account_id,
                sender_device_id: envelope.sender_device_id,
                epoch: envelope.epoch,
                message_kind: envelope.message_kind,
                content_type: envelope.content_type,
                projection_kind: LocalProjectionKind::WelcomeRef,
                payload: Some(payload),
                merged_epoch: None,
                created_at_unix: envelope.created_at_unix,
            });
        }
    }

    Ok(projected_messages)
}

fn merge_store_report(target: &mut LocalStoreApplyReport, incoming: LocalStoreApplyReport) {
    target.chats_upserted += incoming.chats_upserted;
    target.messages_upserted += incoming.messages_upserted;
    let mut changed = target.changed_chat_ids.clone();
    changed.extend(incoming.changed_chat_ids);
    changed.sort_by_key(|chat_id| chat_id.0);
    changed.dedup();
    target.changed_chat_ids = changed;
}

fn merge_projection_report(
    target: &mut LocalStoreApplyReport,
    chat_id: ChatId,
    projection_report: &crate::LocalProjectionApplyReport,
) {
    if projection_report_changed_chat(projection_report)
        && !target.changed_chat_ids.contains(&chat_id)
    {
        target.changed_chat_ids.push(chat_id);
        target.changed_chat_ids.sort_by_key(|id| id.0);
        target.changed_chat_ids.dedup();
    }
}

fn projection_report_changed_chat(projection_report: &crate::LocalProjectionApplyReport) -> bool {
    projection_report.projected_messages_upserted > 0
        || projection_report.advanced_to_server_seq.is_some()
}

fn control_mutation_requires_resync(
    operation: &str,
    chat_id: ChatId,
    error: anyhow::Error,
) -> anyhow::Error {
    anyhow!(
        "requires resync: local state repair is required after successful {operation} for chat {}: {error}",
        chat_id.0
    )
}

fn restore_failed_outbox_send(
    store: &mut LocalHistoryStore,
    chat_id: ChatId,
    sender_account_id: AccountId,
    sender_device_id: DeviceId,
    message_id: MessageId,
    body: &MessageBody,
    queued_at_unix: u64,
    prepared_send: &PreparedLocalOutboxSend,
    failure_message: &str,
) {
    let _ = store.ensure_outbox_message(
        chat_id,
        sender_account_id,
        sender_device_id,
        message_id,
        body.clone(),
        queued_at_unix,
    );
    let _ = store.prepare_outbox_message_send(message_id, prepared_send.clone());
    let _ = store.mark_outbox_failure(message_id, failure_message.to_owned());
}

fn advance_sparse_prefix(prefix: &mut u64, pending: &mut BTreeSet<u64>) -> bool {
    let mut next = prefix.saturating_add(1);
    let mut changed = false;
    while pending.remove(&next) {
        *prefix = next;
        changed = true;
        next = prefix.saturating_add(1);
    }
    changed
}

fn current_unix_seconds() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| anyhow!("system clock is before unix epoch: {err}"))?
        .as_secs())
}

const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";

fn save_state_to_path(
    path: &Path,
    database_key: Option<&[u8]>,
    state: &PersistedSyncState,
) -> Result<()> {
    let mut connection = open_sync_sqlite(path, database_key)?;
    let transaction = connection
        .transaction()
        .context("failed to start sync state transaction")?;

    transaction.execute_batch(
        r#"
        DELETE FROM sync_state_metadata;
        DELETE FROM sync_state_values;
        DELETE FROM sync_state_chat_cursors;
        DELETE FROM sync_state_pending_acked_inbox_ids;
        DELETE FROM sync_state_pending_chat_server_seqs;
        DELETE FROM sync_state_history_sync_target_jobs;
        "#,
    )?;

    transaction.execute(
        r#"
        INSERT INTO sync_state_metadata (key, value)
        VALUES ('version', ?1)
        "#,
        params![state.version.to_string()],
    )?;
    transaction.execute(
        r#"
        INSERT INTO sync_state_values (key, value)
        VALUES ('lease_owner', ?1)
        "#,
        params![state.lease_owner],
    )?;
    transaction.execute(
        r#"
        INSERT INTO sync_state_values (key, value)
        VALUES ('last_acked_inbox_id', ?1)
        "#,
        params![state.last_acked_inbox_id.map(|value| value.to_string())],
    )?;

    let mut pending_ack_statement = transaction.prepare(
        r#"
        INSERT INTO sync_state_pending_acked_inbox_ids (inbox_id)
        VALUES (?1)
        "#,
    )?;
    for inbox_id in &state.pending_acked_inbox_ids {
        pending_ack_statement.execute(params![u64_to_i64(*inbox_id, "pending acked inbox id")?])?;
    }
    drop(pending_ack_statement);

    let mut cursor_statement = transaction.prepare(
        r#"
        INSERT INTO sync_state_chat_cursors (chat_id, last_server_seq)
        VALUES (?1, ?2)
        "#,
    )?;
    for (chat_id, last_server_seq) in &state.chat_cursors {
        cursor_statement.execute(params![
            chat_id,
            u64_to_i64(*last_server_seq, "last_server_seq")?,
        ])?;
    }
    drop(cursor_statement);

    let mut pending_chat_seq_statement = transaction.prepare(
        r#"
        INSERT INTO sync_state_pending_chat_server_seqs (chat_id, server_seq)
        VALUES (?1, ?2)
        "#,
    )?;
    for (chat_id, pending_server_seqs) in &state.pending_chat_server_seqs {
        for server_seq in pending_server_seqs {
            pending_chat_seq_statement.execute(params![
                chat_id,
                u64_to_i64(*server_seq, "pending chat server_seq")?,
            ])?;
        }
    }
    drop(pending_chat_seq_statement);

    let mut history_sync_job_statement = transaction.prepare(
        r#"
        INSERT INTO sync_state_history_sync_target_jobs (
            job_id,
            last_applied_sequence_no,
            applied_final_chunk
        )
        VALUES (?1, ?2, ?3)
        "#,
    )?;
    for (job_id, job_state) in &state.history_sync_target_jobs {
        history_sync_job_statement.execute(params![
            job_id,
            u64_to_i64(
                job_state.last_applied_sequence_no,
                "history sync last_applied_sequence_no",
            )?,
            if job_state.applied_final_chunk { 1 } else { 0 },
        ])?;
    }
    drop(history_sync_job_statement);

    transaction
        .commit()
        .context("failed to commit sync state transaction")?;
    Ok(())
}

fn load_state_from_path(path: &Path) -> Result<PersistedSyncState> {
    if !is_sqlite_database(path)? {
        let state = load_legacy_json_state_from_path(path)?;
        save_state_to_path(path, None, &state)?;
        return Ok(state);
    }

    load_state_from_sqlite(path, None)
}

fn load_state_from_encrypted_path(path: &Path, database_key: &[u8]) -> Result<PersistedSyncState> {
    load_state_from_sqlite(path, Some(database_key))
}

fn load_state_from_sqlite(path: &Path, database_key: Option<&[u8]>) -> Result<PersistedSyncState> {
    let connection = open_sync_sqlite(path, database_key)?;
    let version = connection
        .query_row(
            r#"
            SELECT value
            FROM sync_state_metadata
            WHERE key = 'version'
            "#,
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_else(|| "1".to_owned())
        .parse::<u32>()
        .context("failed to parse sync state version")?;
    if version != 1 && version != 2 && version != 3 {
        return Err(anyhow!(
            "unsupported sync state version {} in {}",
            version,
            path.display()
        ));
    }

    let lease_owner = connection
        .query_row(
            r#"
            SELECT value
            FROM sync_state_values
            WHERE key = 'lease_owner'
            "#,
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let last_acked_inbox_id = connection
        .query_row(
            r#"
            SELECT value
            FROM sync_state_values
            WHERE key = 'last_acked_inbox_id'
            "#,
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten()
        .map(|value| {
            value
                .parse::<u64>()
                .with_context(|| format!("invalid last_acked_inbox_id `{value}`"))
        })
        .transpose()?;

    let mut state = PersistedSyncState {
        version: 3,
        lease_owner,
        last_acked_inbox_id,
        pending_acked_inbox_ids: BTreeSet::new(),
        chat_cursors: BTreeMap::new(),
        pending_chat_server_seqs: BTreeMap::new(),
        history_sync_target_jobs: BTreeMap::new(),
    };

    let mut cursor_statement = connection.prepare(
        r#"
        SELECT chat_id, last_server_seq
        FROM sync_state_chat_cursors
        ORDER BY chat_id
        "#,
    )?;
    let cursor_rows = cursor_statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;
    for row in cursor_rows {
        let (chat_id, last_server_seq) = row?;
        state
            .chat_cursors
            .insert(chat_id, i64_to_u64(last_server_seq, "last_server_seq")?);
    }

    let mut pending_ack_statement = connection.prepare(
        r#"
        SELECT inbox_id
        FROM sync_state_pending_acked_inbox_ids
        ORDER BY inbox_id
        "#,
    )?;
    let pending_ack_rows = pending_ack_statement.query_map([], |row| row.get::<_, i64>(0))?;
    for row in pending_ack_rows {
        state
            .pending_acked_inbox_ids
            .insert(i64_to_u64(row?, "pending acked inbox id")?);
    }

    let mut pending_chat_statement = connection.prepare(
        r#"
        SELECT chat_id, server_seq
        FROM sync_state_pending_chat_server_seqs
        ORDER BY chat_id, server_seq
        "#,
    )?;
    let pending_chat_rows = pending_chat_statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;
    for row in pending_chat_rows {
        let (chat_id, server_seq) = row?;
        state
            .pending_chat_server_seqs
            .entry(chat_id)
            .or_default()
            .insert(i64_to_u64(server_seq, "pending chat server_seq")?);
    }

    let mut history_sync_job_statement = connection.prepare(
        r#"
        SELECT job_id, last_applied_sequence_no, applied_final_chunk
        FROM sync_state_history_sync_target_jobs
        ORDER BY job_id
        "#,
    )?;
    let history_sync_job_rows = history_sync_job_statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    for row in history_sync_job_rows {
        let (job_id, last_applied_sequence_no, applied_final_chunk) = row?;
        state.history_sync_target_jobs.insert(
            job_id,
            PersistedTargetHistorySyncJobState {
                last_applied_sequence_no: i64_to_u64(
                    last_applied_sequence_no,
                    "history sync last_applied_sequence_no",
                )?,
                applied_final_chunk: applied_final_chunk != 0,
            },
        );
    }

    Ok(state)
}

fn load_legacy_json_state_from_path(path: &Path) -> Result<PersistedSyncState> {
    let input_file = File::open(path)
        .with_context(|| format!("failed to open sync state file {}", path.display()))?;
    let mut state: PersistedSyncState =
        serde_json::from_reader(input_file).context("failed to parse sync state file")?;
    if state.version != 1 && state.version != 2 && state.version != 3 {
        return Err(anyhow!(
            "unsupported sync state version {} in {}",
            state.version,
            path.display()
        ));
    }
    if state.version < 3 {
        state.version = 3;
    }
    Ok(state)
}

fn open_sync_sqlite(path: &Path, database_key: Option<&[u8]>) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!("failed to create sync state directory {}", parent.display())
        })?;
    }
    if database_key.is_none() && path.exists() && !is_sqlite_database(path)? {
        fs::remove_file(path)
            .with_context(|| format!("failed to replace legacy sync state {}", path.display()))?;
    }

    let connection = Connection::open(path)
        .with_context(|| format!("failed to open sync state database {}", path.display()))?;
    if let Some(database_key) = database_key {
        configure_sqlcipher_connection(&connection, path, database_key, "sync state")?;
    }
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS sync_state_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_state_values (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        CREATE TABLE IF NOT EXISTS sync_state_chat_cursors (
            chat_id TEXT PRIMARY KEY,
            last_server_seq INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_state_pending_acked_inbox_ids (
            inbox_id INTEGER PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS sync_state_pending_chat_server_seqs (
            chat_id TEXT NOT NULL,
            server_seq INTEGER NOT NULL,
            PRIMARY KEY (chat_id, server_seq)
        );
        CREATE TABLE IF NOT EXISTS sync_state_history_sync_target_jobs (
            job_id TEXT PRIMARY KEY,
            last_applied_sequence_no INTEGER NOT NULL,
            applied_final_chunk INTEGER NOT NULL
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
        .with_context(|| format!("failed to inspect sync state file {}", path.display()))?;
    let mut header = [0u8; 16];
    let bytes_read = file
        .read(&mut header)
        .with_context(|| format!("failed to read sync state file {}", path.display()))?;
    Ok(bytes_read == SQLITE_HEADER.len() && &header == SQLITE_HEADER)
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64> {
    i64::try_from(value).with_context(|| format!("{field} exceeds SQLite integer range"))
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

fn i64_to_u64(value: i64, field: &str) -> Result<u64> {
    u64::try_from(value).with_context(|| format!("{field} must not be negative"))
}

fn should_process_source_history_sync_job(job: &trix_types::HistorySyncJobSummary) -> bool {
    matches!(
        job.job_status,
        HistorySyncJobStatus::Pending | HistorySyncJobStatus::Running
    ) && matches!(
        job.job_type,
        HistorySyncJobType::InitialSync | HistorySyncJobType::ChatBackfill
    )
}

fn should_process_target_history_sync_job(job: &trix_types::HistorySyncJobSummary) -> bool {
    matches!(
        job.job_status,
        HistorySyncJobStatus::Pending
            | HistorySyncJobStatus::Running
            | HistorySyncJobStatus::Completed
    ) && matches!(
        job.job_type,
        HistorySyncJobType::InitialSync | HistorySyncJobType::ChatBackfill
    )
}

fn next_history_sync_sequence_no(metadata: Option<&HistorySyncExportMetadata>) -> u64 {
    let Some(metadata) = metadata else {
        return 1;
    };
    if metadata.projected_message_count == 0 {
        return 1;
    }
    (metadata.projected_message_count as u64).div_ceil(metadata.chunk_message_limit.max(1) as u64)
        + 1
}

fn parse_chat_id(value: &str) -> Result<ChatId> {
    Ok(ChatId(Uuid::parse_str(value).map_err(|err| {
        anyhow!("invalid chat_id in sync state: {err}")
    })?))
}

#[cfg(test)]
mod tests {
    use std::{
        collections::{BTreeMap, BTreeSet},
        env, fs,
        sync::{Arc, Mutex},
    };

    use axum::{
        Json, Router,
        extract::{Path as AxumPath, Query, State},
        http::StatusCode,
        response::IntoResponse,
        routing::{get, post},
    };
    use serde::Deserialize;
    use serde_json::json;
    use tokio::{net::TcpListener, task::JoinHandle};
    use trix_types::{
        AccountId, ChatDetailResponse, ChatId, ChatParticipantProfileSummary, ChatSummary,
        ChatType, ContentType, CreateMessageRequest, CreateMessageResponse, DeviceId,
        ErrorResponse, InboxItem, MessageEnvelope, MessageId, MessageKind,
        PublishKeyPackagesRequest, PublishKeyPackagesResponse, PublishedKeyPackage,
    };
    use uuid::Uuid;

    use super::{
        PersistedSyncState, PersistedTargetHistorySyncJobState, SyncCoordinator,
        is_sqlite_database, merge_projection_report,
    };
    use crate::{
        LocalHistoryStore, LocalOutboxStatus, LocalProjectionKind, LocalStoreApplyReport,
        MessageBody, MlsFacade, MlsProcessResult, ServerApiClient, TextMessageBody,
        decode_b64_field,
    };

    #[derive(Debug, Clone, Deserialize)]
    struct MockHistoryQuery {
        after_server_seq: Option<u64>,
        limit: Option<usize>,
    }

    #[derive(Debug)]
    struct MockChatServerState {
        chat_detail: ChatDetailResponse,
        history: Vec<MessageEnvelope>,
        sender_account_id: AccountId,
        sender_device_id: DeviceId,
        expected_create_epoch: Option<u64>,
        create_requests: Vec<CreateMessageRequest>,
        create_responses: BTreeMap<String, CreateMessageResponse>,
        chat_detail_requests: usize,
        history_requests: usize,
        history_after_server_seq_requests: Vec<Option<u64>>,
        reset_requests: usize,
        published_key_package_requests: Vec<PublishKeyPackagesRequest>,
    }

    struct MockChatServer {
        base_url: String,
        state: Arc<Mutex<MockChatServerState>>,
        task: JoinHandle<()>,
    }

    impl MockChatServer {
        async fn spawn(state: MockChatServerState) -> Self {
            let state = Arc::new(Mutex::new(state));
            let app = Router::new()
                .route("/v0/chats/{chat_id}", get(mock_get_chat))
                .route("/v0/chats/{chat_id}/history", get(mock_get_chat_history))
                .route("/v0/chats/{chat_id}/messages", post(mock_create_message))
                .route("/v0/key-packages:reset", post(mock_reset_key_packages))
                .route("/v0/key-packages:publish", post(mock_publish_key_packages))
                .with_state(state.clone());
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base_url = format!("http://{}", listener.local_addr().unwrap());
            let task = tokio::spawn(async move {
                axum::serve(listener, app)
                    .await
                    .expect("mock chat server should stay up");
            });

            Self {
                base_url,
                state,
                task,
            }
        }

        fn client(&self) -> ServerApiClient {
            ServerApiClient::new(&self.base_url).expect("mock base url should be valid")
        }

        async fn shutdown(self) {
            self.task.abort();
            let _ = self.task.await;
        }
    }

    async fn mock_get_chat(
        AxumPath(chat_id): AxumPath<Uuid>,
        State(state): State<Arc<Mutex<MockChatServerState>>>,
    ) -> impl IntoResponse {
        let mut state = state.lock().unwrap();
        if state.chat_detail.chat_id != ChatId(chat_id) {
            return StatusCode::NOT_FOUND.into_response();
        }
        state.chat_detail_requests += 1;
        Json(state.chat_detail.clone()).into_response()
    }

    async fn mock_get_chat_history(
        AxumPath(chat_id): AxumPath<Uuid>,
        Query(query): Query<MockHistoryQuery>,
        State(state): State<Arc<Mutex<MockChatServerState>>>,
    ) -> impl IntoResponse {
        let mut state = state.lock().unwrap();
        if state.chat_detail.chat_id != ChatId(chat_id) {
            return StatusCode::NOT_FOUND.into_response();
        }
        state.history_requests += 1;
        state
            .history_after_server_seq_requests
            .push(query.after_server_seq);
        let mut messages = state
            .history
            .iter()
            .filter(|message| {
                query
                    .after_server_seq
                    .map(|after| message.server_seq > after)
                    .unwrap_or(true)
            })
            .cloned()
            .collect::<Vec<_>>();
        if let Some(limit) = query.limit {
            messages.truncate(limit);
        }
        Json(trix_types::ChatHistoryResponse {
            chat_id: state.chat_detail.chat_id,
            messages,
        })
        .into_response()
    }

    async fn mock_create_message(
        AxumPath(chat_id): AxumPath<Uuid>,
        State(state): State<Arc<Mutex<MockChatServerState>>>,
        Json(request): Json<CreateMessageRequest>,
    ) -> impl IntoResponse {
        let mut state = state.lock().unwrap();
        if state.chat_detail.chat_id != ChatId(chat_id) {
            return StatusCode::NOT_FOUND.into_response();
        }
        if let Some(expected_epoch) = state.expected_create_epoch
            && request.epoch != expected_epoch
        {
            return (
                StatusCode::CONFLICT,
                Json(ErrorResponse {
                    code: "epoch_conflict".to_owned(),
                    message: format!("expected epoch {expected_epoch}, got {}", request.epoch),
                }),
            )
                .into_response();
        }

        state.create_requests.push(request.clone());
        if let Some(existing) = state
            .create_responses
            .get(&request.message_id.0.to_string())
            .cloned()
        {
            return Json(existing).into_response();
        }

        let server_seq = state
            .history
            .last()
            .map(|message| message.server_seq)
            .unwrap_or_default()
            + 1;
        let envelope = MessageEnvelope {
            message_id: request.message_id,
            chat_id: ChatId(chat_id),
            server_seq,
            sender_account_id: state.sender_account_id,
            sender_device_id: state.sender_device_id,
            epoch: request.epoch,
            message_kind: request.message_kind,
            content_type: request.content_type,
            ciphertext_b64: request.ciphertext_b64.clone(),
            aad_json: request.aad_json.clone().unwrap_or_else(|| json!({})),
            created_at_unix: 1_700_000_000 + server_seq,
        };
        state.history.push(envelope.clone());
        state.chat_detail.last_server_seq = server_seq;
        state.chat_detail.epoch = request.epoch;
        state.chat_detail.last_message = Some(envelope);
        let response = CreateMessageResponse {
            message_id: request.message_id,
            server_seq,
        };
        state
            .create_responses
            .insert(request.message_id.0.to_string(), response.clone());
        Json(response).into_response()
    }

    async fn mock_reset_key_packages(
        State(state): State<Arc<Mutex<MockChatServerState>>>,
    ) -> impl IntoResponse {
        let mut state = state.lock().unwrap();
        state.reset_requests += 1;
        Json(json!({
            "device_id": state.sender_device_id,
            "expired_key_package_count": 1u64,
        }))
        .into_response()
    }

    async fn mock_publish_key_packages(
        State(state): State<Arc<Mutex<MockChatServerState>>>,
        Json(request): Json<PublishKeyPackagesRequest>,
    ) -> impl IntoResponse {
        let mut state = state.lock().unwrap();
        state.published_key_package_requests.push(request.clone());
        Json(PublishKeyPackagesResponse {
            device_id: state.sender_device_id,
            packages: request
                .packages
                .iter()
                .enumerate()
                .map(|(index, package)| PublishedKeyPackage {
                    key_package_id: format!("mock-key-package-{index}"),
                    cipher_suite: package.cipher_suite.clone(),
                })
                .collect(),
        })
        .into_response()
    }

    fn text_body(text: &str) -> MessageBody {
        MessageBody::Text(TextMessageBody {
            text: text.to_owned(),
        })
    }

    fn empty_chat_detail(
        chat_id: ChatId,
        last_server_seq: u64,
        epoch: u64,
        last_message: Option<MessageEnvelope>,
        last_commit_message_id: Option<MessageId>,
    ) -> ChatDetailResponse {
        ChatDetailResponse {
            chat_id,
            chat_type: ChatType::Dm,
            title: None,
            last_server_seq,
            pending_message_count: 0,
            epoch,
            last_commit_message_id,
            last_message,
            participant_profiles: Vec::new(),
            members: Vec::new(),
            device_members: Vec::new(),
        }
    }

    #[test]
    fn sync_coordinator_persists_chat_cursors_and_inbox_cursor() {
        let state_path = env::temp_dir().join(format!("trix-sync-{}.json", Uuid::new_v4()));
        let mut coordinator = SyncCoordinator::new_persistent(&state_path).unwrap();
        let chat_id = ChatId(Uuid::new_v4());

        coordinator.record_chat_server_seq(chat_id, 42).unwrap();
        coordinator.state.last_acked_inbox_id = Some(7);
        coordinator.save_state().unwrap();

        let restored = SyncCoordinator::new_persistent(&state_path).unwrap();
        assert_eq!(restored.chat_cursor(chat_id), Some(42));
        assert_eq!(restored.last_acked_inbox_id(), Some(7));

        fs::remove_file(state_path).ok();
    }

    #[test]
    fn sync_coordinator_persists_history_sync_target_job_progress() {
        let state_path =
            env::temp_dir().join(format!("trix-sync-history-jobs-{}.db", Uuid::new_v4()));
        let mut coordinator = SyncCoordinator::new_persistent(&state_path).unwrap();

        coordinator
            .record_target_history_sync_progress("job-123", 7, true)
            .unwrap();

        let restored = SyncCoordinator::new_persistent(&state_path).unwrap();
        assert_eq!(
            restored.target_history_sync_job_state("job-123"),
            PersistedTargetHistorySyncJobState {
                last_applied_sequence_no: 7,
                applied_final_chunk: true,
            }
        );

        cleanup_sqlite_test_path(&state_path);
    }

    #[test]
    fn sync_coordinator_migrates_legacy_json_state_to_sqlite() {
        let state_path = env::temp_dir().join(format!("trix-sync-legacy-{}.json", Uuid::new_v4()));
        let chat_id = ChatId(Uuid::new_v4());
        let state = PersistedSyncState {
            version: 1,
            lease_owner: "legacy-lease-owner".to_owned(),
            last_acked_inbox_id: Some(12),
            pending_acked_inbox_ids: BTreeSet::new(),
            chat_cursors: BTreeMap::from([(chat_id.0.to_string(), 44)]),
            pending_chat_server_seqs: BTreeMap::new(),
            history_sync_target_jobs: BTreeMap::new(),
        };
        let file = fs::File::create(&state_path).unwrap();
        serde_json::to_writer_pretty(file, &state).unwrap();

        let restored = SyncCoordinator::new_persistent(&state_path).unwrap();
        assert_eq!(restored.lease_owner(), "legacy-lease-owner");
        assert_eq!(restored.last_acked_inbox_id(), Some(12));
        assert_eq!(restored.chat_cursor(chat_id), Some(44));
        assert!(is_sqlite_database(&state_path).unwrap());

        fs::remove_file(state_path).ok();
    }

    #[test]
    fn encrypted_sync_coordinator_round_trips_with_same_key() {
        let state_path = env::temp_dir().join(format!("trix-sync-encrypted-{}.db", Uuid::new_v4()));
        let chat_id = ChatId(Uuid::new_v4());
        let mut coordinator = SyncCoordinator::new_encrypted(&state_path, vec![9u8; 32]).unwrap();

        coordinator.record_chat_server_seq(chat_id, 77).unwrap();
        let acked = (1..=15).collect::<Vec<_>>();
        coordinator.record_acked_inbox_ids(&acked).unwrap();

        let restored = SyncCoordinator::new_encrypted(&state_path, vec![9u8; 32]).unwrap();
        assert_eq!(restored.chat_cursor(chat_id), Some(77));
        assert_eq!(restored.last_acked_inbox_id(), Some(15));

        cleanup_sqlite_test_path(&state_path);
    }

    #[test]
    fn encrypted_sync_coordinator_rejects_wrong_key() {
        let state_path = env::temp_dir().join(format!("trix-sync-wrong-key-{}.db", Uuid::new_v4()));
        SyncCoordinator::new_encrypted(&state_path, vec![3u8; 32]).unwrap();

        let error = SyncCoordinator::new_encrypted(&state_path, vec![4u8; 32]).unwrap_err();
        assert!(
            error.to_string().contains("database key rejected")
                || error.to_string().contains("corrupted")
        );

        cleanup_sqlite_test_path(&state_path);
    }

    #[tokio::test]
    async fn create_chat_control_returns_existing_local_direct_chat() {
        let existing_chat_id = ChatId(Uuid::new_v4());
        let self_account_id = AccountId(Uuid::new_v4());
        let peer_account_id = AccountId(Uuid::new_v4());
        let self_device_id = DeviceId(Uuid::new_v4());
        let mut coordinator = SyncCoordinator::new();
        let mut store = LocalHistoryStore::new();
        let mut facade = MlsFacade::new(b"alice-device".to_vec()).unwrap();

        store
            .apply_chat_list(&trix_types::ChatListResponse {
                chats: vec![ChatSummary {
                    chat_id: existing_chat_id,
                    chat_type: ChatType::Dm,
                    title: None,
                    last_server_seq: 7,
                    epoch: 2,
                    pending_message_count: 0,
                    last_message: None,
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
                }],
            })
            .unwrap();

        let outcome = coordinator
            .create_chat_control(
                &ServerApiClient::new("http://127.0.0.1:9").unwrap(),
                &mut store,
                &mut facade,
                super::CreateChatControlInput {
                    creator_account_id: self_account_id,
                    creator_device_id: self_device_id,
                    chat_type: ChatType::Dm,
                    title: None,
                    participant_account_ids: vec![peer_account_id],
                    group_id: None,
                    commit_aad_json: None,
                    welcome_aad_json: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(outcome.chat_id, existing_chat_id);
        assert_eq!(outcome.chat_type, ChatType::Dm);
        assert_eq!(outcome.epoch, 2);
        assert_eq!(outcome.projected_messages, Vec::new());
    }

    #[test]
    fn apply_inbox_items_advances_chat_cursors() {
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());
        let mut coordinator = SyncCoordinator::new();
        let mut store = LocalHistoryStore::new();

        let report = coordinator
            .apply_inbox_items_into_store(
                &mut store,
                &[
                    InboxItem {
                        inbox_id: 7,
                        message: MessageEnvelope {
                            message_id: MessageId(Uuid::new_v4()),
                            chat_id,
                            server_seq: 1,
                            sender_account_id: account_id,
                            sender_device_id: device_id,
                            epoch: 1,
                            message_kind: MessageKind::Application,
                            content_type: ContentType::Text,
                            ciphertext_b64: crate::encode_b64(b"ciphertext-1"),
                            aad_json: json!({}),
                            created_at_unix: 1,
                        },
                    },
                    InboxItem {
                        inbox_id: 8,
                        message: MessageEnvelope {
                            message_id: MessageId(Uuid::new_v4()),
                            chat_id,
                            server_seq: 3,
                            sender_account_id: account_id,
                            sender_device_id: device_id,
                            epoch: 1,
                            message_kind: MessageKind::Application,
                            content_type: ContentType::Text,
                            ciphertext_b64: crate::encode_b64(b"ciphertext-3"),
                            aad_json: json!({}),
                            created_at_unix: 2,
                        },
                    },
                ],
            )
            .unwrap();

        assert_eq!(report.messages_upserted, 2);
        assert_eq!(coordinator.chat_cursor(chat_id), Some(1));

        coordinator
            .apply_inbox_items_into_store(
                &mut store,
                &[InboxItem {
                    inbox_id: 9,
                    message: MessageEnvelope {
                        message_id: MessageId(Uuid::new_v4()),
                        chat_id,
                        server_seq: 2,
                        sender_account_id: account_id,
                        sender_device_id: device_id,
                        epoch: 1,
                        message_kind: MessageKind::Application,
                        content_type: ContentType::Text,
                        ciphertext_b64: crate::encode_b64(b"ciphertext-2"),
                        aad_json: json!({}),
                        created_at_unix: 3,
                    },
                }],
            )
            .unwrap();
        assert_eq!(coordinator.chat_cursor(chat_id), Some(3));
    }

    #[test]
    fn acked_inbox_ids_advance_only_after_contiguous_gap_is_closed() {
        let mut coordinator = SyncCoordinator::new();

        coordinator.record_acked_inbox_ids(&[11]).unwrap();
        assert_eq!(coordinator.last_acked_inbox_id(), None);

        coordinator.record_acked_inbox_ids(&[10]).unwrap();
        assert_eq!(coordinator.last_acked_inbox_id(), None);

        let leading_prefix = (1..=9).collect::<Vec<_>>();
        coordinator.record_acked_inbox_ids(&leading_prefix).unwrap();
        assert_eq!(coordinator.last_acked_inbox_id(), Some(11));
    }

    #[test]
    fn merge_projection_report_marks_chat_changed_when_cursor_only_advances() {
        let chat_id = ChatId(Uuid::new_v4());
        let mut report = LocalStoreApplyReport {
            chats_upserted: 0,
            messages_upserted: 0,
            changed_chat_ids: Vec::new(),
        };

        merge_projection_report(
            &mut report,
            chat_id,
            &crate::LocalProjectionApplyReport {
                chat_id,
                processed_messages: 0,
                projected_messages_upserted: 0,
                advanced_to_server_seq: Some(3),
            },
        );

        assert_eq!(report.changed_chat_ids, vec![chat_id]);
    }

    #[tokio::test]
    async fn send_message_repairs_stale_group_mapping_before_network_send() {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let mut alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();

        let unrelated_group = alice.create_group(b"stale-group-id").unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut correct_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let add_bundle = alice
            .add_members(&mut correct_group, &[bob_key_package])
            .unwrap();
        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();
        let existing_ciphertext = alice
            .create_application_message(&mut correct_group, b"existing from alice")
            .unwrap();
        let correct_group_id = correct_group.group_id();
        let commit_message_id = MessageId(Uuid::new_v4());
        let welcome_message_id = MessageId(Uuid::new_v4());
        let existing_message_id = MessageId(Uuid::new_v4());
        let history = vec![
            MessageEnvelope {
                message_id: commit_message_id,
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
                message_id: welcome_message_id,
                chat_id,
                server_seq: 2,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: add_bundle.epoch,
                message_kind: MessageKind::WelcomeRef,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(add_bundle.welcome_message.as_ref().unwrap()),
                aad_json: json!({
                    "_trix": {
                        "ratchet_tree_b64": crate::encode_b64(add_bundle.ratchet_tree.as_ref().unwrap())
                    }
                }),
                created_at_unix: 2,
            },
            MessageEnvelope {
                message_id: existing_message_id,
                chat_id,
                server_seq: 3,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: add_bundle.epoch,
                message_kind: MessageKind::Application,
                content_type: ContentType::Text,
                ciphertext_b64: crate::encode_b64(&existing_ciphertext),
                aad_json: json!({}),
                created_at_unix: 3,
            },
        ];

        let mut store = LocalHistoryStore::new();
        store
            .apply_chat_history(&trix_types::ChatHistoryResponse {
                chat_id,
                messages: history.clone(),
            })
            .unwrap();
        let projection = store
            .project_chat_with_facade(chat_id, &alice, None)
            .unwrap();
        assert_eq!(projection.advanced_to_server_seq, Some(3));
        store
            .set_chat_mls_group_id(chat_id, &unrelated_group.group_id())
            .unwrap();

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(
                chat_id,
                3,
                add_bundle.epoch,
                history.last().cloned(),
                Some(commit_message_id),
            ),
            history,
            sender_account_id: alice_account,
            sender_device_id: alice_device,
            expected_create_epoch: Some(add_bundle.epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let mut coordinator = SyncCoordinator::new();
        let body = text_body("fresh after mapping repair");
        let mut conversation = alice
            .load_group(&unrelated_group.group_id())
            .unwrap()
            .unwrap();
        let outcome = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut alice,
                &mut conversation,
                alice_account,
                alice_device,
                chat_id,
                None,
                &body,
                None,
            )
            .await
            .unwrap();

        assert_eq!(outcome.server_seq, 4);
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(correct_group_id.as_slice())
        );

        let state = server.state.lock().unwrap();
        assert_eq!(state.chat_detail_requests, 0);
        assert_eq!(state.history_requests, 0);
        assert_eq!(state.create_requests.len(), 1);
        let ciphertext =
            decode_b64_field("ciphertext_b64", &state.create_requests[0].ciphertext_b64).unwrap();
        drop(state);
        match bob.process_message(&mut bob_group, &ciphertext).unwrap() {
            MlsProcessResult::ApplicationMessage(bytes) => {
                assert_eq!(bytes, body.to_bytes().unwrap())
            }
            other => panic!("expected application message, got {other:?}"),
        }

        server.shutdown().await;
    }

    #[tokio::test]
    async fn send_message_replays_pending_local_commit_before_sending() {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let bob_account = AccountId(Uuid::new_v4());
        let bob_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let mut bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();
        let charlie = MlsFacade::new(b"charlie-device".to_vec()).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let add_bob_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let add_bob_commit_id = MessageId(Uuid::new_v4());
        let add_bob_welcome_id = MessageId(Uuid::new_v4());
        let mut store = LocalHistoryStore::new();
        store
            .apply_chat_history(&trix_types::ChatHistoryResponse {
                chat_id,
                messages: vec![
                    MessageEnvelope {
                        message_id: add_bob_commit_id,
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
                        message_id: add_bob_welcome_id,
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
                ],
            })
            .unwrap();
        store.project_chat_with_facade(chat_id, &bob, None).unwrap();
        assert_eq!(store.projected_cursor(chat_id), Some(2));

        let charlie_key_package = charlie.generate_key_package().unwrap();
        let add_charlie_bundle = alice
            .add_members(&mut alice_group, &[charlie_key_package])
            .unwrap();
        let add_charlie_commit_id = MessageId(Uuid::new_v4());
        let pending_commit = MessageEnvelope {
            message_id: add_charlie_commit_id,
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
        };
        store
            .apply_chat_history(&trix_types::ChatHistoryResponse {
                chat_id,
                messages: vec![pending_commit.clone()],
            })
            .unwrap();
        store
            .apply_chat_detail(&empty_chat_detail(
                chat_id,
                3,
                add_charlie_bundle.epoch,
                Some(pending_commit.clone()),
                Some(add_charlie_commit_id),
            ))
            .unwrap();
        let group_id = store.chat_mls_group_id(chat_id).unwrap();

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(
                chat_id,
                3,
                add_charlie_bundle.epoch,
                Some(pending_commit.clone()),
                Some(add_charlie_commit_id),
            ),
            history: vec![
                MessageEnvelope {
                    message_id: add_bob_commit_id,
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
                    message_id: add_bob_welcome_id,
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
                pending_commit,
            ],
            sender_account_id: bob_account,
            sender_device_id: bob_device,
            expected_create_epoch: Some(add_charlie_bundle.epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let mut coordinator = SyncCoordinator::new();
        let body = text_body("after local commit replay");
        let mut conversation = bob.load_group(&group_id).unwrap().unwrap();
        assert_eq!(conversation.epoch(), add_bob_bundle.epoch);
        let outcome = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut bob,
                &mut conversation,
                bob_account,
                bob_device,
                chat_id,
                None,
                &body,
                None,
            )
            .await
            .unwrap();

        assert_eq!(outcome.server_seq, 4);
        assert_eq!(store.projected_cursor(chat_id), Some(4));
        let state = server.state.lock().unwrap();
        assert_eq!(state.chat_detail_requests, 1);
        assert_eq!(state.history_requests, 1);
        assert_eq!(state.create_requests.len(), 1);
        assert_eq!(state.create_requests[0].epoch, add_charlie_bundle.epoch);
        drop(state);
        assert_eq!(
            bob.load_group(&group_id).unwrap().unwrap().epoch(),
            add_charlie_bundle.epoch
        );

        server.shutdown().await;
    }

    #[tokio::test]
    async fn send_message_retry_reuses_persisted_outbox_after_local_apply_failure() {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let mls_root = env::temp_dir().join(format!("trix-sync-send-retry-mls-{}", Uuid::new_v4()));
        let store_path =
            env::temp_dir().join(format!("trix-sync-send-retry-store-{}.db", Uuid::new_v4()));
        let mut facade = MlsFacade::new_persistent(b"alice-device".to_vec(), &mls_root).unwrap();
        let initial_conversation = facade.create_group(chat_id.0.as_bytes()).unwrap();
        let initial_epoch = initial_conversation.epoch();
        let group_id = initial_conversation.group_id();
        drop(initial_conversation);

        let mut store = LocalHistoryStore::new_persistent(&store_path).unwrap();
        store
            .apply_chat_detail(&empty_chat_detail(chat_id, 0, initial_epoch, None, None))
            .unwrap();
        store.set_chat_mls_group_id(chat_id, &group_id).unwrap();

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(chat_id, 0, initial_epoch, None, None),
            history: Vec::new(),
            sender_account_id: alice_account,
            sender_device_id: alice_device,
            expected_create_epoch: Some(initial_epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let body = text_body("retry after local failure");
        let mut coordinator = SyncCoordinator::new();
        let mut conversation = facade.load_group(&group_id).unwrap().unwrap();
        store.inject_save_failure_after(2);
        let error = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut facade,
                &mut conversation,
                alice_account,
                alice_device,
                chat_id,
                None,
                &body,
                None,
            )
            .await
            .expect_err("apply_outgoing_message should fail after server accepted the send");
        assert!(
            error
                .to_string()
                .contains("injected local history save failure")
        );

        let failed_outbox = store.list_outbox_messages(Some(chat_id));
        assert_eq!(failed_outbox.len(), 1);
        assert_eq!(failed_outbox[0].status, LocalOutboxStatus::Failed);
        assert!(failed_outbox[0].prepared_send.is_some());
        let message_id = failed_outbox[0].message_id;
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
        assert_eq!(store.projected_cursor(chat_id), Some(0));

        drop(conversation);
        drop(store);
        drop(facade);

        let mut store = LocalHistoryStore::new_persistent(&store_path).unwrap();
        let mut facade = MlsFacade::load_persistent(&mls_root).unwrap();
        let reloaded_outbox = store.list_outbox_messages(Some(chat_id));
        assert_eq!(reloaded_outbox.len(), 1);
        assert_eq!(reloaded_outbox[0].message_id, message_id);
        assert_eq!(reloaded_outbox[0].status, LocalOutboxStatus::Failed);
        assert!(reloaded_outbox[0].prepared_send.is_some());
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
        assert_eq!(store.projected_cursor(chat_id), Some(0));
        assert_eq!(
            store
                .outbox_message(message_id)
                .map(|message| message.message_id),
            Some(message_id)
        );

        let mut conversation = facade.load_group(&group_id).unwrap().unwrap();
        let outcome = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut facade,
                &mut conversation,
                alice_account,
                alice_device,
                chat_id,
                Some(message_id),
                &body,
                None,
            )
            .await
            .unwrap();

        let state = server.state.lock().unwrap();
        assert_eq!(state.create_requests.len(), 2);
        assert_eq!(state.create_requests[1].message_id, message_id);
        assert_eq!(state.history.len(), 1);
        assert_eq!(state.history[0].message_id, message_id);
        drop(state);
        assert_eq!(outcome.message_id, message_id);
        assert!(store.outbox_message(message_id).is_none());
        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 1);
        assert_eq!(
            projected[0].payload.as_deref(),
            Some(body.to_bytes().unwrap().as_slice())
        );

        server.shutdown().await;
        cleanup_sqlite_test_path(&store_path);
        fs::remove_dir_all(&mls_root).ok();
    }

    #[tokio::test]
    async fn send_message_without_explicit_message_id_keeps_identical_bodies_distinct() {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let mls_root =
            env::temp_dir().join(format!("trix-sync-send-duplicate-mls-{}", Uuid::new_v4()));
        let store_path = env::temp_dir().join(format!(
            "trix-sync-send-duplicate-store-{}.db",
            Uuid::new_v4()
        ));
        let mut facade = MlsFacade::new_persistent(b"alice-device".to_vec(), &mls_root).unwrap();
        let initial_conversation = facade.create_group(chat_id.0.as_bytes()).unwrap();
        let initial_epoch = initial_conversation.epoch();
        let group_id = initial_conversation.group_id();
        drop(initial_conversation);

        let mut store = LocalHistoryStore::new_persistent(&store_path).unwrap();
        store
            .apply_chat_detail(&empty_chat_detail(chat_id, 0, initial_epoch, None, None))
            .unwrap();
        store.set_chat_mls_group_id(chat_id, &group_id).unwrap();

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(chat_id, 0, initial_epoch, None, None),
            history: Vec::new(),
            sender_account_id: alice_account,
            sender_device_id: alice_device,
            expected_create_epoch: Some(initial_epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let body = text_body("same body, separate sends");
        let mut coordinator = SyncCoordinator::new();
        let mut conversation = facade.load_group(&group_id).unwrap().unwrap();
        let first = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut facade,
                &mut conversation,
                alice_account,
                alice_device,
                chat_id,
                None,
                &body,
                None,
            )
            .await
            .unwrap();
        let second = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut facade,
                &mut conversation,
                alice_account,
                alice_device,
                chat_id,
                None,
                &body,
                None,
            )
            .await
            .unwrap();

        assert_ne!(first.message_id, second.message_id);
        let state = server.state.lock().unwrap();
        assert_eq!(state.create_requests.len(), 2);
        assert_ne!(
            state.create_requests[0].message_id,
            state.create_requests[1].message_id
        );
        assert_eq!(state.history.len(), 2);
        assert_ne!(state.history[0].message_id, state.history[1].message_id);
        drop(state);

        let projected = store.get_projected_messages(chat_id, None, Some(10));
        assert_eq!(projected.len(), 2);
        assert_eq!(
            projected[0].payload.as_deref(),
            Some(body.to_bytes().unwrap().as_slice())
        );
        assert_eq!(
            projected[1].payload.as_deref(),
            Some(body.to_bytes().unwrap().as_slice())
        );

        server.shutdown().await;
        cleanup_sqlite_test_path(&store_path);
        fs::remove_dir_all(&mls_root).ok();
    }

    #[tokio::test]
    async fn send_message_bootstraps_from_full_history_when_cursor_is_ahead_and_local_bootstrap_is_missing()
     {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let bob_account = AccountId(Uuid::new_v4());
        let bob_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let mut bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let existing_body = text_body("existing from alice");
        let existing_body_bytes = existing_body.to_bytes().unwrap();
        let existing_ciphertext = alice
            .create_application_message(&mut alice_group, &existing_body_bytes)
            .unwrap();
        let commit_message_id = MessageId(Uuid::new_v4());
        let welcome_message_id = MessageId(Uuid::new_v4());
        let existing_message_id = MessageId(Uuid::new_v4());
        let existing_message = MessageEnvelope {
            message_id: existing_message_id,
            chat_id,
            server_seq: 3,
            sender_account_id: alice_account,
            sender_device_id: alice_device,
            epoch: add_bundle.epoch,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: crate::encode_b64(&existing_ciphertext),
            aad_json: json!({}),
            created_at_unix: 3,
        };
        let history = vec![
            MessageEnvelope {
                message_id: commit_message_id,
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
                message_id: welcome_message_id,
                chat_id,
                server_seq: 2,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: add_bundle.epoch,
                message_kind: MessageKind::WelcomeRef,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(add_bundle.welcome_message.as_ref().unwrap()),
                aad_json: json!({
                    "_trix": {
                        "ratchet_tree_b64": crate::encode_b64(
                            add_bundle.ratchet_tree.as_ref().unwrap()
                        )
                    }
                }),
                created_at_unix: 2,
            },
            existing_message.clone(),
        ];

        let mut store = LocalHistoryStore::new();
        store
            .apply_chat_detail(&empty_chat_detail(
                chat_id,
                3,
                add_bundle.epoch,
                Some(existing_message.clone()),
                Some(commit_message_id),
            ))
            .unwrap();
        store
            .apply_chat_history(&trix_types::ChatHistoryResponse {
                chat_id,
                messages: vec![existing_message.clone()],
            })
            .unwrap();
        store
            .apply_local_projection(
                &existing_message,
                LocalProjectionKind::ApplicationMessage,
                Some(existing_body_bytes.clone()),
                None,
            )
            .unwrap();
        assert_eq!(store.projected_cursor(chat_id), Some(3));
        assert!(store.chat_mls_group_id(chat_id).is_none());
        assert!(!store.needs_history_refresh(chat_id));

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(
                chat_id,
                3,
                add_bundle.epoch,
                Some(existing_message.clone()),
                Some(commit_message_id),
            ),
            history,
            sender_account_id: bob_account,
            sender_device_id: bob_device,
            expected_create_epoch: Some(add_bundle.epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let mut coordinator = SyncCoordinator::new();
        coordinator.record_chat_server_seq(chat_id, 3).unwrap();

        let send_body = text_body("fresh after bootstrap repair");
        let send_body_bytes = send_body.to_bytes().unwrap();
        let expected_group_id = alice_group.group_id();
        let mut conversation = bob.create_group(b"placeholder-conversation").unwrap();
        let outcome = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut bob,
                &mut conversation,
                bob_account,
                bob_device,
                chat_id,
                None,
                &send_body,
                None,
            )
            .await
            .unwrap();

        assert_eq!(outcome.server_seq, 4);
        assert_eq!(coordinator.chat_cursor(chat_id), Some(4));
        assert_eq!(conversation.group_id(), expected_group_id);
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(expected_group_id.as_slice())
        );

        let state = server.state.lock().unwrap();
        assert_eq!(state.chat_detail_requests, 1);
        assert_eq!(state.history_requests, 1);
        assert_eq!(state.history_after_server_seq_requests, vec![None]);
        assert_eq!(state.create_requests.len(), 1);
        let ciphertext =
            decode_b64_field("ciphertext_b64", &state.create_requests[0].ciphertext_b64).unwrap();
        drop(state);
        match alice
            .process_message(&mut alice_group, &ciphertext)
            .unwrap()
        {
            MlsProcessResult::ApplicationMessage(bytes) => assert_eq!(bytes, send_body_bytes),
            other => panic!("expected application message, got {other:?}"),
        }

        server.shutdown().await;
    }

    #[tokio::test]
    async fn send_message_refreshes_full_history_and_recovers_from_newer_valid_welcome_after_local_bootstrap_loss()
     {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let current_account = AccountId(Uuid::new_v4());
        let current_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let stale_member = MlsFacade::new(b"stale-device".to_vec()).unwrap();
        let mut current_member = MlsFacade::new(b"current-device".to_vec()).unwrap();

        let stale_key_package = stale_member.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let stale_add_bundle = alice
            .add_members(&mut alice_group, &[stale_key_package])
            .unwrap();
        let fresh_key_package = current_member.generate_key_package().unwrap();
        let fresh_add_bundle = alice
            .add_members(&mut alice_group, &[fresh_key_package])
            .unwrap();
        let expected_group_id = alice_group.group_id();

        let stale_commit_message_id = MessageId(Uuid::new_v4());
        let stale_welcome_message_id = MessageId(Uuid::new_v4());
        let fresh_commit_message_id = MessageId(Uuid::new_v4());
        let fresh_welcome_message_id = MessageId(Uuid::new_v4());
        let stale_history = vec![
            MessageEnvelope {
                message_id: stale_commit_message_id,
                chat_id,
                server_seq: 1,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: stale_add_bundle.epoch,
                message_kind: MessageKind::Commit,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(&stale_add_bundle.commit_message),
                aad_json: json!({}),
                created_at_unix: 1,
            },
            MessageEnvelope {
                message_id: stale_welcome_message_id,
                chat_id,
                server_seq: 2,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: stale_add_bundle.epoch,
                message_kind: MessageKind::WelcomeRef,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(
                    stale_add_bundle.welcome_message.as_ref().unwrap(),
                ),
                aad_json: json!({
                    "_trix": {
                        "ratchet_tree_b64": crate::encode_b64(
                            stale_add_bundle.ratchet_tree.as_ref().unwrap()
                        )
                    }
                }),
                created_at_unix: 2,
            },
        ];
        let full_history = vec![
            stale_history[0].clone(),
            stale_history[1].clone(),
            MessageEnvelope {
                message_id: fresh_commit_message_id,
                chat_id,
                server_seq: 3,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: fresh_add_bundle.epoch,
                message_kind: MessageKind::Commit,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(&fresh_add_bundle.commit_message),
                aad_json: json!({}),
                created_at_unix: 3,
            },
            MessageEnvelope {
                message_id: fresh_welcome_message_id,
                chat_id,
                server_seq: 4,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: fresh_add_bundle.epoch,
                message_kind: MessageKind::WelcomeRef,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(
                    fresh_add_bundle.welcome_message.as_ref().unwrap(),
                ),
                aad_json: json!({
                    "_trix": {
                        "ratchet_tree_b64": crate::encode_b64(
                            fresh_add_bundle.ratchet_tree.as_ref().unwrap()
                        )
                    }
                }),
                created_at_unix: 4,
            },
        ];

        let mut store = LocalHistoryStore::new();
        store
            .apply_chat_detail(&empty_chat_detail(
                chat_id,
                2,
                stale_add_bundle.epoch,
                Some(stale_history[1].clone()),
                Some(stale_commit_message_id),
            ))
            .unwrap();
        store
            .apply_chat_history(&trix_types::ChatHistoryResponse {
                chat_id,
                messages: stale_history,
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, b"stale-group-id")
            .unwrap();

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(
                chat_id,
                4,
                fresh_add_bundle.epoch,
                Some(full_history[3].clone()),
                Some(fresh_commit_message_id),
            ),
            history: full_history,
            sender_account_id: current_account,
            sender_device_id: current_device,
            expected_create_epoch: Some(fresh_add_bundle.epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let mut coordinator = SyncCoordinator::new();
        let send_body = text_body("fresh after welcome recovery");
        let send_body_bytes = send_body.to_bytes().unwrap();
        let mut conversation = current_member
            .create_group(b"placeholder-conversation")
            .unwrap();
        let outcome = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut current_member,
                &mut conversation,
                current_account,
                current_device,
                chat_id,
                None,
                &send_body,
                None,
            )
            .await
            .unwrap();

        assert_eq!(outcome.server_seq, 5);
        assert_eq!(coordinator.chat_cursor(chat_id), Some(5));
        assert_eq!(conversation.group_id(), expected_group_id);
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(expected_group_id.as_slice())
        );

        let state = server.state.lock().unwrap();
        assert_eq!(state.chat_detail_requests, 1);
        assert_eq!(state.history_requests, 1);
        assert_eq!(state.history_after_server_seq_requests, vec![None]);
        assert_eq!(state.create_requests.len(), 1);
        let ciphertext =
            decode_b64_field("ciphertext_b64", &state.create_requests[0].ciphertext_b64).unwrap();
        drop(state);
        match alice
            .process_message(&mut alice_group, &ciphertext)
            .unwrap()
        {
            MlsProcessResult::ApplicationMessage(bytes) => assert_eq!(bytes, send_body_bytes),
            other => panic!("expected application message, got {other:?}"),
        }

        server.shutdown().await;
    }

    #[tokio::test]
    async fn send_message_returns_rebootstrap_guidance_when_no_matching_key_package_exists_even_after_refresh()
     {
        let chat_id = ChatId(Uuid::new_v4());
        let alice_account = AccountId(Uuid::new_v4());
        let alice_device = DeviceId(Uuid::new_v4());
        let current_account = AccountId(Uuid::new_v4());
        let current_device = DeviceId(Uuid::new_v4());
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let stale_member = MlsFacade::new(b"stale-device".to_vec()).unwrap();
        let mut current_member = MlsFacade::new(b"current-device".to_vec()).unwrap();

        let stale_key_package = stale_member.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(chat_id.0.as_bytes()).unwrap();
        let stale_add_bundle = alice
            .add_members(&mut alice_group, &[stale_key_package])
            .unwrap();

        let stale_commit_message_id = MessageId(Uuid::new_v4());
        let stale_welcome_message_id = MessageId(Uuid::new_v4());
        let full_history = vec![
            MessageEnvelope {
                message_id: stale_commit_message_id,
                chat_id,
                server_seq: 1,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: stale_add_bundle.epoch,
                message_kind: MessageKind::Commit,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(&stale_add_bundle.commit_message),
                aad_json: json!({}),
                created_at_unix: 1,
            },
            MessageEnvelope {
                message_id: stale_welcome_message_id,
                chat_id,
                server_seq: 2,
                sender_account_id: alice_account,
                sender_device_id: alice_device,
                epoch: stale_add_bundle.epoch,
                message_kind: MessageKind::WelcomeRef,
                content_type: ContentType::ChatEvent,
                ciphertext_b64: crate::encode_b64(
                    stale_add_bundle.welcome_message.as_ref().unwrap(),
                ),
                aad_json: json!({
                    "_trix": {
                        "ratchet_tree_b64": crate::encode_b64(
                            stale_add_bundle.ratchet_tree.as_ref().unwrap()
                        )
                    }
                }),
                created_at_unix: 2,
            },
        ];

        let mut store = LocalHistoryStore::new();
        store
            .apply_chat_detail(&empty_chat_detail(
                chat_id,
                2,
                stale_add_bundle.epoch,
                Some(full_history[1].clone()),
                Some(stale_commit_message_id),
            ))
            .unwrap();
        store
            .apply_chat_history(&trix_types::ChatHistoryResponse {
                chat_id,
                messages: full_history.clone(),
            })
            .unwrap();
        store
            .set_chat_mls_group_id(chat_id, b"stale-group-id")
            .unwrap();

        let server = MockChatServer::spawn(MockChatServerState {
            chat_detail: empty_chat_detail(
                chat_id,
                2,
                stale_add_bundle.epoch,
                Some(full_history[1].clone()),
                Some(stale_commit_message_id),
            ),
            history: full_history,
            sender_account_id: current_account,
            sender_device_id: current_device,
            expected_create_epoch: Some(stale_add_bundle.epoch),
            create_requests: Vec::new(),
            create_responses: BTreeMap::new(),
            chat_detail_requests: 0,
            history_requests: 0,
            history_after_server_seq_requests: Vec::new(),
            reset_requests: 0,
            published_key_package_requests: Vec::new(),
        })
        .await;
        let client = server.client();

        let mut coordinator = SyncCoordinator::new();
        let mut conversation = current_member
            .create_group(b"placeholder-conversation")
            .unwrap();
        let error = coordinator
            .send_message_body(
                &client,
                &mut store,
                &mut current_member,
                &mut conversation,
                current_account,
                current_device,
                chat_id,
                None,
                &text_body("should fail with recovery guidance"),
                None,
            )
            .await
            .expect_err("missing key package should produce rebootstrap guidance");

        assert_eq!(
            error.to_string(),
            "This chat can't be opened on this device because its local bootstrap keys were lost. Open it on another active device and add this device to the chat again, then try again here."
        );

        let state = server.state.lock().unwrap();
        assert_eq!(state.chat_detail_requests, 1);
        assert_eq!(state.history_requests, 1);
        assert!(state.create_requests.is_empty());
        assert_eq!(state.reset_requests, 1);
        assert_eq!(state.published_key_package_requests.len(), 1);
        assert_eq!(state.published_key_package_requests[0].packages.len(), 12);
        drop(state);

        server.shutdown().await;
    }

    fn cleanup_sqlite_test_path(path: &std::path::Path) {
        fs::remove_file(path).ok();
        fs::remove_file(format!("{}-wal", path.display())).ok();
        fs::remove_file(format!("{}-shm", path.display())).ok();
    }
}
