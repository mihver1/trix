use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::runtime::{Builder, Runtime};
use trix_types::{AccountId, ChatId, DeviceId, DeviceStatus, MessageId};
use uuid::Uuid;

use crate::{
    AttachmentMessageBody, AuthChallengeMaterial, CompleteLinkIntentParams, CreateChatControlInput,
    DeviceKeyMaterial, FfiChatType, FfiContentType, FfiDeviceStatus, FfiReactionAction,
    FfiReceiptType, LocalChatListItem, LocalHistoryStore, LocalTimelineItem, MessageBody,
    MlsFacade, ModifyChatDevicesControlInput, ModifyChatMembersControlInput,
    PublishKeyPackageMaterial, ReactionAction, ReceiptType, SendMessageOutcome, ServerApiClient,
    ServerApiError, SyncCoordinator, account_bootstrap_message, create_device_transfer_bundle,
    decrypt_attachment_payload, decrypt_device_transfer_bundle, device_revoke_message, encode_b64,
    prepare_attachment_upload,
};

const SAFE_ATTACHMENT_TOKEN_TTL_SECONDS: u64 = 15 * 60;
const SAFE_DEVICE_KEY_PACKAGE_MINIMUM: u32 = 5;
const SAFE_DEVICE_KEY_PACKAGE_TARGET: u32 = 12;
const SAFE_DEFAULT_REVOKE_REASON: &str = "revoked_from_safe_messenger_ffi";
const SNAPSHOT_SYNC_LIMIT_PER_CHAT: usize = 200;

#[derive(Debug, Error, uniffi::Error)]
pub enum FfiMessengerError {
    #[error("{0}")]
    Message(String),
    #[error("requires_resync: {0}")]
    RequiresResync(String),
    #[error("attachment_expired: {0}")]
    AttachmentExpired(String),
    #[error("attachment_invalid: {0}")]
    AttachmentInvalid(String),
    #[error("device_not_approvable: {0}")]
    DeviceNotApprovable(String),
    #[error("not_configured: {0}")]
    NotConfigured(String),
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiMessengerMessageBodyKind {
    Text,
    Reaction,
    Receipt,
    Attachment,
    ChatEvent,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiMessengerEventKind {
    MessageCreated,
    MessageUpdated,
    ConversationUpdated,
    DevicePending,
    DeviceApproved,
    DeviceRevoked,
    AttachmentReady,
    ReadStateUpdated,
    TypingUpdated,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerOpenConfig {
    pub root_path: String,
    pub database_key: Vec<u8>,
    pub base_url: String,
    pub access_token: Option<String>,
    pub account_id: Option<String>,
    pub device_id: Option<String>,
    pub account_sync_chat_id: Option<String>,
    pub device_display_name: Option<String>,
    pub platform: Option<String>,
    pub credential_identity: Option<Vec<u8>>,
    pub account_root_private_key: Option<Vec<u8>>,
    pub transport_private_key: Option<Vec<u8>>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerCapabilityFlags {
    pub safe_messaging: bool,
    pub attachments: bool,
    pub typing: bool,
    pub device_linking: bool,
    pub conversation_controls: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerParticipantProfile {
    pub account_id: String,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerConversationSummary {
    pub conversation_id: String,
    pub conversation_type: FfiChatType,
    pub title: Option<String>,
    pub display_title: String,
    pub last_server_seq: u64,
    pub epoch: u64,
    pub unread_count: u64,
    pub pending_message_count: u64,
    pub preview_text: Option<String>,
    pub preview_sender_account_id: Option<String>,
    pub preview_sender_display_name: Option<String>,
    pub preview_is_outgoing: Option<bool>,
    pub preview_server_seq: Option<u64>,
    pub preview_created_at_unix: Option<u64>,
    pub participant_profiles: Vec<FfiMessengerParticipantProfile>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerAttachmentDescriptor {
    pub attachment_ref: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerMessageBody {
    pub kind: FfiMessengerMessageBodyKind,
    pub text: Option<String>,
    pub target_message_id: Option<String>,
    pub emoji: Option<String>,
    pub reaction_action: Option<FfiReactionAction>,
    pub receipt_type: Option<FfiReceiptType>,
    pub receipt_at_unix: Option<u64>,
    pub attachment: Option<FfiMessengerAttachmentDescriptor>,
    pub event_type: Option<String>,
    pub event_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerMessageRecord {
    pub conversation_id: String,
    pub server_seq: u64,
    pub message_id: String,
    pub sender_account_id: String,
    pub sender_device_id: String,
    pub sender_display_name: Option<String>,
    pub is_outgoing: bool,
    pub epoch: u64,
    pub content_type: FfiContentType,
    pub body: Option<FfiMessengerMessageBody>,
    pub preview_text: String,
    pub created_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerMessagePage {
    pub conversation_id: String,
    pub messages: Vec<FfiMessengerMessageRecord>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerSnapshot {
    pub account_id: Option<String>,
    pub device_id: Option<String>,
    pub account_sync_chat_id: Option<String>,
    pub conversations: Vec<FfiMessengerConversationSummary>,
    pub devices: Vec<FfiMessengerDeviceRecord>,
    pub capabilities: FfiMessengerCapabilityFlags,
    pub checkpoint: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerSendMessageRequest {
    pub conversation_id: String,
    pub message_id: Option<String>,
    pub kind: FfiMessengerMessageBodyKind,
    pub text: Option<String>,
    pub target_message_id: Option<String>,
    pub emoji: Option<String>,
    pub reaction_action: Option<FfiReactionAction>,
    pub receipt_type: Option<FfiReceiptType>,
    pub receipt_at_unix: Option<u64>,
    pub event_type: Option<String>,
    pub event_json: Option<String>,
    pub attachment_tokens: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerSendMessageResult {
    pub conversation_id: String,
    pub message: FfiMessengerMessageRecord,
    pub checkpoint: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerAttachmentMetadata {
    pub mime_type: String,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerAttachmentToken {
    pub token: String,
    pub conversation_id: String,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerAttachmentFile {
    pub attachment_ref: String,
    pub local_path: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerCreateConversationRequest {
    pub conversation_type: FfiChatType,
    pub title: Option<String>,
    pub participant_account_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerUpdateConversationMembersRequest {
    pub conversation_id: String,
    pub participant_account_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerUpdateConversationDevicesRequest {
    pub conversation_id: String,
    pub device_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerConversationMutationResult {
    pub conversation_id: String,
    pub conversation: Option<FfiMessengerConversationSummary>,
    pub messages: Vec<FfiMessengerMessageRecord>,
    pub changed_account_ids: Vec<String>,
    pub changed_device_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerReadStateResult {
    pub conversation_id: String,
    pub read_cursor_server_seq: u64,
    pub unread_count: u64,
    pub checkpoint: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerDeviceRecord {
    pub account_id: String,
    pub device_id: String,
    pub display_name: String,
    pub platform: String,
    pub device_status: FfiDeviceStatus,
    pub available_key_package_count: u32,
    pub is_current_device: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerDeviceLinkIntent {
    pub link_intent_id: String,
    pub payload: String,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerPendingDeviceRecord {
    pub account_id: String,
    pub device_id: String,
    pub device_status: FfiDeviceStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerDeviceMutationResult {
    pub account_id: Option<String>,
    pub device_id: String,
    pub device_status: FfiDeviceStatus,
    pub devices: Vec<FfiMessengerDeviceRecord>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerRevokeDeviceRequest {
    pub device_id: String,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerEvent {
    pub event_id: String,
    pub kind: FfiMessengerEventKind,
    pub conversation_id: Option<String>,
    pub message: Option<FfiMessengerMessageRecord>,
    pub conversation: Option<FfiMessengerConversationSummary>,
    pub device: Option<FfiMessengerDeviceRecord>,
    pub read_state: Option<FfiMessengerReadStateResult>,
    pub attachment_ref: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessengerEventBatch {
    pub checkpoint: Option<String>,
    pub events: Vec<FfiMessengerEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct MessengerClientState {
    version: u32,
    base_url: String,
    access_token: Option<String>,
    account_id: Option<String>,
    device_id: Option<String>,
    account_sync_chat_id: Option<String>,
    device_display_name: Option<String>,
    platform: Option<String>,
    credential_identity: Option<Vec<u8>>,
    account_root_private_key: Option<Vec<u8>>,
    transport_private_key: Option<Vec<u8>>,
    next_event_id: u64,
    last_event_id: u64,
    #[serde(default)]
    attachment_tokens: BTreeMap<String, StoredPendingAttachment>,
    #[serde(default)]
    attachment_refs: BTreeMap<String, StoredAttachmentRef>,
    #[serde(default)]
    attachment_ref_index: BTreeMap<String, String>,
    #[serde(default)]
    device_statuses: BTreeMap<String, StoredDeviceState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredPendingAttachment {
    conversation_id: String,
    body: AttachmentMessageBody,
    created_at_unix: u64,
    expires_at_unix: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredAttachmentRef {
    body: AttachmentMessageBody,
    created_at_unix: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredDeviceState {
    account_id: String,
    device_status: DeviceStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LinkPayload {
    version: u32,
    #[serde(rename = "base_url")]
    base_url: String,
    #[serde(rename = "account_id")]
    account_id: String,
    #[serde(rename = "link_intent_id")]
    link_intent_id: String,
    #[serde(rename = "link_token")]
    link_token: String,
}

#[derive(uniffi::Object)]
pub struct FfiMessengerClient {
    runtime: Runtime,
    client: Mutex<ServerApiClient>,
    history_store: Mutex<LocalHistoryStore>,
    sync_coordinator: Mutex<SyncCoordinator>,
    mls_operation: Mutex<()>,
    state: Mutex<MessengerClientState>,
    root_path: String,
    database_key: Vec<u8>,
    state_path: String,
    mls_storage_root: String,
    attachment_cache_root: String,
}

#[uniffi::export]
impl FfiMessengerClient {
    #[uniffi::constructor]
    pub fn open(config: FfiMessengerOpenConfig) -> Result<Arc<Self>, FfiMessengerError> {
        let root_path = PathBuf::from(&config.root_path);
        fs::create_dir_all(&root_path).map_err(messenger_error)?;
        migrate_legacy_mls_storage_root(&root_path).map_err(messenger_error)?;

        let database_path = root_path.join("client-store.sqlite");
        let attachment_cache_root = root_path.join("attachments");
        let mls_storage_root = root_path.join("mls");
        let state_path = root_path.join("messenger-state.bin");
        let database_existed = database_path.exists();

        fs::create_dir_all(&attachment_cache_root).map_err(messenger_error)?;
        fs::create_dir_all(&mls_storage_root).map_err(messenger_error)?;

        let mut history_store =
            LocalHistoryStore::new_encrypted(&database_path, config.database_key.clone())
                .map_err(messenger_error)?;
        let mut sync_coordinator =
            SyncCoordinator::new_encrypted(&database_path, config.database_key.clone())
                .map_err(messenger_error)?;
        let should_attempt_store_migration = has_any_legacy_client_store_path(&root_path)
            && (!database_existed || history_store.list_chats().is_empty());
        if should_attempt_store_migration {
            migrate_legacy_client_store(
                &root_path,
                &database_path,
                &mut history_store,
                &mut sync_coordinator,
            )
            .map_err(messenger_error)?;
        }

        let mut state = if state_path.exists() {
            load_state_from_path(&state_path, &config.database_key)?
        } else {
            MessengerClientState {
                version: 1,
                base_url: config.base_url.clone(),
                ..MessengerClientState::default()
            }
        };

        state.version = 1;
        if !config.base_url.trim().is_empty() {
            state.base_url = config.base_url.trim().to_owned();
        }
        merge_option(&mut state.access_token, config.access_token);
        merge_option(&mut state.account_id, config.account_id);
        merge_option(&mut state.device_id, config.device_id);
        merge_option(&mut state.account_sync_chat_id, config.account_sync_chat_id);
        merge_option(&mut state.device_display_name, config.device_display_name);
        merge_option(&mut state.platform, config.platform);
        merge_option_vec(&mut state.credential_identity, config.credential_identity);
        merge_option_vec(
            &mut state.account_root_private_key,
            config.account_root_private_key,
        );
        merge_option_vec(
            &mut state.transport_private_key,
            config.transport_private_key,
        );
        gc_attachment_tokens(&mut state, current_unix_seconds().map_err(messenger_error)?);
        save_state_to_path(&state_path, &config.database_key, &state)?;

        let mut client = ServerApiClient::new(state.base_url.clone()).map_err(messenger_error)?;
        if let Some(access_token) = state.access_token.clone() {
            client.set_access_token(access_token);
        }

        Ok(Arc::new(Self {
            runtime: build_runtime().map_err(messenger_error)?,
            client: Mutex::new(client),
            history_store: Mutex::new(history_store),
            sync_coordinator: Mutex::new(sync_coordinator),
            mls_operation: Mutex::new(()),
            state: Mutex::new(state),
            root_path: root_path.to_string_lossy().into_owned(),
            database_key: config.database_key,
            state_path: state_path.to_string_lossy().into_owned(),
            mls_storage_root: mls_storage_root.to_string_lossy().into_owned(),
            attachment_cache_root: attachment_cache_root.to_string_lossy().into_owned(),
        }))
    }

    pub fn root_path(&self) -> String {
        self.root_path.clone()
    }

    pub fn load_snapshot(&self) -> Result<FfiMessengerSnapshot, FfiMessengerError> {
        self.sync_workspace()?;
        self.maybe_import_transfer_bundle()?;
        let devices = self.list_devices()?;
        let conversations = self.list_conversations()?;
        let state = lock_state(&self.state)?;
        Ok(FfiMessengerSnapshot {
            account_id: state.account_id.clone(),
            device_id: state.device_id.clone(),
            account_sync_chat_id: state.account_sync_chat_id.clone(),
            conversations,
            devices,
            capabilities: capability_flags(),
            checkpoint: checkpoint_from_event_id(state.last_event_id),
        })
    }

    pub fn list_conversations(
        &self,
    ) -> Result<Vec<FfiMessengerConversationSummary>, FfiMessengerError> {
        let self_account_id = self.state_account_id().transpose()?;
        let store = lock_history_store(&self.history_store)?;
        Ok(store
            .list_local_chat_list_items(self_account_id)
            .into_iter()
            .map(conversation_summary_to_ffi)
            .collect())
    }

    pub fn get_messages(
        &self,
        conversation_id: String,
        page_cursor: Option<String>,
        limit: Option<u32>,
    ) -> Result<FfiMessengerMessagePage, FfiMessengerError> {
        let chat_id = parse_chat_id(&conversation_id)?;
        self.ensure_chat_projection_current(chat_id)?;
        let limit = limit.unwrap_or(50) as usize;
        let self_account_id = self.state_account_id().transpose()?;
        let before_server_seq = page_cursor.as_deref().map(parse_page_cursor).transpose()?;
        let mut messages = {
            let store = lock_history_store(&self.history_store)?;
            store.get_local_timeline_items(chat_id, self_account_id, None, None)
        };
        let (page_start, filtered_end, next_cursor_seq) =
            paginate_server_seq_window(&messages, before_server_seq, limit, |message| {
                message.server_seq
            });
        let next_cursor = next_cursor_seq.map(page_cursor_from_server_seq);
        messages = messages
            .into_iter()
            .skip(page_start)
            .take(filtered_end.saturating_sub(page_start))
            .collect();
        let messages = messages
            .into_iter()
            .map(|message| self.timeline_item_to_message_record(chat_id, message))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(FfiMessengerMessagePage {
            conversation_id,
            messages,
            next_cursor,
        })
    }

    pub fn get_new_events(
        &self,
        checkpoint: Option<String>,
    ) -> Result<FfiMessengerEventBatch, FfiMessengerError> {
        let requested_checkpoint = checkpoint.as_deref().map(parse_checkpoint).transpose()?;
        self.validate_requested_checkpoint(requested_checkpoint)?;
        let client = self.authenticated_client()?;
        self.maybe_import_transfer_bundle()?;

        let mut previous_cursors = BTreeMap::new();
        {
            let store = lock_history_store(&self.history_store)?;
            for chat in store.list_chats() {
                previous_cursors.insert(
                    chat.chat_id.0.to_string(),
                    store.projected_cursor(chat.chat_id).unwrap_or(0),
                );
            }
        }

        let lease = {
            let coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            self.runtime
                .block_on(coordinator.lease_inbox(&client, Some(100), Some(30)))
                .map_err(map_domain_error)?
        };
        let report = {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            coordinator
                .apply_inbox_items_into_store(&mut store, &lease.items)
                .map_err(map_domain_error)?
        };

        let changed_chat_ids = report.changed_chat_ids;
        if !changed_chat_ids.is_empty() {
            self.refresh_chat_details(&client, &changed_chat_ids)?;
            self.project_changed_chats(&changed_chat_ids)?;
        }
        let inbox_ids = lease
            .items
            .iter()
            .map(|item| item.inbox_id)
            .collect::<Vec<_>>();
        if !inbox_ids.is_empty() {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            self.runtime
                .block_on(coordinator.ack_inbox(&client, inbox_ids))
                .map_err(map_domain_error)?;
        }

        let mut events = Vec::new();
        for chat_id in changed_chat_ids {
            let after_server_seq = previous_cursors
                .get(&chat_id.0.to_string())
                .copied()
                .unwrap_or_default();
            let new_messages = {
                let store = lock_history_store(&self.history_store)?;
                store.get_local_timeline_items(
                    chat_id,
                    self.state_account_id().transpose()?,
                    Some(after_server_seq),
                    None,
                )
            };
            for message in new_messages {
                let message = self.timeline_item_to_message_record(chat_id, message)?;
                events.push(self.new_event(
                    FfiMessengerEventKind::MessageCreated,
                    Some(chat_id.0.to_string()),
                    Some(message),
                    None,
                    None,
                    None,
                    None,
                )?);
            }
            if let Some(conversation) = self.get_conversation_summary(chat_id)? {
                events.push(self.new_event(
                    FfiMessengerEventKind::ConversationUpdated,
                    Some(chat_id.0.to_string()),
                    None,
                    Some(conversation),
                    None,
                    None,
                    None,
                )?);
            }
        }

        let (_devices, mut device_events) = self.fetch_and_store_devices(&client)?;
        events.append(&mut device_events);
        Ok(FfiMessengerEventBatch {
            checkpoint: {
                let state = lock_state(&self.state)?;
                checkpoint_from_event_id(state.last_event_id)
            },
            events,
        })
    }

    pub fn send_message(
        &self,
        request: FfiMessengerSendMessageRequest,
    ) -> Result<FfiMessengerSendMessageResult, FfiMessengerError> {
        let chat_id = parse_chat_id(&request.conversation_id)?;
        let body = self.build_send_message_body(&request)?;
        let client = self.authenticated_client()?;
        let (self_account_id, self_device_id) = self.require_self_identity()?;

        {
            let mut store = lock_history_store(&self.history_store)?;
            self.bootstrap_chat_if_needed(&client, &mut store, chat_id)?;
        }

        let outcome = self.with_mls_facade(|facade| {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            let mut conversation = store
                .load_or_bootstrap_chat_mls_conversation(chat_id, facade)
                .map_err(map_domain_error)?
                .ok_or_else(|| {
                    FfiMessengerError::RequiresResync(format!(
                        "conversation {} has no bootstrappable MLS state",
                        chat_id.0
                    ))
                })?;
            self.runtime
                .block_on(
                    coordinator.send_message_body(
                        &client,
                        &mut store,
                        facade,
                        &mut conversation,
                        self_account_id,
                        self_device_id,
                        chat_id,
                        request
                            .message_id
                            .as_deref()
                            .map(parse_message_id)
                            .transpose()?,
                        &body,
                        None,
                    ),
                )
                .map_err(map_domain_error)
        })?;
        let message = self.send_outcome_to_message_record(chat_id, outcome)?;
        Ok(FfiMessengerSendMessageResult {
            conversation_id: request.conversation_id,
            message,
            checkpoint: {
                let state = lock_state(&self.state)?;
                checkpoint_from_event_id(state.last_event_id)
            },
        })
    }

    pub fn send_attachment(
        &self,
        conversation_id: String,
        payload: Vec<u8>,
        metadata: FfiMessengerAttachmentMetadata,
    ) -> Result<FfiMessengerAttachmentToken, FfiMessengerError> {
        let chat_id = parse_chat_id(&conversation_id)?;
        let prepared = prepare_attachment_upload(
            &payload,
            metadata.mime_type,
            metadata.file_name,
            metadata.width_px,
            metadata.height_px,
        )
        .map_err(messenger_error)?;
        let create = self.run_transport(|runtime, client| {
            runtime.block_on(client.create_blob_upload(
                chat_id,
                prepared.mime_type.clone(),
                prepared.encrypted_size_bytes,
                &prepared.encrypted_sha256,
            ))
        })?;
        let upload_status = if create.needs_upload {
            self.run_transport(|runtime, client| {
                runtime.block_on(
                    client.upload_blob(create.blob_id.clone(), &prepared.encrypted_payload),
                )
            })?
            .upload_status
        } else {
            self.run_transport(|runtime, client| {
                runtime.block_on(client.head_blob(create.blob_id.clone()))
            })?
            .upload_status
        };
        if upload_status != trix_types::BlobUploadStatus::Available {
            return Err(FfiMessengerError::Message(format!(
                "attachment upload did not complete for blob {}",
                create.blob_id
            )));
        }

        let created_at_unix = current_unix_seconds().map_err(messenger_error)?;
        let expires_at_unix = created_at_unix + SAFE_ATTACHMENT_TOKEN_TTL_SECONDS;
        let token = Uuid::new_v4().to_string();
        let body = prepared.into_message_body(create.blob_id);

        {
            let mut state = lock_state(&self.state)?;
            gc_attachment_tokens(&mut state, created_at_unix);
            state.attachment_tokens.insert(
                token.clone(),
                StoredPendingAttachment {
                    conversation_id: conversation_id.clone(),
                    body,
                    created_at_unix,
                    expires_at_unix,
                },
            );
            self.save_state_locked(&state)?;
        }

        Ok(FfiMessengerAttachmentToken {
            token,
            conversation_id,
            expires_at_unix,
        })
    }

    pub fn get_attachment(
        &self,
        attachment_ref: String,
    ) -> Result<FfiMessengerAttachmentFile, FfiMessengerError> {
        let body = {
            let store = lock_history_store(&self.history_store)?;
            if let Some(body) = store.attachment_ref(&attachment_ref) {
                body
            } else {
                drop(store);
                let legacy = {
                    let state = lock_state(&self.state)?;
                    state
                        .attachment_refs
                        .get(&attachment_ref)
                        .cloned()
                        .ok_or_else(|| {
                            FfiMessengerError::AttachmentInvalid(format!(
                                "attachment reference {} is unknown",
                                attachment_ref
                            ))
                        })?
                        .body
                };
                let fingerprint = attachment_fingerprint(&legacy).map_err(messenger_error)?;
                let created_at_unix = current_unix_seconds().map_err(messenger_error)?;
                lock_history_store(&self.history_store)?
                    .persist_attachment_ref(
                        attachment_ref.clone(),
                        fingerprint,
                        legacy.clone(),
                        created_at_unix,
                    )
                    .map_err(map_domain_error)?;
                legacy
            }
        };
        let local_path = attachment_file_path(&self.attachment_cache_root, &attachment_ref, &body);
        if !local_path.exists() {
            let encrypted_payload = self.run_transport(|runtime, client| {
                runtime.block_on(client.download_blob(body.blob_id.clone()))
            })?;
            let plaintext =
                decrypt_attachment_payload(&body, &encrypted_payload).map_err(map_domain_error)?;
            if let Some(parent) = local_path.parent() {
                fs::create_dir_all(parent).map_err(messenger_error)?;
            }
            fs::write(&local_path, plaintext).map_err(messenger_error)?;
        }
        Ok(FfiMessengerAttachmentFile {
            attachment_ref,
            local_path: local_path.to_string_lossy().into_owned(),
            mime_type: body.mime_type,
            size_bytes: body.size_bytes,
            file_name: body.file_name,
            width_px: body.width_px,
            height_px: body.height_px,
        })
    }

    pub fn create_conversation(
        &self,
        request: FfiMessengerCreateConversationRequest,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let client = self.authenticated_client()?;
        let (self_account_id, self_device_id) = self.require_self_identity()?;
        let outcome = self.with_mls_facade(|facade| {
            self.ensure_device_key_packages(&client, facade)?;
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            self.runtime
                .block_on(
                    coordinator.create_chat_control(
                        &client,
                        &mut store,
                        facade,
                        CreateChatControlInput {
                            creator_account_id: self_account_id,
                            creator_device_id: self_device_id,
                            chat_type: ffi_chat_type_to_model(request.conversation_type),
                            title: request.title.clone(),
                            participant_account_ids: request
                                .participant_account_ids
                                .iter()
                                .map(|account_id| parse_account_id(account_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            group_id: None,
                            commit_aad_json: None,
                            welcome_aad_json: None,
                        },
                    ),
                )
                .map_err(map_domain_error)
        })?;
        self.conversation_mutation_from_create_outcome(outcome)
    }

    pub fn update_conversation_members(
        &self,
        request: FfiMessengerUpdateConversationMembersRequest,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let chat_id = parse_chat_id(&request.conversation_id)?;
        let client = self.authenticated_client()?;
        let (self_account_id, self_device_id) = self.require_self_identity()?;
        let outcome = self.with_mls_facade(|facade| {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            self.bootstrap_chat_if_needed(&client, &mut store, chat_id)?;
            self.runtime
                .block_on(
                    coordinator.add_chat_members_control(
                        &client,
                        &mut store,
                        facade,
                        ModifyChatMembersControlInput {
                            actor_account_id: self_account_id,
                            actor_device_id: self_device_id,
                            chat_id,
                            participant_account_ids: request
                                .participant_account_ids
                                .iter()
                                .map(|account_id| parse_account_id(account_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: None,
                            welcome_aad_json: None,
                        },
                    ),
                )
                .map_err(map_domain_error)
        })?;
        self.conversation_mutation_from_member_outcome(outcome)
    }

    pub fn remove_conversation_members(
        &self,
        request: FfiMessengerUpdateConversationMembersRequest,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let chat_id = parse_chat_id(&request.conversation_id)?;
        let client = self.authenticated_client()?;
        let (self_account_id, self_device_id) = self.require_self_identity()?;
        let outcome = self.with_mls_facade(|facade| {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            self.bootstrap_chat_if_needed(&client, &mut store, chat_id)?;
            self.runtime
                .block_on(
                    coordinator.remove_chat_members_control(
                        &client,
                        &mut store,
                        facade,
                        ModifyChatMembersControlInput {
                            actor_account_id: self_account_id,
                            actor_device_id: self_device_id,
                            chat_id,
                            participant_account_ids: request
                                .participant_account_ids
                                .iter()
                                .map(|account_id| parse_account_id(account_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: None,
                            welcome_aad_json: None,
                        },
                    ),
                )
                .map_err(map_domain_error)
        })?;
        self.conversation_mutation_from_member_outcome(outcome)
    }

    pub fn update_conversation_devices(
        &self,
        request: FfiMessengerUpdateConversationDevicesRequest,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let chat_id = parse_chat_id(&request.conversation_id)?;
        let client = self.authenticated_client()?;
        let (self_account_id, self_device_id) = self.require_self_identity()?;
        let outcome = self.with_mls_facade(|facade| {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            self.bootstrap_chat_if_needed(&client, &mut store, chat_id)?;
            self.runtime
                .block_on(
                    coordinator.add_chat_devices_control(
                        &client,
                        &mut store,
                        facade,
                        ModifyChatDevicesControlInput {
                            actor_account_id: self_account_id,
                            actor_device_id: self_device_id,
                            chat_id,
                            device_ids: request
                                .device_ids
                                .iter()
                                .map(|device_id| parse_device_id(device_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: None,
                            welcome_aad_json: None,
                        },
                    ),
                )
                .map_err(map_domain_error)
        })?;
        self.conversation_mutation_from_device_outcome(outcome)
    }

    pub fn remove_conversation_devices(
        &self,
        request: FfiMessengerUpdateConversationDevicesRequest,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let chat_id = parse_chat_id(&request.conversation_id)?;
        let client = self.authenticated_client()?;
        let (self_account_id, self_device_id) = self.require_self_identity()?;
        let outcome = self.with_mls_facade(|facade| {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            self.bootstrap_chat_if_needed(&client, &mut store, chat_id)?;
            self.runtime
                .block_on(
                    coordinator.remove_chat_devices_control(
                        &client,
                        &mut store,
                        facade,
                        ModifyChatDevicesControlInput {
                            actor_account_id: self_account_id,
                            actor_device_id: self_device_id,
                            chat_id,
                            device_ids: request
                                .device_ids
                                .iter()
                                .map(|device_id| parse_device_id(device_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: None,
                            welcome_aad_json: None,
                        },
                    ),
                )
                .map_err(map_domain_error)
        })?;
        self.conversation_mutation_from_device_outcome(outcome)
    }

    pub fn mark_read(
        &self,
        conversation_id: String,
        through_message_id: Option<String>,
    ) -> Result<FfiMessengerReadStateResult, FfiMessengerError> {
        let chat_id = parse_chat_id(&conversation_id)?;
        let self_account_id = self.state_account_id().transpose()?;
        let through_server_seq = through_message_id
            .as_deref()
            .map(parse_message_id)
            .transpose()?
            .map(|message_id| self.find_message_server_seq(chat_id, message_id))
            .transpose()?;
        let read_state = {
            let mut store = lock_history_store(&self.history_store)?;
            store
                .mark_chat_read(chat_id, through_server_seq, self_account_id)
                .map_err(map_domain_error)?
        };
        Ok(FfiMessengerReadStateResult {
            conversation_id,
            read_cursor_server_seq: read_state.read_cursor_server_seq,
            unread_count: read_state.unread_count,
            checkpoint: {
                let state = lock_state(&self.state)?;
                checkpoint_from_event_id(state.last_event_id)
            },
        })
    }

    pub fn set_typing(
        &self,
        conversation_id: String,
        is_typing: bool,
    ) -> Result<(), FfiMessengerError> {
        let chat_id = parse_chat_id(&conversation_id)?;
        let client = self.authenticated_client()?;
        let mut websocket = self
            .runtime
            .block_on(client.connect_websocket())
            .map_err(messenger_error)?;
        self.runtime
            .block_on(websocket.send_typing_update(chat_id, is_typing))
            .map_err(messenger_error)
    }

    pub fn list_devices(&self) -> Result<Vec<FfiMessengerDeviceRecord>, FfiMessengerError> {
        let client = self.authenticated_client()?;
        self.fetch_and_store_devices(&client).map(|result| result.0)
    }

    pub fn create_link_device_intent(
        &self,
    ) -> Result<FfiMessengerDeviceLinkIntent, FfiMessengerError> {
        let response =
            self.run_transport(|runtime, client| runtime.block_on(client.create_link_intent()))?;
        Ok(FfiMessengerDeviceLinkIntent {
            link_intent_id: response.link_intent_id,
            payload: response.qr_payload,
            expires_at_unix: response.expires_at_unix,
        })
    }

    pub fn complete_link_device(
        &self,
        link_payload: String,
        device_display_name: String,
    ) -> Result<FfiMessengerPendingDeviceRecord, FfiMessengerError> {
        let payload: LinkPayload = serde_json::from_str(&link_payload)
            .map_err(|err| FfiMessengerError::Message(format!("invalid link payload: {err}")))?;
        {
            let mut state = lock_state(&self.state)?;
            state.base_url = payload.base_url.clone();
            state.account_id = Some(payload.account_id.clone());
            if !device_display_name.trim().is_empty() {
                state.device_display_name = Some(device_display_name.clone());
            }
            self.save_state_locked(&state)?;
        }

        self.rebuild_client_base_url(&payload.base_url)?;
        let client = self.authenticated_client_for_pending_device()?;
        let key_packages = self.with_mls_facade(|facade| {
            Ok(facade
                .generate_key_packages(SAFE_DEVICE_KEY_PACKAGE_TARGET as usize)
                .map_err(map_domain_error)?
                .into_iter()
                .map(|key_package| PublishKeyPackageMaterial {
                    cipher_suite: facade.ciphersuite_label(),
                    key_package,
                })
                .collect::<Vec<_>>())
        })?;
        let state = lock_state(&self.state)?;
        let credential_identity = state.credential_identity.clone().ok_or_else(|| {
            FfiMessengerError::NotConfigured("credential_identity is missing".to_owned())
        })?;
        let device_keys = DeviceKeyMaterial::from_bytes(to_32_bytes(
            state.transport_private_key.clone().ok_or_else(|| {
                FfiMessengerError::NotConfigured("transport_private_key is missing".to_owned())
            })?,
            "transport private key",
        )?);
        let platform = state
            .platform
            .clone()
            .ok_or_else(|| FfiMessengerError::NotConfigured("platform is missing".to_owned()))?;
        let display_name = if device_display_name.trim().is_empty() {
            state.device_display_name.clone().ok_or_else(|| {
                FfiMessengerError::NotConfigured("device_display_name is missing".to_owned())
            })?
        } else {
            device_display_name
        };
        drop(state);

        let response = self
            .runtime
            .block_on(client.complete_link_intent(
                payload.link_intent_id,
                CompleteLinkIntentParams {
                    link_token: payload.link_token,
                    device_display_name: display_name,
                    platform,
                    credential_identity,
                    transport_pubkey: device_keys.public_key_bytes(),
                    key_packages,
                },
            ))
            .map_err(messenger_error)?;

        {
            let mut state = lock_state(&self.state)?;
            state.account_id = Some(response.account_id.0.to_string());
            state.device_id = Some(response.pending_device_id.0.to_string());
            self.save_state_locked(&state)?;
        }

        Ok(FfiMessengerPendingDeviceRecord {
            account_id: response.account_id.0.to_string(),
            device_id: response.pending_device_id.0.to_string(),
            device_status: device_status_to_ffi(response.device_status),
        })
    }

    pub fn approve_linked_device(
        &self,
        device_id: String,
    ) -> Result<FfiMessengerDeviceMutationResult, FfiMessengerError> {
        let target_device_id = parse_device_id(&device_id)?;
        let account_root = self.require_account_root_material()?;
        let payload = self
            .run_transport(|runtime, client| {
                runtime.block_on(client.get_device_approve_payload(target_device_id))
            })
            .map_err(|err| match err {
                FfiMessengerError::Message(message) => {
                    FfiMessengerError::DeviceNotApprovable(message)
                }
                other => other,
            })?;
        let self_device_id = self.require_device_id()?;
        let self_account_id = self.require_account_id()?;
        let state = lock_state(&self.state)?;
        let sender_device_keys = DeviceKeyMaterial::from_bytes(to_32_bytes(
            state.transport_private_key.clone().ok_or_else(|| {
                FfiMessengerError::NotConfigured("transport_private_key is missing".to_owned())
            })?,
            "transport private key",
        )?);
        let transfer_bundle = create_device_transfer_bundle(
            crate::CreateDeviceTransferBundleInput {
                account_id: self_account_id.0.to_string(),
                source_device_id: self_device_id.0.to_string(),
                target_device_id: target_device_id.0.to_string(),
                account_sync_chat_id: state.account_sync_chat_id.clone(),
            },
            &account_root,
            &sender_device_keys,
            &payload.transport_pubkey,
        )
        .map_err(map_domain_error)?;
        drop(state);

        let account_root_signature = account_root.sign(&account_bootstrap_message(
            &payload.transport_pubkey,
            &payload.credential_identity,
        ));
        let response = self.run_transport(|runtime, client| {
            runtime.block_on(client.approve_device(
                target_device_id,
                &account_root_signature,
                Some(&transfer_bundle),
            ))
        })?;
        let devices = self.list_devices()?;
        Ok(FfiMessengerDeviceMutationResult {
            account_id: Some(response.account_id.0.to_string()),
            device_id,
            device_status: device_status_to_ffi(response.device_status),
            devices,
        })
    }

    pub fn unlink_device(
        &self,
        device_id: String,
    ) -> Result<FfiMessengerDeviceMutationResult, FfiMessengerError> {
        self.revoke_device(FfiMessengerRevokeDeviceRequest {
            device_id,
            reason: None,
        })
    }

    pub fn revoke_device(
        &self,
        request: FfiMessengerRevokeDeviceRequest,
    ) -> Result<FfiMessengerDeviceMutationResult, FfiMessengerError> {
        let target_device_id = parse_device_id(&request.device_id)?;
        let account_root = self.require_account_root_material()?;
        let reason = normalize_revoke_reason(request.reason);
        let signature = account_root.sign(&device_revoke_message(target_device_id.0, &reason));
        let response = self.run_transport(|runtime, client| {
            runtime.block_on(client.revoke_device(target_device_id, reason.clone(), &signature))
        })?;
        let devices = self.list_devices()?;
        Ok(FfiMessengerDeviceMutationResult {
            account_id: Some(response.account_id.0.to_string()),
            device_id: request.device_id,
            device_status: device_status_to_ffi(response.device_status),
            devices,
        })
    }
}

impl FfiMessengerClient {
    fn save_state_locked(&self, state: &MessengerClientState) -> Result<(), FfiMessengerError> {
        save_state_to_path(Path::new(&self.state_path), &self.database_key, state)
    }

    fn rebuild_client_base_url(&self, base_url: &str) -> Result<(), FfiMessengerError> {
        let mut client = lock_client(&self.client)?;
        *client = ServerApiClient::new(base_url).map_err(messenger_error)?;
        if let Some(access_token) = lock_state(&self.state)?.access_token.clone() {
            client.set_access_token(access_token);
        }
        Ok(())
    }

    fn state_account_id(&self) -> Option<Result<AccountId, FfiMessengerError>> {
        lock_state(&self.state)
            .ok()
            .and_then(|state| state.account_id.clone())
            .map(|account_id| parse_account_id(&account_id))
    }

    fn require_account_id(&self) -> Result<AccountId, FfiMessengerError> {
        let state = lock_state(&self.state)?;
        let account_id = state
            .account_id
            .clone()
            .ok_or_else(|| FfiMessengerError::NotConfigured("account_id is missing".to_owned()))?;
        parse_account_id(&account_id)
    }

    fn require_device_id(&self) -> Result<DeviceId, FfiMessengerError> {
        let state = lock_state(&self.state)?;
        let device_id = state
            .device_id
            .clone()
            .ok_or_else(|| FfiMessengerError::NotConfigured("device_id is missing".to_owned()))?;
        parse_device_id(&device_id)
    }

    fn require_self_identity(&self) -> Result<(AccountId, DeviceId), FfiMessengerError> {
        Ok((self.require_account_id()?, self.require_device_id()?))
    }

    fn require_account_root_material(
        &self,
    ) -> Result<crate::AccountRootMaterial, FfiMessengerError> {
        let state = lock_state(&self.state)?;
        let private_key = state.account_root_private_key.clone().ok_or_else(|| {
            FfiMessengerError::DeviceNotApprovable(
                "account_root_private_key is missing for this device".to_owned(),
            )
        })?;
        Ok(crate::AccountRootMaterial::from_bytes(to_32_bytes(
            private_key,
            "account root private key",
        )?))
    }

    fn authenticated_client(&self) -> Result<ServerApiClient, FfiMessengerError> {
        let has_token = lock_state(&self.state)?.access_token.is_some();
        if !has_token {
            self.refresh_session()?;
        }
        let client = lock_client(&self.client)?.clone();
        Ok(client)
    }

    fn authenticated_client_for_pending_device(
        &self,
    ) -> Result<ServerApiClient, FfiMessengerError> {
        let client = lock_client(&self.client)?.clone();
        Ok(client)
    }

    fn refresh_session(&self) -> Result<AuthChallengeMaterial, FfiMessengerError> {
        let (base_url, device_id, transport_private_key) = {
            let state = lock_state(&self.state)?;
            (
                state.base_url.clone(),
                state.device_id.clone().ok_or_else(|| {
                    FfiMessengerError::NotConfigured("device_id is missing".to_owned())
                })?,
                state.transport_private_key.clone().ok_or_else(|| {
                    FfiMessengerError::NotConfigured("transport_private_key is missing".to_owned())
                })?,
            )
        };

        self.rebuild_client_base_url(&base_url)?;
        let device_id = parse_device_id(&device_id)?;
        let device_keys = DeviceKeyMaterial::from_bytes(to_32_bytes(
            transport_private_key,
            "device private key",
        )?);
        let client = lock_client(&self.client)?.clone();
        let challenge = self
            .runtime
            .block_on(client.create_auth_challenge(device_id))
            .map_err(messenger_error)?;
        let signature = device_keys.sign(&challenge.challenge);
        let session = self
            .runtime
            .block_on(client.create_auth_session(
                device_id,
                challenge.challenge_id.clone(),
                &signature,
            ))
            .map_err(messenger_error)?;
        {
            let mut state = lock_state(&self.state)?;
            state.access_token = Some(session.access_token.clone());
            state.account_id = Some(session.account_id.0.to_string());
            self.save_state_locked(&state)?;
        }
        lock_client(&self.client)?.set_access_token(session.access_token);
        Ok(challenge)
    }

    fn run_transport<T, F>(&self, op: F) -> Result<T, FfiMessengerError>
    where
        F: Fn(&Runtime, ServerApiClient) -> Result<T, ServerApiError>,
    {
        let mut client = self.authenticated_client()?;
        match op(&self.runtime, client.clone()) {
            Ok(value) => Ok(value),
            Err(error) if is_unauthorized(&error) => {
                self.refresh_session()?;
                client = self.authenticated_client()?;
                op(&self.runtime, client).map_err(messenger_error)
            }
            Err(error) => Err(messenger_error(error)),
        }
    }

    fn open_or_load_mls_facade(&self) -> Result<MlsFacade, FfiMessengerError> {
        let state = lock_state(&self.state)?;
        let credential_identity = state.credential_identity.clone().ok_or_else(|| {
            FfiMessengerError::NotConfigured("credential_identity is missing".to_owned())
        })?;
        let storage_root = PathBuf::from(&self.mls_storage_root);
        if has_persistent_mls_state(&storage_root) {
            MlsFacade::load_persistent(storage_root).map_err(map_domain_error)
        } else {
            MlsFacade::new_persistent(credential_identity, storage_root).map_err(map_domain_error)
        }
    }

    fn with_mls_facade<T, F>(&self, op: F) -> Result<T, FfiMessengerError>
    where
        F: FnOnce(&mut MlsFacade) -> Result<T, FfiMessengerError>,
    {
        let _guard = lock_mls_operation(&self.mls_operation)?;
        let mut facade = self.open_or_load_mls_facade()?;
        let result = op(&mut facade)?;
        facade.save_state().map_err(map_domain_error)?;
        Ok(result)
    }

    fn sync_workspace(&self) -> Result<(), FfiMessengerError> {
        let client = self.authenticated_client()?;
        self.maybe_import_transfer_bundle()?;
        let report = {
            let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            let mut store = lock_history_store(&self.history_store)?;
            self.runtime
                .block_on(coordinator.sync_chat_histories_into_store(
                    &client,
                    &mut store,
                    SNAPSHOT_SYNC_LIMIT_PER_CHAT,
                ))
                .map_err(map_domain_error)?
        };
        if !report.changed_chat_ids.is_empty() {
            self.refresh_chat_details(&client, &report.changed_chat_ids)?;
            self.project_changed_chats(&report.changed_chat_ids)?;
        }
        self.with_mls_facade(|facade| self.ensure_device_key_packages(&client, facade))?;
        Ok(())
    }

    fn maybe_import_transfer_bundle(&self) -> Result<(), FfiMessengerError> {
        let (has_account_root, maybe_device_id, maybe_transport_private_key) = {
            let state = lock_state(&self.state)?;
            (
                state.account_root_private_key.is_some(),
                state.device_id.clone(),
                state.transport_private_key.clone(),
            )
        };
        if has_account_root {
            return Ok(());
        }
        let Some(device_id) = maybe_device_id else {
            return Ok(());
        };
        let Some(transport_private_key) = maybe_transport_private_key else {
            return Ok(());
        };
        let client = self.authenticated_client()?;
        let (devices, _) = self.fetch_and_store_devices(&client)?;
        let current_device = devices
            .iter()
            .find(|device| device.device_id == device_id && device.is_current_device);
        let Some(current_device) = current_device else {
            return Ok(());
        };
        if !matches!(current_device.device_status, FfiDeviceStatus::Active) {
            return Ok(());
        }

        let device_id = parse_device_id(&device_id)?;
        let bundle = match self.run_transport(|runtime, client| {
            runtime.block_on(client.get_device_transfer_bundle(device_id))
        }) {
            Ok(bundle) => bundle,
            Err(_) => return Ok(()),
        };
        let device_keys = DeviceKeyMaterial::from_bytes(to_32_bytes(
            transport_private_key,
            "device private key",
        )?);
        let imported = decrypt_device_transfer_bundle(&bundle.transfer_bundle, &device_keys)
            .map_err(map_domain_error)?;
        let mut state = lock_state(&self.state)?;
        state.account_id = Some(imported.account_id);
        state.account_sync_chat_id = imported.account_sync_chat_id;
        state.account_root_private_key = Some(imported.account_root_private_key);
        self.save_state_locked(&state)?;
        Ok(())
    }

    fn ensure_device_key_packages(
        &self,
        client: &ServerApiClient,
        facade: &MlsFacade,
    ) -> Result<(), FfiMessengerError> {
        let device_id = self.require_device_id()?;
        let response = self
            .runtime
            .block_on(client.list_devices())
            .map_err(messenger_error)?;
        let Some(device) = response
            .devices
            .into_iter()
            .find(|device| device.device_id == device_id)
        else {
            return Ok(());
        };
        if device.available_key_package_count >= SAFE_DEVICE_KEY_PACKAGE_MINIMUM {
            return Ok(());
        }
        let publish_count = SAFE_DEVICE_KEY_PACKAGE_TARGET
            .saturating_sub(device.available_key_package_count)
            .max(SAFE_DEVICE_KEY_PACKAGE_MINIMUM - device.available_key_package_count);
        if publish_count == 0 {
            return Ok(());
        }
        let cipher_suite = facade.ciphersuite_label();
        let packages = facade
            .generate_key_packages(publish_count as usize)
            .map_err(map_domain_error)?
            .into_iter()
            .map(|key_package| PublishKeyPackageMaterial {
                cipher_suite: cipher_suite.clone(),
                key_package,
            })
            .collect::<Vec<_>>();
        self.runtime
            .block_on(client.publish_key_packages(packages))
            .map_err(messenger_error)?;
        facade.save_state().map_err(map_domain_error)?;
        Ok(())
    }

    fn refresh_chat_details(
        &self,
        client: &ServerApiClient,
        chat_ids: &[ChatId],
    ) -> Result<(), FfiMessengerError> {
        let mut store = lock_history_store(&self.history_store)?;
        for chat_id in chat_ids {
            let detail = self
                .runtime
                .block_on(client.get_chat(*chat_id))
                .map_err(messenger_error)?;
            store.apply_chat_detail(&detail).map_err(map_domain_error)?;
        }
        Ok(())
    }

    fn bootstrap_chat_if_needed(
        &self,
        client: &ServerApiClient,
        store: &mut LocalHistoryStore,
        chat_id: ChatId,
    ) -> Result<(), FfiMessengerError> {
        if store.get_chat(chat_id).is_some() && store.chat_mls_group_id(chat_id).is_some() {
            return Ok(());
        }
        let detail = self
            .runtime
            .block_on(client.get_chat(chat_id))
            .map_err(messenger_error)?;
        store.apply_chat_detail(&detail).map_err(map_domain_error)?;
        let after_server_seq = {
            let coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
            coordinator.chat_cursor(chat_id)
        };
        let history = self
            .runtime
            .block_on(client.get_chat_history(chat_id, after_server_seq, None))
            .map_err(messenger_error)?;
        store
            .apply_chat_history(&history)
            .map_err(map_domain_error)?;
        Ok(())
    }

    fn project_changed_chats(&self, chat_ids: &[ChatId]) -> Result<(), FfiMessengerError> {
        let projected_cursors = self.with_mls_facade(|facade| {
            let mut store = lock_history_store(&self.history_store)?;
            let mut projected_cursors = Vec::new();
            for chat_id in chat_ids {
                store
                    .project_chat_with_facade(*chat_id, facade, None)
                    .map_err(map_domain_error)?;
                if let Some(projected_cursor) = store.projected_cursor(*chat_id) {
                    projected_cursors.push((*chat_id, projected_cursor));
                }
            }
            Ok(projected_cursors)
        })?;
        let mut coordinator = lock_sync_coordinator(&self.sync_coordinator)?;
        for (chat_id, projected_cursor) in projected_cursors {
            coordinator
                .record_chat_server_seq(chat_id, projected_cursor)
                .map_err(map_domain_error)?;
        }
        Ok(())
    }

    fn ensure_chat_projection_current(&self, chat_id: ChatId) -> Result<(), FfiMessengerError> {
        let (needs_history_refresh, needs_projection) = {
            let store = lock_history_store(&self.history_store)?;
            (
                store.needs_history_refresh(chat_id),
                store.needs_projection(chat_id),
            )
        };

        if needs_history_refresh {
            let client = self.authenticated_client()?;
            self.refresh_chat_history_fully(&client, chat_id)?;
        }

        if needs_history_refresh || needs_projection {
            self.project_changed_chats(&[chat_id])?;
        }

        Ok(())
    }

    fn refresh_chat_history_fully(
        &self,
        client: &ServerApiClient,
        chat_id: ChatId,
    ) -> Result<(), FfiMessengerError> {
        let detail = self
            .runtime
            .block_on(client.get_chat(chat_id))
            .map_err(messenger_error)?;
        let history = self
            .runtime
            .block_on(client.get_chat_history(chat_id, None, None))
            .map_err(messenger_error)?;
        {
            let mut store = lock_history_store(&self.history_store)?;
            store.apply_chat_detail(&detail).map_err(map_domain_error)?;
            store
                .apply_chat_history(&history)
                .map_err(map_domain_error)?;
        }
        Ok(())
    }

    fn get_conversation_summary(
        &self,
        chat_id: ChatId,
    ) -> Result<Option<FfiMessengerConversationSummary>, FfiMessengerError> {
        let self_account_id = self.state_account_id().transpose()?;
        let store = lock_history_store(&self.history_store)?;
        Ok(store
            .get_local_chat_list_item(chat_id, self_account_id)
            .map(conversation_summary_to_ffi))
    }

    fn build_send_message_body(
        &self,
        request: &FfiMessengerSendMessageRequest,
    ) -> Result<MessageBody, FfiMessengerError> {
        if !request.attachment_tokens.is_empty() {
            if request.attachment_tokens.len() != 1 {
                return Err(FfiMessengerError::AttachmentInvalid(
                    "exactly one attachment token is supported per message".to_owned(),
                ));
            }
            return Ok(MessageBody::Attachment(self.consume_attachment_token(
                &request.conversation_id,
                &request.attachment_tokens[0],
            )?));
        }

        match request.kind {
            FfiMessengerMessageBodyKind::Text => Ok(MessageBody::Text(crate::TextMessageBody {
                text: request.text.clone().ok_or_else(|| {
                    FfiMessengerError::Message("text body requires `text`".to_owned())
                })?,
            })),
            FfiMessengerMessageBodyKind::Reaction => {
                Ok(MessageBody::Reaction(crate::ReactionMessageBody {
                    target_message_id: parse_message_id(
                        request.target_message_id.as_deref().ok_or_else(|| {
                            FfiMessengerError::Message(
                                "reaction body requires target_message_id".to_owned(),
                            )
                        })?,
                    )?,
                    emoji: request.emoji.clone().ok_or_else(|| {
                        FfiMessengerError::Message("reaction body requires emoji".to_owned())
                    })?,
                    action: ffi_reaction_action_to_model(request.reaction_action.ok_or_else(
                        || {
                            FfiMessengerError::Message(
                                "reaction body requires reaction_action".to_owned(),
                            )
                        },
                    )?),
                }))
            }
            FfiMessengerMessageBodyKind::Receipt => {
                Ok(MessageBody::Receipt(crate::ReceiptMessageBody {
                    target_message_id: parse_message_id(
                        request.target_message_id.as_deref().ok_or_else(|| {
                            FfiMessengerError::Message(
                                "receipt body requires target_message_id".to_owned(),
                            )
                        })?,
                    )?,
                    receipt_type: ffi_receipt_type_to_model(request.receipt_type.ok_or_else(
                        || {
                            FfiMessengerError::Message(
                                "receipt body requires receipt_type".to_owned(),
                            )
                        },
                    )?),
                    at_unix: request.receipt_at_unix,
                }))
            }
            FfiMessengerMessageBodyKind::Attachment => Err(FfiMessengerError::AttachmentInvalid(
                "attachment messages must be sent via send_attachment + send_message(token)"
                    .to_owned(),
            )),
            FfiMessengerMessageBodyKind::ChatEvent => {
                Ok(MessageBody::ChatEvent(crate::ChatEventMessageBody {
                    event_type: request.event_type.clone().ok_or_else(|| {
                        FfiMessengerError::Message("chat_event body requires event_type".to_owned())
                    })?,
                    payload_json: parse_json_string(request.event_json.clone())?,
                }))
            }
        }
    }

    fn consume_attachment_token(
        &self,
        conversation_id: &str,
        token: &str,
    ) -> Result<AttachmentMessageBody, FfiMessengerError> {
        let now = current_unix_seconds().map_err(messenger_error)?;
        let mut state = lock_state(&self.state)?;
        gc_attachment_tokens(&mut state, now);
        let pending = state.attachment_tokens.get(token).cloned().ok_or_else(|| {
            FfiMessengerError::AttachmentExpired(format!(
                "attachment token {} is missing or expired",
                token
            ))
        })?;
        if pending.conversation_id != conversation_id {
            return Err(FfiMessengerError::AttachmentInvalid(format!(
                "attachment token {} belongs to another conversation",
                token
            )));
        }
        state.attachment_tokens.remove(token);
        if let Err(error) = self.save_state_locked(&state) {
            state
                .attachment_tokens
                .insert(token.to_owned(), pending.clone());
            return Err(error);
        }
        Ok(pending.body)
    }

    fn validate_requested_checkpoint(
        &self,
        requested_checkpoint: Option<u64>,
    ) -> Result<(), FfiMessengerError> {
        let current_tail = lock_state(&self.state)?.last_event_id;
        if requested_checkpoint_matches_local_tail(requested_checkpoint, current_tail) {
            return Ok(());
        }

        let requested_checkpoint = requested_checkpoint.expect("mismatched checkpoint must exist");

        let current_label =
            checkpoint_from_event_id(current_tail).unwrap_or_else(|| "none".to_owned());
        Err(FfiMessengerError::RequiresResync(format!(
            "checkpoint evt:{requested_checkpoint} does not match local event tail {current_label}; reload snapshot"
        )))
    }

    fn send_outcome_to_message_record(
        &self,
        chat_id: ChatId,
        outcome: SendMessageOutcome,
    ) -> Result<FfiMessengerMessageRecord, FfiMessengerError> {
        let self_account_id = self.state_account_id().transpose()?;
        let message = {
            let store = lock_history_store(&self.history_store)?;
            store
                .get_local_timeline_items(
                    chat_id,
                    self_account_id,
                    outcome.server_seq.checked_sub(1),
                    Some(1),
                )
                .into_iter()
                .next()
        };
        match message {
            Some(message) => self.timeline_item_to_message_record(chat_id, message),
            None => self.projected_message_to_record(chat_id, outcome.projected_message),
        }
    }

    fn projected_message_to_record(
        &self,
        chat_id: ChatId,
        message: crate::LocalProjectedMessage,
    ) -> Result<FfiMessengerMessageRecord, FfiMessengerError> {
        let body = match message.payload {
            Some(payload) => MessageBody::from_bytes(message.content_type, &payload).ok(),
            None => None,
        };
        let preview_text = body
            .as_ref()
            .map(preview_text_for_body)
            .unwrap_or_else(|| "Message".to_owned());
        let safe_body = body
            .map(|body| self.safe_message_body_from(chat_id, message.message_id, body))
            .transpose()?;
        Ok(FfiMessengerMessageRecord {
            conversation_id: chat_id.0.to_string(),
            server_seq: message.server_seq,
            message_id: message.message_id.0.to_string(),
            sender_account_id: message.sender_account_id.0.to_string(),
            sender_device_id: message.sender_device_id.0.to_string(),
            sender_display_name: None,
            is_outgoing: Some(message.sender_account_id) == self.state_account_id().transpose()?,
            epoch: message.epoch,
            content_type: message.content_type.into(),
            body: safe_body,
            preview_text,
            created_at_unix: message.created_at_unix,
        })
    }

    fn timeline_item_to_message_record(
        &self,
        chat_id: ChatId,
        item: LocalTimelineItem,
    ) -> Result<FfiMessengerMessageRecord, FfiMessengerError> {
        let body = item
            .body
            .map(|body| self.safe_message_body_from(chat_id, item.message_id, body))
            .transpose()?;
        Ok(FfiMessengerMessageRecord {
            conversation_id: chat_id.0.to_string(),
            server_seq: item.server_seq,
            message_id: item.message_id.0.to_string(),
            sender_account_id: item.sender_account_id.0.to_string(),
            sender_device_id: item.sender_device_id.0.to_string(),
            sender_display_name: Some(item.sender_display_name),
            is_outgoing: item.is_outgoing,
            epoch: item.epoch,
            content_type: item.content_type.into(),
            body,
            preview_text: item.preview_text,
            created_at_unix: item.created_at_unix,
        })
    }

    fn safe_message_body_from(
        &self,
        chat_id: ChatId,
        message_id: MessageId,
        body: MessageBody,
    ) -> Result<FfiMessengerMessageBody, FfiMessengerError> {
        match body {
            MessageBody::Text(body) => Ok(FfiMessengerMessageBody {
                kind: FfiMessengerMessageBodyKind::Text,
                text: Some(body.text),
                target_message_id: None,
                emoji: None,
                reaction_action: None,
                receipt_type: None,
                receipt_at_unix: None,
                attachment: None,
                event_type: None,
                event_json: None,
            }),
            MessageBody::Reaction(body) => Ok(FfiMessengerMessageBody {
                kind: FfiMessengerMessageBodyKind::Reaction,
                text: None,
                target_message_id: Some(body.target_message_id.0.to_string()),
                emoji: Some(body.emoji),
                reaction_action: Some(reaction_action_to_ffi(body.action)),
                receipt_type: None,
                receipt_at_unix: None,
                attachment: None,
                event_type: None,
                event_json: None,
            }),
            MessageBody::Receipt(body) => Ok(FfiMessengerMessageBody {
                kind: FfiMessengerMessageBodyKind::Receipt,
                text: None,
                target_message_id: Some(body.target_message_id.0.to_string()),
                emoji: None,
                reaction_action: None,
                receipt_type: Some(receipt_type_to_ffi(body.receipt_type)),
                receipt_at_unix: body.at_unix,
                attachment: None,
                event_type: None,
                event_json: None,
            }),
            MessageBody::Attachment(body) => Ok(FfiMessengerMessageBody {
                kind: FfiMessengerMessageBodyKind::Attachment,
                text: None,
                target_message_id: None,
                emoji: None,
                reaction_action: None,
                receipt_type: None,
                receipt_at_unix: None,
                attachment: Some(self.attachment_descriptor_from(chat_id, message_id, &body)?),
                event_type: None,
                event_json: None,
            }),
            MessageBody::ChatEvent(body) => Ok(FfiMessengerMessageBody {
                kind: FfiMessengerMessageBodyKind::ChatEvent,
                text: None,
                target_message_id: None,
                emoji: None,
                reaction_action: None,
                receipt_type: None,
                receipt_at_unix: None,
                attachment: None,
                event_type: Some(body.event_type),
                event_json: Some(body.payload_json.to_string()),
            }),
        }
    }

    fn attachment_descriptor_from(
        &self,
        _chat_id: ChatId,
        _message_id: MessageId,
        body: &AttachmentMessageBody,
    ) -> Result<FfiMessengerAttachmentDescriptor, FfiMessengerError> {
        let fingerprint = attachment_fingerprint(body).map_err(messenger_error)?;
        let attachment_ref = {
            let mut store = lock_history_store(&self.history_store)?;
            let attachment_ref = store
                .attachment_ref_for_fingerprint(&fingerprint)
                .unwrap_or_else(|| Uuid::new_v4().to_string());
            let created_at_unix = current_unix_seconds().map_err(messenger_error)?;
            store
                .persist_attachment_ref(
                    attachment_ref.clone(),
                    fingerprint.clone(),
                    body.clone(),
                    created_at_unix,
                )
                .map_err(map_domain_error)?;
            attachment_ref
        };
        Ok(FfiMessengerAttachmentDescriptor {
            attachment_ref,
            mime_type: body.mime_type.clone(),
            size_bytes: body.size_bytes,
            file_name: body.file_name.clone(),
            width_px: body.width_px,
            height_px: body.height_px,
        })
    }

    fn fetch_and_store_devices(
        &self,
        client: &ServerApiClient,
    ) -> Result<(Vec<FfiMessengerDeviceRecord>, Vec<FfiMessengerEvent>), FfiMessengerError> {
        let response = self
            .runtime
            .block_on(client.list_devices())
            .map_err(messenger_error)?;
        let current_device_id = lock_state(&self.state)?.device_id.clone();
        let mut new_events = Vec::new();
        let devices = response
            .devices
            .into_iter()
            .map(|device| FfiMessengerDeviceRecord {
                account_id: response.account_id.0.to_string(),
                device_id: device.device_id.0.to_string(),
                display_name: device.display_name,
                platform: device.platform,
                device_status: device_status_to_ffi(device.device_status),
                available_key_package_count: device.available_key_package_count,
                is_current_device: current_device_id
                    .as_deref()
                    .map(|value| value == device.device_id.0.to_string())
                    .unwrap_or(false),
            })
            .collect::<Vec<_>>();

        let mut pending_device_events = Vec::new();
        {
            let mut state = lock_state(&self.state)?;
            for device in &devices {
                let previous = state.device_statuses.get(&device.device_id).cloned();
                let current = ffi_device_status_to_model(device.device_status);
                if let Some(previous) = previous {
                    match (previous.device_status, current) {
                        (DeviceStatus::Pending, DeviceStatus::Active) => pending_device_events
                            .push((FfiMessengerEventKind::DeviceApproved, device.clone())),
                        (DeviceStatus::Active | DeviceStatus::Pending, DeviceStatus::Revoked) => {
                            pending_device_events
                                .push((FfiMessengerEventKind::DeviceRevoked, device.clone()));
                        }
                        _ => {}
                    }
                } else if current == DeviceStatus::Pending {
                    pending_device_events
                        .push((FfiMessengerEventKind::DevicePending, device.clone()));
                }
                state.device_statuses.insert(
                    device.device_id.clone(),
                    StoredDeviceState {
                        account_id: device.account_id.clone(),
                        device_status: current,
                    },
                );
            }
            self.save_state_locked(&state)?;
        }

        for (kind, device) in pending_device_events {
            new_events.push(self.new_event(kind, None, None, None, Some(device), None, None)?);
        }

        Ok((devices, new_events))
    }

    fn conversation_mutation_from_create_outcome(
        &self,
        outcome: crate::CreateChatControlOutcome,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let messages = {
            let self_account_id = self.state_account_id().transpose()?;
            let store = lock_history_store(&self.history_store)?;
            store.get_local_timeline_items(outcome.chat_id, self_account_id, None, None)
        };
        Ok(FfiMessengerConversationMutationResult {
            conversation_id: outcome.chat_id.0.to_string(),
            conversation: self.get_conversation_summary(outcome.chat_id)?,
            messages: messages
                .into_iter()
                .map(|message| self.timeline_item_to_message_record(outcome.chat_id, message))
                .collect::<Result<Vec<_>, _>>()?,
            changed_account_ids: Vec::new(),
            changed_device_ids: Vec::new(),
        })
    }

    fn conversation_mutation_from_member_outcome(
        &self,
        outcome: crate::ModifyChatMembersControlOutcome,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let messages = {
            let self_account_id = self.state_account_id().transpose()?;
            let store = lock_history_store(&self.history_store)?;
            store.get_local_timeline_items(outcome.chat_id, self_account_id, None, None)
        };
        Ok(FfiMessengerConversationMutationResult {
            conversation_id: outcome.chat_id.0.to_string(),
            conversation: self.get_conversation_summary(outcome.chat_id)?,
            messages: messages
                .into_iter()
                .map(|message| self.timeline_item_to_message_record(outcome.chat_id, message))
                .collect::<Result<Vec<_>, _>>()?,
            changed_account_ids: outcome
                .changed_account_ids
                .into_iter()
                .map(|account_id| account_id.0.to_string())
                .collect(),
            changed_device_ids: Vec::new(),
        })
    }

    fn conversation_mutation_from_device_outcome(
        &self,
        outcome: crate::ModifyChatDevicesControlOutcome,
    ) -> Result<FfiMessengerConversationMutationResult, FfiMessengerError> {
        let messages = {
            let self_account_id = self.state_account_id().transpose()?;
            let store = lock_history_store(&self.history_store)?;
            store.get_local_timeline_items(outcome.chat_id, self_account_id, None, None)
        };
        Ok(FfiMessengerConversationMutationResult {
            conversation_id: outcome.chat_id.0.to_string(),
            conversation: self.get_conversation_summary(outcome.chat_id)?,
            messages: messages
                .into_iter()
                .map(|message| self.timeline_item_to_message_record(outcome.chat_id, message))
                .collect::<Result<Vec<_>, _>>()?,
            changed_account_ids: Vec::new(),
            changed_device_ids: outcome
                .changed_device_ids
                .into_iter()
                .map(|device_id| device_id.0.to_string())
                .collect(),
        })
    }

    fn new_event(
        &self,
        kind: FfiMessengerEventKind,
        conversation_id: Option<String>,
        message: Option<FfiMessengerMessageRecord>,
        conversation: Option<FfiMessengerConversationSummary>,
        device: Option<FfiMessengerDeviceRecord>,
        read_state: Option<FfiMessengerReadStateResult>,
        attachment_ref: Option<String>,
    ) -> Result<FfiMessengerEvent, FfiMessengerError> {
        let mut state = lock_state(&self.state)?;
        state.next_event_id += 1;
        state.last_event_id = state.next_event_id;
        let event_id = state.last_event_id.to_string();
        self.save_state_locked(&state)?;
        Ok(FfiMessengerEvent {
            event_id,
            kind,
            conversation_id,
            message,
            conversation,
            device,
            read_state,
            attachment_ref,
        })
    }

    fn find_message_server_seq(
        &self,
        chat_id: ChatId,
        message_id: MessageId,
    ) -> Result<u64, FfiMessengerError> {
        let store = lock_history_store(&self.history_store)?;
        let history = store.get_chat_history(chat_id, None, None);
        history
            .messages
            .into_iter()
            .find(|message| message.message_id == message_id)
            .map(|message| message.server_seq)
            .ok_or_else(|| {
                FfiMessengerError::Message(format!(
                    "message {} was not found in conversation {}",
                    message_id.0, chat_id.0
                ))
            })
    }
}

fn build_runtime() -> Result<Runtime> {
    Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to build tokio runtime")
}

fn load_state_from_path(
    path: &Path,
    database_key: &[u8],
) -> Result<MessengerClientState, FfiMessengerError> {
    let payload = fs::read(path).map_err(messenger_error)?;
    if payload.len() < 24 {
        return Err(FfiMessengerError::Message(format!(
            "messenger state at {} is truncated",
            path.display()
        )));
    }
    let cipher = state_cipher(database_key).map_err(messenger_error)?;
    let (nonce, ciphertext) = payload.split_at(24);
    let plaintext = cipher
        .decrypt(XNonce::from_slice(nonce), ciphertext)
        .map_err(|_| {
            FfiMessengerError::Message(format!(
                "failed to decrypt messenger state at {}",
                path.display()
            ))
        })?;
    serde_json::from_slice(&plaintext)
        .map_err(|err| FfiMessengerError::Message(format!("invalid messenger state: {err}")))
}

fn save_state_to_path(
    path: &Path,
    database_key: &[u8],
    state: &MessengerClientState,
) -> Result<(), FfiMessengerError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(messenger_error)?;
    }
    let plaintext = serde_json::to_vec(state).map_err(messenger_error)?;
    let nonce = rand::random::<[u8; 24]>();
    let cipher = state_cipher(database_key).map_err(messenger_error)?;
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext.as_slice())
        .map_err(|_| FfiMessengerError::Message("failed to encrypt messenger state".to_owned()))?;
    let mut payload = nonce.to_vec();
    payload.extend_from_slice(&ciphertext);
    fs::write(path, payload).map_err(messenger_error)
}

fn state_cipher(database_key: &[u8]) -> Result<XChaCha20Poly1305> {
    let digest = Sha256::digest(database_key);
    XChaCha20Poly1305::new_from_slice(digest.as_slice())
        .map_err(|_| anyhow!("failed to derive messenger state cipher"))
}

fn attachment_file_path(root: &str, attachment_ref: &str, body: &AttachmentMessageBody) -> PathBuf {
    let extension = body
        .file_name
        .as_deref()
        .and_then(|file_name| Path::new(file_name).extension())
        .and_then(|ext| ext.to_str())
        .map(|ext| format!(".{ext}"))
        .unwrap_or_default();
    PathBuf::from(root).join(format!("{attachment_ref}{extension}"))
}

fn attachment_fingerprint(body: &AttachmentMessageBody) -> Result<String> {
    let payload = serde_json::to_vec(body)?;
    Ok(encode_b64(&Sha256::digest(&payload)))
}

fn current_unix_seconds() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before unix epoch")?
        .as_secs())
}

fn merge_option(target: &mut Option<String>, incoming: Option<String>) {
    if let Some(incoming) = incoming {
        if !incoming.trim().is_empty() {
            *target = Some(incoming);
        }
    }
}

fn merge_option_vec(target: &mut Option<Vec<u8>>, incoming: Option<Vec<u8>>) {
    if let Some(incoming) = incoming {
        if !incoming.is_empty() {
            *target = Some(incoming);
        }
    }
}

fn normalize_revoke_reason(reason: Option<String>) -> String {
    reason
        .and_then(|value| {
            let trimmed = value.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_owned())
        })
        .unwrap_or_else(|| SAFE_DEFAULT_REVOKE_REASON.to_owned())
}

fn gc_attachment_tokens(state: &mut MessengerClientState, now: u64) {
    state
        .attachment_tokens
        .retain(|_, attachment| attachment.expires_at_unix > now);
}

fn parse_page_cursor(value: &str) -> Result<u64, FfiMessengerError> {
    let value = value
        .strip_prefix("seq:")
        .ok_or_else(|| FfiMessengerError::Message("invalid page cursor".to_owned()))?;
    value
        .parse::<u64>()
        .map_err(|err| FfiMessengerError::Message(format!("invalid page cursor: {err}")))
}

fn page_cursor_from_server_seq(server_seq: u64) -> String {
    format!("seq:{server_seq}")
}

fn paginate_server_seq_window<T, F>(
    items: &[T],
    before_server_seq: Option<u64>,
    limit: usize,
    server_seq: F,
) -> (usize, usize, Option<u64>)
where
    F: Fn(&T) -> u64,
{
    if limit == 0 || items.is_empty() {
        return (0, 0, None);
    }
    let filtered_end = before_server_seq
        .map(|cursor| items.partition_point(|item| server_seq(item) < cursor))
        .unwrap_or(items.len());
    let page_start = filtered_end.saturating_sub(limit);
    let next_cursor = if page_start > 0 && page_start < filtered_end {
        Some(server_seq(&items[page_start]))
    } else {
        None
    };
    (page_start, filtered_end, next_cursor)
}

fn parse_checkpoint(value: &str) -> Result<u64, FfiMessengerError> {
    let value = value
        .strip_prefix("evt:")
        .ok_or_else(|| FfiMessengerError::Message("invalid checkpoint".to_owned()))?;
    value
        .parse::<u64>()
        .map_err(|err| FfiMessengerError::Message(format!("invalid checkpoint: {err}")))
}

fn checkpoint_from_event_id(event_id: u64) -> Option<String> {
    if event_id == 0 {
        None
    } else {
        Some(format!("evt:{event_id}"))
    }
}

fn requested_checkpoint_matches_local_tail(
    requested_checkpoint: Option<u64>,
    current_tail: u64,
) -> bool {
    requested_checkpoint.is_none() || requested_checkpoint == Some(current_tail)
}

fn parse_uuid(value: &str, field: &str) -> Result<Uuid, FfiMessengerError> {
    Uuid::parse_str(value)
        .map_err(|err| FfiMessengerError::Message(format!("invalid {field}: {err}")))
}

fn parse_account_id(value: &str) -> Result<AccountId, FfiMessengerError> {
    Ok(AccountId(parse_uuid(value, "account_id")?))
}

fn parse_device_id(value: &str) -> Result<DeviceId, FfiMessengerError> {
    Ok(DeviceId(parse_uuid(value, "device_id")?))
}

fn parse_chat_id(value: &str) -> Result<ChatId, FfiMessengerError> {
    Ok(ChatId(parse_uuid(value, "chat_id")?))
}

fn parse_message_id(value: &str) -> Result<MessageId, FfiMessengerError> {
    Ok(MessageId(parse_uuid(value, "message_id")?))
}

fn parse_json_string(value: Option<String>) -> Result<Value, FfiMessengerError> {
    let payload = value.unwrap_or_else(|| "{}".to_owned());
    serde_json::from_str(&payload)
        .map_err(|err| FfiMessengerError::Message(format!("invalid json payload: {err}")))
}

fn to_32_bytes(bytes: Vec<u8>, field: &str) -> Result<[u8; 32], FfiMessengerError> {
    bytes
        .as_slice()
        .try_into()
        .map_err(|_| FfiMessengerError::Message(format!("{field} must be exactly 32 bytes")))
}

fn has_persistent_mls_state(storage_root: &Path) -> bool {
    storage_root.join("metadata.json").exists() && storage_root.join("storage.json").exists()
}

fn migrate_legacy_mls_storage_root(root_path: &Path) -> Result<()> {
    let legacy_root = root_path.join("mls-state");
    if !legacy_root.exists() {
        return Ok(());
    }

    let target_root = root_path.join("mls");
    let legacy_has_snapshot = has_persistent_mls_state(&legacy_root);
    let target_has_snapshot = has_persistent_mls_state(&target_root);
    if !legacy_has_snapshot || target_has_snapshot {
        return Ok(());
    }

    if target_root.exists() {
        fs::remove_dir_all(&target_root).with_context(|| {
            format!(
                "failed to remove incomplete migrated MLS storage root {}",
                target_root.display()
            )
        })?;
    }

    fs::rename(&legacy_root, &target_root).with_context(|| {
        format!(
            "failed to migrate legacy MLS storage root {} to {}",
            legacy_root.display(),
            target_root.display()
        )
    })?;
    Ok(())
}

fn has_any_legacy_client_store_path(root_path: &Path) -> bool {
    legacy_history_paths(root_path)
        .into_iter()
        .chain(legacy_sync_paths(root_path))
        .any(|path| path.exists())
}

fn migrate_legacy_client_store(
    root_path: &Path,
    database_path: &Path,
    history_store: &mut LocalHistoryStore,
    sync_coordinator: &mut SyncCoordinator,
) -> Result<()> {
    if let Some(legacy_history) = load_legacy_history_store(root_path)? {
        history_store.replace_with(&legacy_history)?;
    }
    if let Some(legacy_sync) = load_legacy_sync_coordinator(root_path)? {
        sync_coordinator.replace_with(&legacy_sync)?;
    }

    cleanup_legacy_client_store(root_path)?;

    if !database_path.exists() {
        return Err(anyhow!(
            "encrypted client store was not created at {}",
            database_path.display()
        ));
    }

    Ok(())
}

fn load_legacy_history_store(root_path: &Path) -> Result<Option<LocalHistoryStore>> {
    for path in legacy_history_paths(root_path) {
        if path.exists() {
            return LocalHistoryStore::new_persistent(&path).map(Some);
        }
    }
    Ok(None)
}

fn load_legacy_sync_coordinator(root_path: &Path) -> Result<Option<SyncCoordinator>> {
    for path in legacy_sync_paths(root_path) {
        if path.exists() {
            return SyncCoordinator::new_persistent(&path).map(Some);
        }
    }
    Ok(None)
}

fn cleanup_legacy_client_store(root_path: &Path) -> Result<()> {
    for path in legacy_history_paths(root_path)
        .into_iter()
        .chain(legacy_sync_paths(root_path))
    {
        cleanup_sqlite_sidecars(&path)?;
    }
    remove_dir_if_empty(&root_path.join("history"))?;
    remove_dir_if_empty(&root_path.join("sync"))?;
    Ok(())
}

fn cleanup_sqlite_sidecars(path: &Path) -> Result<()> {
    for candidate in sqlite_path_set(path) {
        remove_file_if_exists(&candidate)?;
    }
    Ok(())
}

fn sqlite_path_set(path: &Path) -> [PathBuf; 3] {
    [
        path.to_path_buf(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ]
}

fn remove_file_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn remove_dir_if_empty(path: &Path) -> Result<()> {
    if path.is_dir() && path.read_dir()?.next().is_none() {
        fs::remove_dir(path)?;
    }
    Ok(())
}

fn legacy_history_paths(root_path: &Path) -> [PathBuf; 4] {
    [
        root_path.join("trix-client.db"),
        root_path.join("local-history.sqlite"),
        root_path.join("history-store.sqlite"),
        root_path.join("history/local-history-v1.json"),
    ]
}

fn legacy_sync_paths(root_path: &Path) -> [PathBuf; 2] {
    [
        root_path.join("sync-state.sqlite"),
        root_path.join("sync/sync-state-v1.json"),
    ]
}

fn lock_client(
    value: &Mutex<ServerApiClient>,
) -> Result<MutexGuard<'_, ServerApiClient>, FfiMessengerError> {
    value
        .lock()
        .map_err(|_| FfiMessengerError::Message("client mutex poisoned".to_owned()))
}

fn lock_state(
    value: &Mutex<MessengerClientState>,
) -> Result<MutexGuard<'_, MessengerClientState>, FfiMessengerError> {
    value
        .lock()
        .map_err(|_| FfiMessengerError::Message("state mutex poisoned".to_owned()))
}

fn lock_history_store(
    value: &Mutex<LocalHistoryStore>,
) -> Result<MutexGuard<'_, LocalHistoryStore>, FfiMessengerError> {
    value
        .lock()
        .map_err(|_| FfiMessengerError::Message("history store mutex poisoned".to_owned()))
}

fn lock_sync_coordinator(
    value: &Mutex<SyncCoordinator>,
) -> Result<MutexGuard<'_, SyncCoordinator>, FfiMessengerError> {
    value
        .lock()
        .map_err(|_| FfiMessengerError::Message("sync coordinator mutex poisoned".to_owned()))
}

fn lock_mls_operation(value: &Mutex<()>) -> Result<MutexGuard<'_, ()>, FfiMessengerError> {
    value
        .lock()
        .map_err(|_| FfiMessengerError::Message("mls operation mutex poisoned".to_owned()))
}

fn capability_flags() -> FfiMessengerCapabilityFlags {
    FfiMessengerCapabilityFlags {
        safe_messaging: true,
        attachments: true,
        typing: true,
        device_linking: true,
        conversation_controls: true,
    }
}

fn conversation_summary_to_ffi(value: LocalChatListItem) -> FfiMessengerConversationSummary {
    FfiMessengerConversationSummary {
        conversation_id: value.chat_id.0.to_string(),
        conversation_type: chat_type_to_ffi(value.chat_type),
        title: value.title,
        display_title: value.display_title,
        last_server_seq: value.last_server_seq,
        epoch: value.epoch,
        unread_count: value.unread_count,
        pending_message_count: value.pending_message_count,
        preview_text: value.preview_text,
        preview_sender_account_id: value
            .preview_sender_account_id
            .map(|account_id| account_id.0.to_string()),
        preview_sender_display_name: value.preview_sender_display_name,
        preview_is_outgoing: value.preview_is_outgoing,
        preview_server_seq: value.preview_server_seq,
        preview_created_at_unix: value.preview_created_at_unix,
        participant_profiles: value
            .participant_profiles
            .into_iter()
            .map(|profile| FfiMessengerParticipantProfile {
                account_id: profile.account_id.0.to_string(),
                handle: profile.handle,
                profile_name: profile.profile_name,
                profile_bio: profile.profile_bio,
            })
            .collect(),
    }
}

fn chat_type_to_ffi(value: trix_types::ChatType) -> FfiChatType {
    match value {
        trix_types::ChatType::Dm => FfiChatType::Dm,
        trix_types::ChatType::Group => FfiChatType::Group,
        trix_types::ChatType::AccountSync => FfiChatType::AccountSync,
    }
}

fn ffi_chat_type_to_model(value: FfiChatType) -> trix_types::ChatType {
    match value {
        FfiChatType::Dm => trix_types::ChatType::Dm,
        FfiChatType::Group => trix_types::ChatType::Group,
        FfiChatType::AccountSync => trix_types::ChatType::AccountSync,
    }
}

fn device_status_to_ffi(value: DeviceStatus) -> FfiDeviceStatus {
    match value {
        DeviceStatus::Pending => FfiDeviceStatus::Pending,
        DeviceStatus::Active => FfiDeviceStatus::Active,
        DeviceStatus::Revoked => FfiDeviceStatus::Revoked,
    }
}

fn ffi_device_status_to_model(value: FfiDeviceStatus) -> DeviceStatus {
    match value {
        FfiDeviceStatus::Pending => DeviceStatus::Pending,
        FfiDeviceStatus::Active => DeviceStatus::Active,
        FfiDeviceStatus::Revoked => DeviceStatus::Revoked,
    }
}

fn reaction_action_to_ffi(value: ReactionAction) -> FfiReactionAction {
    match value {
        ReactionAction::Add => FfiReactionAction::Add,
        ReactionAction::Remove => FfiReactionAction::Remove,
    }
}

fn ffi_reaction_action_to_model(value: FfiReactionAction) -> ReactionAction {
    match value {
        FfiReactionAction::Add => ReactionAction::Add,
        FfiReactionAction::Remove => ReactionAction::Remove,
    }
}

fn receipt_type_to_ffi(value: ReceiptType) -> FfiReceiptType {
    match value {
        ReceiptType::Delivered => FfiReceiptType::Delivered,
        ReceiptType::Read => FfiReceiptType::Read,
    }
}

fn ffi_receipt_type_to_model(value: FfiReceiptType) -> ReceiptType {
    match value {
        FfiReceiptType::Delivered => ReceiptType::Delivered,
        FfiReceiptType::Read => ReceiptType::Read,
    }
}

fn preview_text_for_body(body: &MessageBody) -> String {
    match body {
        MessageBody::Text(body) => body.text.clone(),
        MessageBody::Reaction(body) => format!("Reaction {}", body.emoji),
        MessageBody::Receipt(body) => match body.receipt_type {
            ReceiptType::Delivered => "Delivered".to_owned(),
            ReceiptType::Read => "Read".to_owned(),
        },
        MessageBody::Attachment(body) => body
            .file_name
            .clone()
            .unwrap_or_else(|| "Attachment".to_owned()),
        MessageBody::ChatEvent(body) => body.event_type.clone(),
    }
}

fn is_unauthorized(error: &ServerApiError) -> bool {
    matches!(error, ServerApiError::Api { status: 401, .. })
}

fn map_domain_error(error: impl std::fmt::Display) -> FfiMessengerError {
    let message = error.to_string();
    if message.contains("no bootstrappable MLS state")
        || message.contains("failed to bootstrap MLS conversation")
        || message.contains("MLS")
    {
        FfiMessengerError::RequiresResync(message)
    } else {
        FfiMessengerError::Message(message)
    }
}

fn messenger_error(error: impl std::fmt::Display) -> FfiMessengerError {
    FfiMessengerError::Message(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    use trix_types::{
        ChatDetailResponse, ChatHistoryResponse, ChatParticipantProfileSummary, ChatType,
        ContentType, MessageEnvelope, MessageKind,
    };

    #[test]
    fn attachment_tokens_are_gced_when_expired() {
        let mut state = MessengerClientState::default();
        state.attachment_tokens.insert(
            "expired".to_owned(),
            StoredPendingAttachment {
                conversation_id: Uuid::new_v4().to_string(),
                body: AttachmentMessageBody {
                    blob_id: "blob".to_owned(),
                    mime_type: "image/png".to_owned(),
                    size_bytes: 1,
                    sha256: vec![1],
                    file_name: Some("pic.png".to_owned()),
                    width_px: None,
                    height_px: None,
                    file_key: vec![0; 32],
                    nonce: vec![0; 24],
                },
                created_at_unix: 1,
                expires_at_unix: 2,
            },
        );
        gc_attachment_tokens(&mut state, 2);
        assert!(state.attachment_tokens.is_empty());
    }

    #[test]
    fn page_cursor_round_trip() {
        let cursor = page_cursor_from_server_seq(42);
        assert_eq!(parse_page_cursor(&cursor).unwrap(), 42);
    }

    #[test]
    fn message_pagination_defaults_to_latest_page() {
        let server_seqs = vec![1_u64, 2, 3, 4, 5];
        let (start, end, next_cursor) =
            paginate_server_seq_window(&server_seqs, None, 2, |value| *value);
        assert_eq!(&server_seqs[start..end], &[4, 5]);
        assert_eq!(next_cursor, Some(4));

        let (older_start, older_end, older_cursor) =
            paginate_server_seq_window(&server_seqs, Some(4), 2, |value| *value);
        assert_eq!(&server_seqs[older_start..older_end], &[2, 3]);
        assert_eq!(older_cursor, Some(2));

        let (oldest_start, oldest_end, oldest_cursor) =
            paginate_server_seq_window(&server_seqs, Some(2), 2, |value| *value);
        assert_eq!(&server_seqs[oldest_start..oldest_end], &[1]);
        assert_eq!(oldest_cursor, None);
    }

    #[test]
    fn checkpoint_round_trip() {
        let checkpoint = checkpoint_from_event_id(9).unwrap();
        assert_eq!(parse_checkpoint(&checkpoint).unwrap(), 9);
    }

    #[test]
    fn requested_checkpoint_must_match_local_tail() {
        assert!(requested_checkpoint_matches_local_tail(None, 0));
        assert!(requested_checkpoint_matches_local_tail(None, 9));
        assert!(requested_checkpoint_matches_local_tail(Some(9), 9));
        assert!(!requested_checkpoint_matches_local_tail(Some(7), 9));
        assert!(!requested_checkpoint_matches_local_tail(Some(11), 9));
    }

    #[test]
    fn revoke_reason_defaults_when_empty() {
        assert_eq!(
            normalize_revoke_reason(None),
            SAFE_DEFAULT_REVOKE_REASON.to_owned()
        );
        assert_eq!(
            normalize_revoke_reason(Some("   ".to_owned())),
            SAFE_DEFAULT_REVOKE_REASON.to_owned()
        );
        assert_eq!(
            normalize_revoke_reason(Some(" compromised ".to_owned())),
            "compromised".to_owned()
        );
    }

    #[test]
    fn open_migrates_legacy_store_and_mls_layout() {
        let root_path = env::temp_dir().join(format!("trix-messenger-open-{}", Uuid::new_v4()));
        fs::create_dir_all(&root_path).unwrap();

        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());
        let credential_identity = b"legacy-device".to_vec();

        let legacy_history_path = root_path.join("local-history.sqlite");
        let legacy_sync_path = root_path.join("sync-state.sqlite");
        let legacy_mls_root = root_path.join("mls-state");
        let unified_database_path = root_path.join("client-store.sqlite");

        let mut legacy_history = LocalHistoryStore::new_persistent(&legacy_history_path).unwrap();
        legacy_history
            .apply_chat_detail(&ChatDetailResponse {
                chat_id,
                chat_type: ChatType::Dm,
                title: None,
                last_server_seq: 1,
                pending_message_count: 0,
                epoch: 1,
                last_commit_message_id: None,
                last_message: None,
                participant_profiles: vec![ChatParticipantProfileSummary {
                    account_id,
                    handle: Some("legacy".to_owned()),
                    profile_name: "Legacy".to_owned(),
                    profile_bio: None,
                }],
                members: Vec::new(),
                device_members: Vec::new(),
            })
            .unwrap();
        legacy_history
            .apply_chat_history(&ChatHistoryResponse {
                chat_id,
                messages: vec![MessageEnvelope {
                    message_id: MessageId(Uuid::new_v4()),
                    chat_id,
                    server_seq: 1,
                    sender_account_id: account_id,
                    sender_device_id: device_id,
                    epoch: 1,
                    message_kind: MessageKind::System,
                    content_type: ContentType::ChatEvent,
                    ciphertext_b64: encode_b64(br#"{"migrated":true}"#),
                    aad_json: serde_json::json!({}),
                    created_at_unix: 1,
                }],
            })
            .unwrap();

        let mut legacy_sync = SyncCoordinator::new_persistent(&legacy_sync_path).unwrap();
        legacy_sync.record_chat_server_seq(chat_id, 1).unwrap();

        let legacy_facade =
            MlsFacade::new_persistent(credential_identity.clone(), &legacy_mls_root).unwrap();
        let legacy_group = legacy_facade.create_group(chat_id.0.as_bytes()).unwrap();
        legacy_history
            .set_chat_mls_group_id(chat_id, &legacy_group.group_id())
            .unwrap();

        // Simulate a failed first safe-client launch that already created an empty
        // encrypted store before migration logic was added.
        LocalHistoryStore::new_encrypted(&unified_database_path, vec![7u8; 32]).unwrap();
        SyncCoordinator::new_encrypted(&unified_database_path, vec![7u8; 32]).unwrap();

        let client = FfiMessengerClient::open(FfiMessengerOpenConfig {
            root_path: root_path.to_string_lossy().into_owned(),
            database_key: vec![7u8; 32],
            base_url: "http://127.0.0.1:8080".to_owned(),
            access_token: None,
            account_id: Some(account_id.0.to_string()),
            device_id: Some(device_id.0.to_string()),
            account_sync_chat_id: None,
            device_display_name: Some("legacy-device".to_owned()),
            platform: Some("test".to_owned()),
            credential_identity: Some(credential_identity.clone()),
            account_root_private_key: None,
            transport_private_key: None,
        })
        .unwrap();

        assert!(!legacy_history_path.exists());
        assert!(!legacy_sync_path.exists());
        assert!(!legacy_mls_root.exists());
        assert!(root_path.join("client-store.sqlite").exists());
        assert!(has_persistent_mls_state(&root_path.join("mls")));

        let store = lock_history_store(&client.history_store).unwrap();
        assert!(store.get_chat(chat_id).is_some());
        assert_eq!(
            store.chat_mls_group_id(chat_id).as_deref(),
            Some(legacy_group.group_id().as_slice())
        );
        drop(store);

        let facade = client.open_or_load_mls_facade().unwrap();
        assert!(
            facade
                .load_group(legacy_group.group_id())
                .unwrap()
                .is_some()
        );

        fs::remove_dir_all(root_path).ok();
    }
}
