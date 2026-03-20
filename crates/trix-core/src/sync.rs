use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, File},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use trix_types::{
    AccountId, AckInboxResponse, ChatDetailResponse, ChatDeviceSummary, ChatHistoryResponse,
    ChatId, ChatType, CreateChatRequest, DeviceId, LeaseInboxRequest, LeaseInboxResponse,
    MessageEnvelope, MessageId, MessageKind, ModifyChatDevicesRequest, ModifyChatMembersRequest,
};
use uuid::Uuid;

use crate::{
    LocalHistoryStore, LocalOutgoingMessageApplyOutcome, LocalProjectedMessage,
    LocalProjectionKind, LocalStoreApplyReport, MessageBody, MlsConversation, MlsFacade,
    ServerApiClient, SyncStateStore, decode_b64_field, encode_b64, make_create_message_request,
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

    pub async fn create_chat_control(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &mut MlsFacade,
        input: CreateChatControlInput,
    ) -> Result<CreateChatControlOutcome> {
        let participant_account_ids =
            normalize_account_ids(input.participant_account_ids, input.creator_account_id);
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
                    crate::make_control_message_input(
                        welcome_message_id,
                        welcome,
                        input.welcome_aad_json,
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
                return Err(err.into());
            }
        };

        let (detail, history, mut report) = self
            .refresh_chat_state(client, store, response.chat_id, None)
            .await?;
        store.set_chat_mls_group_id(response.chat_id, &group_id)?;
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
                chats_upserted: usize::from(projection_report.projected_messages_upserted > 0),
                messages_upserted: 0,
                changed_chat_ids: if projection_report.projected_messages_upserted > 0 {
                    vec![response.chat_id]
                } else {
                    Vec::new()
                },
            },
        );
        self.record_chat_server_seq(response.chat_id, detail.last_server_seq)?;

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
                        crate::make_control_message_input(
                            welcome_message_id,
                            welcome,
                            input.welcome_aad_json,
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

        let (_, history, mut report) = self
            .refresh_chat_state(client, store, input.chat_id, after_server_seq)
            .await?;
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

        let (_, history, mut report) = self
            .refresh_chat_state(client, store, input.chat_id, after_server_seq)
            .await?;
        let projected_messages = synthesize_control_messages(
            &history,
            Some((commit_message_id, remove_bundle.epoch)),
            None,
        )?;
        let projection_report =
            store.apply_projected_messages(input.chat_id, &projected_messages)?;
        merge_projection_report(&mut report, input.chat_id, &projection_report);

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
                        crate::make_control_message_input(
                            welcome_message_id,
                            welcome,
                            input.welcome_aad_json,
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

        let (_, history, mut report) = self
            .refresh_chat_state(client, store, input.chat_id, after_server_seq)
            .await?;
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

        let (_, history, mut report) = self
            .refresh_chat_state(client, store, input.chat_id, after_server_seq)
            .await?;
        let projected_messages = synthesize_control_messages(
            &history,
            Some((commit_message_id, remove_bundle.epoch)),
            None,
        )?;
        let projection_report =
            store.apply_projected_messages(input.chat_id, &projected_messages)?;
        merge_projection_report(&mut report, input.chat_id, &projection_report);

        Ok(ModifyChatDevicesControlOutcome {
            chat_id: response.chat_id,
            epoch: response.epoch,
            changed_device_ids: response.changed_device_ids,
            report,
            projected_messages,
        })
    }

    async fn prepare_chat_control_context(
        &mut self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        facade: &MlsFacade,
        chat_id: ChatId,
    ) -> Result<(ChatDetailResponse, MlsConversation)> {
        let group_id = store
            .chat_mls_group_id(chat_id)
            .ok_or_else(|| anyhow!("chat {} has no MLS group id in local store", chat_id.0))?;
        let mut conversation = facade.load_group(&group_id)?.ok_or_else(|| {
            anyhow!(
                "MLS group for chat {} is missing from facade storage",
                chat_id.0
            )
        })?;
        let history = client
            .get_chat_history(chat_id, self.chat_cursor(chat_id), None)
            .await?;
        if let Some(last_server_seq) = history
            .messages
            .iter()
            .map(|message| message.server_seq)
            .max()
        {
            self.record_chat_server_seq(chat_id, last_server_seq)?;
        }
        store.apply_chat_history(&history)?;
        store.project_chat_messages(chat_id, facade, &mut conversation, None)?;
        let detail = client.get_chat(chat_id).await?;
        store.apply_chat_detail(&detail)?;
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
        if let Some(last_server_seq) = history
            .messages
            .iter()
            .map(|message| message.server_seq)
            .max()
        {
            self.record_chat_server_seq(chat_id, last_server_seq)?;
        }
        merge_store_report(&mut report, store.apply_chat_history(&history)?);
        Ok((detail, history, report))
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
    if projection_report.projected_messages_upserted > 0
        && !target.changed_chat_ids.contains(&chat_id)
    {
        target.changed_chat_ids.push(chat_id);
        target.changed_chat_ids.sort_by_key(|id| id.0);
        target.changed_chat_ids.dedup();
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
