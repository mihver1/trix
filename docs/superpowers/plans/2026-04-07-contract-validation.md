# Contract Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible to ship a client-server contract mismatch — compile errors for type drift, test failures for missing contracts and protocol violations.

**Architecture:** A `contract` module in `trix-types` declares every endpoint's path, HTTP method, request/response types via an `ApiEndpoint` trait. Generic transport methods in `trix-core` and `E::PATH` constants in `trix-server` routes link both sides to this single source of truth. A WebSocket state machine validates protocol transitions. Tests enforce exhaustiveness, serde roundtrips, and protocol correctness.

**Tech Stack:** Rust, http crate (for `Method`), proptest (for property-based WS tests), existing serde/axum/reqwest stack.

**Spec:** `docs/superpowers/specs/2026-04-07-contract-validation-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `crates/trix-types/Cargo.toml` | Modify | Add `http` dependency |
| `crates/trix-types/src/contract.rs` | Create | `ApiEndpoint` trait + all endpoint declarations |
| `crates/trix-types/src/ws_protocol.rs` | Create | WebSocket state machine |
| `crates/trix-types/src/lib.rs` | Modify | Export new modules |
| `crates/trix-types/src/api.rs` | Modify | Move query types from transport, make them public |
| `crates/trix-core/src/transport.rs` | Modify | Add generic `call_*` methods, migrate pilot endpoints |
| `crates/trix-server/src/routes/mod.rs` | Modify | Use `E::PATH` constants, add `rel()` helper |
| `crates/trix-server/src/routes/auth.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/accounts.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/devices.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/chats.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/inbox.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/key_packages.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/history_sync.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/blobs.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/message_repairs.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/admin.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/admin_feature_flags.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/admin_debug_metrics.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/admin_logs.rs` | Modify | Use `E::PATH` constants |
| `crates/trix-server/src/routes/system.rs` | No change | (routes registered in mod.rs) |
| `crates/trix-server/tests/openapi_v0_contract.rs` | Modify | Replace with contract-based exhaustiveness test |
| `crates/trix-types/tests/serde_roundtrip.rs` | Create | Serde roundtrip tests for all contract types |
| `crates/trix-types/tests/ws_protocol.rs` | Create | WebSocket state machine tests |

---

### Task 1: Contract Trait and Endpoint Declarations

**Files:**
- Modify: `crates/trix-types/Cargo.toml`
- Create: `crates/trix-types/src/contract.rs`
- Modify: `crates/trix-types/src/lib.rs`
- Modify: `crates/trix-types/src/api.rs`

- [ ] **Step 1: Add `http` dependency to trix-types**

In `crates/trix-types/Cargo.toml`, add `http` under `[dependencies]`:

```toml
[dependencies]
base64.workspace = true
http.workspace = true
serde.workspace = true
serde_json.workspace = true
uuid.workspace = true
```

- [ ] **Step 2: Move query types from transport.rs to api.rs**

The following query types are currently private in `crates/trix-core/src/transport.rs` and need to become public in `crates/trix-types/src/api.rs`. Add them at the end of `api.rs` (before the closing of file):

```rust
// --- Query parameter types (used by QueryEndpoint contracts) ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListHistorySyncJobsQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<HistorySyncJobRole>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<HistorySyncJobStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatHistoryQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub after_server_seq: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InboxQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub after_inbox_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountDirectoryQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub q: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
    pub exclude_self: bool,
}
```

Also add them to the `pub use api::{ ... }` block in `crates/trix-types/src/lib.rs`.

Then in `crates/trix-core/src/transport.rs`, remove the four private query structs (`ListHistorySyncJobsQuery`, `HistoryQuery`, `InboxQuery`, `AccountDirectoryQuery`) and import them from `trix_types` instead. Note: `HistoryQuery` in transport.rs maps to `ChatHistoryQuery` in the new api.rs — update all usages in transport.rs to use the new name `ChatHistoryQuery`.

- [ ] **Step 3: Create contract.rs with trait definitions and all endpoint declarations**

Create `crates/trix-types/src/contract.rs`:

```rust
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

endpoint!(Health, GET, "/v0/system/health", NoBody, super::HealthResponse);
endpoint!(Version, GET, "/v0/system/version", NoBody, super::VersionResponse);

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

endpoint!(AuthChallenge, POST, "/v0/auth/challenge", super::AuthChallengeRequest, super::AuthChallengeResponse);
endpoint!(AuthSession, POST, "/v0/auth/session", super::AuthSessionRequest, super::AuthSessionResponse);

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

endpoint!(CreateAccount, POST, "/v0/accounts", super::CreateAccountRequest, super::CreateAccountResponse);
endpoint!(GetMe, GET, "/v0/accounts/me", NoBody, super::AccountProfileResponse);
endpoint!(UpdateMe, PATCH, "/v0/accounts/me", super::UpdateAccountProfileRequest, super::AccountProfileResponse);
endpoint!(GetFeatureFlags, GET, "/v0/accounts/me/feature-flags", NoBody, super::AccountFeatureFlagsResponse);
endpoint!(GetDebugMetricsStatus, GET, "/v0/accounts/me/debug/metrics", NoBody, super::AccountDebugMetricsStatusResponse);
endpoint!(SubmitDebugMetrics, POST, "/v0/accounts/me/debug/metrics", super::SubmitDebugMetricsRequest, NoResponse);

query_endpoint!(SearchDirectory, GET, "/v0/accounts/directory", NoBody, super::AccountDirectoryResponse, super::AccountDirectoryQuery);

path_endpoint!(GetAccount, GET, "/v0/accounts/{account_id}", NoBody, super::DirectoryAccountSummary,
    AccountId, |id: &AccountId| format!("/v0/accounts/{}", id.0));

path_endpoint!(GetAccountKeyPackages, GET, "/v0/accounts/{account_id}/key-packages", NoBody, super::AccountKeyPackagesResponse,
    AccountId, |id: &AccountId| format!("/v0/accounts/{}/key-packages", id.0));

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

endpoint!(ListDevices, GET, "/v0/devices", NoBody, super::DeviceListResponse);
endpoint!(RegisterPushToken, PUT, "/v0/devices/push-token", super::RegisterApplePushTokenRequest, super::RegisterApplePushTokenResponse);
endpoint!(DeletePushToken, DELETE, "/v0/devices/push-token", NoBody, NoResponse);
endpoint!(CreateLinkIntent, POST, "/v0/devices/link-intents", NoBody, super::CreateLinkIntentResponse);

path_endpoint!(CompleteLinkIntent, POST, "/v0/devices/link-intents/{link_intent_id}/complete",
    super::CompleteLinkIntentRequest, super::CompleteLinkIntentResponse,
    String, |id: &String| format!("/v0/devices/link-intents/{}/complete", id));

path_endpoint!(GetTransferBundle, GET, "/v0/devices/{device_id}/transfer-bundle", NoBody, super::DeviceTransferBundleResponse,
    DeviceId, |id: &DeviceId| format!("/v0/devices/{}/transfer-bundle", id.0));

path_endpoint!(GetTransportKey, GET, "/v0/devices/{device_id}/transport-key", NoBody, super::DeviceTransportKeyResponse,
    DeviceId, |id: &DeviceId| format!("/v0/devices/{}/transport-key", id.0));

path_endpoint!(GetApprovePayload, GET, "/v0/devices/{device_id}/approve-payload", NoBody, super::DeviceApprovePayloadResponse,
    DeviceId, |id: &DeviceId| format!("/v0/devices/{}/approve-payload", id.0));

path_endpoint!(ApproveDevice, POST, "/v0/devices/{device_id}/approve",
    super::ApproveDeviceRequest, super::ApproveDeviceResponse,
    DeviceId, |id: &DeviceId| format!("/v0/devices/{}/approve", id.0));

path_endpoint!(RevokeDevice, POST, "/v0/devices/{device_id}/revoke",
    super::RevokeDeviceRequest, super::RevokeDeviceResponse,
    DeviceId, |id: &DeviceId| format!("/v0/devices/{}/revoke", id.0));

// ---------------------------------------------------------------------------
// Key Packages
// ---------------------------------------------------------------------------

endpoint!(PublishKeyPackages, POST, "/v0/key-packages:publish", super::PublishKeyPackagesRequest, super::PublishKeyPackagesResponse);
endpoint!(ResetKeyPackages, POST, "/v0/key-packages:reset", NoBody, super::ResetKeyPackagesResponse);
endpoint!(ReserveKeyPackages, POST, "/v0/key-packages:reserve", super::ReserveKeyPackagesRequest, super::AccountKeyPackagesResponse);

// ---------------------------------------------------------------------------
// Chats
// ---------------------------------------------------------------------------

endpoint!(ListChats, GET, "/v0/chats", NoBody, super::ChatListResponse);
endpoint!(CreateChat, POST, "/v0/chats", super::CreateChatRequest, super::CreateChatResponse);

path_endpoint!(GetChat, GET, "/v0/chats/{chat_id}", NoBody, super::ChatDetailResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}", id.0));

path_endpoint!(CreateMessage, POST, "/v0/chats/{chat_id}/messages",
    super::CreateMessageRequest, super::CreateMessageResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/messages", id.0));

path_query_endpoint!(GetChatHistory, GET, "/v0/chats/{chat_id}/history", NoBody, super::ChatHistoryResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/history", id.0),
    super::ChatHistoryQuery);

path_endpoint!(AddChatMembers, POST, "/v0/chats/{chat_id}/members:add",
    super::ModifyChatMembersRequest, super::ModifyChatMembersResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/members:add", id.0));

path_endpoint!(RemoveChatMembers, POST, "/v0/chats/{chat_id}/members:remove",
    super::ModifyChatMembersRequest, super::ModifyChatMembersResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/members:remove", id.0));

path_endpoint!(AddChatDevices, POST, "/v0/chats/{chat_id}/devices:add",
    super::ModifyChatDevicesRequest, super::ModifyChatDevicesResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/devices:add", id.0));

path_endpoint!(RemoveChatDevices, POST, "/v0/chats/{chat_id}/devices:remove",
    super::ModifyChatDevicesRequest, super::ModifyChatDevicesResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/devices:remove", id.0));

path_endpoint!(LeaveChat, POST, "/v0/chats/{chat_id}/leave",
    super::LeaveChatRequest, super::LeaveChatResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/leave", id.0));

path_endpoint!(DmGlobalDelete, POST, "/v0/chats/{chat_id}/dm-global-delete",
    super::DmGlobalDeleteRequest, super::DmGlobalDeleteResponse,
    ChatId, |id: &ChatId| format!("/v0/chats/{}/dm-global-delete", id.0));

// ---------------------------------------------------------------------------
// Inbox
// ---------------------------------------------------------------------------

query_endpoint!(GetInbox, GET, "/v0/inbox", NoBody, super::InboxResponse, super::InboxQuery);
endpoint!(LeaseInbox, POST, "/v0/inbox/lease", super::LeaseInboxRequest, super::LeaseInboxResponse);
endpoint!(AckInbox, POST, "/v0/inbox/ack", super::AckInboxRequest, super::AckInboxResponse);

// ---------------------------------------------------------------------------
// Blobs (only the JSON endpoints — upload/download are raw bytes)
// ---------------------------------------------------------------------------

endpoint!(CreateBlobUpload, POST, "/v0/blobs/uploads", super::CreateBlobUploadRequest, super::CreateBlobUploadResponse);

// Note: PUT /v0/blobs/{blob_id} (upload), GET /v0/blobs/{blob_id} (download),
// HEAD /v0/blobs/{blob_id} are raw byte operations and are NOT ApiEndpoint contracts.
// They are tracked in NON_JSON_PATHS below.

// ---------------------------------------------------------------------------
// History Sync
// ---------------------------------------------------------------------------

query_endpoint!(ListHistorySyncJobs, GET, "/v0/history-sync/jobs", NoBody, super::HistorySyncJobListResponse, super::ListHistorySyncJobsQuery);
endpoint!(RequestHistorySyncRepair, POST, "/v0/history-sync/jobs:request-repair", super::RequestHistorySyncRepairRequest, super::RequestHistorySyncRepairResponse);
endpoint!(RequestChatBackfill, POST, "/v0/history-sync/jobs/request", super::RequestChatBackfillRequest, super::RequestChatBackfillResponse);

path_endpoint!(ListHistorySyncChunks, GET, "/v0/history-sync/jobs/{job_id}/chunks", NoBody, super::HistorySyncChunkListResponse,
    String, |id: &String| format!("/v0/history-sync/jobs/{}/chunks", id));

path_endpoint!(AppendHistorySyncChunk, POST, "/v0/history-sync/jobs/{job_id}/chunks",
    super::AppendHistorySyncChunkRequest, super::AppendHistorySyncChunkResponse,
    String, |id: &String| format!("/v0/history-sync/jobs/{}/chunks", id));

path_endpoint!(CompleteHistorySyncJob, POST, "/v0/history-sync/jobs/{job_id}/complete",
    super::CompleteHistorySyncJobRequest, super::CompleteHistorySyncJobResponse,
    String, |id: &String| format!("/v0/history-sync/jobs/{}/complete", id));

// ---------------------------------------------------------------------------
// Message Repairs
// ---------------------------------------------------------------------------

endpoint!(RequestMessageRepair, POST, "/v0/message-repairs:request", super::RequestMessageRepairWitnessRequest, super::RequestMessageRepairWitnessResponse);
endpoint!(ListWitnessRepairs, GET, "/v0/message-repairs/witness", NoBody, super::WitnessMessageRepairRequestListResponse);
endpoint!(ListTargetRepairs, GET, "/v0/message-repairs/target", NoBody, super::TargetMessageRepairRequestListResponse);

path_endpoint!(SubmitRepairWitness, POST, "/v0/message-repairs/{request_id}/submit",
    super::SubmitMessageRepairWitnessResultRequest, super::SubmitMessageRepairWitnessResultResponse,
    String, |id: &String| format!("/v0/message-repairs/{}/submit", id));

path_endpoint!(CompleteRepairWitness, POST, "/v0/message-repairs/{request_id}/complete",
    super::CompleteMessageRepairWitnessRequest, super::CompleteMessageRepairWitnessResponse,
    String, |id: &String| format!("/v0/message-repairs/{}/complete", id));

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

endpoint!(AdminCreateSession, POST, "/v0/admin/session", super::AdminSessionRequest, super::AdminSessionResponse);
endpoint!(AdminDeleteSession, DELETE, "/v0/admin/session", NoBody, NoResponse);
endpoint!(AdminOverview, GET, "/v0/admin/overview", NoBody, super::AdminOverviewResponse);
endpoint!(AdminGetRegistrationSettings, GET, "/v0/admin/settings/registration", NoBody, super::AdminRegistrationSettingsResponse);
endpoint!(AdminPatchRegistrationSettings, PATCH, "/v0/admin/settings/registration", super::PatchAdminRegistrationSettingsRequest, super::AdminRegistrationSettingsResponse);
endpoint!(AdminGetServerSettings, GET, "/v0/admin/settings/server", NoBody, super::AdminServerSettingsResponse);
endpoint!(AdminPatchServerSettings, PATCH, "/v0/admin/settings/server", super::PatchAdminServerSettingsRequest, super::AdminServerSettingsResponse);

query_endpoint!(AdminListUsers, GET, "/v0/admin/users", NoBody, super::AdminUserListResponse, super::AdminListUsersQuery);
endpoint!(AdminCreateUserProvision, POST, "/v0/admin/users", super::CreateAdminUserProvisionRequest, super::CreateAdminUserProvisionResponse);

path_endpoint!(AdminGetUser, GET, "/v0/admin/users/{account_id}", NoBody, super::AdminUserSummary,
    AccountId, |id: &AccountId| format!("/v0/admin/users/{}", id.0));

path_endpoint!(AdminPatchUser, PATCH, "/v0/admin/users/{account_id}",
    super::PatchAdminUserRequest, super::AdminUserSummary,
    AccountId, |id: &AccountId| format!("/v0/admin/users/{}", id.0));

path_endpoint!(AdminDisableUser, POST, "/v0/admin/users/{account_id}/disable",
    super::AdminDisableAccountRequest, NoResponse,
    AccountId, |id: &AccountId| format!("/v0/admin/users/{}/disable", id.0));

path_endpoint!(AdminReactivateUser, POST, "/v0/admin/users/{account_id}/reactivate",
    NoBody, NoResponse,
    AccountId, |id: &AccountId| format!("/v0/admin/users/{}/reactivate", id.0));

// Admin Feature Flags
endpoint!(AdminListFlagDefinitions, GET, "/v0/admin/feature-flags/definitions", NoBody, super::AdminFeatureFlagDefinitionListResponse);
endpoint!(AdminCreateFlagDefinition, POST, "/v0/admin/feature-flags/definitions", super::CreateAdminFeatureFlagDefinitionRequest, super::AdminFeatureFlagDefinition);

path_endpoint!(AdminGetFlagDefinition, GET, "/v0/admin/feature-flags/definitions/{flag_key}", NoBody, super::AdminFeatureFlagDefinition,
    String, |key: &String| format!("/v0/admin/feature-flags/definitions/{}", key));

path_endpoint!(AdminPatchFlagDefinition, PATCH, "/v0/admin/feature-flags/definitions/{flag_key}",
    super::PatchAdminFeatureFlagDefinitionRequest, super::AdminFeatureFlagDefinition,
    String, |key: &String| format!("/v0/admin/feature-flags/definitions/{}", key));

query_endpoint!(AdminListFlagOverrides, GET, "/v0/admin/feature-flags/overrides", NoBody, super::AdminFeatureFlagOverrideListResponse, super::AdminListFlagOverridesQuery);
endpoint!(AdminCreateFlagOverride, POST, "/v0/admin/feature-flags/overrides", super::CreateAdminFeatureFlagOverrideRequest, super::AdminFeatureFlagOverride);

path_endpoint!(AdminPatchFlagOverride, PATCH, "/v0/admin/feature-flags/overrides/{override_id}",
    super::PatchAdminFeatureFlagOverrideRequest, super::AdminFeatureFlagOverride,
    uuid::Uuid, |id: &uuid::Uuid| format!("/v0/admin/feature-flags/overrides/{}", id));

path_endpoint!(AdminDeleteFlagOverride, DELETE, "/v0/admin/feature-flags/overrides/{override_id}",
    NoBody, NoResponse,
    uuid::Uuid, |id: &uuid::Uuid| format!("/v0/admin/feature-flags/overrides/{}", id));

// Admin Debug Metrics
query_endpoint!(AdminListDebugMetricSessions, GET, "/v0/admin/debug/metric-sessions", NoBody, super::AdminDebugMetricSessionListResponse, super::AdminListDebugMetricSessionsQuery);
endpoint!(AdminCreateDebugMetricSession, POST, "/v0/admin/debug/metric-sessions", super::CreateAdminDebugMetricSessionRequest, super::AdminDebugMetricSessionResponse);

path_endpoint!(AdminRevokeDebugMetricSession, DELETE, "/v0/admin/debug/metric-sessions/{session_id}",
    NoBody, NoResponse,
    uuid::Uuid, |id: &uuid::Uuid| format!("/v0/admin/debug/metric-sessions/{}", id));

path_query_endpoint!(AdminListDebugMetricBatches, GET, "/v0/admin/debug/metric-sessions/{session_id}/batches",
    NoBody, super::AdminDebugMetricBatchListResponse,
    uuid::Uuid, |id: &uuid::Uuid| format!("/v0/admin/debug/metric-sessions/{}/batches", id),
    super::AdminListDebugMetricBatchesQuery);

// Admin Logs
endpoint!(AdminListServerLogs, GET, "/v0/admin/server/logs", NoBody, super::AdminServerLogListResponse);

// ---------------------------------------------------------------------------
// Endpoint registry — used by exhaustiveness tests
// ---------------------------------------------------------------------------

/// Paths for non-JSON endpoints (blob upload/download, WebSocket).
/// These are excluded from ApiEndpoint but still tracked for exhaustiveness.
pub const NON_JSON_PATHS: &[(&str, Method)] = &[
    ("/v0/blobs/{blob_id}", Method::PUT),    // blob upload (raw bytes)
    ("/v0/blobs/{blob_id}", Method::GET),    // blob download (raw bytes)
    ("/v0/blobs/{blob_id}", Method::HEAD),   // blob head (headers only)
    ("/v0/ws", Method::GET),                 // websocket upgrade
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
    (RequestHistorySyncRepair::PATH, RequestHistorySyncRepair::METHOD),
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
    (AdminGetRegistrationSettings::PATH, AdminGetRegistrationSettings::METHOD),
    (AdminPatchRegistrationSettings::PATH, AdminPatchRegistrationSettings::METHOD),
    (AdminGetServerSettings::PATH, AdminGetServerSettings::METHOD),
    (AdminPatchServerSettings::PATH, AdminPatchServerSettings::METHOD),
    (AdminListUsers::PATH, AdminListUsers::METHOD),
    (AdminCreateUserProvision::PATH, AdminCreateUserProvision::METHOD),
    (AdminGetUser::PATH, AdminGetUser::METHOD),
    (AdminPatchUser::PATH, AdminPatchUser::METHOD),
    (AdminDisableUser::PATH, AdminDisableUser::METHOD),
    (AdminReactivateUser::PATH, AdminReactivateUser::METHOD),
    // Admin Feature Flags
    (AdminListFlagDefinitions::PATH, AdminListFlagDefinitions::METHOD),
    (AdminCreateFlagDefinition::PATH, AdminCreateFlagDefinition::METHOD),
    (AdminGetFlagDefinition::PATH, AdminGetFlagDefinition::METHOD),
    (AdminPatchFlagDefinition::PATH, AdminPatchFlagDefinition::METHOD),
    (AdminListFlagOverrides::PATH, AdminListFlagOverrides::METHOD),
    (AdminCreateFlagOverride::PATH, AdminCreateFlagOverride::METHOD),
    (AdminPatchFlagOverride::PATH, AdminPatchFlagOverride::METHOD),
    (AdminDeleteFlagOverride::PATH, AdminDeleteFlagOverride::METHOD),
    // Admin Debug Metrics
    (AdminListDebugMetricSessions::PATH, AdminListDebugMetricSessions::METHOD),
    (AdminCreateDebugMetricSession::PATH, AdminCreateDebugMetricSession::METHOD),
    (AdminRevokeDebugMetricSession::PATH, AdminRevokeDebugMetricSession::METHOD),
    (AdminListDebugMetricBatches::PATH, AdminListDebugMetricBatches::METHOD),
    // Admin Logs
    (AdminListServerLogs::PATH, AdminListServerLogs::METHOD),
];
```

**Important:** Some admin query types (`AdminListUsersQuery`, `AdminListFlagOverridesQuery`, `AdminListDebugMetricSessionsQuery`, `AdminListDebugMetricBatchesQuery`) may be currently private in admin route files. If they are, add public versions to `api.rs` following the same pattern as the other query types. Check each admin route file's handler to see what `Query<T>` type it uses and replicate that struct in `api.rs`. If the server uses an inline query type, create a named public struct for it.

If any admin query types are NOT found in the server code (meaning the endpoint uses no query params), replace `query_endpoint!` with `endpoint!` for those.

- [ ] **Step 4: Export contract module from lib.rs**

In `crates/trix-types/src/lib.rs`, add:

```rust
pub mod contract;
```

Also add the new query types to the existing `pub use api::{ ... }` block.

- [ ] **Step 5: Verify compilation**

Run: `cargo check -p trix-types`

Expected: compiles successfully.

- [ ] **Step 6: Verify the whole workspace compiles**

Run: `cargo check --workspace`

Expected: compiles successfully (transport.rs query type imports may need updating).

- [ ] **Step 7: Commit**

```bash
git add crates/trix-types/
git commit -m "feat: add ApiEndpoint contract trait with all endpoint declarations"
```

---

### Task 2: Generic Transport Methods

**Files:**
- Modify: `crates/trix-core/src/transport.rs`

**Depends on:** Task 1

- [ ] **Step 1: Add generic call methods to ServerApiClient**

In `crates/trix-core/src/transport.rs`, add these methods to the `impl ServerApiClient` block (after the existing `request()` helper, before `send_json()`):

```rust
    // --- Generic contract-based call methods ---

    /// Call a simple endpoint (no path params, no query params).
    /// For POST/PUT/PATCH: sends `request` as JSON body.
    /// For GET/DELETE with NoBody: sends no body.
    pub async fn call<E>(&self, request: &E::Request) -> Result<E::Response, ServerApiError>
    where
        E: trix_types::contract::ApiEndpoint,
    {
        let path = E::PATH.trim_start_matches('/');
        let mut builder = self.request(E::METHOD.clone(), path)?;
        // Only attach JSON body for non-unit request types.
        // serde_json serializes () as "null" — we skip it.
        if std::mem::size_of::<E::Request>() > 0 {
            builder = builder.json(request);
        }
        self.send_json(builder).await
    }

    /// Call an endpoint that returns no JSON body (204 No Content).
    pub async fn call_empty<E>(&self, request: &E::Request) -> Result<(), ServerApiError>
    where
        E: trix_types::contract::ApiEndpoint<Response = trix_types::contract::NoResponse>,
    {
        let path = E::PATH.trim_start_matches('/');
        let mut builder = self.request(E::METHOD.clone(), path)?;
        if std::mem::size_of::<E::Request>() > 0 {
            builder = builder.json(request);
        }
        self.send_empty(builder).await
    }

    /// Call an endpoint with path parameters (no body).
    pub async fn call_path<E>(&self, params: &E::PathParams) -> Result<E::Response, ServerApiError>
    where
        E: trix_types::contract::PathEndpoint<Request = trix_types::contract::NoBody>,
    {
        let path = E::render_path(params);
        let path = path.trim_start_matches('/');
        let builder = self.request(E::METHOD.clone(), path)?;
        self.send_json(builder).await
    }

    /// Call an endpoint with path parameters and a JSON body.
    pub async fn call_path_body<E>(
        &self,
        params: &E::PathParams,
        request: &E::Request,
    ) -> Result<E::Response, ServerApiError>
    where
        E: trix_types::contract::PathEndpoint,
    {
        let path = E::render_path(params);
        let path = path.trim_start_matches('/');
        let builder = self.request(E::METHOD.clone(), path)?.json(request);
        self.send_json(builder).await
    }

    /// Call an endpoint with path parameters, returning no JSON body.
    pub async fn call_path_empty<E>(
        &self,
        params: &E::PathParams,
        request: &E::Request,
    ) -> Result<(), ServerApiError>
    where
        E: trix_types::contract::PathEndpoint<Response = trix_types::contract::NoResponse>,
    {
        let path = E::render_path(params);
        let path = path.trim_start_matches('/');
        let mut builder = self.request(E::METHOD.clone(), path)?;
        if std::mem::size_of::<E::Request>() > 0 {
            builder = builder.json(request);
        }
        self.send_empty(builder).await
    }

    /// Call an endpoint with query parameters (no body, no path params).
    pub async fn call_query<E>(&self, query: &E::Query) -> Result<E::Response, ServerApiError>
    where
        E: trix_types::contract::QueryEndpoint<Request = trix_types::contract::NoBody>,
    {
        let path = E::PATH.trim_start_matches('/');
        let builder = self.request(E::METHOD.clone(), path)?.query(query);
        self.send_json(builder).await
    }

    /// Call an endpoint with both path and query parameters (no body).
    pub async fn call_path_query<E>(
        &self,
        params: &E::PathParams,
        query: &E::Query,
    ) -> Result<E::Response, ServerApiError>
    where
        E: trix_types::contract::PathEndpoint<Request = trix_types::contract::NoBody> + trix_types::contract::QueryEndpoint,
    {
        let path = E::render_path(params);
        let path = path.trim_start_matches('/');
        let builder = self.request(E::METHOD.clone(), path)?.query(query);
        self.send_json(builder).await
    }
```

- [ ] **Step 2: Migrate 3 pilot endpoints to use generic calls**

Replace the implementations of `get_health`, `get_version`, and `create_auth_session` to use the new generic methods, while keeping the same public API:

```rust
    pub async fn get_health(&self) -> Result<HealthResponse, ServerApiError> {
        self.call::<trix_types::contract::Health>(&()).await
    }

    pub async fn get_version(&self) -> Result<VersionResponse, ServerApiError> {
        self.call::<trix_types::contract::Version>(&()).await
    }

    pub async fn create_auth_session(
        &self,
        device_id: DeviceId,
        challenge_id: impl Into<String>,
        signature: &[u8],
    ) -> Result<trix_types::AuthSessionResponse, ServerApiError> {
        self.call::<trix_types::contract::AuthSession>(&trix_types::AuthSessionRequest {
            device_id,
            challenge_id: challenge_id.into(),
            signature_b64: encode_b64(signature),
        })
        .await
    }
```

- [ ] **Step 3: Verify compilation**

Run: `cargo check -p trix-core`

Expected: compiles successfully.

- [ ] **Step 4: Run existing tests to verify no regressions**

Run: `cargo test -p trix-core --lib`

Expected: all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add crates/trix-core/src/transport.rs
git commit -m "feat: add generic contract-based transport methods, migrate 3 pilot endpoints"
```

---

### Task 3: Server Routes Use Contract PATH Constants

**Files:**
- Modify: `crates/trix-server/src/routes/mod.rs`
- Modify: `crates/trix-server/src/routes/auth.rs`
- Modify: `crates/trix-server/src/routes/accounts.rs`
- Modify: `crates/trix-server/src/routes/devices.rs`
- Modify: `crates/trix-server/src/routes/chats.rs`
- Modify: `crates/trix-server/src/routes/inbox.rs`
- Modify: `crates/trix-server/src/routes/key_packages.rs`
- Modify: `crates/trix-server/src/routes/history_sync.rs`
- Modify: `crates/trix-server/src/routes/blobs.rs`
- Modify: `crates/trix-server/src/routes/message_repairs.rs`
- Modify: `crates/trix-server/src/routes/admin.rs`
- Modify: `crates/trix-server/src/routes/admin_feature_flags.rs`
- Modify: `crates/trix-server/src/routes/admin_debug_metrics.rs`
- Modify: `crates/trix-server/src/routes/admin_logs.rs`

**Depends on:** Task 1

**Approach:** Each server route module currently registers routes with string literal paths (e.g. `.route("/challenge", post(challenge))`). We replace these strings with `E::PATH` constants from the contract. Routes registered in nested routers use **relative paths** (the prefix is added by `.nest()`), so we need a helper to strip the prefix.

**Important design note:** The `v0_router()` in `mod.rs` uses `.nest("/auth", auth::router())` which means `auth::router()` registers routes with **relative** paths like `"/challenge"`, not absolute `/v0/auth/challenge`. The contract `PATH` constants are absolute (e.g. `/v0/auth/challenge`). So in each sub-router, we strip the nesting prefix when using the contract constant. We'll use a helper for this.

- [ ] **Step 1: Add a path helper for nested routes**

In `crates/trix-server/src/routes/mod.rs`, add this helper at the top (after imports):

```rust
use trix_types::contract;

/// Strip a nesting prefix from an absolute contract path to get the relative path
/// expected by Axum's `.nest()` combinator.
///
/// Example: `relative_path("/v0/auth", contract::AuthChallenge::PATH)` → `"/challenge"`
fn relative_path(prefix: &str, absolute: &str) -> &str {
    absolute
        .strip_prefix(prefix)
        .unwrap_or_else(|| panic!("contract path {absolute} does not start with prefix {prefix}"))
}
```

Wait — this returns `&str` but `absolute` is a `&'static str` so we can return `&'static str`. But actually Axum's `.route()` takes `&str`, and since `PATH` is `&'static str`, the stripped version is also `&'static str`. However `strip_prefix` returns a borrowed slice of the same lifetime. This works.

Actually, the simpler approach is to just use the stripped paths inline. For the very first implementation, let's use a macro:

```rust
/// Strips a compile-time prefix from a contract PATH constant.
macro_rules! rel {
    ($prefix:expr, $endpoint:ty) => {
        <$endpoint as trix_types::contract::ApiEndpoint>::PATH
            .strip_prefix($prefix)
            .expect(concat!(
                "contract path does not start with prefix: ",
                stringify!($endpoint)
            ))
    };
}
```

Add this macro in `crates/trix-server/src/routes/mod.rs` before `v0_router()`. Since route modules use `super::rel!`, make it `pub(crate)` or just define it in each module. The simplest approach: define it as `macro_rules!` in `mod.rs` before the submodule declarations so it's available in submodules.

Actually in Rust 2024 edition, `macro_rules!` defined in a parent module are NOT automatically available in submodules by default. The simplest approach is to place this macro in a separate file and `#[macro_use]` include it, or just define a function.

Let's use a const function instead:

```rust
// In mod.rs, after imports:
/// Strip a nesting prefix from an absolute contract path.
/// Panics if the path doesn't start with the prefix.
pub(crate) fn strip_prefix(prefix: &str, path: &'static str) -> &'static str {
    // Can't use strip_prefix in const, but this works at runtime during router construction.
    let prefix_bytes = prefix.as_bytes();
    let path_bytes = path.as_bytes();
    assert!(
        path_bytes.len() >= prefix_bytes.len(),
        "contract path is shorter than prefix"
    );
    let mut i = 0;
    while i < prefix_bytes.len() {
        assert!(
            path_bytes[i] == prefix_bytes[i],
            "contract path does not match prefix"
        );
        i += 1;
    }
    // Safety: we've verified the prefix matches, and both are valid UTF-8 &str
    // The result points into the 'static PATH string.
    unsafe { std::str::from_utf8_unchecked(&path_bytes[prefix_bytes.len()..]) }
}
```

Actually this is way overcomplicating it. Since `strip_prefix` returns `Option<&str>` and the input is `&'static str`, the result is also `&'static str`. Let's just use a simple helper:

```rust
pub(crate) fn rel(prefix: &str, path: &'static str) -> &'static str {
    // strip_prefix on &'static str returns &'static str
    path.strip_prefix(prefix)
        .unwrap_or_else(|| panic!("contract path `{path}` doesn't start with `{prefix}`"))
}
```

Wait, that won't work either because `strip_prefix` takes `&str` (not `&'static str`) and returns an `Option<&str>` with the lifetime of `self`, which is `'static` since `path` is `&'static str`. So this should work. Let me verify: yes, `str::strip_prefix` returns `Option<&'a str>` where `'a` is the lifetime of `self`, so if `self: &'static str`, the result is `&'static str`. Good.

- [ ] **Step 2: Update mod.rs to use contract PATH constants**

Replace `crates/trix-server/src/routes/mod.rs`:

```rust
use axum::{Json, Router, routing::get};
use serde_json::{Value, json};
use trix_types::contract::{self, ApiEndpoint};

pub mod accounts;
pub mod admin;
pub mod admin_debug_metrics;
pub mod admin_feature_flags;
pub mod admin_logs;
pub mod auth;
pub mod blobs;
pub mod chats;
pub mod devices;
pub mod history_sync;
pub mod inbox;
pub mod key_packages;
pub mod message_repairs;
pub mod system;
pub mod ws;

/// Strip a nesting prefix from an absolute contract path to get the relative
/// path expected by axum's `.nest()`.
pub(crate) fn rel(prefix: &str, path: &'static str) -> &'static str {
    path.strip_prefix(prefix)
        .unwrap_or_else(|| panic!("contract path `{path}` doesn't start with `{prefix}`"))
}

pub async fn root() -> Json<Value> {
    Json(json!({
        "service": "trixd",
        "status": "ok",
        "api_base": "/v0"
    }))
}

pub fn v0_router() -> Router<crate::state::AppState> {
    Router::new()
        .route(contract::Health::PATH, get(system::health))
        .route(contract::Version::PATH, get(system::version))
        .nest("/auth", auth::router())
        .nest("/admin", admin::router())
        .nest("/accounts", accounts::router())
        .nest("/devices", devices::router())
        .nest("/chats", chats::router())
        .nest("/history-sync", history_sync::router())
        .merge(message_repairs::router())
        .merge(inbox::router())
        .merge(key_packages::router())
        .nest("/blobs", blobs::router())
        .merge(ws::router())
}
```

Note: `Health::PATH` is `/v0/system/health` but `v0_router()` is already nested under `/v0` by the app. Wait — let me check. Looking at the original `mod.rs`, the routes are `.route("/system/health", ...)`. And in `app.rs`, the router is nested at `/v0`. So the routes are RELATIVE to `/v0`.

That means `Health::PATH = "/v0/system/health"` needs to become `"/system/health"` in `v0_router()`. So we need `rel("/v0", contract::Health::PATH)`.

Updated approach:

```rust
pub fn v0_router() -> Router<crate::state::AppState> {
    Router::new()
        .route(rel("/v0", contract::Health::PATH), get(system::health))
        .route(rel("/v0", contract::Version::PATH), get(system::version))
        .nest("/auth", auth::router())
        // ... rest unchanged
}
```

- [ ] **Step 3: Update each sub-router to use contract PATH constants**

For each route file, replace string literal paths with `rel()` calls. Example for `auth.rs`:

```rust
// Before:
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/challenge", post(challenge))
        .route("/session", post(session))
}

// After:
pub fn router() -> Router<AppState> {
    use trix_types::contract::{self, ApiEndpoint};
    Router::new()
        .route(super::rel("/v0/auth", contract::AuthChallenge::PATH), post(challenge))
        .route(super::rel("/v0/auth", contract::AuthSession::PATH), post(session))
}
```

Apply the same pattern to every route file:
- `accounts.rs` — prefix `/v0/accounts`
- `devices.rs` — prefix `/v0/devices`
- `chats.rs` — prefix `/v0/chats`
- `inbox.rs` — prefix `/v0` (merged, not nested)
- `key_packages.rs` — prefix `/v0` (merged, not nested)
- `history_sync.rs` — prefix `/v0/history-sync`
- `blobs.rs` — prefix `/v0/blobs`
- `message_repairs.rs` — prefix `/v0` (merged, not nested)
- `admin.rs` — prefix `/v0/admin`
- `admin_feature_flags.rs` — prefix `/v0/admin` (check nesting)
- `admin_debug_metrics.rs` — prefix `/v0/admin` (check nesting)
- `admin_logs.rs` — prefix `/v0/admin` (check nesting)

For non-JSON routes (blobs PUT/GET/HEAD, ws GET), keep string literals since they're not in the contract.

**Crucial:** read each route file to determine the exact nesting prefix before making changes. The prefix depends on how `v0_router()` nests/merges that router.

- [ ] **Step 4: Verify compilation**

Run: `cargo check -p trix-server`

Expected: compiles successfully.

- [ ] **Step 5: Run existing tests**

Run: `cargo test -p trix-server --lib`

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add crates/trix-server/src/routes/
git commit -m "refactor: use contract PATH constants in server route registration"
```

---

### Task 4: Contract Exhaustiveness Test

**Files:**
- Modify: `crates/trix-server/tests/openapi_v0_contract.rs`

**Depends on:** Task 1, Task 3

- [ ] **Step 1: Rewrite the contract test**

Replace the content of `crates/trix-server/tests/openapi_v0_contract.rs` with a test that verifies all server routes have corresponding contract declarations. Keep the existing route-extraction logic (it works well), but compare against `ALL_ENDPOINT_PATHS` + `NON_JSON_PATHS` instead of the OpenAPI YAML.

```rust
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::PathBuf;

use http::Method;
use trix_types::contract::{ALL_ENDPOINT_PATHS, NON_JSON_PATHS};

// --- Route extraction from source code (keep existing logic) ---

fn routes_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/routes")
}

fn route_source(module: &str) -> String {
    let path = routes_dir().join(format!("{module}.rs"));
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()))
}

fn collect_invocations(source: &str, needle: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;
    while let Some(found) = source[offset..].find(needle) {
        let start = offset + found + needle.len();
        let mut depth = 1i32;
        let mut end = start;
        for (relative_index, ch) in source[start..].char_indices() {
            match ch {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        end = start + relative_index;
                        break;
                    }
                }
                _ => {}
            }
        }
        assert!(depth == 0, "unterminated invocation for {needle}");
        out.push(source[start..end].trim().to_owned());
        offset = end + 1;
    }
    out
}

fn split_top_level_args(invocation: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut depth = 0i32;
    let mut start = 0usize;
    for (index, ch) in invocation.char_indices() {
        match ch {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                args.push(invocation[start..index].trim().to_owned());
                start = index + 1;
            }
            _ => {}
        }
    }
    args.push(invocation[start..].trim().to_owned());
    args
}

fn first_string_literal(input: &str) -> Option<String> {
    let start = input.find('"')?;
    let rest = &input[start + 1..];
    let end = rest.find('"')?;
    Some(rest[..end].to_owned())
}

fn module_name(expr: &str) -> Option<String> {
    expr.trim()
        .strip_suffix("::router()")
        .map(str::trim)
        .map(ToOwned::to_owned)
}

fn http_methods(expr: &str) -> BTreeSet<String> {
    [
        ("get(", "GET"),
        ("post(", "POST"),
        ("put(", "PUT"),
        ("patch(", "PATCH"),
        ("delete(", "DELETE"),
        ("head(", "HEAD"),
    ]
    .into_iter()
    .filter_map(|(needle, method)| expr.contains(needle).then(|| method.to_owned()))
    .collect()
}

fn join_paths(prefix: &str, path: &str) -> String {
    if prefix.is_empty() {
        return path.to_owned();
    }
    if path == "/" {
        return prefix.to_owned();
    }
    format!("{}{}", prefix.trim_end_matches('/'), path)
}

fn merge_path_methods(
    target: &mut BTreeMap<String, BTreeSet<String>>,
    source: BTreeMap<String, BTreeSet<String>>,
) {
    for (path, methods) in source {
        target.entry(path).or_default().extend(methods);
    }
}

fn source_route_path_methods(module: &str, prefix: &str) -> BTreeMap<String, BTreeSet<String>> {
    let source = route_source(module);
    let mut out = BTreeMap::<String, BTreeSet<String>>::new();

    for route in collect_invocations(&source, ".route(") {
        let args = split_top_level_args(&route);
        // The first arg may be a string literal OR a rel() call referencing a contract path.
        // Extract the effective path string in either case.
        let route_path = if let Some(literal) = first_string_literal(&args[0]) {
            literal
        } else {
            // rel() call — skip, the contract check covers this
            continue;
        };
        let methods = http_methods(args.get(1).map(String::as_str).unwrap_or_default());
        out.entry(join_paths(prefix, &route_path))
            .or_default()
            .extend(methods);
    }

    for nest in collect_invocations(&source, ".nest(") {
        let args = split_top_level_args(&nest);
        let nested_prefix = join_paths(
            prefix,
            &first_string_literal(&args[0])
                .unwrap_or_else(|| panic!("nest invocation missing path literal: {nest}")),
        );
        let nested_module = module_name(args.get(1).map(String::as_str).unwrap_or_default())
            .unwrap_or_else(|| panic!("nest invocation missing module router(): {nest}"));
        merge_path_methods(
            &mut out,
            source_route_path_methods(&nested_module, &nested_prefix),
        );
    }

    for merge in collect_invocations(&source, ".merge(") {
        let args = split_top_level_args(&merge);
        let merged_module = module_name(args.first().map(String::as_str).unwrap_or_default())
            .unwrap_or_else(|| panic!("merge invocation missing module router(): {merge}"));
        merge_path_methods(&mut out, source_route_path_methods(&merged_module, prefix));
    }

    out
}

fn server_route_path_methods() -> BTreeMap<String, BTreeSet<String>> {
    source_route_path_methods("mod", "/v0")
}

/// Normalize a contract path template for comparison with server routes.
/// Contract paths use `{param}` placeholders, server routes use `:param`.
/// Both should match structurally.
fn normalize_path(path: &str) -> String {
    // Replace {param_name} with :param_name for consistent comparison
    let mut result = String::new();
    let mut chars = path.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '{' {
            result.push(':');
            while let Some(&next) = chars.peek() {
                if next == '}' {
                    chars.next();
                    break;
                }
                result.push(next);
                chars.next();
            }
        } else {
            result.push(ch);
        }
    }
    result
}

// --- Contract-based exhaustiveness test ---

fn contract_path_methods() -> BTreeMap<String, BTreeSet<String>> {
    let mut out = BTreeMap::<String, BTreeSet<String>>::new();

    for (path, method) in ALL_ENDPOINT_PATHS {
        out.entry(normalize_path(path))
            .or_default()
            .insert(method.to_string());
    }

    for (path, method) in NON_JSON_PATHS {
        out.entry(normalize_path(path))
            .or_default()
            .insert(method.to_string());
    }

    out
}

#[test]
fn all_server_routes_have_contracts() {
    let server = server_route_path_methods();
    let contracts = contract_path_methods();

    // Check: every server route must have a contract
    let mut missing_contracts = Vec::new();
    for (path, methods) in &server {
        for method in methods {
            let normalized = normalize_path(path);
            if !contracts
                .get(&normalized)
                .is_some_and(|m| m.contains(method))
            {
                missing_contracts.push(format!("{method} {path}"));
            }
        }
    }

    // Check: every contract must have a server route
    let mut orphaned_contracts = Vec::new();
    for (path, methods) in &contracts {
        for method in methods {
            if !server.get(path).is_some_and(|m| m.contains(method)) {
                orphaned_contracts.push(format!("{method} {path}"));
            }
        }
    }

    let mut errors = Vec::new();
    if !missing_contracts.is_empty() {
        errors.push(format!(
            "Server routes WITHOUT contracts:\n  {}",
            missing_contracts.join("\n  ")
        ));
    }
    if !orphaned_contracts.is_empty() {
        errors.push(format!(
            "Contracts WITHOUT server routes:\n  {}",
            orphaned_contracts.join("\n  ")
        ));
    }

    assert!(errors.is_empty(), "\n{}", errors.join("\n\n"));
}

// Keep the old OpenAPI test for backwards compatibility until OpenAPI generation is added
#[test]
fn documented_v0_operation_ids_are_unique() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../openapi/v0.yaml");
    let yaml = fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));

    let mut seen = BTreeSet::new();
    for operation_id in yaml
        .lines()
        .filter_map(|line| line.trim().strip_prefix("operationId: "))
    {
        assert!(
            seen.insert(operation_id.to_owned()),
            "duplicate operationId found in openapi/v0.yaml: {operation_id}"
        );
    }
}
```

- [ ] **Step 2: Run the test**

Run: `cargo test -p trix-server --test openapi_v0_contract`

Expected: PASS. If it fails, the error message will show exactly which routes are missing contracts or vice versa. Fix any mismatches by adding missing contract declarations or correcting paths.

**Troubleshooting:** The path normalization must account for Axum's `/:param` vs contract's `/{param}` format. The server source extraction picks up raw string literals which may use either format. Adjust `normalize_path` if needed.

- [ ] **Step 3: Commit**

```bash
git add crates/trix-server/tests/openapi_v0_contract.rs
git commit -m "test: replace OpenAPI path check with contract exhaustiveness test"
```

---

### Task 5: WebSocket State Machine

**Files:**
- Create: `crates/trix-types/src/ws_protocol.rs`
- Modify: `crates/trix-types/src/lib.rs`
- Create: `crates/trix-types/tests/ws_protocol.rs`
- Modify: `crates/trix-types/Cargo.toml`

**Depends on:** Nothing (independent of Tasks 1-4)

- [ ] **Step 1: Create ws_protocol.rs**

Create `crates/trix-types/src/ws_protocol.rs`:

```rust
//! WebSocket protocol state machine.
//!
//! Defines valid state transitions for the trix WebSocket protocol.
//! Used in tests and debug builds to catch protocol violations.

use crate::api::{WebSocketClientFrame, WebSocketServerFrame};

/// WebSocket connection state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsState {
    /// TCP connected, awaiting Hello from server.
    Connected,
    /// Received Hello, normal bidirectional operation.
    Active,
    /// SessionReplaced received, must disconnect.
    Replaced,
}

/// Result of attempting a state transition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WsTransition {
    /// Valid transition to new state.
    Valid(WsState),
    /// Invalid frame for current state; contains reason.
    Invalid(&'static str),
}

impl WsState {
    /// Check if a server-sent frame is valid in the current state.
    pub fn on_server_frame(&self, frame: &WebSocketServerFrame) -> WsTransition {
        match (self, frame) {
            // Connected: only Hello is valid
            (WsState::Connected, WebSocketServerFrame::Hello { .. }) => {
                WsTransition::Valid(WsState::Active)
            }
            (WsState::Connected, _) => {
                WsTransition::Invalid("server must send Hello before any other frame")
            }

            // Active: anything except a duplicate Hello
            (WsState::Active, WebSocketServerFrame::Hello { .. }) => {
                WsTransition::Invalid("duplicate Hello in active session")
            }
            (WsState::Active, WebSocketServerFrame::SessionReplaced { .. }) => {
                WsTransition::Valid(WsState::Replaced)
            }
            (WsState::Active, _) => WsTransition::Valid(WsState::Active),

            // Replaced: no frames are valid, must disconnect
            (WsState::Replaced, _) => {
                WsTransition::Invalid("session is replaced, must disconnect")
            }
        }
    }

    /// Check if a client-sent frame is valid in the current state.
    pub fn on_client_frame(&self, _frame: &WebSocketClientFrame) -> WsTransition {
        match self {
            WsState::Connected => {
                WsTransition::Invalid("client must wait for Hello before sending frames")
            }
            WsState::Active => WsTransition::Valid(WsState::Active),
            WsState::Replaced => {
                WsTransition::Invalid("session is replaced, must disconnect")
            }
        }
    }

    /// Whether the connection should be closed.
    pub fn should_disconnect(&self) -> bool {
        matches!(self, WsState::Replaced)
    }
}
```

- [ ] **Step 2: Export ws_protocol from lib.rs**

In `crates/trix-types/src/lib.rs`, add:

```rust
pub mod ws_protocol;
```

- [ ] **Step 3: Add proptest dev-dependency to trix-types**

In `crates/trix-types/Cargo.toml`, add:

```toml
[dev-dependencies]
proptest = "1.6.0"
```

- [ ] **Step 4: Create WebSocket protocol tests**

Create `crates/trix-types/tests/ws_protocol.rs`:

```rust
use trix_types::api::{WebSocketClientFrame, WebSocketServerFrame};
use trix_types::ws_protocol::{WsState, WsTransition};
use trix_types::{AccountId, ChatId, DeviceId};

// --- Scenario tests ---

#[test]
fn hello_transitions_from_connected_to_active() {
    let hello = WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    };
    assert_eq!(
        WsState::Connected.on_server_frame(&hello),
        WsTransition::Valid(WsState::Active)
    );
}

#[test]
fn duplicate_hello_is_invalid() {
    let hello = WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    };
    assert!(matches!(
        WsState::Active.on_server_frame(&hello),
        WsTransition::Invalid(_)
    ));
}

#[test]
fn client_frame_before_hello_is_invalid() {
    let ack = WebSocketClientFrame::Ack {
        inbox_ids: vec![1],
    };
    assert!(matches!(
        WsState::Connected.on_client_frame(&ack),
        WsTransition::Invalid(_)
    ));
}

#[test]
fn session_replaced_transitions_to_replaced() {
    let replaced = WebSocketServerFrame::SessionReplaced {
        reason: "new device".into(),
    };
    assert_eq!(
        WsState::Active.on_server_frame(&replaced),
        WsTransition::Valid(WsState::Replaced)
    );
}

#[test]
fn frames_after_session_replaced_are_invalid() {
    let pong = WebSocketServerFrame::Pong {
        nonce: None,
        server_unix: 123,
    };
    assert!(matches!(
        WsState::Replaced.on_server_frame(&pong),
        WsTransition::Invalid(_)
    ));

    let ack = WebSocketClientFrame::Ack {
        inbox_ids: vec![1],
    };
    assert!(matches!(
        WsState::Replaced.on_client_frame(&ack),
        WsTransition::Invalid(_)
    ));
}

#[test]
fn normal_flow_hello_inbox_ack() {
    let mut state = WsState::Connected;

    // Server sends Hello
    let hello = WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    };
    if let WsTransition::Valid(next) = state.on_server_frame(&hello) {
        state = next;
    } else {
        panic!("Hello should be valid");
    }
    assert_eq!(state, WsState::Active);

    // Server sends InboxItems
    let inbox = WebSocketServerFrame::InboxItems {
        lease_owner: "owner".into(),
        lease_expires_at_unix: 999,
        items: vec![],
    };
    if let WsTransition::Valid(next) = state.on_server_frame(&inbox) {
        state = next;
    } else {
        panic!("InboxItems should be valid");
    }
    assert_eq!(state, WsState::Active);

    // Client sends Ack
    let ack = WebSocketClientFrame::Ack {
        inbox_ids: vec![1, 2],
    };
    if let WsTransition::Valid(next) = state.on_client_frame(&ack) {
        state = next;
    } else {
        panic!("Ack should be valid");
    }
    assert_eq!(state, WsState::Active);

    // Client sends PresencePing
    let ping = WebSocketClientFrame::PresencePing {
        nonce: Some("abc".into()),
    };
    assert!(matches!(
        state.on_client_frame(&ping),
        WsTransition::Valid(WsState::Active)
    ));

    // Client sends TypingUpdate
    let typing = WebSocketClientFrame::TypingUpdate {
        chat_id: ChatId::new(),
        is_typing: true,
    };
    assert!(matches!(
        state.on_client_frame(&typing),
        WsTransition::Valid(WsState::Active)
    ));
}

#[test]
fn replaced_state_should_disconnect() {
    assert!(!WsState::Connected.should_disconnect());
    assert!(!WsState::Active.should_disconnect());
    assert!(WsState::Replaced.should_disconnect());
}

// --- Property-based tests ---

mod proptest_tests {
    use super::*;
    use proptest::prelude::*;
    use serde_json::Value;

    fn arb_server_frame() -> impl Strategy<Value = WebSocketServerFrame> {
        prop_oneof![
            Just(WebSocketServerFrame::Hello {
                session_id: "s".into(),
                account_id: AccountId::new(),
                device_id: DeviceId::new(),
                lease_owner: "o".into(),
                lease_ttl_seconds: 60,
            }),
            Just(WebSocketServerFrame::InboxItems {
                lease_owner: "o".into(),
                lease_expires_at_unix: 999,
                items: vec![],
            }),
            Just(WebSocketServerFrame::Acked {
                acked_inbox_ids: vec![1],
            }),
            Just(WebSocketServerFrame::Pong {
                nonce: None,
                server_unix: 0,
            }),
            Just(WebSocketServerFrame::SessionReplaced {
                reason: "r".into(),
            }),
            Just(WebSocketServerFrame::Error {
                code: "e".into(),
                message: "m".into(),
            }),
        ]
    }

    fn arb_client_frame() -> impl Strategy<Value = WebSocketClientFrame> {
        prop_oneof![
            Just(WebSocketClientFrame::Ack {
                inbox_ids: vec![1],
            }),
            Just(WebSocketClientFrame::PresencePing { nonce: None }),
            Just(WebSocketClientFrame::TypingUpdate {
                chat_id: ChatId::new(),
                is_typing: true,
            }),
            Just(WebSocketClientFrame::HistorySyncProgress {
                job_id: "j".into(),
                cursor_json: None,
                completed_chunks: None,
            }),
        ]
    }

    proptest! {
        #[test]
        fn state_machine_never_panics_server_frames(
            frames in prop::collection::vec(arb_server_frame(), 0..50)
        ) {
            let mut state = WsState::Connected;
            for frame in &frames {
                match state.on_server_frame(frame) {
                    WsTransition::Valid(next) => state = next,
                    WsTransition::Invalid(_) => {} // invalid is fine, just don't transition
                }
            }
        }

        #[test]
        fn state_machine_never_panics_mixed_frames(
            server_frames in prop::collection::vec(arb_server_frame(), 0..25),
            client_frames in prop::collection::vec(arb_client_frame(), 0..25),
        ) {
            let mut state = WsState::Connected;
            let mut si = 0;
            let mut ci = 0;
            // Interleave server and client frames
            while si < server_frames.len() || ci < client_frames.len() {
                if si < server_frames.len() {
                    match state.on_server_frame(&server_frames[si]) {
                        WsTransition::Valid(next) => state = next,
                        WsTransition::Invalid(_) => {}
                    }
                    si += 1;
                }
                if ci < client_frames.len() {
                    match state.on_client_frame(&client_frames[ci]) {
                        WsTransition::Valid(next) => state = next,
                        WsTransition::Invalid(_) => {}
                    }
                    ci += 1;
                }
            }
        }
    }
}
```

- [ ] **Step 5: Verify compilation**

Run: `cargo check -p trix-types --tests`

Expected: compiles successfully.

- [ ] **Step 6: Run tests**

Run: `cargo test -p trix-types --test ws_protocol`

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add crates/trix-types/
git commit -m "feat: add WebSocket protocol state machine with property-based tests"
```

---

### Task 6: Serde Roundtrip Tests

**Files:**
- Create: `crates/trix-types/tests/serde_roundtrip.rs`

**Depends on:** Task 1

- [ ] **Step 1: Create serde roundtrip tests**

Create `crates/trix-types/tests/serde_roundtrip.rs`. For every request/response type used in a contract, verify it survives a serialize → deserialize roundtrip.

```rust
//! Serde roundtrip tests for all contract types.
//!
//! Every type used in an ApiEndpoint declaration must serialize to JSON
//! and deserialize back to an equal value. This catches:
//! - Missing serde derives
//! - Broken custom serializers
//! - Fields that silently disappear on roundtrip

use serde::{Serialize, de::DeserializeOwned};
use std::fmt::Debug;
use trix_types::*;

fn roundtrip<T: Serialize + DeserializeOwned + Debug + PartialEq>(value: &T) {
    let json = serde_json::to_string(value).expect("serialize failed");
    let decoded: T = serde_json::from_str(&json).expect("deserialize failed");
    assert_eq!(*value, decoded, "roundtrip mismatch for {}", std::any::type_name::<T>());
}

// --- Auth ---

#[test]
fn auth_challenge_request() {
    roundtrip(&AuthChallengeRequest {
        device_id: DeviceId::new(),
    });
}

#[test]
fn auth_challenge_response() {
    roundtrip(&AuthChallengeResponse {
        challenge_id: "ch1".into(),
        challenge_b64: "AAAA".into(),
        expires_at_unix: 1234567890,
    });
}

#[test]
fn auth_session_request() {
    roundtrip(&AuthSessionRequest {
        device_id: DeviceId::new(),
        challenge_id: "ch1".into(),
        signature_b64: "BBBB".into(),
    });
}

#[test]
fn auth_session_response() {
    roundtrip(&AuthSessionResponse {
        access_token: "tok".into(),
        expires_at_unix: 999,
        account_id: AccountId::new(),
        device_status: DeviceStatus::Active,
    });
}

// --- Accounts ---

#[test]
fn create_account_request() {
    roundtrip(&CreateAccountRequest {
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: None,
        device_display_name: "iPhone".into(),
        platform: "ios".into(),
        credential_identity_b64: "AAAA".into(),
        account_root_pubkey_b64: "BBBB".into(),
        account_root_signature_b64: "CCCC".into(),
        transport_pubkey_b64: "DDDD".into(),
        provision_token: None,
    });
}

#[test]
fn create_account_response() {
    roundtrip(&CreateAccountResponse {
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        account_sync_chat_id: ChatId::new(),
    });
}

#[test]
fn account_profile_response() {
    roundtrip(&AccountProfileResponse {
        account_id: AccountId::new(),
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: None,
        device_id: DeviceId::new(),
        device_status: DeviceStatus::Active,
    });
}

#[test]
fn update_account_profile_request() {
    roundtrip(&UpdateAccountProfileRequest {
        handle: Some("bob".into()),
        profile_name: "Bob".into(),
        profile_bio: Some("hi".into()),
    });
}

// --- Devices ---

#[test]
fn device_list_response() {
    roundtrip(&DeviceListResponse {
        account_id: AccountId::new(),
        devices: vec![DeviceSummary {
            device_id: DeviceId::new(),
            display_name: "iPhone".into(),
            platform: "ios".into(),
            device_status: DeviceStatus::Active,
            available_key_package_count: 5,
        }],
    });
}

// --- Chats ---

#[test]
fn create_chat_request() {
    roundtrip(&CreateChatRequest {
        chat_type: ChatType::Group,
        title: Some("test".into()),
        participant_account_ids: vec![AccountId::new()],
        reserved_key_package_ids: vec![],
        initial_commit: None,
        welcome_message: None,
    });
}

#[test]
fn create_chat_response() {
    roundtrip(&CreateChatResponse {
        chat_id: ChatId::new(),
        chat_type: ChatType::Group,
        epoch: 1,
    });
}

// --- Inbox ---

#[test]
fn lease_inbox_request() {
    roundtrip(&LeaseInboxRequest {
        lease_owner: Some("device-1".into()),
        limit: Some(50),
        after_inbox_id: None,
        lease_ttl_seconds: Some(30),
    });
}

#[test]
fn ack_inbox_request() {
    roundtrip(&AckInboxRequest {
        inbox_ids: vec![1, 2, 3],
    });
}

#[test]
fn ack_inbox_response() {
    roundtrip(&AckInboxResponse {
        acked_inbox_ids: vec![1, 2, 3],
    });
}

// --- Key Packages ---

#[test]
fn publish_key_packages_request() {
    roundtrip(&PublishKeyPackagesRequest {
        packages: vec![PublishKeyPackageItem {
            cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
            key_package_b64: "AAAA".into(),
        }],
    });
}

// --- WebSocket frames ---

#[test]
fn websocket_client_frames() {
    roundtrip(&WebSocketClientFrame::Ack {
        inbox_ids: vec![1, 2],
    });
    roundtrip(&WebSocketClientFrame::PresencePing {
        nonce: Some("abc".into()),
    });
    roundtrip(&WebSocketClientFrame::TypingUpdate {
        chat_id: ChatId::new(),
        is_typing: true,
    });
    roundtrip(&WebSocketClientFrame::HistorySyncProgress {
        job_id: "j1".into(),
        cursor_json: None,
        completed_chunks: Some(5),
    });
}

#[test]
fn websocket_server_frames() {
    roundtrip(&WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    });
    roundtrip(&WebSocketServerFrame::InboxItems {
        lease_owner: "o".into(),
        lease_expires_at_unix: 999,
        items: vec![],
    });
    roundtrip(&WebSocketServerFrame::Acked {
        acked_inbox_ids: vec![1],
    });
    roundtrip(&WebSocketServerFrame::Pong {
        nonce: None,
        server_unix: 123,
    });
    roundtrip(&WebSocketServerFrame::SessionReplaced {
        reason: "replaced".into(),
    });
    roundtrip(&WebSocketServerFrame::Error {
        code: "err".into(),
        message: "msg".into(),
    });
}

// --- Error response ---

#[test]
fn error_response() {
    roundtrip(&ErrorResponse {
        code: "not_found".into(),
        message: "Chat not found".into(),
    });
}

// --- History Sync ---

#[test]
fn append_history_sync_chunk_request() {
    roundtrip(&AppendHistorySyncChunkRequest {
        sequence_no: 1,
        payload_b64: "AAAA".into(),
        cursor_json: None,
        is_final: false,
    });
}

// --- Message Repairs ---

#[test]
fn message_repair_binding() {
    roundtrip(&MessageRepairBinding {
        chat_id: ChatId::new(),
        message_id: MessageId::new(),
        server_seq: 42,
        epoch: 3,
        sender_account_id: AccountId::new(),
        sender_device_id: DeviceId::new(),
        message_kind: MessageKind::Application,
        content_type: ContentType::Text,
        ciphertext_sha256_b64: "AAAA".into(),
    });
}

// --- Blob ---

#[test]
fn create_blob_upload_request() {
    roundtrip(&CreateBlobUploadRequest {
        chat_id: ChatId::new(),
        mime_type: "image/png".into(),
        size_bytes: 1024,
        sha256_b64: "AAAA".into(),
    });
}

// --- Admin ---

#[test]
fn admin_session_request() {
    roundtrip(&AdminSessionRequest {
        username: "admin".into(),
        password: "secret".into(),
    });
}

#[test]
fn admin_session_response() {
    roundtrip(&AdminSessionResponse {
        access_token: "tok".into(),
        expires_at_unix: 999,
        username: "admin".into(),
    });
}

// --- Enums ---

#[test]
fn all_model_enums_roundtrip() {
    roundtrip(&DeviceStatus::Pending);
    roundtrip(&DeviceStatus::Active);
    roundtrip(&DeviceStatus::Revoked);
    roundtrip(&ChatType::Dm);
    roundtrip(&ChatType::Group);
    roundtrip(&ChatType::AccountSync);
    roundtrip(&MessageKind::Application);
    roundtrip(&MessageKind::Commit);
    roundtrip(&MessageKind::WelcomeRef);
    roundtrip(&MessageKind::System);
    roundtrip(&ContentType::Text);
    roundtrip(&ContentType::Reaction);
    roundtrip(&ContentType::Receipt);
    roundtrip(&ContentType::Attachment);
    roundtrip(&ContentType::ChatEvent);
    roundtrip(&HistorySyncJobType::InitialSync);
    roundtrip(&HistorySyncJobStatus::Pending);
    roundtrip(&HistorySyncJobStatus::Running);
    roundtrip(&HistorySyncJobStatus::Completed);
    roundtrip(&HistorySyncJobStatus::Failed);
    roundtrip(&HistorySyncJobStatus::Canceled);
    roundtrip(&MessageRepairRequestStatus::Pending);
    roundtrip(&MessageRepairRequestStatus::Completed);
}
```

- [ ] **Step 2: Run tests**

Run: `cargo test -p trix-types --test serde_roundtrip`

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add crates/trix-types/tests/serde_roundtrip.rs
git commit -m "test: add serde roundtrip tests for all contract types"
```

---

### Task 7: Pre-commit Hook

**Files:**
- Create: `.githooks/pre-commit`

**Depends on:** Tasks 1-6

- [ ] **Step 1: Create the pre-commit hook**

Create `.githooks/pre-commit`:

```bash
#!/bin/sh
# Contract validation pre-commit hook.
# Fast checks only — no database required.

set -e

echo "Running contract checks..."

# 1. Compile check (catches type mismatches)
cargo check --workspace --quiet 2>&1 | tail -5
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ Compilation failed — contract type mismatch?"
    exit 1
fi

# 2. Contract exhaustiveness (catches missing contracts)
cargo test -p trix-server --test openapi_v0_contract --quiet 2>&1 | tail -3
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ Contract exhaustiveness test failed"
    exit 1
fi

# 3. Serde roundtrip (catches serialization issues)
cargo test -p trix-types --test serde_roundtrip --quiet 2>&1 | tail -3
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ Serde roundtrip test failed"
    exit 1
fi

# 4. WS protocol tests
cargo test -p trix-types --test ws_protocol --quiet 2>&1 | tail -3
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ WebSocket protocol test failed"
    exit 1
fi

echo "✅ Contract checks passed"
```

- [ ] **Step 2: Make it executable and configure git**

```bash
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
```

- [ ] **Step 3: Test the hook**

Run: `./.githooks/pre-commit`

Expected: all checks pass.

- [ ] **Step 4: Commit**

```bash
git add .githooks/pre-commit
git commit -m "chore: add pre-commit hook for contract validation"
```

---

## Dependency Graph

```
Task 1 (contract trait + declarations)
  ├── Task 2 (generic transport) ──────────┐
  ├── Task 3 (server route constants) ─────┤
  ├── Task 6 (serde roundtrip tests) ──────┤
  │                                        ├── Task 7 (pre-commit hook)
  └── Task 4 (exhaustiveness test) ────────┤
                                           │
Task 5 (WS state machine + tests) ────────┘
```

Tasks 2, 3, 5, 6 can run in **parallel** after Task 1.
Task 4 depends on 1 and 3.
Task 7 depends on all others.
