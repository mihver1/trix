//! Compile-time contract between trix-core (client) and trix-server.
//!
//! Each API endpoint is declared as a struct implementing `ApiEndpoint`,
//! binding its path, HTTP method, and request/response types.
//! Both client transport and server routes reference these declarations,
//! so any type mismatch is caught at compile time.

use http::Method;
use serde::{Serialize, de::DeserializeOwned};

use crate::{AccountId, ChatId, DeviceId};

/// Marker for endpoints with no JSON request body (GET, DELETE, HEAD).
pub type NoBody = ();

/// Marker for endpoints with no JSON response body (204 No Content).
pub type NoResponse = ();

/// Associates an API endpoint with its path, HTTP method, and request/response types.
pub trait ApiEndpoint {
    /// URL path template, e.g. "/v0/accounts" or "/v0/chats/{chat_id}".
    const PATH: &'static str;
    const METHOD: Method;
    type Request: Serialize + DeserializeOwned + Send;
    type Response: Serialize + DeserializeOwned + Send;
}

/// Extension for endpoints with path parameters.
pub trait PathEndpoint: ApiEndpoint {
    type PathParams: Send;
    fn render_path(params: &Self::PathParams) -> String;
}

/// Extension for endpoints with query parameters.
pub trait QueryEndpoint: ApiEndpoint {
    type Query: Serialize + Send;
}

// ---------------------------------------------------------------------------
// Declarative macros for concise endpoint declarations
// ---------------------------------------------------------------------------

macro_rules! endpoint {
    ($name:ident, $method:ident, $path:expr, $req:ty, $resp:ty) => {
        pub struct $name;
        impl ApiEndpoint for $name {
            const PATH: &'static str = $path;
            const METHOD: Method = Method::$method;
            type Request = $req;
            type Response = $resp;
        }
    };
}

macro_rules! path_endpoint {
    ($name:ident, $method:ident, $path:expr, $req:ty, $resp:ty, $params:ty, $render:expr) => {
        endpoint!($name, $method, $path, $req, $resp);
        impl PathEndpoint for $name {
            type PathParams = $params;
            fn render_path(params: &Self::PathParams) -> String {
                let render_fn: fn(&$params) -> String = $render;
                render_fn(params)
            }
        }
    };
}

macro_rules! query_endpoint {
    ($name:ident, $method:ident, $path:expr, $req:ty, $resp:ty, $query:ty) => {
        endpoint!($name, $method, $path, $req, $resp);
        impl QueryEndpoint for $name {
            type Query = $query;
        }
    };
}

macro_rules! path_query_endpoint {
    ($name:ident, $method:ident, $path:expr, $req:ty, $resp:ty, $params:ty, $render:expr, $query:ty) => {
        path_endpoint!($name, $method, $path, $req, $resp, $params, $render);
        impl QueryEndpoint for $name {
            type Query = $query;
        }
    };
}

// ---------------------------------------------------------------------------
// System
// ---------------------------------------------------------------------------

endpoint!(
    Health,
    GET,
    "/v0/system/health",
    NoBody,
    super::HealthResponse
);
endpoint!(
    Version,
    GET,
    "/v0/system/version",
    NoBody,
    super::VersionResponse
);

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

endpoint!(
    AuthChallenge,
    POST,
    "/v0/auth/challenge",
    super::AuthChallengeRequest,
    super::AuthChallengeResponse
);
endpoint!(
    AuthSession,
    POST,
    "/v0/auth/session",
    super::AuthSessionRequest,
    super::AuthSessionResponse
);

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

endpoint!(
    CreateAccount,
    POST,
    "/v0/accounts",
    super::CreateAccountRequest,
    super::CreateAccountResponse
);
endpoint!(
    GetMe,
    GET,
    "/v0/accounts/me",
    NoBody,
    super::AccountProfileResponse
);
endpoint!(
    UpdateMe,
    PATCH,
    "/v0/accounts/me",
    super::UpdateAccountProfileRequest,
    super::AccountProfileResponse
);
endpoint!(
    GetFeatureFlags,
    GET,
    "/v0/accounts/me/feature-flags",
    NoBody,
    super::AccountFeatureFlagsResponse
);
endpoint!(
    GetDebugMetricsStatus,
    GET,
    "/v0/accounts/me/debug/metrics",
    NoBody,
    super::AccountDebugMetricsStatusResponse
);
endpoint!(
    SubmitDebugMetrics,
    POST,
    "/v0/accounts/me/debug/metrics",
    super::SubmitDebugMetricsRequest,
    NoResponse
);

query_endpoint!(
    SearchDirectory,
    GET,
    "/v0/accounts/directory",
    NoBody,
    super::AccountDirectoryResponse,
    super::AccountDirectoryQuery
);

path_endpoint!(
    GetAccount,
    GET,
    "/v0/accounts/{account_id}",
    NoBody,
    super::DirectoryAccountSummary,
    AccountId,
    |id: &AccountId| format!("/v0/accounts/{}", id.0)
);

path_endpoint!(
    GetAccountKeyPackages,
    GET,
    "/v0/accounts/{account_id}/key-packages",
    NoBody,
    super::AccountKeyPackagesResponse,
    AccountId,
    |id: &AccountId| format!("/v0/accounts/{}/key-packages", id.0)
);

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

endpoint!(
    ListDevices,
    GET,
    "/v0/devices",
    NoBody,
    super::DeviceListResponse
);
endpoint!(
    RegisterPushToken,
    PUT,
    "/v0/devices/push-token",
    super::RegisterApplePushTokenRequest,
    super::RegisterApplePushTokenResponse
);
endpoint!(
    DeletePushToken,
    DELETE,
    "/v0/devices/push-token",
    NoBody,
    NoResponse
);
endpoint!(
    CreateLinkIntent,
    POST,
    "/v0/devices/link-intents",
    NoBody,
    super::CreateLinkIntentResponse
);

path_endpoint!(
    CompleteLinkIntent,
    POST,
    "/v0/devices/link-intents/{link_intent_id}/complete",
    super::CompleteLinkIntentRequest,
    super::CompleteLinkIntentResponse,
    String,
    |id: &String| format!("/v0/devices/link-intents/{}/complete", id)
);

path_endpoint!(
    GetTransferBundle,
    GET,
    "/v0/devices/{device_id}/transfer-bundle",
    NoBody,
    super::DeviceTransferBundleResponse,
    DeviceId,
    |id: &DeviceId| format!("/v0/devices/{}/transfer-bundle", id.0)
);

path_endpoint!(
    GetTransportKey,
    GET,
    "/v0/devices/{device_id}/transport-key",
    NoBody,
    super::DeviceTransportKeyResponse,
    DeviceId,
    |id: &DeviceId| format!("/v0/devices/{}/transport-key", id.0)
);

path_endpoint!(
    GetApprovePayload,
    GET,
    "/v0/devices/{device_id}/approve-payload",
    NoBody,
    super::DeviceApprovePayloadResponse,
    DeviceId,
    |id: &DeviceId| format!("/v0/devices/{}/approve-payload", id.0)
);

path_endpoint!(
    ApproveDevice,
    POST,
    "/v0/devices/{device_id}/approve",
    super::ApproveDeviceRequest,
    super::ApproveDeviceResponse,
    DeviceId,
    |id: &DeviceId| format!("/v0/devices/{}/approve", id.0)
);

path_endpoint!(
    RevokeDevice,
    POST,
    "/v0/devices/{device_id}/revoke",
    super::RevokeDeviceRequest,
    super::RevokeDeviceResponse,
    DeviceId,
    |id: &DeviceId| format!("/v0/devices/{}/revoke", id.0)
);

// ---------------------------------------------------------------------------
// Key Packages
// ---------------------------------------------------------------------------

endpoint!(
    PublishKeyPackages,
    POST,
    "/v0/key-packages:publish",
    super::PublishKeyPackagesRequest,
    super::PublishKeyPackagesResponse
);
endpoint!(
    ResetKeyPackages,
    POST,
    "/v0/key-packages:reset",
    NoBody,
    super::ResetKeyPackagesResponse
);
endpoint!(
    ReserveKeyPackages,
    POST,
    "/v0/key-packages:reserve",
    super::ReserveKeyPackagesRequest,
    super::AccountKeyPackagesResponse
);

// ---------------------------------------------------------------------------
// Chats
// ---------------------------------------------------------------------------

endpoint!(ListChats, GET, "/v0/chats", NoBody, super::ChatListResponse);
endpoint!(
    CreateChat,
    POST,
    "/v0/chats",
    super::CreateChatRequest,
    super::CreateChatResponse
);

path_endpoint!(
    GetChat,
    GET,
    "/v0/chats/{chat_id}",
    NoBody,
    super::ChatDetailResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}", id.0)
);

path_endpoint!(
    CreateMessage,
    POST,
    "/v0/chats/{chat_id}/messages",
    super::CreateMessageRequest,
    super::CreateMessageResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/messages", id.0)
);

path_query_endpoint!(
    GetChatHistory,
    GET,
    "/v0/chats/{chat_id}/history",
    NoBody,
    super::ChatHistoryResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/history", id.0),
    super::ChatHistoryQuery
);

path_endpoint!(
    AddChatMembers,
    POST,
    "/v0/chats/{chat_id}/members:add",
    super::ModifyChatMembersRequest,
    super::ModifyChatMembersResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/members:add", id.0)
);

path_endpoint!(
    RemoveChatMembers,
    POST,
    "/v0/chats/{chat_id}/members:remove",
    super::ModifyChatMembersRequest,
    super::ModifyChatMembersResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/members:remove", id.0)
);

path_endpoint!(
    AddChatDevices,
    POST,
    "/v0/chats/{chat_id}/devices:add",
    super::ModifyChatDevicesRequest,
    super::ModifyChatDevicesResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/devices:add", id.0)
);

path_endpoint!(
    RemoveChatDevices,
    POST,
    "/v0/chats/{chat_id}/devices:remove",
    super::ModifyChatDevicesRequest,
    super::ModifyChatDevicesResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/devices:remove", id.0)
);

path_endpoint!(
    LeaveChat,
    POST,
    "/v0/chats/{chat_id}/leave",
    super::LeaveChatRequest,
    super::LeaveChatResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/leave", id.0)
);

path_endpoint!(
    DmGlobalDelete,
    POST,
    "/v0/chats/{chat_id}/dm-global-delete",
    super::DmGlobalDeleteRequest,
    super::DmGlobalDeleteResponse,
    ChatId,
    |id: &ChatId| format!("/v0/chats/{}/dm-global-delete", id.0)
);

// ---------------------------------------------------------------------------
// Inbox
// ---------------------------------------------------------------------------

query_endpoint!(
    GetInbox,
    GET,
    "/v0/inbox",
    NoBody,
    super::InboxResponse,
    super::InboxQuery
);
endpoint!(
    LeaseInbox,
    POST,
    "/v0/inbox/lease",
    super::LeaseInboxRequest,
    super::LeaseInboxResponse
);
endpoint!(
    AckInbox,
    POST,
    "/v0/inbox/ack",
    super::AckInboxRequest,
    super::AckInboxResponse
);

// ---------------------------------------------------------------------------
// Blobs (only the JSON endpoints -- upload/download are raw bytes)
// ---------------------------------------------------------------------------

endpoint!(
    CreateBlobUpload,
    POST,
    "/v0/blobs/uploads",
    super::CreateBlobUploadRequest,
    super::CreateBlobUploadResponse
);

// Note: PUT /v0/blobs/{blob_id} (upload), GET /v0/blobs/{blob_id} (download),
// HEAD /v0/blobs/{blob_id} are raw byte operations and are NOT ApiEndpoint contracts.
// They are tracked in NON_JSON_PATHS below.

// ---------------------------------------------------------------------------
// History Sync
// ---------------------------------------------------------------------------

query_endpoint!(
    ListHistorySyncJobs,
    GET,
    "/v0/history-sync/jobs",
    NoBody,
    super::HistorySyncJobListResponse,
    super::ListHistorySyncJobsQuery
);
endpoint!(
    RequestHistorySyncRepair,
    POST,
    "/v0/history-sync/jobs:request-repair",
    super::RequestHistorySyncRepairRequest,
    super::RequestHistorySyncRepairResponse
);
endpoint!(
    RequestChatBackfill,
    POST,
    "/v0/history-sync/jobs/request",
    super::RequestChatBackfillRequest,
    super::RequestChatBackfillResponse
);

path_endpoint!(
    ListHistorySyncChunks,
    GET,
    "/v0/history-sync/jobs/{job_id}/chunks",
    NoBody,
    super::HistorySyncChunkListResponse,
    String,
    |id: &String| format!("/v0/history-sync/jobs/{}/chunks", id)
);

path_endpoint!(
    AppendHistorySyncChunk,
    POST,
    "/v0/history-sync/jobs/{job_id}/chunks",
    super::AppendHistorySyncChunkRequest,
    super::AppendHistorySyncChunkResponse,
    String,
    |id: &String| format!("/v0/history-sync/jobs/{}/chunks", id)
);

path_endpoint!(
    CompleteHistorySyncJob,
    POST,
    "/v0/history-sync/jobs/{job_id}/complete",
    super::CompleteHistorySyncJobRequest,
    super::CompleteHistorySyncJobResponse,
    String,
    |id: &String| format!("/v0/history-sync/jobs/{}/complete", id)
);

// ---------------------------------------------------------------------------
// Message Repairs
// ---------------------------------------------------------------------------

endpoint!(
    RequestMessageRepair,
    POST,
    "/v0/message-repairs:request",
    super::RequestMessageRepairWitnessRequest,
    super::RequestMessageRepairWitnessResponse
);
endpoint!(
    ListWitnessRepairs,
    GET,
    "/v0/message-repairs/witness",
    NoBody,
    super::WitnessMessageRepairRequestListResponse
);
endpoint!(
    ListTargetRepairs,
    GET,
    "/v0/message-repairs/target",
    NoBody,
    super::TargetMessageRepairRequestListResponse
);

path_endpoint!(
    SubmitRepairWitness,
    POST,
    "/v0/message-repairs/{request_id}/submit",
    super::SubmitMessageRepairWitnessResultRequest,
    super::SubmitMessageRepairWitnessResultResponse,
    String,
    |id: &String| format!("/v0/message-repairs/{}/submit", id)
);

path_endpoint!(
    CompleteRepairWitness,
    POST,
    "/v0/message-repairs/{request_id}/complete",
    super::CompleteMessageRepairWitnessRequest,
    super::CompleteMessageRepairWitnessResponse,
    String,
    |id: &String| format!("/v0/message-repairs/{}/complete", id)
);

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

endpoint!(
    AdminCreateSession,
    POST,
    "/v0/admin/session",
    super::AdminSessionRequest,
    super::AdminSessionResponse
);
endpoint!(
    AdminDeleteSession,
    DELETE,
    "/v0/admin/session",
    NoBody,
    NoResponse
);
endpoint!(
    AdminOverview,
    GET,
    "/v0/admin/overview",
    NoBody,
    super::AdminOverviewResponse
);
endpoint!(
    AdminGetRegistrationSettings,
    GET,
    "/v0/admin/settings/registration",
    NoBody,
    super::AdminRegistrationSettingsResponse
);
endpoint!(
    AdminPatchRegistrationSettings,
    PATCH,
    "/v0/admin/settings/registration",
    super::PatchAdminRegistrationSettingsRequest,
    super::AdminRegistrationSettingsResponse
);
endpoint!(
    AdminGetServerSettings,
    GET,
    "/v0/admin/settings/server",
    NoBody,
    super::AdminServerSettingsResponse
);
endpoint!(
    AdminPatchServerSettings,
    PATCH,
    "/v0/admin/settings/server",
    super::PatchAdminServerSettingsRequest,
    super::AdminServerSettingsResponse
);

query_endpoint!(
    AdminListUsers,
    GET,
    "/v0/admin/users",
    NoBody,
    super::AdminUserListResponse,
    super::AdminListUsersQuery
);
endpoint!(
    AdminCreateUserProvision,
    POST,
    "/v0/admin/users",
    super::CreateAdminUserProvisionRequest,
    super::CreateAdminUserProvisionResponse
);

path_endpoint!(
    AdminGetUser,
    GET,
    "/v0/admin/users/{account_id}",
    NoBody,
    super::AdminUserSummary,
    AccountId,
    |id: &AccountId| format!("/v0/admin/users/{}", id.0)
);

path_endpoint!(
    AdminPatchUser,
    PATCH,
    "/v0/admin/users/{account_id}",
    super::PatchAdminUserRequest,
    super::AdminUserSummary,
    AccountId,
    |id: &AccountId| format!("/v0/admin/users/{}", id.0)
);

path_endpoint!(
    AdminDisableUser,
    POST,
    "/v0/admin/users/{account_id}/disable",
    super::AdminDisableAccountRequest,
    NoResponse,
    AccountId,
    |id: &AccountId| format!("/v0/admin/users/{}/disable", id.0)
);

path_endpoint!(
    AdminReactivateUser,
    POST,
    "/v0/admin/users/{account_id}/reactivate",
    NoBody,
    NoResponse,
    AccountId,
    |id: &AccountId| format!("/v0/admin/users/{}/reactivate", id.0)
);

// Admin Feature Flags
endpoint!(
    AdminListFlagDefinitions,
    GET,
    "/v0/admin/feature-flags/definitions",
    NoBody,
    super::AdminFeatureFlagDefinitionListResponse
);
endpoint!(
    AdminCreateFlagDefinition,
    POST,
    "/v0/admin/feature-flags/definitions",
    super::CreateAdminFeatureFlagDefinitionRequest,
    super::AdminFeatureFlagDefinition
);

path_endpoint!(
    AdminGetFlagDefinition,
    GET,
    "/v0/admin/feature-flags/definitions/{flag_key}",
    NoBody,
    super::AdminFeatureFlagDefinition,
    String,
    |key: &String| format!("/v0/admin/feature-flags/definitions/{}", key)
);

path_endpoint!(
    AdminPatchFlagDefinition,
    PATCH,
    "/v0/admin/feature-flags/definitions/{flag_key}",
    super::PatchAdminFeatureFlagDefinitionRequest,
    super::AdminFeatureFlagDefinition,
    String,
    |key: &String| format!("/v0/admin/feature-flags/definitions/{}", key)
);

query_endpoint!(
    AdminListFlagOverrides,
    GET,
    "/v0/admin/feature-flags/overrides",
    NoBody,
    super::AdminFeatureFlagOverrideListResponse,
    super::AdminListFlagOverridesQuery
);
endpoint!(
    AdminCreateFlagOverride,
    POST,
    "/v0/admin/feature-flags/overrides",
    super::CreateAdminFeatureFlagOverrideRequest,
    super::AdminFeatureFlagOverride
);

path_endpoint!(
    AdminPatchFlagOverride,
    PATCH,
    "/v0/admin/feature-flags/overrides/{override_id}",
    super::PatchAdminFeatureFlagOverrideRequest,
    super::AdminFeatureFlagOverride,
    uuid::Uuid,
    |id: &uuid::Uuid| format!("/v0/admin/feature-flags/overrides/{}", id)
);

path_endpoint!(
    AdminDeleteFlagOverride,
    DELETE,
    "/v0/admin/feature-flags/overrides/{override_id}",
    NoBody,
    NoResponse,
    uuid::Uuid,
    |id: &uuid::Uuid| format!("/v0/admin/feature-flags/overrides/{}", id)
);

// Admin Debug Metrics
query_endpoint!(
    AdminListDebugMetricSessions,
    GET,
    "/v0/admin/debug/metric-sessions",
    NoBody,
    super::AdminDebugMetricSessionListResponse,
    super::AdminListDebugMetricSessionsQuery
);
endpoint!(
    AdminCreateDebugMetricSession,
    POST,
    "/v0/admin/debug/metric-sessions",
    super::CreateAdminDebugMetricSessionRequest,
    super::AdminDebugMetricSessionResponse
);

path_endpoint!(
    AdminRevokeDebugMetricSession,
    DELETE,
    "/v0/admin/debug/metric-sessions/{session_id}",
    NoBody,
    NoResponse,
    uuid::Uuid,
    |id: &uuid::Uuid| format!("/v0/admin/debug/metric-sessions/{}", id)
);

path_query_endpoint!(
    AdminListDebugMetricBatches,
    GET,
    "/v0/admin/debug/metric-sessions/{session_id}/batches",
    NoBody,
    super::AdminDebugMetricBatchListResponse,
    uuid::Uuid,
    |id: &uuid::Uuid| format!("/v0/admin/debug/metric-sessions/{}/batches", id),
    super::AdminListDebugMetricBatchesQuery
);

// Admin Logs
query_endpoint!(
    AdminListServerLogs,
    GET,
    "/v0/admin/server/logs",
    NoBody,
    super::AdminServerLogListResponse,
    super::AdminListServerLogsQuery
);

// ---------------------------------------------------------------------------
// Endpoint registry -- used by exhaustiveness tests
// ---------------------------------------------------------------------------

/// Paths for non-JSON endpoints (blob upload/download, WebSocket).
/// These are excluded from ApiEndpoint but still tracked for exhaustiveness.
pub const NON_JSON_PATHS: &[(&str, Method)] = &[
    ("/v0/blobs/{blob_id}", Method::PUT),  // blob upload (raw bytes)
    ("/v0/blobs/{blob_id}", Method::GET),  // blob download (raw bytes)
    ("/v0/blobs/{blob_id}", Method::HEAD), // blob head (headers only)
    ("/v0/ws", Method::GET),               // websocket upgrade
];

/// All JSON API endpoint paths and methods, for exhaustiveness checks.
pub const ALL_ENDPOINT_PATHS: &[(&str, Method)] = &[
    // System
    (Health::PATH, Health::METHOD),
    (Version::PATH, Version::METHOD),
    // Auth
    (AuthChallenge::PATH, AuthChallenge::METHOD),
    (AuthSession::PATH, AuthSession::METHOD),
    // Accounts
    (CreateAccount::PATH, CreateAccount::METHOD),
    (GetMe::PATH, GetMe::METHOD),
    (UpdateMe::PATH, UpdateMe::METHOD),
    (GetFeatureFlags::PATH, GetFeatureFlags::METHOD),
    (GetDebugMetricsStatus::PATH, GetDebugMetricsStatus::METHOD),
    (SubmitDebugMetrics::PATH, SubmitDebugMetrics::METHOD),
    (SearchDirectory::PATH, SearchDirectory::METHOD),
    (GetAccount::PATH, GetAccount::METHOD),
    (GetAccountKeyPackages::PATH, GetAccountKeyPackages::METHOD),
    // Devices
    (ListDevices::PATH, ListDevices::METHOD),
    (RegisterPushToken::PATH, RegisterPushToken::METHOD),
    (DeletePushToken::PATH, DeletePushToken::METHOD),
    (CreateLinkIntent::PATH, CreateLinkIntent::METHOD),
    (CompleteLinkIntent::PATH, CompleteLinkIntent::METHOD),
    (GetTransferBundle::PATH, GetTransferBundle::METHOD),
    (GetTransportKey::PATH, GetTransportKey::METHOD),
    (GetApprovePayload::PATH, GetApprovePayload::METHOD),
    (ApproveDevice::PATH, ApproveDevice::METHOD),
    (RevokeDevice::PATH, RevokeDevice::METHOD),
    // Key Packages
    (PublishKeyPackages::PATH, PublishKeyPackages::METHOD),
    (ResetKeyPackages::PATH, ResetKeyPackages::METHOD),
    (ReserveKeyPackages::PATH, ReserveKeyPackages::METHOD),
    // Chats
    (ListChats::PATH, ListChats::METHOD),
    (CreateChat::PATH, CreateChat::METHOD),
    (GetChat::PATH, GetChat::METHOD),
    (CreateMessage::PATH, CreateMessage::METHOD),
    (GetChatHistory::PATH, GetChatHistory::METHOD),
    (AddChatMembers::PATH, AddChatMembers::METHOD),
    (RemoveChatMembers::PATH, RemoveChatMembers::METHOD),
    (AddChatDevices::PATH, AddChatDevices::METHOD),
    (RemoveChatDevices::PATH, RemoveChatDevices::METHOD),
    (LeaveChat::PATH, LeaveChat::METHOD),
    (DmGlobalDelete::PATH, DmGlobalDelete::METHOD),
    // Inbox
    (GetInbox::PATH, GetInbox::METHOD),
    (LeaseInbox::PATH, LeaseInbox::METHOD),
    (AckInbox::PATH, AckInbox::METHOD),
    // Blobs
    (CreateBlobUpload::PATH, CreateBlobUpload::METHOD),
    // History Sync
    (ListHistorySyncJobs::PATH, ListHistorySyncJobs::METHOD),
    (
        RequestHistorySyncRepair::PATH,
        RequestHistorySyncRepair::METHOD,
    ),
    (RequestChatBackfill::PATH, RequestChatBackfill::METHOD),
    (ListHistorySyncChunks::PATH, ListHistorySyncChunks::METHOD),
    (AppendHistorySyncChunk::PATH, AppendHistorySyncChunk::METHOD),
    (CompleteHistorySyncJob::PATH, CompleteHistorySyncJob::METHOD),
    // Message Repairs
    (RequestMessageRepair::PATH, RequestMessageRepair::METHOD),
    (ListWitnessRepairs::PATH, ListWitnessRepairs::METHOD),
    (ListTargetRepairs::PATH, ListTargetRepairs::METHOD),
    (SubmitRepairWitness::PATH, SubmitRepairWitness::METHOD),
    (CompleteRepairWitness::PATH, CompleteRepairWitness::METHOD),
    // Admin
    (AdminCreateSession::PATH, AdminCreateSession::METHOD),
    (AdminDeleteSession::PATH, AdminDeleteSession::METHOD),
    (AdminOverview::PATH, AdminOverview::METHOD),
    (
        AdminGetRegistrationSettings::PATH,
        AdminGetRegistrationSettings::METHOD,
    ),
    (
        AdminPatchRegistrationSettings::PATH,
        AdminPatchRegistrationSettings::METHOD,
    ),
    (AdminGetServerSettings::PATH, AdminGetServerSettings::METHOD),
    (
        AdminPatchServerSettings::PATH,
        AdminPatchServerSettings::METHOD,
    ),
    (AdminListUsers::PATH, AdminListUsers::METHOD),
    (
        AdminCreateUserProvision::PATH,
        AdminCreateUserProvision::METHOD,
    ),
    (AdminGetUser::PATH, AdminGetUser::METHOD),
    (AdminPatchUser::PATH, AdminPatchUser::METHOD),
    (AdminDisableUser::PATH, AdminDisableUser::METHOD),
    (AdminReactivateUser::PATH, AdminReactivateUser::METHOD),
    // Admin Feature Flags
    (
        AdminListFlagDefinitions::PATH,
        AdminListFlagDefinitions::METHOD,
    ),
    (
        AdminCreateFlagDefinition::PATH,
        AdminCreateFlagDefinition::METHOD,
    ),
    (AdminGetFlagDefinition::PATH, AdminGetFlagDefinition::METHOD),
    (
        AdminPatchFlagDefinition::PATH,
        AdminPatchFlagDefinition::METHOD,
    ),
    (AdminListFlagOverrides::PATH, AdminListFlagOverrides::METHOD),
    (
        AdminCreateFlagOverride::PATH,
        AdminCreateFlagOverride::METHOD,
    ),
    (AdminPatchFlagOverride::PATH, AdminPatchFlagOverride::METHOD),
    (
        AdminDeleteFlagOverride::PATH,
        AdminDeleteFlagOverride::METHOD,
    ),
    // Admin Debug Metrics
    (
        AdminListDebugMetricSessions::PATH,
        AdminListDebugMetricSessions::METHOD,
    ),
    (
        AdminCreateDebugMetricSession::PATH,
        AdminCreateDebugMetricSession::METHOD,
    ),
    (
        AdminRevokeDebugMetricSession::PATH,
        AdminRevokeDebugMetricSession::METHOD,
    ),
    (
        AdminListDebugMetricBatches::PATH,
        AdminListDebugMetricBatches::METHOD,
    ),
    // Admin Logs
    (AdminListServerLogs::PATH, AdminListServerLogs::METHOD),
];
