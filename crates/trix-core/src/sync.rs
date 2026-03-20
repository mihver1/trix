use std::{
    collections::BTreeMap,
    fs::{self, File},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use trix_types::{
    AckInboxResponse, ChatHistoryResponse, ChatId, LeaseInboxRequest, LeaseInboxResponse,
    MessageEnvelope, MessageId, MessageKind,
};
use uuid::Uuid;

use crate::{
    LocalHistoryStore, LocalOutgoingMessageApplyOutcome, LocalProjectedMessage,
    LocalStoreApplyReport, MessageBody, MlsConversation, MlsFacade, ServerApiClient,
    SyncStateStore, encode_b64, make_create_message_request,
};

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

#[derive(Debug, Clone)]
pub struct SendMessageOutcome {
    pub chat_id: ChatId,
    pub message_id: MessageId,
    pub server_seq: u64,
    pub report: LocalStoreApplyReport,
    pub projected_message: LocalProjectedMessage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedSyncState {
    version: u32,
    lease_owner: String,
    last_acked_inbox_id: Option<u64>,
    chat_cursors: BTreeMap<String, u64>,
}

impl Default for PersistedSyncState {
    fn default() -> Self {
        Self {
            version: 1,
            lease_owner: Uuid::new_v4().to_string(),
            last_acked_inbox_id: None,
            chat_cursors: BTreeMap::new(),
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

    pub fn save_state(&self) -> Result<()> {
        let Some(store) = &self.store else {
            return Ok(());
        };
        save_state_to_path(&store.state_path, &self.state)
    }

    pub fn state_path(&self) -> Option<&Path> {
        self.store.as_ref().map(|store| store.state_path.as_path())
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

    pub fn record_chat_server_seq(&mut self, chat_id: ChatId, server_seq: u64) -> Result<bool> {
        let key = chat_id.0.to_string();
        let current = self
            .state
            .chat_cursors
            .get(&key)
            .copied()
            .unwrap_or_default();
        if server_seq <= current {
            return Ok(false);
        }
        self.state.chat_cursors.insert(key, server_seq);
        self.save_state()?;
        Ok(true)
    }

    pub async fn sync_chat_histories(
        &mut self,
        client: &ServerApiClient,
        limit_per_chat: usize,
    ) -> Result<Vec<ChatHistoryResponse>> {
        let chats = client.list_chats().await?;
        let mut updated_histories = Vec::new();
        let mut state_changed = false;

        for chat in chats.chats {
            let history = client
                .get_chat_history(
                    chat.chat_id,
                    self.chat_cursor(chat.chat_id),
                    Some(limit_per_chat),
                )
                .await?;

            if let Some(last_server_seq) = history
                .messages
                .iter()
                .map(|message| message.server_seq)
                .max()
            {
                let key = history.chat_id.0.to_string();
                let current = self
                    .state
                    .chat_cursors
                    .get(&key)
                    .copied()
                    .unwrap_or_default();
                if last_server_seq > current {
                    self.state.chat_cursors.insert(key, last_server_seq);
                    state_changed = true;
                }
            }

            if !history.messages.is_empty() {
                updated_histories.push(history);
            }
        }

        if state_changed {
            self.save_state()?;
        }

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

        for chat in chats.chats {
            let history = client
                .get_chat_history(
                    chat.chat_id,
                    self.chat_cursor(chat.chat_id),
                    Some(limit_per_chat),
                )
                .await?;
            if let Some(last_server_seq) = history
                .messages
                .iter()
                .map(|message| message.server_seq)
                .max()
            {
                self.record_chat_server_seq(history.chat_id, last_server_seq)?;
            }
            let report = store.apply_chat_history(&history)?;
            combined.chats_upserted += report.chats_upserted;
            combined.messages_upserted += report.messages_upserted;
            changed_chat_ids.extend(report.changed_chat_ids);
        }

        changed_chat_ids.sort_by_key(|chat_id| chat_id.0);
        changed_chat_ids.dedup();
        combined.changed_chat_ids = changed_chat_ids;
        Ok(combined)
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
        if let Some(max_inbox_id) = response.acked_inbox_ids.iter().copied().max() {
            let current = self.state.last_acked_inbox_id.unwrap_or_default();
            if max_inbox_id > current {
                self.state.last_acked_inbox_id = Some(max_inbox_id);
                self.save_state()?;
            }
        }
        Ok(response)
    }

    pub async fn lease_inbox_into_store(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        limit: Option<usize>,
        lease_ttl_seconds: Option<u64>,
    ) -> Result<InboxApplyOutcome> {
        let lease = self.lease_inbox(client, limit, lease_ttl_seconds).await?;
        let report = store.apply_inbox_items(&lease.items)?;
        for item in &lease.items {
            self.record_chat_server_seq(item.message.chat_id, item.message.server_seq)?;
        }
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
        facade: &MlsFacade,
        conversation: &mut MlsConversation,
        sender_account_id: trix_types::AccountId,
        sender_device_id: trix_types::DeviceId,
        chat_id: ChatId,
        message_id: Option<MessageId>,
        body: &MessageBody,
        aad_json: Option<Value>,
    ) -> Result<SendMessageOutcome> {
        let plaintext = body.to_bytes()?;
        let epoch = conversation.epoch();
        let message_id = message_id.unwrap_or_default();
        let ciphertext = facade.create_application_message(conversation, &plaintext)?;
        let response = client
            .create_message(
                chat_id,
                make_create_message_request(
                    message_id,
                    epoch,
                    MessageKind::Application,
                    body.content_type(),
                    &ciphertext,
                    aad_json.clone(),
                ),
            )
            .await?;

        let envelope = MessageEnvelope {
            message_id: response.message_id,
            chat_id,
            server_seq: response.server_seq,
            sender_account_id,
            sender_device_id,
            epoch,
            message_kind: MessageKind::Application,
            content_type: body.content_type(),
            ciphertext_b64: encode_b64(&ciphertext),
            aad_json: aad_json.unwrap_or(Value::Null),
            created_at_unix: current_unix_seconds()?,
        };
        let LocalOutgoingMessageApplyOutcome {
            report,
            projected_message,
        } = store.apply_outgoing_message(&envelope, body)?;
        self.record_chat_server_seq(chat_id, response.server_seq)?;

        Ok(SendMessageOutcome {
            chat_id,
            message_id: response.message_id,
            server_seq: response.server_seq,
            report,
            projected_message,
        })
    }
}

fn current_unix_seconds() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| anyhow!("system clock is before unix epoch: {err}"))?
        .as_secs())
}

fn save_state_to_path(path: &Path, state: &PersistedSyncState) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!("failed to create sync state directory {}", parent.display())
        })?;
    }

    let tmp_path = path.with_extension("tmp");
    let output_file = File::create(&tmp_path).with_context(|| {
        format!(
            "failed to create temporary sync state file {}",
            tmp_path.display()
        )
    })?;
    serde_json::to_writer_pretty(output_file, state).context("failed to write sync state")?;
    fs::rename(&tmp_path, path)
        .with_context(|| format!("failed to replace sync state file {}", path.display()))?;
    Ok(())
}

fn load_state_from_path(path: &Path) -> Result<PersistedSyncState> {
    let input_file = File::open(path)
        .with_context(|| format!("failed to open sync state file {}", path.display()))?;
    let state: PersistedSyncState =
        serde_json::from_reader(input_file).context("failed to parse sync state file")?;
    if state.version != 1 {
        return Err(anyhow!(
            "unsupported sync state version {} in {}",
            state.version,
            path.display()
        ));
    }
    Ok(state)
}

fn parse_chat_id(value: &str) -> Result<ChatId> {
    Ok(ChatId(Uuid::parse_str(value).map_err(|err| {
        anyhow!("invalid chat_id in sync state: {err}")
    })?))
}

#[cfg(test)]
mod tests {
    use std::{env, fs};

    use uuid::Uuid;

    use super::SyncCoordinator;
    use trix_types::ChatId;

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
}
