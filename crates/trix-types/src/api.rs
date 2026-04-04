use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use serde_json::Value;

use crate::{
    AccountId, ChatId, ChatType, ContentType, DeviceId, DeviceStatus, HistorySyncJobRole,
    HistorySyncJobStatus, HistorySyncJobType, MessageId, MessageKind,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceStatus {
    Ok,
    Degraded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlobUploadStatus {
    PendingUpload,
    Available,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApplePushEnvironment {
    Sandbox,
    Production,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthResponse {
    pub service: String,
    pub status: ServiceStatus,
    pub version: String,
    pub uptime_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionResponse {
    pub service: String,
    pub version: String,
    pub git_sha: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAccountRequest {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity_b64: String,
    pub account_root_pubkey_b64: String,
    pub account_root_signature_b64: String,
    pub transport_pubkey_b64: String,
    #[serde(default)]
    pub provision_token: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAccountResponse {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub account_sync_chat_id: ChatId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthChallengeRequest {
    pub device_id: DeviceId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthChallengeResponse {
    pub challenge_id: String,
    pub challenge_b64: String,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthSessionRequest {
    pub device_id: DeviceId,
    pub challenge_id: String,
    pub signature_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthSessionResponse {
    pub access_token: String,
    pub expires_at_unix: u64,
    pub account_id: AccountId,
    pub device_status: DeviceStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountProfileResponse {
    pub account_id: AccountId,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub device_id: DeviceId,
    pub device_status: DeviceStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirectoryAccountSummary {
    pub account_id: AccountId,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatParticipantProfileSummary {
    pub account_id: AccountId,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountDirectoryResponse {
    pub accounts: Vec<DirectoryAccountSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateAccountProfileRequest {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceSummary {
    pub device_id: DeviceId,
    pub display_name: String,
    pub platform: String,
    pub device_status: DeviceStatus,
    pub available_key_package_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceListResponse {
    pub account_id: AccountId,
    pub devices: Vec<DeviceSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegisterApplePushTokenRequest {
    pub token_hex: String,
    pub environment: ApplePushEnvironment,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegisterApplePushTokenResponse {
    pub device_id: DeviceId,
    pub environment: ApplePushEnvironment,
    pub push_delivery_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateLinkIntentResponse {
    pub link_intent_id: String,
    pub qr_payload: String,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompleteLinkIntentRequest {
    pub link_token: String,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity_b64: String,
    pub transport_pubkey_b64: String,
    #[serde(default)]
    pub key_packages: Vec<PublishKeyPackageItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompleteLinkIntentResponse {
    pub account_id: AccountId,
    pub pending_device_id: DeviceId,
    pub device_status: DeviceStatus,
    pub bootstrap_payload_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceApprovePayloadResponse {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub device_display_name: String,
    pub platform: String,
    pub device_status: DeviceStatus,
    pub credential_identity_b64: String,
    pub transport_pubkey_b64: String,
    pub bootstrap_payload_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceTransportKeyResponse {
    pub device_id: DeviceId,
    pub device_status: DeviceStatus,
    pub transport_pubkey_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproveDeviceRequest {
    pub account_root_signature_b64: String,
    pub transfer_bundle_b64: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproveDeviceResponse {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub device_status: DeviceStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceTransferBundleResponse {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub transfer_bundle_b64: String,
    pub uploaded_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevokeDeviceRequest {
    pub reason: String,
    pub account_root_signature_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevokeDeviceResponse {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub device_status: DeviceStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishKeyPackageItem {
    pub cipher_suite: String,
    pub key_package_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishKeyPackagesRequest {
    pub packages: Vec<PublishKeyPackageItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReserveKeyPackagesRequest {
    pub account_id: AccountId,
    pub device_ids: Vec<DeviceId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishedKeyPackage {
    pub key_package_id: String,
    pub cipher_suite: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishKeyPackagesResponse {
    pub device_id: DeviceId,
    pub packages: Vec<PublishedKeyPackage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResetKeyPackagesResponse {
    pub device_id: DeviceId,
    pub expired_key_package_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReservedKeyPackage {
    pub key_package_id: String,
    pub device_id: DeviceId,
    pub cipher_suite: String,
    pub key_package_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountKeyPackagesResponse {
    pub account_id: AccountId,
    pub packages: Vec<ReservedKeyPackage>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateChatRequest {
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub participant_account_ids: Vec<AccountId>,
    #[serde(default)]
    pub reserved_key_package_ids: Vec<String>,
    pub initial_commit: Option<ControlMessageInput>,
    pub welcome_message: Option<ControlMessageInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateChatResponse {
    pub chat_id: ChatId,
    pub chat_type: ChatType,
    pub epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatSummary {
    pub chat_id: ChatId,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub last_server_seq: u64,
    pub epoch: u64,
    #[serde(default)]
    pub pending_message_count: u64,
    pub last_message: Option<MessageEnvelope>,
    #[serde(default)]
    pub participant_profiles: Vec<ChatParticipantProfileSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatListResponse {
    pub chats: Vec<ChatSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatMemberSummary {
    pub account_id: AccountId,
    pub role: String,
    pub membership_status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatDeviceSummary {
    pub device_id: DeviceId,
    pub account_id: AccountId,
    pub display_name: String,
    pub platform: String,
    pub leaf_index: u32,
    pub credential_identity_b64: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatDetailResponse {
    pub chat_id: ChatId,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub last_server_seq: u64,
    #[serde(default)]
    pub pending_message_count: u64,
    pub epoch: u64,
    pub last_commit_message_id: Option<MessageId>,
    pub last_message: Option<MessageEnvelope>,
    #[serde(default)]
    pub participant_profiles: Vec<ChatParticipantProfileSummary>,
    pub members: Vec<ChatMemberSummary>,
    #[serde(default)]
    pub device_members: Vec<ChatDeviceSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControlMessageInput {
    pub message_id: MessageId,
    pub ciphertext_b64: String,
    pub aad_json: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModifyChatMembersRequest {
    pub epoch: u64,
    pub participant_account_ids: Vec<AccountId>,
    #[serde(default)]
    pub reserved_key_package_ids: Vec<String>,
    pub commit_message: Option<ControlMessageInput>,
    pub welcome_message: Option<ControlMessageInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModifyChatMembersResponse {
    pub chat_id: ChatId,
    pub epoch: u64,
    pub changed_account_ids: Vec<AccountId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModifyChatDevicesRequest {
    pub epoch: u64,
    pub device_ids: Vec<DeviceId>,
    #[serde(default)]
    pub reserved_key_package_ids: Vec<String>,
    pub commit_message: Option<ControlMessageInput>,
    pub welcome_message: Option<ControlMessageInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModifyChatDevicesResponse {
    pub chat_id: ChatId,
    pub epoch: u64,
    pub changed_device_ids: Vec<DeviceId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LeaveChatScope {
    ThisDevice,
    AllMyDevices,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LeaveChatRequest {
    pub scope: LeaveChatScope,
    pub epoch: u64,
    pub commit_message: Option<ControlMessageInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaveChatResponse {
    pub chat_id: ChatId,
    pub epoch: u64,
    pub changed_device_ids: Vec<DeviceId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DmGlobalDeleteRequest {
    pub epoch: u64,
    pub commit_message: Option<ControlMessageInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DmGlobalDeleteResponse {
    pub chat_id: ChatId,
    pub epoch: u64,
    pub changed_account_ids: Vec<AccountId>,
    pub changed_device_ids: Vec<DeviceId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateMessageRequest {
    pub message_id: MessageId,
    pub epoch: u64,
    pub message_kind: MessageKind,
    pub content_type: ContentType,
    pub ciphertext_b64: String,
    pub aad_json: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateMessageResponse {
    pub message_id: MessageId,
    pub server_seq: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageEnvelope {
    pub message_id: MessageId,
    pub chat_id: ChatId,
    pub server_seq: u64,
    pub sender_account_id: AccountId,
    pub sender_device_id: DeviceId,
    pub epoch: u64,
    pub message_kind: MessageKind,
    pub content_type: ContentType,
    pub ciphertext_b64: String,
    pub aad_json: Value,
    pub created_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatHistoryResponse {
    pub chat_id: ChatId,
    pub messages: Vec<MessageEnvelope>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InboxItem {
    pub inbox_id: u64,
    pub message: MessageEnvelope,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InboxResponse {
    pub items: Vec<InboxItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LeaseInboxRequest {
    pub lease_owner: Option<String>,
    pub limit: Option<usize>,
    pub after_inbox_id: Option<u64>,
    pub lease_ttl_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LeaseInboxResponse {
    pub lease_owner: String,
    pub lease_expires_at_unix: u64,
    pub items: Vec<InboxItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AckInboxRequest {
    pub inbox_ids: Vec<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AckInboxResponse {
    pub acked_inbox_ids: Vec<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WebSocketClientFrame {
    Ack {
        inbox_ids: Vec<u64>,
    },
    PresencePing {
        nonce: Option<String>,
    },
    TypingUpdate {
        chat_id: ChatId,
        is_typing: bool,
    },
    HistorySyncProgress {
        job_id: String,
        cursor_json: Option<Value>,
        completed_chunks: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WebSocketServerFrame {
    Hello {
        session_id: String,
        account_id: AccountId,
        device_id: DeviceId,
        lease_owner: String,
        lease_ttl_seconds: u64,
    },
    InboxItems {
        lease_owner: String,
        lease_expires_at_unix: u64,
        items: Vec<InboxItem>,
    },
    Acked {
        acked_inbox_ids: Vec<u64>,
    },
    Pong {
        nonce: Option<String>,
        server_unix: u64,
    },
    SessionReplaced {
        reason: String,
    },
    Error {
        code: String,
        message: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateBlobUploadRequest {
    pub chat_id: ChatId,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateBlobUploadResponse {
    pub blob_id: String,
    pub upload_url: String,
    pub upload_status: BlobUploadStatus,
    pub needs_upload: bool,
    pub max_upload_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlobMetadataResponse {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256_b64: String,
    pub upload_status: BlobUploadStatus,
    pub created_by_device_id: DeviceId,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistorySyncJobSummary {
    pub job_id: String,
    pub job_type: HistorySyncJobType,
    pub job_status: HistorySyncJobStatus,
    pub source_device_id: DeviceId,
    pub target_device_id: DeviceId,
    pub chat_id: Option<ChatId>,
    pub cursor_json: Value,
    pub created_at_unix: u64,
    pub updated_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistorySyncJobListResponse {
    pub jobs: Vec<HistorySyncJobSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestHistorySyncRepairRequest {
    pub chat_id: ChatId,
    pub repair_from_server_seq: u64,
    pub repair_through_server_seq: u64,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestHistorySyncRepairResponse {
    pub jobs: Vec<HistorySyncJobSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppendHistorySyncChunkRequest {
    pub sequence_no: u64,
    pub payload_b64: String,
    pub cursor_json: Option<Value>,
    pub is_final: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppendHistorySyncChunkResponse {
    pub job_id: String,
    pub chunk_id: u64,
    pub job_status: HistorySyncJobStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistorySyncChunkSummary {
    pub chunk_id: u64,
    pub sequence_no: u64,
    pub payload_b64: String,
    pub cursor_json: Option<Value>,
    pub is_final: bool,
    pub uploaded_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistorySyncChunkListResponse {
    pub job_id: String,
    pub role: HistorySyncJobRole,
    pub chunks: Vec<HistorySyncChunkSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompleteHistorySyncJobRequest {
    pub cursor_json: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompleteHistorySyncJobResponse {
    pub job_id: String,
    pub job_status: HistorySyncJobStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestChatBackfillRequest {
    pub chat_id: ChatId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestChatBackfillResponse {
    pub job_id: String,
    pub source_device_id: DeviceId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminSessionRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminSessionResponse {
    pub access_token: String,
    pub expires_at_unix: u64,
    pub username: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminRegistrationSettingsResponse {
    pub allow_public_account_registration: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminServerSettingsResponse {
    pub brand_display_name: Option<String>,
    pub support_contact: Option<String>,
    pub policy_text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchAdminRegistrationSettingsRequest {
    pub allow_public_account_registration: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchAdminServerSettingsRequest {
    #[serde(default)]
    pub brand_display_name: Option<Option<String>>,
    #[serde(default)]
    pub support_contact: Option<Option<String>>,
    #[serde(default)]
    pub policy_text: Option<Option<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminOverviewResponse {
    pub status: String,
    pub service: String,
    pub version: String,
    pub git_sha: Option<String>,
    pub health_status: ServiceStatus,
    pub uptime_ms: u64,
    pub allow_public_account_registration: bool,
    pub user_count: u64,
    pub disabled_user_count: u64,
    pub admin_username: String,
    pub admin_session_expires_at_unix: u64,
    /// When true, debug metric collection endpoints are enabled on this server.
    pub debug_metrics_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminUserSummary {
    pub account_id: AccountId,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub created_at_unix: u64,
    pub disabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminUserListResponse {
    pub users: Vec<AdminUserSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchAdminUserRequest {
    #[serde(default)]
    pub handle: Option<Option<String>>,
    #[serde(default)]
    pub profile_name: Option<String>,
    #[serde(default)]
    pub profile_bio: Option<Option<String>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminDisableAccountRequest {
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAdminUserProvisionRequest {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub ttl_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAdminUserProvisionResponse {
    pub provision_id: String,
    pub provision_token: String,
    pub expires_at_unix: u64,
    pub profile_name: String,
    pub handle: Option<String>,
    pub profile_bio: Option<String>,
}

// --- Feature flags ---

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeatureFlagScope {
    Global,
    Platform,
    Account,
    Device,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountFeatureFlagsResponse {
    pub revision: u64,
    pub flags: BTreeMap<String, bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminFeatureFlagDefinition {
    pub flag_key: String,
    pub description: String,
    pub default_enabled: bool,
    pub deleted_at_unix: Option<u64>,
    pub updated_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminFeatureFlagDefinitionListResponse {
    pub definitions: Vec<AdminFeatureFlagDefinition>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAdminFeatureFlagDefinitionRequest {
    pub flag_key: String,
    pub description: String,
    pub default_enabled: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchAdminFeatureFlagDefinitionRequest {
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub default_enabled: Option<bool>,
    #[serde(default)]
    pub deleted_at_unix: Option<Option<u64>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminFeatureFlagOverride {
    pub override_id: String,
    pub flag_key: String,
    pub scope: FeatureFlagScope,
    pub platform: Option<String>,
    pub account_id: Option<AccountId>,
    pub device_id: Option<DeviceId>,
    pub enabled: bool,
    pub expires_at_unix: Option<u64>,
    pub updated_at_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminFeatureFlagOverrideListResponse {
    pub overrides: Vec<AdminFeatureFlagOverride>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAdminFeatureFlagOverrideRequest {
    pub flag_key: String,
    pub scope: FeatureFlagScope,
    #[serde(default)]
    pub platform: Option<String>,
    #[serde(default)]
    pub account_id: Option<AccountId>,
    #[serde(default)]
    pub device_id: Option<DeviceId>,
    pub enabled: bool,
    #[serde(default)]
    pub expires_at_unix: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchAdminFeatureFlagOverrideRequest {
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub expires_at_unix: Option<Option<u64>>,
}

// --- Debug metrics (opt-in server feature) ---

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountDebugMetricsStatusResponse {
    pub active: bool,
    pub session_id: Option<String>,
    pub user_visible_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubmitDebugMetricsRequest {
    pub session_id: String,
    pub payload: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateAdminDebugMetricSessionRequest {
    pub account_id: AccountId,
    #[serde(default)]
    pub device_id: Option<DeviceId>,
    pub user_visible_message: String,
    pub ttl_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminDebugMetricSession {
    pub session_id: String,
    pub account_id: AccountId,
    pub device_id: Option<DeviceId>,
    pub user_visible_message: String,
    pub created_at_unix: u64,
    pub expires_at_unix: u64,
    pub revoked_at_unix: Option<u64>,
    pub created_by_admin: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminDebugMetricSessionResponse {
    pub session: AdminDebugMetricSession,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminDebugMetricSessionListResponse {
    pub sessions: Vec<AdminDebugMetricSession>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminDebugMetricBatch {
    pub batch_id: String,
    pub session_id: String,
    pub device_id: DeviceId,
    pub received_at_unix: u64,
    pub payload: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminDebugMetricBatchListResponse {
    pub batches: Vec<AdminDebugMetricBatch>,
}
