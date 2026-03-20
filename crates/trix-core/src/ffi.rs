use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::Value;
use thiserror::Error;
use tokio::runtime::{Builder, Runtime};
use trix_types::{AccountId, ChatId, DeviceId, MessageId};
use uuid::Uuid;

use crate::{
    AccountRootMaterial, AuthChallengeMaterial, CompleteLinkIntentParams,
    CompletedLinkIntentMaterial, CreateAccountParams, CreateChatControlInput,
    CreateChatControlOutcome, DeviceApprovePayloadMaterial, DeviceKeyMaterial,
    DeviceTransferBundleMaterial, DirectoryAccountMaterial, HistorySyncChunkMaterial,
    InboxApplyOutcome, LocalHistoryStore, LocalProjectedMessage, LocalProjectionApplyReport,
    LocalProjectionKind, LocalStoreApplyReport, MessageBody, MlsCommitBundle, MlsFacade,
    MlsMemberIdentity, MlsProcessResult, ModifyChatDevicesControlInput,
    ModifyChatDevicesControlOutcome, ModifyChatMembersControlInput,
    ModifyChatMembersControlOutcome, PublishKeyPackageMaterial, ReactionAction, ReceiptType,
    ReservedKeyPackageMaterial, SendMessageOutcome, ServerApiClient, SyncChatCursor,
    SyncCoordinator, SyncStateSnapshot, UpdateAccountProfileParams,
};

#[derive(Debug, Error, uniffi::Error)]
pub enum TrixFfiError {
    #[error("{0}")]
    Message(String),
}

impl From<crate::ServerApiError> for TrixFfiError {
    fn from(value: crate::ServerApiError) -> Self {
        ffi_error(value)
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiDeviceStatus {
    Pending,
    Active,
    Revoked,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiChatType {
    Dm,
    Group,
    AccountSync,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiMessageKind {
    Application,
    Commit,
    WelcomeRef,
    System,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiContentType {
    Text,
    Reaction,
    Receipt,
    Attachment,
    ChatEvent,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiHistorySyncJobType {
    InitialSync,
    ChatBackfill,
    DeviceRekey,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiHistorySyncJobStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Canceled,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiHistorySyncJobRole {
    Source,
    Target,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiBlobUploadStatus {
    PendingUpload,
    Available,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiServiceStatus {
    Ok,
    Degraded,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiMlsProcessKind {
    ApplicationMessage,
    ProposalQueued,
    CommitMerged,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateAccountParams {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity: Vec<u8>,
    pub account_root_pubkey: Vec<u8>,
    pub account_root_signature: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateAccountResponse {
    pub account_id: String,
    pub device_id: String,
    pub account_sync_chat_id: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiHealthResponse {
    pub service: String,
    pub status: FfiServiceStatus,
    pub version: String,
    pub uptime_ms: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiVersionResponse {
    pub service: String,
    pub version: String,
    pub git_sha: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAuthChallenge {
    pub challenge_id: String,
    pub challenge: Vec<u8>,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAuthSession {
    pub access_token: String,
    pub expires_at_unix: u64,
    pub account_id: String,
    pub device_status: FfiDeviceStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAccountProfile {
    pub account_id: String,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub device_id: String,
    pub device_status: FfiDeviceStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDirectoryAccount {
    pub account_id: String,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAccountDirectory {
    pub accounts: Vec<FfiDirectoryAccount>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiUpdateAccountProfileParams {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDeviceSummary {
    pub device_id: String,
    pub display_name: String,
    pub platform: String,
    pub device_status: FfiDeviceStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDeviceList {
    pub account_id: String,
    pub devices: Vec<FfiDeviceSummary>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateLinkIntentResponse {
    pub link_intent_id: String,
    pub qr_payload: String,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPublishKeyPackage {
    pub cipher_suite: String,
    pub key_package: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPublishedKeyPackage {
    pub key_package_id: String,
    pub cipher_suite: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPublishKeyPackagesResponse {
    pub device_id: String,
    pub packages: Vec<FfiPublishedKeyPackage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiReservedKeyPackage {
    pub key_package_id: String,
    pub device_id: String,
    pub cipher_suite: String,
    pub key_package: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCompleteLinkIntentParams {
    pub link_token: String,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
    pub key_packages: Vec<FfiPublishKeyPackage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCompletedLinkIntent {
    pub account_id: String,
    pub pending_device_id: String,
    pub device_status: FfiDeviceStatus,
    pub bootstrap_payload: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDeviceApprovePayload {
    pub account_id: String,
    pub device_id: String,
    pub device_display_name: String,
    pub platform: String,
    pub device_status: FfiDeviceStatus,
    pub credential_identity: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
    pub bootstrap_payload: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiApproveDeviceResponse {
    pub account_id: String,
    pub device_id: String,
    pub device_status: FfiDeviceStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDeviceTransferBundle {
    pub account_id: String,
    pub device_id: String,
    pub transfer_bundle: Vec<u8>,
    pub uploaded_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRevokeDeviceResponse {
    pub account_id: String,
    pub device_id: String,
    pub device_status: FfiDeviceStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiHistorySyncJob {
    pub job_id: String,
    pub job_type: FfiHistorySyncJobType,
    pub job_status: FfiHistorySyncJobStatus,
    pub source_device_id: String,
    pub target_device_id: String,
    pub chat_id: Option<String>,
    pub cursor_json: String,
    pub created_at_unix: u64,
    pub updated_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAppendHistorySyncChunkResponse {
    pub job_id: String,
    pub chunk_id: u64,
    pub job_status: FfiHistorySyncJobStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiHistorySyncChunk {
    pub chunk_id: u64,
    pub sequence_no: u64,
    pub payload: Vec<u8>,
    pub cursor_json: Option<String>,
    pub is_final: bool,
    pub uploaded_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCompleteHistorySyncJobResponse {
    pub job_id: String,
    pub job_status: FfiHistorySyncJobStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatSummary {
    pub chat_id: String,
    pub chat_type: FfiChatType,
    pub title: Option<String>,
    pub last_server_seq: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatMember {
    pub account_id: String,
    pub role: String,
    pub membership_status: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatDeviceMember {
    pub device_id: String,
    pub account_id: String,
    pub display_name: String,
    pub platform: String,
    pub leaf_index: u32,
    pub credential_identity: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatDetail {
    pub chat_id: String,
    pub chat_type: FfiChatType,
    pub title: Option<String>,
    pub last_server_seq: u64,
    pub epoch: u64,
    pub last_commit_message_id: Option<String>,
    pub members: Vec<FfiChatMember>,
    pub device_members: Vec<FfiChatDeviceMember>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiControlMessage {
    pub message_id: String,
    pub ciphertext: Vec<u8>,
    pub aad_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateChatParams {
    pub chat_type: FfiChatType,
    pub title: Option<String>,
    pub participant_account_ids: Vec<String>,
    pub reserved_key_package_ids: Vec<String>,
    pub initial_commit: Option<FfiControlMessage>,
    pub welcome_message: Option<FfiControlMessage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateChatResponse {
    pub chat_id: String,
    pub chat_type: FfiChatType,
    pub epoch: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatMembersParams {
    pub epoch: u64,
    pub participant_account_ids: Vec<String>,
    pub reserved_key_package_ids: Vec<String>,
    pub commit_message: Option<FfiControlMessage>,
    pub welcome_message: Option<FfiControlMessage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatMembersResponse {
    pub chat_id: String,
    pub epoch: u64,
    pub changed_account_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatDevicesParams {
    pub epoch: u64,
    pub device_ids: Vec<String>,
    pub reserved_key_package_ids: Vec<String>,
    pub commit_message: Option<FfiControlMessage>,
    pub welcome_message: Option<FfiControlMessage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatDevicesResponse {
    pub chat_id: String,
    pub epoch: u64,
    pub changed_device_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateMessageParams {
    pub message_id: String,
    pub epoch: u64,
    pub message_kind: FfiMessageKind,
    pub content_type: FfiContentType,
    pub ciphertext: Vec<u8>,
    pub aad_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateMessageResponse {
    pub message_id: String,
    pub server_seq: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessageEnvelope {
    pub message_id: String,
    pub chat_id: String,
    pub server_seq: u64,
    pub sender_account_id: String,
    pub sender_device_id: String,
    pub epoch: u64,
    pub message_kind: FfiMessageKind,
    pub content_type: FfiContentType,
    pub ciphertext: Vec<u8>,
    pub aad_json: String,
    pub created_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatHistory {
    pub chat_id: String,
    pub messages: Vec<FfiMessageEnvelope>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiInboxItem {
    pub inbox_id: u64,
    pub message: FfiMessageEnvelope,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiInbox {
    pub items: Vec<FfiInboxItem>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiLeaseInboxParams {
    pub lease_owner: Option<String>,
    pub limit: Option<u32>,
    pub after_inbox_id: Option<u64>,
    pub lease_ttl_seconds: Option<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiLeaseInboxResponse {
    pub lease_owner: String,
    pub lease_expires_at_unix: u64,
    pub items: Vec<FfiInboxItem>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAckInboxResponse {
    pub acked_inbox_ids: Vec<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSyncChatCursor {
    pub chat_id: String,
    pub last_server_seq: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSyncStateSnapshot {
    pub lease_owner: String,
    pub last_acked_inbox_id: Option<u64>,
    pub chat_cursors: Vec<FfiSyncChatCursor>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiLocalStoreApplyReport {
    pub chats_upserted: u64,
    pub messages_upserted: u64,
    pub changed_chat_ids: Vec<String>,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiLocalProjectionKind {
    ApplicationMessage,
    ProposalQueued,
    CommitMerged,
    WelcomeRef,
    System,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiReactionAction {
    Add,
    Remove,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiReceiptType {
    Delivered,
    Read,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiMessageBodyKind {
    Text,
    Reaction,
    Receipt,
    Attachment,
    ChatEvent,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessageBody {
    pub kind: FfiMessageBodyKind,
    pub text: Option<String>,
    pub target_message_id: Option<String>,
    pub emoji: Option<String>,
    pub reaction_action: Option<FfiReactionAction>,
    pub receipt_type: Option<FfiReceiptType>,
    pub receipt_at_unix: Option<u64>,
    pub blob_id: Option<String>,
    pub mime_type: Option<String>,
    pub size_bytes: Option<u64>,
    pub sha256: Option<Vec<u8>>,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
    pub file_key: Option<Vec<u8>>,
    pub nonce: Option<Vec<u8>>,
    pub event_type: Option<String>,
    pub event_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiLocalProjectedMessage {
    pub server_seq: u64,
    pub message_id: String,
    pub sender_account_id: String,
    pub sender_device_id: String,
    pub epoch: u64,
    pub message_kind: FfiMessageKind,
    pub content_type: FfiContentType,
    pub projection_kind: FfiLocalProjectionKind,
    pub payload: Option<Vec<u8>>,
    pub body: Option<FfiMessageBody>,
    pub body_parse_error: Option<String>,
    pub merged_epoch: Option<u64>,
    pub created_at_unix: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiLocalProjectionApplyReport {
    pub chat_id: String,
    pub processed_messages: u64,
    pub projected_messages_upserted: u64,
    pub advanced_to_server_seq: Option<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiInboxApplyOutcome {
    pub lease_owner: String,
    pub lease_expires_at_unix: u64,
    pub acked_inbox_ids: Vec<u64>,
    pub report: FfiLocalStoreApplyReport,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSendMessageInput {
    pub sender_account_id: String,
    pub sender_device_id: String,
    pub chat_id: String,
    pub message_id: Option<String>,
    pub body: FfiMessageBody,
    pub aad_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSendMessageOutcome {
    pub chat_id: String,
    pub message_id: String,
    pub server_seq: u64,
    pub report: FfiLocalStoreApplyReport,
    pub projected_message: FfiLocalProjectedMessage,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateChatControlInput {
    pub creator_account_id: String,
    pub creator_device_id: String,
    pub chat_type: FfiChatType,
    pub title: Option<String>,
    pub participant_account_ids: Vec<String>,
    pub group_id: Option<Vec<u8>>,
    pub commit_aad_json: Option<String>,
    pub welcome_aad_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateChatControlOutcome {
    pub chat_id: String,
    pub chat_type: FfiChatType,
    pub epoch: u64,
    pub mls_group_id: Vec<u8>,
    pub report: FfiLocalStoreApplyReport,
    pub projected_messages: Vec<FfiLocalProjectedMessage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatMembersControlInput {
    pub actor_account_id: String,
    pub actor_device_id: String,
    pub chat_id: String,
    pub participant_account_ids: Vec<String>,
    pub commit_aad_json: Option<String>,
    pub welcome_aad_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatMembersControlOutcome {
    pub chat_id: String,
    pub epoch: u64,
    pub changed_account_ids: Vec<String>,
    pub report: FfiLocalStoreApplyReport,
    pub projected_messages: Vec<FfiLocalProjectedMessage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatDevicesControlInput {
    pub actor_account_id: String,
    pub actor_device_id: String,
    pub chat_id: String,
    pub device_ids: Vec<String>,
    pub commit_aad_json: Option<String>,
    pub welcome_aad_json: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModifyChatDevicesControlOutcome {
    pub chat_id: String,
    pub epoch: u64,
    pub changed_device_ids: Vec<String>,
    pub report: FfiLocalStoreApplyReport,
    pub projected_messages: Vec<FfiLocalProjectedMessage>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreateBlobUploadResponse {
    pub blob_id: String,
    pub upload_url: String,
    pub upload_status: FfiBlobUploadStatus,
    pub needs_upload: bool,
    pub max_upload_bytes: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiBlobMetadata {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub upload_status: FfiBlobUploadStatus,
    pub created_by_device_id: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiBlobHead {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub upload_status: FfiBlobUploadStatus,
    pub etag: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMlsCommitBundle {
    pub commit_message: Vec<u8>,
    pub welcome_message: Option<Vec<u8>>,
    pub ratchet_tree: Option<Vec<u8>>,
    pub epoch: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMlsMemberIdentity {
    pub leaf_index: u32,
    pub signature_key: Vec<u8>,
    pub credential_identity: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMlsProcessResult {
    pub kind: FfiMlsProcessKind,
    pub application_message: Option<Vec<u8>>,
    pub epoch: Option<u64>,
}

#[derive(uniffi::Object)]
pub struct FfiServerApiClient {
    inner: Mutex<ServerApiClient>,
    runtime: Runtime,
}

#[derive(uniffi::Object)]
pub struct FfiAccountRootMaterial {
    inner: AccountRootMaterial,
}

#[derive(uniffi::Object)]
pub struct FfiDeviceKeyMaterial {
    inner: DeviceKeyMaterial,
}

#[derive(uniffi::Object)]
pub struct FfiMlsFacade {
    inner: Mutex<MlsFacade>,
}

#[derive(uniffi::Object)]
pub struct FfiLocalHistoryStore {
    inner: Mutex<LocalHistoryStore>,
}

#[derive(uniffi::Object)]
pub struct FfiSyncCoordinator {
    inner: Mutex<SyncCoordinator>,
    runtime: Runtime,
}

#[derive(uniffi::Object)]
pub struct FfiMlsConversation {
    inner: Mutex<crate::MlsConversation>,
}

#[uniffi::export]
fn ffi_default_ciphersuite_label() -> String {
    crate::DEFAULT_CIPHERSUITE.to_string()
}

#[uniffi::export]
fn ffi_serialize_message_body(body: FfiMessageBody) -> Result<Vec<u8>, TrixFfiError> {
    message_body_from_ffi(body)?.to_bytes().map_err(ffi_error)
}

#[uniffi::export]
fn ffi_parse_message_body(
    content_type: FfiContentType,
    payload: Vec<u8>,
) -> Result<FfiMessageBody, TrixFfiError> {
    Ok(message_body_to_ffi(
        MessageBody::from_bytes(content_type.into(), &payload).map_err(ffi_error)?,
    ))
}

#[uniffi::export]
impl FfiServerApiClient {
    #[uniffi::constructor]
    pub fn new(base_url: String) -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(ServerApiClient::new(base_url).map_err(ffi_error)?),
            runtime: build_runtime()?,
        }))
    }

    pub fn set_access_token(&self, access_token: String) -> Result<(), TrixFfiError> {
        lock(&self.inner)?.set_access_token(access_token);
        Ok(())
    }

    pub fn clear_access_token(&self) -> Result<(), TrixFfiError> {
        lock(&self.inner)?.clear_access_token();
        Ok(())
    }

    pub fn access_token(&self) -> Result<Option<String>, TrixFfiError> {
        Ok(lock(&self.inner)?.access_token().map(ToOwned::to_owned))
    }

    pub fn create_account(
        &self,
        params: FfiCreateAccountParams,
    ) -> Result<FfiCreateAccountResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.create_account(CreateAccountParams {
                handle: params.handle,
                profile_name: params.profile_name,
                profile_bio: params.profile_bio,
                device_display_name: params.device_display_name,
                platform: params.platform,
                credential_identity: params.credential_identity,
                account_root_pubkey: params.account_root_pubkey,
                account_root_signature: params.account_root_signature,
                transport_pubkey: params.transport_pubkey,
            }))?;

        Ok(FfiCreateAccountResponse {
            account_id: response.account_id.0.to_string(),
            device_id: response.device_id.0.to_string(),
            account_sync_chat_id: response.account_sync_chat_id.0.to_string(),
        })
    }

    pub fn get_health(&self) -> Result<FfiHealthResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.get_health())?;
        Ok(FfiHealthResponse {
            service: response.service,
            status: response.status.into(),
            version: response.version,
            uptime_ms: response.uptime_ms,
        })
    }

    pub fn get_version(&self) -> Result<FfiVersionResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.get_version())?;
        Ok(FfiVersionResponse {
            service: response.service,
            version: response.version,
            git_sha: response.git_sha,
        })
    }

    pub fn create_auth_challenge(
        &self,
        device_id: String,
    ) -> Result<FfiAuthChallenge, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.create_auth_challenge(parse_device_id(&device_id)?))?;
        Ok(auth_challenge_to_ffi(response))
    }

    pub fn create_auth_session(
        &self,
        device_id: String,
        challenge_id: String,
        signature: Vec<u8>,
    ) -> Result<FfiAuthSession, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.create_auth_session(
            parse_device_id(&device_id)?,
            challenge_id,
            &signature,
        ))?;
        Ok(FfiAuthSession {
            access_token: response.access_token,
            expires_at_unix: response.expires_at_unix,
            account_id: response.account_id.0.to_string(),
            device_status: response.device_status.into(),
        })
    }

    pub fn get_me(&self) -> Result<FfiAccountProfile, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.get_me())?;
        Ok(account_profile_to_ffi(response))
    }

    pub fn search_account_directory(
        &self,
        query: Option<String>,
        limit: Option<u32>,
        exclude_self: bool,
    ) -> Result<FfiAccountDirectory, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.search_account_directory(
            query,
            limit.map(|value| value as usize),
            exclude_self,
        ))?;

        Ok(FfiAccountDirectory {
            accounts: response.into_iter().map(directory_account_to_ffi).collect(),
        })
    }

    pub fn get_account(&self, account_id: String) -> Result<FfiDirectoryAccount, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_account(parse_account_id(&account_id)?))?;
        Ok(directory_account_to_ffi(response))
    }

    pub fn update_account_profile(
        &self,
        params: FfiUpdateAccountProfileParams,
    ) -> Result<FfiAccountProfile, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response =
            self.runtime
                .block_on(client.update_account_profile(UpdateAccountProfileParams {
                    handle: params.handle,
                    profile_name: params.profile_name,
                    profile_bio: params.profile_bio,
                }))?;
        Ok(account_profile_to_ffi(response))
    }

    pub fn list_devices(&self) -> Result<FfiDeviceList, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.list_devices())?;
        Ok(FfiDeviceList {
            account_id: response.account_id.0.to_string(),
            devices: response
                .devices
                .into_iter()
                .map(device_summary_to_ffi)
                .collect(),
        })
    }

    pub fn create_link_intent(&self) -> Result<FfiCreateLinkIntentResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.create_link_intent())?;
        Ok(FfiCreateLinkIntentResponse {
            link_intent_id: response.link_intent_id,
            qr_payload: response.qr_payload,
            expires_at_unix: response.expires_at_unix,
        })
    }

    pub fn complete_link_intent(
        &self,
        link_intent_id: String,
        params: FfiCompleteLinkIntentParams,
    ) -> Result<FfiCompletedLinkIntent, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.complete_link_intent(
                link_intent_id,
                CompleteLinkIntentParams {
                    link_token: params.link_token,
                    device_display_name: params.device_display_name,
                    platform: params.platform,
                    credential_identity: params.credential_identity,
                    transport_pubkey: params.transport_pubkey,
                    key_packages: params
                        .key_packages
                        .into_iter()
                        .map(|package| PublishKeyPackageMaterial {
                            cipher_suite: package.cipher_suite,
                            key_package: package.key_package,
                        })
                        .collect(),
                },
            ),
        )?;
        Ok(completed_link_intent_to_ffi(response))
    }

    pub fn get_device_approve_payload(
        &self,
        device_id: String,
    ) -> Result<FfiDeviceApprovePayload, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_device_approve_payload(parse_device_id(&device_id)?))?;
        Ok(device_approve_payload_to_ffi(response))
    }

    pub fn approve_device(
        &self,
        device_id: String,
        account_root_signature: Vec<u8>,
        transfer_bundle: Option<Vec<u8>>,
    ) -> Result<FfiApproveDeviceResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.approve_device(
            parse_device_id(&device_id)?,
            &account_root_signature,
            transfer_bundle.as_deref(),
        ))?;
        Ok(FfiApproveDeviceResponse {
            account_id: response.account_id.0.to_string(),
            device_id: response.device_id.0.to_string(),
            device_status: response.device_status.into(),
        })
    }

    pub fn get_device_transfer_bundle(
        &self,
        device_id: String,
    ) -> Result<FfiDeviceTransferBundle, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_device_transfer_bundle(parse_device_id(&device_id)?))?;
        Ok(device_transfer_bundle_to_ffi(response))
    }

    pub fn revoke_device(
        &self,
        device_id: String,
        reason: String,
        account_root_signature: Vec<u8>,
    ) -> Result<FfiRevokeDeviceResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.revoke_device(
            parse_device_id(&device_id)?,
            reason,
            &account_root_signature,
        ))?;
        Ok(FfiRevokeDeviceResponse {
            account_id: response.account_id.0.to_string(),
            device_id: response.device_id.0.to_string(),
            device_status: response.device_status.into(),
        })
    }

    pub fn publish_key_packages(
        &self,
        packages: Vec<FfiPublishKeyPackage>,
    ) -> Result<FfiPublishKeyPackagesResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.publish_key_packages(
                packages
                    .into_iter()
                    .map(|package| PublishKeyPackageMaterial {
                        cipher_suite: package.cipher_suite,
                        key_package: package.key_package,
                    })
                    .collect(),
            ),
        )?;

        Ok(FfiPublishKeyPackagesResponse {
            device_id: response.device_id.0.to_string(),
            packages: response
                .packages
                .into_iter()
                .map(|package| FfiPublishedKeyPackage {
                    key_package_id: package.key_package_id,
                    cipher_suite: package.cipher_suite,
                })
                .collect(),
        })
    }

    pub fn reserve_key_packages(
        &self,
        account_id: String,
        device_ids: Vec<String>,
    ) -> Result<Vec<FfiReservedKeyPackage>, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.reserve_key_packages(
                parse_account_id(&account_id)?,
                device_ids
                    .iter()
                    .map(|device_id| parse_device_id(device_id))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
        )?;
        Ok(response
            .into_iter()
            .map(reserved_key_package_to_ffi)
            .collect())
    }

    pub fn get_account_key_packages(
        &self,
        account_id: String,
    ) -> Result<Vec<FfiReservedKeyPackage>, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_account_key_packages(parse_account_id(&account_id)?))?;
        Ok(response
            .into_iter()
            .map(reserved_key_package_to_ffi)
            .collect())
    }

    pub fn list_history_sync_jobs(
        &self,
        role: Option<FfiHistorySyncJobRole>,
        status: Option<FfiHistorySyncJobStatus>,
        limit: Option<u32>,
    ) -> Result<Vec<FfiHistorySyncJob>, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.list_history_sync_jobs(
            role.map(Into::into),
            status.map(Into::into),
            limit.map(|value| value as usize),
        ))?;

        Ok(response
            .jobs
            .into_iter()
            .map(history_sync_job_to_ffi)
            .collect())
    }

    pub fn append_history_sync_chunk(
        &self,
        job_id: String,
        sequence_no: u64,
        payload: Vec<u8>,
        cursor_json: Option<String>,
        is_final: bool,
    ) -> Result<FfiAppendHistorySyncChunkResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.append_history_sync_chunk(
            job_id.clone(),
            sequence_no,
            &payload,
            parse_optional_json(cursor_json)?,
            is_final,
        ))?;
        Ok(FfiAppendHistorySyncChunkResponse {
            job_id: response.job_id,
            chunk_id: response.chunk_id,
            job_status: response.job_status.into(),
        })
    }

    pub fn get_history_sync_chunks(
        &self,
        job_id: String,
    ) -> Result<Vec<FfiHistorySyncChunk>, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_history_sync_chunks(job_id))?;
        Ok(response
            .into_iter()
            .map(history_sync_chunk_to_ffi)
            .collect())
    }

    pub fn complete_history_sync_job(
        &self,
        job_id: String,
        cursor_json: Option<String>,
    ) -> Result<FfiCompleteHistorySyncJobResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.complete_history_sync_job(job_id, parse_optional_json(cursor_json)?),
        )?;
        Ok(FfiCompleteHistorySyncJobResponse {
            job_id: response.job_id,
            job_status: response.job_status.into(),
        })
    }

    pub fn list_chats(&self) -> Result<Vec<FfiChatSummary>, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.list_chats())?;
        Ok(response
            .chats
            .into_iter()
            .map(chat_summary_to_ffi)
            .collect())
    }

    pub fn get_chat(&self, chat_id: String) -> Result<FfiChatDetail, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_chat(parse_chat_id(&chat_id)?))?;
        Ok(chat_detail_to_ffi(response))
    }

    pub fn create_chat(
        &self,
        params: FfiCreateChatParams,
    ) -> Result<FfiCreateChatResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.create_chat(trix_types::CreateChatRequest {
                chat_type: params.chat_type.into(),
                title: params.title,
                participant_account_ids: params
                    .participant_account_ids
                    .iter()
                    .map(|account_id| parse_account_id(account_id))
                    .collect::<Result<Vec<_>, _>>()?,
                reserved_key_package_ids: params.reserved_key_package_ids,
                initial_commit: params
                    .initial_commit
                    .map(control_message_from_ffi)
                    .transpose()?,
                welcome_message: params
                    .welcome_message
                    .map(control_message_from_ffi)
                    .transpose()?,
            }),
        )?;
        Ok(FfiCreateChatResponse {
            chat_id: response.chat_id.0.to_string(),
            chat_type: response.chat_type.into(),
            epoch: response.epoch,
        })
    }

    pub fn create_message(
        &self,
        chat_id: String,
        params: FfiCreateMessageParams,
    ) -> Result<FfiCreateMessageResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.create_message(
            parse_chat_id(&chat_id)?,
            trix_types::CreateMessageRequest {
                message_id: parse_message_id(&params.message_id)?,
                epoch: params.epoch,
                message_kind: params.message_kind.into(),
                content_type: params.content_type.into(),
                ciphertext_b64: crate::encode_b64(&params.ciphertext),
                aad_json: parse_optional_json(params.aad_json)?,
            },
        ))?;
        Ok(FfiCreateMessageResponse {
            message_id: response.message_id.0.to_string(),
            server_seq: response.server_seq,
        })
    }

    pub fn add_chat_members(
        &self,
        chat_id: String,
        params: FfiModifyChatMembersParams,
    ) -> Result<FfiModifyChatMembersResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.add_chat_members(
                parse_chat_id(&chat_id)?,
                trix_types::ModifyChatMembersRequest {
                    epoch: params.epoch,
                    participant_account_ids: params
                        .participant_account_ids
                        .iter()
                        .map(|account_id| parse_account_id(account_id))
                        .collect::<Result<Vec<_>, _>>()?,
                    reserved_key_package_ids: params.reserved_key_package_ids,
                    commit_message: params
                        .commit_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                    welcome_message: params
                        .welcome_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                },
            ),
        )?;
        Ok(modify_chat_members_response_to_ffi(response))
    }

    pub fn remove_chat_members(
        &self,
        chat_id: String,
        params: FfiModifyChatMembersParams,
    ) -> Result<FfiModifyChatMembersResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.remove_chat_members(
                parse_chat_id(&chat_id)?,
                trix_types::ModifyChatMembersRequest {
                    epoch: params.epoch,
                    participant_account_ids: params
                        .participant_account_ids
                        .iter()
                        .map(|account_id| parse_account_id(account_id))
                        .collect::<Result<Vec<_>, _>>()?,
                    reserved_key_package_ids: params.reserved_key_package_ids,
                    commit_message: params
                        .commit_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                    welcome_message: params
                        .welcome_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                },
            ),
        )?;
        Ok(modify_chat_members_response_to_ffi(response))
    }

    pub fn add_chat_devices(
        &self,
        chat_id: String,
        params: FfiModifyChatDevicesParams,
    ) -> Result<FfiModifyChatDevicesResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.add_chat_devices(
                parse_chat_id(&chat_id)?,
                trix_types::ModifyChatDevicesRequest {
                    epoch: params.epoch,
                    device_ids: params
                        .device_ids
                        .iter()
                        .map(|device_id| parse_device_id(device_id))
                        .collect::<Result<Vec<_>, _>>()?,
                    reserved_key_package_ids: params.reserved_key_package_ids,
                    commit_message: params
                        .commit_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                    welcome_message: params
                        .welcome_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                },
            ),
        )?;
        Ok(modify_chat_devices_response_to_ffi(response))
    }

    pub fn remove_chat_devices(
        &self,
        chat_id: String,
        params: FfiModifyChatDevicesParams,
    ) -> Result<FfiModifyChatDevicesResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(
            client.remove_chat_devices(
                parse_chat_id(&chat_id)?,
                trix_types::ModifyChatDevicesRequest {
                    epoch: params.epoch,
                    device_ids: params
                        .device_ids
                        .iter()
                        .map(|device_id| parse_device_id(device_id))
                        .collect::<Result<Vec<_>, _>>()?,
                    reserved_key_package_ids: params.reserved_key_package_ids,
                    commit_message: params
                        .commit_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                    welcome_message: params
                        .welcome_message
                        .map(control_message_from_ffi)
                        .transpose()?,
                },
            ),
        )?;
        Ok(modify_chat_devices_response_to_ffi(response))
    }

    pub fn get_chat_history(
        &self,
        chat_id: String,
        after_server_seq: Option<u64>,
        limit: Option<u32>,
    ) -> Result<FfiChatHistory, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.get_chat_history(
            parse_chat_id(&chat_id)?,
            after_server_seq,
            limit.map(|value| value as usize),
        ))?;
        Ok(FfiChatHistory {
            chat_id: response.chat_id.0.to_string(),
            messages: response
                .messages
                .into_iter()
                .map(message_envelope_to_ffi)
                .collect(),
        })
    }

    pub fn get_inbox(
        &self,
        after_inbox_id: Option<u64>,
        limit: Option<u32>,
    ) -> Result<FfiInbox, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.get_inbox(after_inbox_id, limit.map(|value| value as usize)))?;
        Ok(FfiInbox {
            items: response.items.into_iter().map(inbox_item_to_ffi).collect(),
        })
    }

    pub fn lease_inbox(
        &self,
        params: FfiLeaseInboxParams,
    ) -> Result<FfiLeaseInboxResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response =
            self.runtime
                .block_on(client.lease_inbox(trix_types::LeaseInboxRequest {
                    lease_owner: params.lease_owner,
                    limit: params.limit.map(|value| value as usize),
                    after_inbox_id: params.after_inbox_id,
                    lease_ttl_seconds: params.lease_ttl_seconds,
                }))?;
        Ok(FfiLeaseInboxResponse {
            lease_owner: response.lease_owner,
            lease_expires_at_unix: response.lease_expires_at_unix,
            items: response.items.into_iter().map(inbox_item_to_ffi).collect(),
        })
    }

    pub fn ack_inbox(&self, inbox_ids: Vec<u64>) -> Result<FfiAckInboxResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.ack_inbox(inbox_ids))?;
        Ok(FfiAckInboxResponse {
            acked_inbox_ids: response.acked_inbox_ids,
        })
    }

    pub fn create_blob_upload(
        &self,
        chat_id: String,
        mime_type: String,
        size_bytes: u64,
        sha256: Vec<u8>,
    ) -> Result<FfiCreateBlobUploadResponse, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.create_blob_upload(
            parse_chat_id(&chat_id)?,
            mime_type,
            size_bytes,
            &sha256,
        ))?;
        Ok(FfiCreateBlobUploadResponse {
            blob_id: response.blob_id,
            upload_url: response.upload_url,
            upload_status: response.upload_status.into(),
            needs_upload: response.needs_upload,
            max_upload_bytes: response.max_upload_bytes,
        })
    }

    pub fn upload_blob(
        &self,
        blob_id: String,
        payload: Vec<u8>,
    ) -> Result<FfiBlobMetadata, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self
            .runtime
            .block_on(client.upload_blob(blob_id, &payload))?;
        Ok(blob_metadata_to_ffi(response))
    }

    pub fn head_blob(&self, blob_id: String) -> Result<FfiBlobHead, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        let response = self.runtime.block_on(client.head_blob(blob_id))?;
        Ok(blob_head_to_ffi(response))
    }

    pub fn download_blob(&self, blob_id: String) -> Result<Vec<u8>, TrixFfiError> {
        let client = clone_server_api_client(&self.inner)?;
        self.runtime
            .block_on(client.download_blob(blob_id))
            .map_err(Into::into)
    }
}

#[uniffi::export]
impl FfiAccountRootMaterial {
    #[uniffi::constructor]
    pub fn generate() -> Arc<Self> {
        Arc::new(Self {
            inner: AccountRootMaterial::generate(),
        })
    }

    #[uniffi::constructor]
    pub fn from_private_key(private_key: Vec<u8>) -> Result<Arc<Self>, TrixFfiError> {
        let private_key = to_32_bytes(private_key, "account root private key")?;
        Ok(Arc::new(Self {
            inner: AccountRootMaterial::from_bytes(private_key),
        }))
    }

    pub fn private_key_bytes(&self) -> Vec<u8> {
        self.inner.private_key_bytes().to_vec()
    }

    pub fn public_key_bytes(&self) -> Vec<u8> {
        self.inner.public_key_bytes()
    }

    pub fn sign(&self, payload: Vec<u8>) -> Vec<u8> {
        self.inner.sign(&payload)
    }

    pub fn verify(&self, payload: Vec<u8>, signature: Vec<u8>) -> Result<(), TrixFfiError> {
        self.inner.verify(&payload, &signature).map_err(ffi_error)
    }
}

#[uniffi::export]
impl FfiDeviceKeyMaterial {
    #[uniffi::constructor]
    pub fn generate() -> Arc<Self> {
        Arc::new(Self {
            inner: DeviceKeyMaterial::generate(),
        })
    }

    #[uniffi::constructor]
    pub fn from_private_key(private_key: Vec<u8>) -> Result<Arc<Self>, TrixFfiError> {
        let private_key = to_32_bytes(private_key, "device private key")?;
        Ok(Arc::new(Self {
            inner: DeviceKeyMaterial::from_bytes(private_key),
        }))
    }

    pub fn private_key_bytes(&self) -> Vec<u8> {
        self.inner.private_key_bytes().to_vec()
    }

    pub fn public_key_bytes(&self) -> Vec<u8> {
        self.inner.public_key_bytes()
    }

    pub fn sign(&self, payload: Vec<u8>) -> Vec<u8> {
        self.inner.sign(&payload)
    }

    pub fn verify(&self, payload: Vec<u8>, signature: Vec<u8>) -> Result<(), TrixFfiError> {
        self.inner.verify(&payload, &signature).map_err(ffi_error)
    }
}

#[uniffi::export]
impl FfiLocalHistoryStore {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(LocalHistoryStore::new()),
        })
    }

    #[uniffi::constructor]
    pub fn new_persistent(database_path: String) -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(LocalHistoryStore::new_persistent(database_path).map_err(ffi_error)?),
        }))
    }

    pub fn save_state(&self) -> Result<(), TrixFfiError> {
        lock(&self.inner)?.save_state().map_err(ffi_error)
    }

    pub fn database_path(&self) -> Result<Option<String>, TrixFfiError> {
        Ok(lock(&self.inner)?
            .database_path()
            .map(|path| path.to_string_lossy().into_owned()))
    }

    pub fn list_chats(&self) -> Result<Vec<FfiChatSummary>, TrixFfiError> {
        Ok(lock(&self.inner)?
            .list_chats()
            .into_iter()
            .map(chat_summary_to_ffi)
            .collect())
    }

    pub fn get_chat(&self, chat_id: String) -> Result<Option<FfiChatDetail>, TrixFfiError> {
        Ok(lock(&self.inner)?
            .get_chat(parse_chat_id(&chat_id)?)
            .map(chat_detail_to_ffi))
    }

    pub fn get_chat_history(
        &self,
        chat_id: String,
        after_server_seq: Option<u64>,
        limit: Option<u32>,
    ) -> Result<FfiChatHistory, TrixFfiError> {
        Ok(chat_history_to_ffi(lock(&self.inner)?.get_chat_history(
            parse_chat_id(&chat_id)?,
            after_server_seq,
            limit.map(|value| value as usize),
        )))
    }

    pub fn projected_cursor(&self, chat_id: String) -> Result<Option<u64>, TrixFfiError> {
        Ok(lock(&self.inner)?.projected_cursor(parse_chat_id(&chat_id)?))
    }

    pub fn chat_mls_group_id(&self, chat_id: String) -> Result<Option<Vec<u8>>, TrixFfiError> {
        Ok(lock(&self.inner)?.chat_mls_group_id(parse_chat_id(&chat_id)?))
    }

    pub fn set_chat_mls_group_id(
        &self,
        chat_id: String,
        group_id: Vec<u8>,
    ) -> Result<bool, TrixFfiError> {
        lock(&self.inner)?
            .set_chat_mls_group_id(parse_chat_id(&chat_id)?, &group_id)
            .map_err(ffi_error)
    }

    pub fn get_projected_messages(
        &self,
        chat_id: String,
        after_server_seq: Option<u64>,
        limit: Option<u32>,
    ) -> Result<Vec<FfiLocalProjectedMessage>, TrixFfiError> {
        Ok(lock(&self.inner)?
            .get_projected_messages(
                parse_chat_id(&chat_id)?,
                after_server_seq,
                limit.map(|value| value as usize),
            )
            .into_iter()
            .map(local_projected_message_to_ffi)
            .collect())
    }

    pub fn apply_chat_history(
        &self,
        history: FfiChatHistory,
    ) -> Result<FfiLocalStoreApplyReport, TrixFfiError> {
        let history = ffi_chat_history_to_api(history)?;
        Ok(local_store_apply_report_to_ffi(
            lock(&self.inner)?
                .apply_chat_history(&history)
                .map_err(ffi_error)?,
        ))
    }

    pub fn apply_leased_inbox(
        &self,
        lease: FfiLeaseInboxResponse,
    ) -> Result<FfiLocalStoreApplyReport, TrixFfiError> {
        let items = lease
            .items
            .into_iter()
            .map(ffi_inbox_item_to_api)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(local_store_apply_report_to_ffi(
            lock(&self.inner)?
                .apply_inbox_items(&items)
                .map_err(ffi_error)?,
        ))
    }

    pub fn project_chat_messages(
        &self,
        chat_id: String,
        facade: Arc<FfiMlsFacade>,
        conversation: Arc<FfiMlsConversation>,
        limit: Option<u32>,
    ) -> Result<FfiLocalProjectionApplyReport, TrixFfiError> {
        let chat_id = parse_chat_id(&chat_id)?;
        let facade = lock(&facade.inner)?;
        let mut conversation = lock(&conversation.inner)?;
        Ok(local_projection_apply_report_to_ffi(
            lock(&self.inner)?
                .project_chat_messages(
                    chat_id,
                    &facade,
                    &mut conversation,
                    limit.map(|value| value as usize),
                )
                .map_err(ffi_error)?,
        ))
    }
}

#[uniffi::export]
impl FfiSyncCoordinator {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(SyncCoordinator::new()),
            runtime: build_runtime()?,
        }))
    }

    #[uniffi::constructor]
    pub fn new_persistent(state_path: String) -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(SyncCoordinator::new_persistent(state_path).map_err(ffi_error)?),
            runtime: build_runtime()?,
        }))
    }

    pub fn save_state(&self) -> Result<(), TrixFfiError> {
        lock(&self.inner)?.save_state().map_err(ffi_error)
    }

    pub fn state_path(&self) -> Result<Option<String>, TrixFfiError> {
        Ok(lock(&self.inner)?
            .state_path()
            .map(|path| path.to_string_lossy().into_owned()))
    }

    pub fn state_snapshot(&self) -> Result<FfiSyncStateSnapshot, TrixFfiError> {
        Ok(sync_state_snapshot_to_ffi(
            lock(&self.inner)?.snapshot().map_err(ffi_error)?,
        ))
    }

    pub fn lease_owner(&self) -> Result<String, TrixFfiError> {
        Ok(lock(&self.inner)?.lease_owner().to_owned())
    }

    pub fn last_acked_inbox_id(&self) -> Result<Option<u64>, TrixFfiError> {
        Ok(lock(&self.inner)?.last_acked_inbox_id())
    }

    pub fn chat_cursor(&self, chat_id: String) -> Result<Option<u64>, TrixFfiError> {
        Ok(lock(&self.inner)?.chat_cursor(parse_chat_id(&chat_id)?))
    }

    pub fn record_chat_server_seq(
        &self,
        chat_id: String,
        server_seq: u64,
    ) -> Result<bool, TrixFfiError> {
        lock(&self.inner)?
            .record_chat_server_seq(parse_chat_id(&chat_id)?, server_seq)
            .map_err(ffi_error)
    }

    pub fn sync_chat_histories(
        &self,
        client: Arc<FfiServerApiClient>,
        limit_per_chat: u32,
    ) -> Result<Vec<FfiChatHistory>, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let histories = {
            let mut coordinator = lock(&self.inner)?;
            self.runtime
                .block_on(coordinator.sync_chat_histories(&client, limit_per_chat as usize))
                .map_err(ffi_error)?
        };
        Ok(histories.into_iter().map(chat_history_to_ffi).collect())
    }

    pub fn sync_chat_histories_into_store(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        limit_per_chat: u32,
    ) -> Result<FfiLocalStoreApplyReport, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let report = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            self.runtime
                .block_on(coordinator.sync_chat_histories_into_store(
                    &client,
                    &mut store,
                    limit_per_chat as usize,
                ))
                .map_err(ffi_error)?
        };
        Ok(local_store_apply_report_to_ffi(report))
    }

    pub fn lease_inbox(
        &self,
        client: Arc<FfiServerApiClient>,
        limit: Option<u32>,
        lease_ttl_seconds: Option<u64>,
    ) -> Result<FfiLeaseInboxResponse, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let response = {
            let coordinator = lock(&self.inner)?;
            self.runtime
                .block_on(coordinator.lease_inbox(
                    &client,
                    limit.map(|value| value as usize),
                    lease_ttl_seconds,
                ))
                .map_err(ffi_error)?
        };
        Ok(FfiLeaseInboxResponse {
            lease_owner: response.lease_owner,
            lease_expires_at_unix: response.lease_expires_at_unix,
            items: response.items.into_iter().map(inbox_item_to_ffi).collect(),
        })
    }

    pub fn ack_inbox(
        &self,
        client: Arc<FfiServerApiClient>,
        inbox_ids: Vec<u64>,
    ) -> Result<FfiAckInboxResponse, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let response = {
            let mut coordinator = lock(&self.inner)?;
            self.runtime
                .block_on(coordinator.ack_inbox(&client, inbox_ids))
                .map_err(ffi_error)?
        };
        Ok(FfiAckInboxResponse {
            acked_inbox_ids: response.acked_inbox_ids,
        })
    }

    pub fn lease_inbox_into_store(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        limit: Option<u32>,
        lease_ttl_seconds: Option<u64>,
    ) -> Result<FfiInboxApplyOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            self.runtime
                .block_on(coordinator.lease_inbox_into_store(
                    &client,
                    &mut store,
                    limit.map(|value| value as usize),
                    lease_ttl_seconds,
                ))
                .map_err(ffi_error)?
        };
        Ok(inbox_apply_outcome_to_ffi(outcome))
    }

    pub fn send_message_body(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        facade: Arc<FfiMlsFacade>,
        conversation: Arc<FfiMlsConversation>,
        input: FfiSendMessageInput,
    ) -> Result<FfiSendMessageOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let body = message_body_from_ffi(input.body)?;
        let aad_json = parse_optional_json(input.aad_json)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            let facade = lock(&facade.inner)?;
            let mut conversation = lock(&conversation.inner)?;
            self.runtime
                .block_on(
                    coordinator.send_message_body(
                        &client,
                        &mut store,
                        &facade,
                        &mut conversation,
                        parse_account_id(&input.sender_account_id)?,
                        parse_device_id(&input.sender_device_id)?,
                        parse_chat_id(&input.chat_id)?,
                        input
                            .message_id
                            .as_deref()
                            .map(parse_message_id)
                            .transpose()?,
                        &body,
                        aad_json,
                    ),
                )
                .map_err(ffi_error)?
        };
        Ok(send_message_outcome_to_ffi(outcome))
    }

    pub fn create_chat_control(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        facade: Arc<FfiMlsFacade>,
        input: FfiCreateChatControlInput,
    ) -> Result<FfiCreateChatControlOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            let mut facade = lock(&facade.inner)?;
            self.runtime
                .block_on(
                    coordinator.create_chat_control(
                        &client,
                        &mut store,
                        &mut facade,
                        CreateChatControlInput {
                            creator_account_id: parse_account_id(&input.creator_account_id)?,
                            creator_device_id: parse_device_id(&input.creator_device_id)?,
                            chat_type: input.chat_type.into(),
                            title: input.title,
                            participant_account_ids: input
                                .participant_account_ids
                                .iter()
                                .map(|account_id| parse_account_id(account_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            group_id: input.group_id,
                            commit_aad_json: parse_optional_json(input.commit_aad_json)?,
                            welcome_aad_json: parse_optional_json(input.welcome_aad_json)?,
                        },
                    ),
                )
                .map_err(ffi_error)?
        };
        Ok(create_chat_control_outcome_to_ffi(outcome))
    }

    pub fn add_chat_members_control(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        facade: Arc<FfiMlsFacade>,
        input: FfiModifyChatMembersControlInput,
    ) -> Result<FfiModifyChatMembersControlOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            let mut facade = lock(&facade.inner)?;
            self.runtime
                .block_on(
                    coordinator.add_chat_members_control(
                        &client,
                        &mut store,
                        &mut facade,
                        ModifyChatMembersControlInput {
                            actor_account_id: parse_account_id(&input.actor_account_id)?,
                            actor_device_id: parse_device_id(&input.actor_device_id)?,
                            chat_id: parse_chat_id(&input.chat_id)?,
                            participant_account_ids: input
                                .participant_account_ids
                                .iter()
                                .map(|account_id| parse_account_id(account_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: parse_optional_json(input.commit_aad_json)?,
                            welcome_aad_json: parse_optional_json(input.welcome_aad_json)?,
                        },
                    ),
                )
                .map_err(ffi_error)?
        };
        Ok(modify_chat_members_control_outcome_to_ffi(outcome))
    }

    pub fn remove_chat_members_control(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        facade: Arc<FfiMlsFacade>,
        input: FfiModifyChatMembersControlInput,
    ) -> Result<FfiModifyChatMembersControlOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            let mut facade = lock(&facade.inner)?;
            self.runtime
                .block_on(
                    coordinator.remove_chat_members_control(
                        &client,
                        &mut store,
                        &mut facade,
                        ModifyChatMembersControlInput {
                            actor_account_id: parse_account_id(&input.actor_account_id)?,
                            actor_device_id: parse_device_id(&input.actor_device_id)?,
                            chat_id: parse_chat_id(&input.chat_id)?,
                            participant_account_ids: input
                                .participant_account_ids
                                .iter()
                                .map(|account_id| parse_account_id(account_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: parse_optional_json(input.commit_aad_json)?,
                            welcome_aad_json: parse_optional_json(input.welcome_aad_json)?,
                        },
                    ),
                )
                .map_err(ffi_error)?
        };
        Ok(modify_chat_members_control_outcome_to_ffi(outcome))
    }

    pub fn add_chat_devices_control(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        facade: Arc<FfiMlsFacade>,
        input: FfiModifyChatDevicesControlInput,
    ) -> Result<FfiModifyChatDevicesControlOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            let mut facade = lock(&facade.inner)?;
            self.runtime
                .block_on(
                    coordinator.add_chat_devices_control(
                        &client,
                        &mut store,
                        &mut facade,
                        ModifyChatDevicesControlInput {
                            actor_account_id: parse_account_id(&input.actor_account_id)?,
                            actor_device_id: parse_device_id(&input.actor_device_id)?,
                            chat_id: parse_chat_id(&input.chat_id)?,
                            device_ids: input
                                .device_ids
                                .iter()
                                .map(|device_id| parse_device_id(device_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: parse_optional_json(input.commit_aad_json)?,
                            welcome_aad_json: parse_optional_json(input.welcome_aad_json)?,
                        },
                    ),
                )
                .map_err(ffi_error)?
        };
        Ok(modify_chat_devices_control_outcome_to_ffi(outcome))
    }

    pub fn remove_chat_devices_control(
        &self,
        client: Arc<FfiServerApiClient>,
        store: Arc<FfiLocalHistoryStore>,
        facade: Arc<FfiMlsFacade>,
        input: FfiModifyChatDevicesControlInput,
    ) -> Result<FfiModifyChatDevicesControlOutcome, TrixFfiError> {
        let client = clone_server_api_client(&client.inner)?;
        let outcome = {
            let mut coordinator = lock(&self.inner)?;
            let mut store = lock(&store.inner)?;
            let mut facade = lock(&facade.inner)?;
            self.runtime
                .block_on(
                    coordinator.remove_chat_devices_control(
                        &client,
                        &mut store,
                        &mut facade,
                        ModifyChatDevicesControlInput {
                            actor_account_id: parse_account_id(&input.actor_account_id)?,
                            actor_device_id: parse_device_id(&input.actor_device_id)?,
                            chat_id: parse_chat_id(&input.chat_id)?,
                            device_ids: input
                                .device_ids
                                .iter()
                                .map(|device_id| parse_device_id(device_id))
                                .collect::<Result<Vec<_>, _>>()?,
                            commit_aad_json: parse_optional_json(input.commit_aad_json)?,
                            welcome_aad_json: parse_optional_json(input.welcome_aad_json)?,
                        },
                    ),
                )
                .map_err(ffi_error)?
        };
        Ok(modify_chat_devices_control_outcome_to_ffi(outcome))
    }
}

#[uniffi::export]
impl FfiMlsFacade {
    #[uniffi::constructor]
    pub fn new(credential_identity: Vec<u8>) -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(MlsFacade::new(credential_identity).map_err(ffi_error)?),
        }))
    }

    #[uniffi::constructor]
    pub fn new_persistent(
        credential_identity: Vec<u8>,
        storage_root: String,
    ) -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(
                MlsFacade::new_persistent(credential_identity, storage_root).map_err(ffi_error)?,
            ),
        }))
    }

    #[uniffi::constructor]
    pub fn load_persistent(storage_root: String) -> Result<Arc<Self>, TrixFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(MlsFacade::load_persistent(storage_root).map_err(ffi_error)?),
        }))
    }

    pub fn ciphersuite_label(&self) -> Result<String, TrixFfiError> {
        Ok(lock(&self.inner)?.ciphersuite_label())
    }

    pub fn storage_root(&self) -> Result<Option<String>, TrixFfiError> {
        Ok(lock(&self.inner)?
            .storage_root()
            .map(|path| path.to_string_lossy().into_owned()))
    }

    pub fn save_state(&self) -> Result<(), TrixFfiError> {
        lock(&self.inner)?.save_state().map_err(ffi_error)
    }

    pub fn credential_identity(&self) -> Result<Vec<u8>, TrixFfiError> {
        Ok(lock(&self.inner)?.credential_identity().to_vec())
    }

    pub fn signature_public_key(&self) -> Result<Vec<u8>, TrixFfiError> {
        Ok(lock(&self.inner)?.signature_public_key().to_vec())
    }

    pub fn generate_key_package(&self) -> Result<Vec<u8>, TrixFfiError> {
        lock(&self.inner)?.generate_key_package().map_err(ffi_error)
    }

    pub fn generate_key_packages(&self, count: u32) -> Result<Vec<Vec<u8>>, TrixFfiError> {
        lock(&self.inner)?
            .generate_key_packages(count as usize)
            .map_err(ffi_error)
    }

    pub fn create_group(&self, group_id: Vec<u8>) -> Result<Arc<FfiMlsConversation>, TrixFfiError> {
        let conversation = lock(&self.inner)?
            .create_group(group_id)
            .map_err(ffi_error)?;
        Ok(Arc::new(FfiMlsConversation {
            inner: Mutex::new(conversation),
        }))
    }

    pub fn load_group(
        &self,
        group_id: Vec<u8>,
    ) -> Result<Option<Arc<FfiMlsConversation>>, TrixFfiError> {
        let conversation = lock(&self.inner)?.load_group(group_id).map_err(ffi_error)?;
        Ok(conversation.map(|conversation| {
            Arc::new(FfiMlsConversation {
                inner: Mutex::new(conversation),
            })
        }))
    }

    pub fn join_group_from_welcome(
        &self,
        welcome_message: Vec<u8>,
        ratchet_tree: Option<Vec<u8>>,
    ) -> Result<Arc<FfiMlsConversation>, TrixFfiError> {
        let conversation = lock(&self.inner)?
            .join_group_from_welcome(&welcome_message, ratchet_tree.as_deref())
            .map_err(ffi_error)?;
        Ok(Arc::new(FfiMlsConversation {
            inner: Mutex::new(conversation),
        }))
    }

    pub fn add_members(
        &self,
        conversation: Arc<FfiMlsConversation>,
        key_packages: Vec<Vec<u8>>,
    ) -> Result<FfiMlsCommitBundle, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let mut conversation = lock(&conversation.inner)?;
        Ok(commit_bundle_to_ffi(
            facade
                .add_members(&mut conversation, &key_packages)
                .map_err(ffi_error)?,
        ))
    }

    pub fn remove_members(
        &self,
        conversation: Arc<FfiMlsConversation>,
        leaf_indices: Vec<u32>,
    ) -> Result<FfiMlsCommitBundle, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let mut conversation = lock(&conversation.inner)?;
        Ok(commit_bundle_to_ffi(
            facade
                .remove_members(&mut conversation, &leaf_indices)
                .map_err(ffi_error)?,
        ))
    }

    pub fn self_update(
        &self,
        conversation: Arc<FfiMlsConversation>,
    ) -> Result<FfiMlsCommitBundle, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let mut conversation = lock(&conversation.inner)?;
        Ok(commit_bundle_to_ffi(
            facade.self_update(&mut conversation).map_err(ffi_error)?,
        ))
    }

    pub fn create_application_message(
        &self,
        conversation: Arc<FfiMlsConversation>,
        plaintext: Vec<u8>,
    ) -> Result<Vec<u8>, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let mut conversation = lock(&conversation.inner)?;
        facade
            .create_application_message(&mut conversation, &plaintext)
            .map_err(ffi_error)
    }

    pub fn process_message(
        &self,
        conversation: Arc<FfiMlsConversation>,
        message_bytes: Vec<u8>,
    ) -> Result<FfiMlsProcessResult, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let mut conversation = lock(&conversation.inner)?;
        Ok(process_result_to_ffi(
            facade
                .process_message(&mut conversation, &message_bytes)
                .map_err(ffi_error)?,
        ))
    }

    pub fn export_secret(
        &self,
        conversation: Arc<FfiMlsConversation>,
        label: String,
        context: Vec<u8>,
        len: u32,
    ) -> Result<Vec<u8>, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let conversation = lock(&conversation.inner)?;
        facade
            .export_secret(&conversation, &label, &context, len as usize)
            .map_err(ffi_error)
    }

    pub fn members(
        &self,
        conversation: Arc<FfiMlsConversation>,
    ) -> Result<Vec<FfiMlsMemberIdentity>, TrixFfiError> {
        let facade = lock(&self.inner)?;
        let conversation = lock(&conversation.inner)?;
        Ok(facade
            .members(&conversation)
            .map_err(ffi_error)?
            .into_iter()
            .map(member_identity_to_ffi)
            .collect())
    }
}

#[uniffi::export]
impl FfiMlsConversation {
    pub fn group_id(&self) -> Result<Vec<u8>, TrixFfiError> {
        Ok(lock(&self.inner)?.group_id())
    }

    pub fn epoch(&self) -> Result<u64, TrixFfiError> {
        Ok(lock(&self.inner)?.epoch())
    }

    pub fn export_ratchet_tree(&self) -> Result<Vec<u8>, TrixFfiError> {
        lock(&self.inner)?.export_ratchet_tree().map_err(ffi_error)
    }
}

fn build_runtime() -> Result<Runtime, TrixFfiError> {
    Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(ffi_error)
}

fn clone_server_api_client(
    value: &Mutex<ServerApiClient>,
) -> Result<ServerApiClient, TrixFfiError> {
    Ok(lock(value)?.clone())
}

fn lock<T>(value: &Mutex<T>) -> Result<MutexGuard<'_, T>, TrixFfiError> {
    value
        .lock()
        .map_err(|_| TrixFfiError::Message("mutex poisoned".to_owned()))
}

fn ffi_error(err: impl std::fmt::Display) -> TrixFfiError {
    TrixFfiError::Message(err.to_string())
}

fn parse_uuid(value: &str, field: &str) -> Result<Uuid, TrixFfiError> {
    Uuid::parse_str(value).map_err(|err| TrixFfiError::Message(format!("invalid {field}: {err}")))
}

fn parse_account_id(value: &str) -> Result<AccountId, TrixFfiError> {
    Ok(AccountId(parse_uuid(value, "account_id")?))
}

fn parse_device_id(value: &str) -> Result<DeviceId, TrixFfiError> {
    Ok(DeviceId(parse_uuid(value, "device_id")?))
}

fn parse_chat_id(value: &str) -> Result<ChatId, TrixFfiError> {
    Ok(ChatId(parse_uuid(value, "chat_id")?))
}

fn parse_message_id(value: &str) -> Result<MessageId, TrixFfiError> {
    Ok(MessageId(parse_uuid(value, "message_id")?))
}

fn parse_optional_json(value: Option<String>) -> Result<Option<Value>, TrixFfiError> {
    value
        .map(|json| {
            serde_json::from_str(&json)
                .map_err(|err| TrixFfiError::Message(format!("invalid json payload: {err}")))
        })
        .transpose()
}

fn json_to_string(value: Value) -> String {
    value.to_string()
}

fn control_message_from_ffi(
    value: FfiControlMessage,
) -> Result<trix_types::ControlMessageInput, TrixFfiError> {
    Ok(trix_types::ControlMessageInput {
        message_id: parse_message_id(&value.message_id)?,
        ciphertext_b64: crate::encode_b64(&value.ciphertext),
        aad_json: parse_optional_json(value.aad_json)?,
    })
}

fn to_32_bytes(value: Vec<u8>, field: &str) -> Result<[u8; 32], TrixFfiError> {
    value
        .try_into()
        .map_err(|_| TrixFfiError::Message(format!("{field} must be exactly 32 bytes")))
}

fn auth_challenge_to_ffi(value: AuthChallengeMaterial) -> FfiAuthChallenge {
    FfiAuthChallenge {
        challenge_id: value.challenge_id,
        challenge: value.challenge,
        expires_at_unix: value.expires_at_unix,
    }
}

fn account_profile_to_ffi(value: trix_types::AccountProfileResponse) -> FfiAccountProfile {
    FfiAccountProfile {
        account_id: value.account_id.0.to_string(),
        handle: value.handle,
        profile_name: value.profile_name,
        profile_bio: value.profile_bio,
        device_id: value.device_id.0.to_string(),
        device_status: value.device_status.into(),
    }
}

fn directory_account_to_ffi(value: DirectoryAccountMaterial) -> FfiDirectoryAccount {
    FfiDirectoryAccount {
        account_id: value.account_id.0.to_string(),
        handle: value.handle,
        profile_name: value.profile_name,
        profile_bio: value.profile_bio,
    }
}

fn device_summary_to_ffi(value: trix_types::DeviceSummary) -> FfiDeviceSummary {
    FfiDeviceSummary {
        device_id: value.device_id.0.to_string(),
        display_name: value.display_name,
        platform: value.platform,
        device_status: value.device_status.into(),
    }
}

fn completed_link_intent_to_ffi(value: CompletedLinkIntentMaterial) -> FfiCompletedLinkIntent {
    FfiCompletedLinkIntent {
        account_id: value.account_id.0.to_string(),
        pending_device_id: value.pending_device_id.0.to_string(),
        device_status: value.device_status.into(),
        bootstrap_payload: value.bootstrap_payload,
    }
}

fn device_approve_payload_to_ffi(value: DeviceApprovePayloadMaterial) -> FfiDeviceApprovePayload {
    FfiDeviceApprovePayload {
        account_id: value.account_id.0.to_string(),
        device_id: value.device_id.0.to_string(),
        device_display_name: value.device_display_name,
        platform: value.platform,
        device_status: value.device_status.into(),
        credential_identity: value.credential_identity,
        transport_pubkey: value.transport_pubkey,
        bootstrap_payload: value.bootstrap_payload,
    }
}

fn device_transfer_bundle_to_ffi(value: DeviceTransferBundleMaterial) -> FfiDeviceTransferBundle {
    FfiDeviceTransferBundle {
        account_id: value.account_id.0.to_string(),
        device_id: value.device_id.0.to_string(),
        transfer_bundle: value.transfer_bundle,
        uploaded_at_unix: value.uploaded_at_unix,
    }
}

fn reserved_key_package_to_ffi(value: ReservedKeyPackageMaterial) -> FfiReservedKeyPackage {
    FfiReservedKeyPackage {
        key_package_id: value.key_package_id,
        device_id: value.device_id.0.to_string(),
        cipher_suite: value.cipher_suite,
        key_package: value.key_package,
    }
}

fn history_sync_job_to_ffi(value: trix_types::HistorySyncJobSummary) -> FfiHistorySyncJob {
    FfiHistorySyncJob {
        job_id: value.job_id,
        job_type: value.job_type.into(),
        job_status: value.job_status.into(),
        source_device_id: value.source_device_id.0.to_string(),
        target_device_id: value.target_device_id.0.to_string(),
        chat_id: value.chat_id.map(|chat_id| chat_id.0.to_string()),
        cursor_json: json_to_string(value.cursor_json),
        created_at_unix: value.created_at_unix,
        updated_at_unix: value.updated_at_unix,
    }
}

fn history_sync_chunk_to_ffi(value: HistorySyncChunkMaterial) -> FfiHistorySyncChunk {
    FfiHistorySyncChunk {
        chunk_id: value.chunk_id,
        sequence_no: value.sequence_no,
        payload: value.payload,
        cursor_json: value.cursor_json.map(json_to_string),
        is_final: value.is_final,
        uploaded_at_unix: value.uploaded_at_unix,
    }
}

fn chat_summary_to_ffi(value: trix_types::ChatSummary) -> FfiChatSummary {
    FfiChatSummary {
        chat_id: value.chat_id.0.to_string(),
        chat_type: value.chat_type.into(),
        title: value.title,
        last_server_seq: value.last_server_seq,
    }
}

fn chat_detail_to_ffi(value: trix_types::ChatDetailResponse) -> FfiChatDetail {
    FfiChatDetail {
        chat_id: value.chat_id.0.to_string(),
        chat_type: value.chat_type.into(),
        title: value.title,
        last_server_seq: value.last_server_seq,
        epoch: value.epoch,
        last_commit_message_id: value
            .last_commit_message_id
            .map(|message_id| message_id.0.to_string()),
        members: value
            .members
            .into_iter()
            .map(|member| FfiChatMember {
                account_id: member.account_id.0.to_string(),
                role: member.role,
                membership_status: member.membership_status,
            })
            .collect(),
        device_members: value
            .device_members
            .into_iter()
            .map(|member| FfiChatDeviceMember {
                device_id: member.device_id.0.to_string(),
                account_id: member.account_id.0.to_string(),
                display_name: member.display_name,
                platform: member.platform,
                leaf_index: member.leaf_index,
                credential_identity: crate::decode_b64_field(
                    "credential_identity_b64",
                    &member.credential_identity_b64,
                )
                .unwrap_or_default(),
            })
            .collect(),
    }
}

fn chat_history_to_ffi(value: trix_types::ChatHistoryResponse) -> FfiChatHistory {
    FfiChatHistory {
        chat_id: value.chat_id.0.to_string(),
        messages: value
            .messages
            .into_iter()
            .map(message_envelope_to_ffi)
            .collect(),
    }
}

fn ffi_chat_history_to_api(
    value: FfiChatHistory,
) -> Result<trix_types::ChatHistoryResponse, TrixFfiError> {
    Ok(trix_types::ChatHistoryResponse {
        chat_id: parse_chat_id(&value.chat_id)?,
        messages: value
            .messages
            .into_iter()
            .map(ffi_message_envelope_to_api)
            .collect::<Result<Vec<_>, _>>()?,
    })
}

fn modify_chat_members_response_to_ffi(
    value: trix_types::ModifyChatMembersResponse,
) -> FfiModifyChatMembersResponse {
    FfiModifyChatMembersResponse {
        chat_id: value.chat_id.0.to_string(),
        epoch: value.epoch,
        changed_account_ids: value
            .changed_account_ids
            .into_iter()
            .map(|account_id| account_id.0.to_string())
            .collect(),
    }
}

fn modify_chat_devices_response_to_ffi(
    value: trix_types::ModifyChatDevicesResponse,
) -> FfiModifyChatDevicesResponse {
    FfiModifyChatDevicesResponse {
        chat_id: value.chat_id.0.to_string(),
        epoch: value.epoch,
        changed_device_ids: value
            .changed_device_ids
            .into_iter()
            .map(|device_id| device_id.0.to_string())
            .collect(),
    }
}

fn message_envelope_to_ffi(value: trix_types::MessageEnvelope) -> FfiMessageEnvelope {
    FfiMessageEnvelope {
        message_id: value.message_id.0.to_string(),
        chat_id: value.chat_id.0.to_string(),
        server_seq: value.server_seq,
        sender_account_id: value.sender_account_id.0.to_string(),
        sender_device_id: value.sender_device_id.0.to_string(),
        epoch: value.epoch,
        message_kind: value.message_kind.into(),
        content_type: value.content_type.into(),
        ciphertext: crate::decode_b64_field("ciphertext_b64", &value.ciphertext_b64)
            .unwrap_or_default(),
        aad_json: json_to_string(value.aad_json),
        created_at_unix: value.created_at_unix,
    }
}

fn inbox_item_to_ffi(value: trix_types::InboxItem) -> FfiInboxItem {
    FfiInboxItem {
        inbox_id: value.inbox_id,
        message: message_envelope_to_ffi(value.message),
    }
}

fn ffi_inbox_item_to_api(value: FfiInboxItem) -> Result<trix_types::InboxItem, TrixFfiError> {
    Ok(trix_types::InboxItem {
        inbox_id: value.inbox_id,
        message: ffi_message_envelope_to_api(value.message)?,
    })
}

fn ffi_message_envelope_to_api(
    value: FfiMessageEnvelope,
) -> Result<trix_types::MessageEnvelope, TrixFfiError> {
    Ok(trix_types::MessageEnvelope {
        message_id: parse_message_id(&value.message_id)?,
        chat_id: parse_chat_id(&value.chat_id)?,
        server_seq: value.server_seq,
        sender_account_id: parse_account_id(&value.sender_account_id)?,
        sender_device_id: parse_device_id(&value.sender_device_id)?,
        epoch: value.epoch,
        message_kind: message_kind_from_ffi(value.message_kind),
        content_type: content_type_from_ffi(value.content_type),
        ciphertext_b64: crate::encode_b64(&value.ciphertext),
        aad_json: serde_json::from_str(&value.aad_json)
            .map_err(|err| TrixFfiError::Message(format!("invalid aad_json: {err}")))?,
        created_at_unix: value.created_at_unix,
    })
}

fn message_body_to_ffi(value: MessageBody) -> FfiMessageBody {
    match value {
        MessageBody::Text(body) => FfiMessageBody {
            kind: FfiMessageBodyKind::Text,
            text: Some(body.text),
            target_message_id: None,
            emoji: None,
            reaction_action: None,
            receipt_type: None,
            receipt_at_unix: None,
            blob_id: None,
            mime_type: None,
            size_bytes: None,
            sha256: None,
            file_name: None,
            width_px: None,
            height_px: None,
            file_key: None,
            nonce: None,
            event_type: None,
            event_json: None,
        },
        MessageBody::Reaction(body) => FfiMessageBody {
            kind: FfiMessageBodyKind::Reaction,
            text: None,
            target_message_id: Some(body.target_message_id.0.to_string()),
            emoji: Some(body.emoji),
            reaction_action: Some(body.action.into()),
            receipt_type: None,
            receipt_at_unix: None,
            blob_id: None,
            mime_type: None,
            size_bytes: None,
            sha256: None,
            file_name: None,
            width_px: None,
            height_px: None,
            file_key: None,
            nonce: None,
            event_type: None,
            event_json: None,
        },
        MessageBody::Receipt(body) => FfiMessageBody {
            kind: FfiMessageBodyKind::Receipt,
            text: None,
            target_message_id: Some(body.target_message_id.0.to_string()),
            emoji: None,
            reaction_action: None,
            receipt_type: Some(body.receipt_type.into()),
            receipt_at_unix: body.at_unix,
            blob_id: None,
            mime_type: None,
            size_bytes: None,
            sha256: None,
            file_name: None,
            width_px: None,
            height_px: None,
            file_key: None,
            nonce: None,
            event_type: None,
            event_json: None,
        },
        MessageBody::Attachment(body) => FfiMessageBody {
            kind: FfiMessageBodyKind::Attachment,
            text: None,
            target_message_id: None,
            emoji: None,
            reaction_action: None,
            receipt_type: None,
            receipt_at_unix: None,
            blob_id: Some(body.blob_id),
            mime_type: Some(body.mime_type),
            size_bytes: Some(body.size_bytes),
            sha256: Some(body.sha256),
            file_name: body.file_name,
            width_px: body.width_px,
            height_px: body.height_px,
            file_key: Some(body.file_key),
            nonce: Some(body.nonce),
            event_type: None,
            event_json: None,
        },
        MessageBody::ChatEvent(body) => FfiMessageBody {
            kind: FfiMessageBodyKind::ChatEvent,
            text: None,
            target_message_id: None,
            emoji: None,
            reaction_action: None,
            receipt_type: None,
            receipt_at_unix: None,
            blob_id: None,
            mime_type: None,
            size_bytes: None,
            sha256: None,
            file_name: None,
            width_px: None,
            height_px: None,
            file_key: None,
            nonce: None,
            event_type: Some(body.event_type),
            event_json: Some(body.payload_json.to_string()),
        },
    }
}

fn message_body_from_ffi(value: FfiMessageBody) -> Result<MessageBody, TrixFfiError> {
    Ok(match value.kind {
        FfiMessageBodyKind::Text => MessageBody::Text(crate::TextMessageBody {
            text: value
                .text
                .ok_or_else(|| TrixFfiError::Message("text body is missing `text`".to_owned()))?,
        }),
        FfiMessageBodyKind::Reaction => MessageBody::Reaction(crate::ReactionMessageBody {
            target_message_id: parse_message_id(&value.target_message_id.ok_or_else(|| {
                TrixFfiError::Message("reaction body is missing `target_message_id`".to_owned())
            })?)?,
            emoji: value.emoji.ok_or_else(|| {
                TrixFfiError::Message("reaction body is missing `emoji`".to_owned())
            })?,
            action: value
                .reaction_action
                .ok_or_else(|| {
                    TrixFfiError::Message("reaction body is missing `reaction_action`".to_owned())
                })?
                .into(),
        }),
        FfiMessageBodyKind::Receipt => MessageBody::Receipt(crate::ReceiptMessageBody {
            target_message_id: parse_message_id(&value.target_message_id.ok_or_else(|| {
                TrixFfiError::Message("receipt body is missing `target_message_id`".to_owned())
            })?)?,
            receipt_type: value
                .receipt_type
                .ok_or_else(|| {
                    TrixFfiError::Message("receipt body is missing `receipt_type`".to_owned())
                })?
                .into(),
            at_unix: value.receipt_at_unix,
        }),
        FfiMessageBodyKind::Attachment => MessageBody::Attachment(crate::AttachmentMessageBody {
            blob_id: value.blob_id.ok_or_else(|| {
                TrixFfiError::Message("attachment body is missing `blob_id`".to_owned())
            })?,
            mime_type: value.mime_type.ok_or_else(|| {
                TrixFfiError::Message("attachment body is missing `mime_type`".to_owned())
            })?,
            size_bytes: value.size_bytes.ok_or_else(|| {
                TrixFfiError::Message("attachment body is missing `size_bytes`".to_owned())
            })?,
            sha256: value.sha256.ok_or_else(|| {
                TrixFfiError::Message("attachment body is missing `sha256`".to_owned())
            })?,
            file_name: value.file_name,
            width_px: value.width_px,
            height_px: value.height_px,
            file_key: value.file_key.ok_or_else(|| {
                TrixFfiError::Message("attachment body is missing `file_key`".to_owned())
            })?,
            nonce: value.nonce.ok_or_else(|| {
                TrixFfiError::Message("attachment body is missing `nonce`".to_owned())
            })?,
        }),
        FfiMessageBodyKind::ChatEvent => MessageBody::ChatEvent(crate::ChatEventMessageBody {
            event_type: value.event_type.ok_or_else(|| {
                TrixFfiError::Message("chat_event body is missing `event_type`".to_owned())
            })?,
            payload_json: serde_json::from_str(&value.event_json.ok_or_else(|| {
                TrixFfiError::Message("chat_event body is missing `event_json`".to_owned())
            })?)
            .map_err(|err| TrixFfiError::Message(format!("invalid event_json: {err}")))?,
        }),
    })
}

fn local_store_apply_report_to_ffi(value: LocalStoreApplyReport) -> FfiLocalStoreApplyReport {
    FfiLocalStoreApplyReport {
        chats_upserted: value.chats_upserted as u64,
        messages_upserted: value.messages_upserted as u64,
        changed_chat_ids: value
            .changed_chat_ids
            .into_iter()
            .map(|chat_id| chat_id.0.to_string())
            .collect(),
    }
}

fn local_projected_message_to_ffi(value: LocalProjectedMessage) -> FfiLocalProjectedMessage {
    let (body, body_parse_error) = match value.parse_body() {
        Ok(body) => (body.map(message_body_to_ffi), None),
        Err(err) => (None, Some(err.to_string())),
    };
    FfiLocalProjectedMessage {
        server_seq: value.server_seq,
        message_id: value.message_id.0.to_string(),
        sender_account_id: value.sender_account_id.0.to_string(),
        sender_device_id: value.sender_device_id.0.to_string(),
        epoch: value.epoch,
        message_kind: value.message_kind.into(),
        content_type: value.content_type.into(),
        projection_kind: value.projection_kind.into(),
        payload: value.payload,
        body,
        body_parse_error,
        merged_epoch: value.merged_epoch,
        created_at_unix: value.created_at_unix,
    }
}

fn local_projection_apply_report_to_ffi(
    value: LocalProjectionApplyReport,
) -> FfiLocalProjectionApplyReport {
    FfiLocalProjectionApplyReport {
        chat_id: value.chat_id.0.to_string(),
        processed_messages: value.processed_messages as u64,
        projected_messages_upserted: value.projected_messages_upserted as u64,
        advanced_to_server_seq: value.advanced_to_server_seq,
    }
}

fn inbox_apply_outcome_to_ffi(value: InboxApplyOutcome) -> FfiInboxApplyOutcome {
    FfiInboxApplyOutcome {
        lease_owner: value.lease_owner,
        lease_expires_at_unix: value.lease_expires_at_unix,
        acked_inbox_ids: value.acked_inbox_ids,
        report: local_store_apply_report_to_ffi(value.report),
    }
}

fn send_message_outcome_to_ffi(value: SendMessageOutcome) -> FfiSendMessageOutcome {
    FfiSendMessageOutcome {
        chat_id: value.chat_id.0.to_string(),
        message_id: value.message_id.0.to_string(),
        server_seq: value.server_seq,
        report: local_store_apply_report_to_ffi(value.report),
        projected_message: local_projected_message_to_ffi(value.projected_message),
    }
}

fn create_chat_control_outcome_to_ffi(
    value: CreateChatControlOutcome,
) -> FfiCreateChatControlOutcome {
    FfiCreateChatControlOutcome {
        chat_id: value.chat_id.0.to_string(),
        chat_type: value.chat_type.into(),
        epoch: value.epoch,
        mls_group_id: value.mls_group_id,
        report: local_store_apply_report_to_ffi(value.report),
        projected_messages: value
            .projected_messages
            .into_iter()
            .map(local_projected_message_to_ffi)
            .collect(),
    }
}

fn modify_chat_members_control_outcome_to_ffi(
    value: ModifyChatMembersControlOutcome,
) -> FfiModifyChatMembersControlOutcome {
    FfiModifyChatMembersControlOutcome {
        chat_id: value.chat_id.0.to_string(),
        epoch: value.epoch,
        changed_account_ids: value
            .changed_account_ids
            .into_iter()
            .map(|account_id| account_id.0.to_string())
            .collect(),
        report: local_store_apply_report_to_ffi(value.report),
        projected_messages: value
            .projected_messages
            .into_iter()
            .map(local_projected_message_to_ffi)
            .collect(),
    }
}

fn modify_chat_devices_control_outcome_to_ffi(
    value: ModifyChatDevicesControlOutcome,
) -> FfiModifyChatDevicesControlOutcome {
    FfiModifyChatDevicesControlOutcome {
        chat_id: value.chat_id.0.to_string(),
        epoch: value.epoch,
        changed_device_ids: value
            .changed_device_ids
            .into_iter()
            .map(|device_id| device_id.0.to_string())
            .collect(),
        report: local_store_apply_report_to_ffi(value.report),
        projected_messages: value
            .projected_messages
            .into_iter()
            .map(local_projected_message_to_ffi)
            .collect(),
    }
}

fn sync_chat_cursor_to_ffi(value: SyncChatCursor) -> FfiSyncChatCursor {
    FfiSyncChatCursor {
        chat_id: value.chat_id.0.to_string(),
        last_server_seq: value.last_server_seq,
    }
}

fn sync_state_snapshot_to_ffi(value: SyncStateSnapshot) -> FfiSyncStateSnapshot {
    FfiSyncStateSnapshot {
        lease_owner: value.lease_owner,
        last_acked_inbox_id: value.last_acked_inbox_id,
        chat_cursors: value
            .chat_cursors
            .into_iter()
            .map(sync_chat_cursor_to_ffi)
            .collect(),
    }
}

fn blob_metadata_to_ffi(value: crate::BlobMetadataMaterial) -> FfiBlobMetadata {
    FfiBlobMetadata {
        blob_id: value.blob_id,
        mime_type: value.mime_type,
        size_bytes: value.size_bytes,
        sha256: value.sha256,
        upload_status: value.upload_status.into(),
        created_by_device_id: value.created_by_device_id.0.to_string(),
    }
}

fn blob_head_to_ffi(value: crate::BlobHeadMaterial) -> FfiBlobHead {
    FfiBlobHead {
        blob_id: value.blob_id,
        mime_type: value.mime_type,
        size_bytes: value.size_bytes,
        sha256: value.sha256,
        upload_status: value.upload_status.into(),
        etag: value.etag,
    }
}

fn commit_bundle_to_ffi(value: MlsCommitBundle) -> FfiMlsCommitBundle {
    FfiMlsCommitBundle {
        commit_message: value.commit_message,
        welcome_message: value.welcome_message,
        ratchet_tree: value.ratchet_tree,
        epoch: value.epoch,
    }
}

fn member_identity_to_ffi(value: MlsMemberIdentity) -> FfiMlsMemberIdentity {
    FfiMlsMemberIdentity {
        leaf_index: value.leaf_index,
        signature_key: value.signature_key,
        credential_identity: value.credential_identity,
    }
}

fn process_result_to_ffi(value: MlsProcessResult) -> FfiMlsProcessResult {
    match value {
        MlsProcessResult::ApplicationMessage(message) => FfiMlsProcessResult {
            kind: FfiMlsProcessKind::ApplicationMessage,
            application_message: Some(message),
            epoch: None,
        },
        MlsProcessResult::ProposalQueued => FfiMlsProcessResult {
            kind: FfiMlsProcessKind::ProposalQueued,
            application_message: None,
            epoch: None,
        },
        MlsProcessResult::CommitMerged { epoch } => FfiMlsProcessResult {
            kind: FfiMlsProcessKind::CommitMerged,
            application_message: None,
            epoch: Some(epoch),
        },
    }
}

fn message_kind_from_ffi(value: FfiMessageKind) -> trix_types::MessageKind {
    match value {
        FfiMessageKind::Application => trix_types::MessageKind::Application,
        FfiMessageKind::Commit => trix_types::MessageKind::Commit,
        FfiMessageKind::WelcomeRef => trix_types::MessageKind::WelcomeRef,
        FfiMessageKind::System => trix_types::MessageKind::System,
    }
}

fn content_type_from_ffi(value: FfiContentType) -> trix_types::ContentType {
    match value {
        FfiContentType::Text => trix_types::ContentType::Text,
        FfiContentType::Reaction => trix_types::ContentType::Reaction,
        FfiContentType::Receipt => trix_types::ContentType::Receipt,
        FfiContentType::Attachment => trix_types::ContentType::Attachment,
        FfiContentType::ChatEvent => trix_types::ContentType::ChatEvent,
    }
}

impl From<trix_types::DeviceStatus> for FfiDeviceStatus {
    fn from(value: trix_types::DeviceStatus) -> Self {
        match value {
            trix_types::DeviceStatus::Pending => Self::Pending,
            trix_types::DeviceStatus::Active => Self::Active,
            trix_types::DeviceStatus::Revoked => Self::Revoked,
        }
    }
}

impl From<FfiChatType> for trix_types::ChatType {
    fn from(value: FfiChatType) -> Self {
        match value {
            FfiChatType::Dm => Self::Dm,
            FfiChatType::Group => Self::Group,
            FfiChatType::AccountSync => Self::AccountSync,
        }
    }
}

impl From<trix_types::ChatType> for FfiChatType {
    fn from(value: trix_types::ChatType) -> Self {
        match value {
            trix_types::ChatType::Dm => Self::Dm,
            trix_types::ChatType::Group => Self::Group,
            trix_types::ChatType::AccountSync => Self::AccountSync,
        }
    }
}

impl From<FfiMessageKind> for trix_types::MessageKind {
    fn from(value: FfiMessageKind) -> Self {
        match value {
            FfiMessageKind::Application => Self::Application,
            FfiMessageKind::Commit => Self::Commit,
            FfiMessageKind::WelcomeRef => Self::WelcomeRef,
            FfiMessageKind::System => Self::System,
        }
    }
}

impl From<trix_types::MessageKind> for FfiMessageKind {
    fn from(value: trix_types::MessageKind) -> Self {
        match value {
            trix_types::MessageKind::Application => Self::Application,
            trix_types::MessageKind::Commit => Self::Commit,
            trix_types::MessageKind::WelcomeRef => Self::WelcomeRef,
            trix_types::MessageKind::System => Self::System,
        }
    }
}

impl From<FfiContentType> for trix_types::ContentType {
    fn from(value: FfiContentType) -> Self {
        match value {
            FfiContentType::Text => Self::Text,
            FfiContentType::Reaction => Self::Reaction,
            FfiContentType::Receipt => Self::Receipt,
            FfiContentType::Attachment => Self::Attachment,
            FfiContentType::ChatEvent => Self::ChatEvent,
        }
    }
}

impl From<trix_types::ContentType> for FfiContentType {
    fn from(value: trix_types::ContentType) -> Self {
        match value {
            trix_types::ContentType::Text => Self::Text,
            trix_types::ContentType::Reaction => Self::Reaction,
            trix_types::ContentType::Receipt => Self::Receipt,
            trix_types::ContentType::Attachment => Self::Attachment,
            trix_types::ContentType::ChatEvent => Self::ChatEvent,
        }
    }
}

impl From<FfiHistorySyncJobRole> for trix_types::HistorySyncJobRole {
    fn from(value: FfiHistorySyncJobRole) -> Self {
        match value {
            FfiHistorySyncJobRole::Source => Self::Source,
            FfiHistorySyncJobRole::Target => Self::Target,
        }
    }
}

impl From<trix_types::HistorySyncJobType> for FfiHistorySyncJobType {
    fn from(value: trix_types::HistorySyncJobType) -> Self {
        match value {
            trix_types::HistorySyncJobType::InitialSync => Self::InitialSync,
            trix_types::HistorySyncJobType::ChatBackfill => Self::ChatBackfill,
            trix_types::HistorySyncJobType::DeviceRekey => Self::DeviceRekey,
        }
    }
}

impl From<FfiHistorySyncJobStatus> for trix_types::HistorySyncJobStatus {
    fn from(value: FfiHistorySyncJobStatus) -> Self {
        match value {
            FfiHistorySyncJobStatus::Pending => Self::Pending,
            FfiHistorySyncJobStatus::Running => Self::Running,
            FfiHistorySyncJobStatus::Completed => Self::Completed,
            FfiHistorySyncJobStatus::Failed => Self::Failed,
            FfiHistorySyncJobStatus::Canceled => Self::Canceled,
        }
    }
}

impl From<trix_types::HistorySyncJobStatus> for FfiHistorySyncJobStatus {
    fn from(value: trix_types::HistorySyncJobStatus) -> Self {
        match value {
            trix_types::HistorySyncJobStatus::Pending => Self::Pending,
            trix_types::HistorySyncJobStatus::Running => Self::Running,
            trix_types::HistorySyncJobStatus::Completed => Self::Completed,
            trix_types::HistorySyncJobStatus::Failed => Self::Failed,
            trix_types::HistorySyncJobStatus::Canceled => Self::Canceled,
        }
    }
}

impl From<trix_types::BlobUploadStatus> for FfiBlobUploadStatus {
    fn from(value: trix_types::BlobUploadStatus) -> Self {
        match value {
            trix_types::BlobUploadStatus::PendingUpload => Self::PendingUpload,
            trix_types::BlobUploadStatus::Available => Self::Available,
        }
    }
}

impl From<LocalProjectionKind> for FfiLocalProjectionKind {
    fn from(value: LocalProjectionKind) -> Self {
        match value {
            LocalProjectionKind::ApplicationMessage => Self::ApplicationMessage,
            LocalProjectionKind::ProposalQueued => Self::ProposalQueued,
            LocalProjectionKind::CommitMerged => Self::CommitMerged,
            LocalProjectionKind::WelcomeRef => Self::WelcomeRef,
            LocalProjectionKind::System => Self::System,
        }
    }
}

impl From<ReactionAction> for FfiReactionAction {
    fn from(value: ReactionAction) -> Self {
        match value {
            ReactionAction::Add => Self::Add,
            ReactionAction::Remove => Self::Remove,
        }
    }
}

impl From<FfiReactionAction> for ReactionAction {
    fn from(value: FfiReactionAction) -> Self {
        match value {
            FfiReactionAction::Add => Self::Add,
            FfiReactionAction::Remove => Self::Remove,
        }
    }
}

impl From<ReceiptType> for FfiReceiptType {
    fn from(value: ReceiptType) -> Self {
        match value {
            ReceiptType::Delivered => Self::Delivered,
            ReceiptType::Read => Self::Read,
        }
    }
}

impl From<FfiReceiptType> for ReceiptType {
    fn from(value: FfiReceiptType) -> Self {
        match value {
            FfiReceiptType::Delivered => Self::Delivered,
            FfiReceiptType::Read => Self::Read,
        }
    }
}

impl From<trix_types::ServiceStatus> for FfiServiceStatus {
    fn from(value: trix_types::ServiceStatus) -> Self {
        match value {
            trix_types::ServiceStatus::Ok => Self::Ok,
            trix_types::ServiceStatus::Degraded => Self::Degraded,
        }
    }
}
