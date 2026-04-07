//! Serde roundtrip tests for all contract types.
//!
//! Every type used in an ApiEndpoint declaration must serialize to JSON
//! and deserialize back to an equal value. This catches:
//! - Missing serde derives
//! - Broken custom serializers
//! - Fields that silently disappear on roundtrip

use serde::{de::DeserializeOwned, Serialize};
use std::fmt::Debug;
use trix_types::*;

fn roundtrip<T: Serialize + DeserializeOwned + Debug + PartialEq>(value: &T) {
    let json = serde_json::to_string(value).expect("serialize failed");
    let decoded: T = serde_json::from_str(&json).expect("deserialize failed");
    assert_eq!(
        *value,
        decoded,
        "roundtrip mismatch for {}",
        std::any::type_name::<T>()
    );
}

/// Roundtrip for types that don't implement PartialEq (e.g. query types).
/// Compares JSON representation instead.
fn roundtrip_json<T: Serialize + DeserializeOwned + Debug>(value: &T) {
    let json1 = serde_json::to_string(value).expect("serialize failed");
    let decoded: T = serde_json::from_str(&json1).expect("deserialize failed");
    let json2 = serde_json::to_string(&decoded).expect("re-serialize failed");
    assert_eq!(
        json1, json2,
        "roundtrip JSON mismatch for {}",
        std::any::type_name::<T>()
    );
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
fn create_account_request_minimal() {
    roundtrip(&CreateAccountRequest {
        handle: None,
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
fn create_account_request_full() {
    roundtrip(&CreateAccountRequest {
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: Some("Hello world".into()),
        device_display_name: "iPhone".into(),
        platform: "ios".into(),
        credential_identity_b64: "AAAA".into(),
        account_root_pubkey_b64: "BBBB".into(),
        account_root_signature_b64: "CCCC".into(),
        transport_pubkey_b64: "DDDD".into(),
        provision_token: Some("prov-token".into()),
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
fn account_profile_response_minimal() {
    roundtrip(&AccountProfileResponse {
        account_id: AccountId::new(),
        handle: None,
        profile_name: "Alice".into(),
        profile_bio: None,
        device_id: DeviceId::new(),
        device_status: DeviceStatus::Active,
    });
}

#[test]
fn account_profile_response_full() {
    roundtrip(&AccountProfileResponse {
        account_id: AccountId::new(),
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: Some("A bio".into()),
        device_id: DeviceId::new(),
        device_status: DeviceStatus::Pending,
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

#[test]
fn update_account_profile_request_clear_fields() {
    roundtrip(&UpdateAccountProfileRequest {
        handle: None,
        profile_name: "Bob".into(),
        profile_bio: None,
    });
}

#[test]
fn directory_account_summary() {
    roundtrip(&DirectoryAccountSummary {
        account_id: AccountId::new(),
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: None,
    });
}

#[test]
fn account_directory_response() {
    roundtrip(&AccountDirectoryResponse {
        accounts: vec![DirectoryAccountSummary {
            account_id: AccountId::new(),
            handle: Some("alice".into()),
            profile_name: "Alice".into(),
            profile_bio: None,
        }],
    });
}

#[test]
fn account_directory_response_empty() {
    roundtrip(&AccountDirectoryResponse { accounts: vec![] });
}

#[test]
fn chat_participant_profile_summary() {
    roundtrip(&ChatParticipantProfileSummary {
        account_id: AccountId::new(),
        handle: Some("user1".into()),
        profile_name: "User One".into(),
        profile_bio: Some("bio".into()),
    });
}

// --- Devices ---

#[test]
fn device_summary() {
    roundtrip(&DeviceSummary {
        device_id: DeviceId::new(),
        display_name: "iPhone".into(),
        platform: "ios".into(),
        device_status: DeviceStatus::Active,
        available_key_package_count: 10,
    });
}

#[test]
fn device_list_response_empty() {
    roundtrip(&DeviceListResponse {
        account_id: AccountId::new(),
        devices: vec![],
    });
}

#[test]
fn device_list_response_with_devices() {
    roundtrip(&DeviceListResponse {
        account_id: AccountId::new(),
        devices: vec![
            DeviceSummary {
                device_id: DeviceId::new(),
                display_name: "iPhone".into(),
                platform: "ios".into(),
                device_status: DeviceStatus::Active,
                available_key_package_count: 5,
            },
            DeviceSummary {
                device_id: DeviceId::new(),
                display_name: "MacBook".into(),
                platform: "macos".into(),
                device_status: DeviceStatus::Pending,
                available_key_package_count: 0,
            },
        ],
    });
}

#[test]
fn register_apple_push_token_request() {
    roundtrip(&RegisterApplePushTokenRequest {
        token_hex: "abc123".into(),
        environment: ApplePushEnvironment::Production,
    });
}

#[test]
fn register_apple_push_token_response() {
    roundtrip(&RegisterApplePushTokenResponse {
        device_id: DeviceId::new(),
        environment: ApplePushEnvironment::Sandbox,
        push_delivery_enabled: true,
    });
}

#[test]
fn create_link_intent_response() {
    roundtrip(&CreateLinkIntentResponse {
        link_intent_id: "intent-123".into(),
        qr_payload: "qr-data".into(),
        expires_at_unix: 9999999,
    });
}

#[test]
fn complete_link_intent_request() {
    roundtrip(&CompleteLinkIntentRequest {
        link_token: "token".into(),
        device_display_name: "iPad".into(),
        platform: "ipados".into(),
        credential_identity_b64: "AAAA".into(),
        transport_pubkey_b64: "BBBB".into(),
        key_packages: vec![],
    });
}

#[test]
fn complete_link_intent_response() {
    roundtrip(&CompleteLinkIntentResponse {
        account_id: AccountId::new(),
        pending_device_id: DeviceId::new(),
        device_status: DeviceStatus::Pending,
        bootstrap_payload_b64: "payload".into(),
    });
}

#[test]
fn device_approve_payload_response() {
    roundtrip(&DeviceApprovePayloadResponse {
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        device_display_name: "iPhone".into(),
        platform: "ios".into(),
        device_status: DeviceStatus::Pending,
        credential_identity_b64: "AAAA".into(),
        transport_pubkey_b64: "BBBB".into(),
        bootstrap_payload_b64: "CCCC".into(),
    });
}

#[test]
fn device_transport_key_response() {
    roundtrip(&DeviceTransportKeyResponse {
        device_id: DeviceId::new(),
        device_status: DeviceStatus::Active,
        transport_pubkey_b64: "PUBKEY".into(),
    });
}

#[test]
fn approve_device_request_minimal() {
    roundtrip(&ApproveDeviceRequest {
        account_root_signature_b64: "SIG".into(),
        transfer_bundle_b64: None,
    });
}

#[test]
fn approve_device_request_with_bundle() {
    roundtrip(&ApproveDeviceRequest {
        account_root_signature_b64: "SIG".into(),
        transfer_bundle_b64: Some("BUNDLE".into()),
    });
}

#[test]
fn approve_device_response() {
    roundtrip(&ApproveDeviceResponse {
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        device_status: DeviceStatus::Active,
    });
}

#[test]
fn device_transfer_bundle_response() {
    roundtrip(&DeviceTransferBundleResponse {
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        transfer_bundle_b64: "BUNDLE".into(),
        uploaded_at_unix: 1234567890,
    });
}

#[test]
fn revoke_device_request() {
    roundtrip(&RevokeDeviceRequest {
        reason: "lost".into(),
        account_root_signature_b64: "SIG".into(),
    });
}

#[test]
fn revoke_device_response() {
    roundtrip(&RevokeDeviceResponse {
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        device_status: DeviceStatus::Revoked,
    });
}

// --- Key Packages ---

#[test]
fn publish_key_package_item() {
    roundtrip(&PublishKeyPackageItem {
        cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
        key_package_b64: "AAAA".into(),
    });
}

#[test]
fn publish_key_packages_request_empty() {
    roundtrip(&PublishKeyPackagesRequest { packages: vec![] });
}

#[test]
fn publish_key_packages_request() {
    roundtrip(&PublishKeyPackagesRequest {
        packages: vec![PublishKeyPackageItem {
            cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
            key_package_b64: "AAAA".into(),
        }],
    });
}

#[test]
fn reserve_key_packages_request() {
    roundtrip(&ReserveKeyPackagesRequest {
        account_id: AccountId::new(),
        device_ids: vec![DeviceId::new(), DeviceId::new()],
    });
}

#[test]
fn published_key_package() {
    roundtrip(&PublishedKeyPackage {
        key_package_id: "kp-123".into(),
        cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
    });
}

#[test]
fn publish_key_packages_response() {
    roundtrip(&PublishKeyPackagesResponse {
        device_id: DeviceId::new(),
        packages: vec![PublishedKeyPackage {
            key_package_id: "kp-1".into(),
            cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
        }],
    });
}

#[test]
fn reset_key_packages_response() {
    roundtrip(&ResetKeyPackagesResponse {
        device_id: DeviceId::new(),
        expired_key_package_count: 42,
    });
}

#[test]
fn reserved_key_package() {
    roundtrip(&ReservedKeyPackage {
        key_package_id: "kp-1".into(),
        device_id: DeviceId::new(),
        cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
        key_package_b64: "AAAA".into(),
    });
}

#[test]
fn account_key_packages_response() {
    roundtrip(&AccountKeyPackagesResponse {
        account_id: AccountId::new(),
        packages: vec![ReservedKeyPackage {
            key_package_id: "kp-1".into(),
            device_id: DeviceId::new(),
            cipher_suite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519".into(),
            key_package_b64: "AAAA".into(),
        }],
    });
}

// --- Chats ---

#[test]
fn control_message_input() {
    roundtrip(&ControlMessageInput {
        message_id: MessageId::new(),
        ciphertext_b64: "CIPHER".into(),
        aad_json: None,
    });
}

#[test]
fn control_message_input_with_aad() {
    roundtrip(&ControlMessageInput {
        message_id: MessageId::new(),
        ciphertext_b64: "CIPHER".into(),
        aad_json: Some(serde_json::json!({"key": "value"})),
    });
}

#[test]
fn create_chat_request_minimal() {
    roundtrip(&CreateChatRequest {
        chat_type: ChatType::Dm,
        title: None,
        participant_account_ids: vec![AccountId::new()],
        reserved_key_package_ids: vec![],
        initial_commit: None,
        welcome_message: None,
    });
}

#[test]
fn create_chat_request_full() {
    roundtrip(&CreateChatRequest {
        chat_type: ChatType::Group,
        title: Some("Test Group".into()),
        participant_account_ids: vec![AccountId::new(), AccountId::new()],
        reserved_key_package_ids: vec!["kp-1".into(), "kp-2".into()],
        initial_commit: Some(ControlMessageInput {
            message_id: MessageId::new(),
            ciphertext_b64: "CIPHER".into(),
            aad_json: None,
        }),
        welcome_message: Some(ControlMessageInput {
            message_id: MessageId::new(),
            ciphertext_b64: "WELCOME".into(),
            aad_json: Some(serde_json::json!({})),
        }),
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

#[test]
fn chat_member_summary() {
    roundtrip(&ChatMemberSummary {
        account_id: AccountId::new(),
        role: "member".into(),
        membership_status: "active".into(),
    });
}

#[test]
fn chat_device_summary() {
    roundtrip(&ChatDeviceSummary {
        device_id: DeviceId::new(),
        account_id: AccountId::new(),
        display_name: "iPhone".into(),
        platform: "ios".into(),
        leaf_index: 0,
        credential_identity_b64: "CRED".into(),
    });
}

#[test]
fn modify_chat_members_request_minimal() {
    roundtrip(&ModifyChatMembersRequest {
        epoch: 2,
        participant_account_ids: vec![AccountId::new()],
        reserved_key_package_ids: vec![],
        commit_message: None,
        welcome_message: None,
    });
}

#[test]
fn modify_chat_members_request_full() {
    roundtrip(&ModifyChatMembersRequest {
        epoch: 3,
        participant_account_ids: vec![AccountId::new()],
        reserved_key_package_ids: vec!["kp-1".into()],
        commit_message: Some(ControlMessageInput {
            message_id: MessageId::new(),
            ciphertext_b64: "COMMIT".into(),
            aad_json: None,
        }),
        welcome_message: Some(ControlMessageInput {
            message_id: MessageId::new(),
            ciphertext_b64: "WELCOME".into(),
            aad_json: None,
        }),
    });
}

#[test]
fn modify_chat_members_response() {
    roundtrip(&ModifyChatMembersResponse {
        chat_id: ChatId::new(),
        epoch: 4,
        changed_account_ids: vec![AccountId::new()],
    });
}

#[test]
fn modify_chat_devices_request() {
    roundtrip(&ModifyChatDevicesRequest {
        epoch: 2,
        device_ids: vec![DeviceId::new()],
        reserved_key_package_ids: vec![],
        commit_message: None,
        welcome_message: None,
    });
}

#[test]
fn modify_chat_devices_response() {
    roundtrip(&ModifyChatDevicesResponse {
        chat_id: ChatId::new(),
        epoch: 3,
        changed_device_ids: vec![DeviceId::new()],
    });
}

#[test]
fn leave_chat_request_this_device() {
    roundtrip(&LeaveChatRequest {
        scope: LeaveChatScope::ThisDevice,
        epoch: 5,
        commit_message: None,
    });
}

#[test]
fn leave_chat_request_all_devices() {
    roundtrip(&LeaveChatRequest {
        scope: LeaveChatScope::AllMyDevices,
        epoch: 5,
        commit_message: Some(ControlMessageInput {
            message_id: MessageId::new(),
            ciphertext_b64: "COMMIT".into(),
            aad_json: None,
        }),
    });
}

#[test]
fn leave_chat_response() {
    roundtrip(&LeaveChatResponse {
        chat_id: ChatId::new(),
        epoch: 6,
        changed_device_ids: vec![],
    });
}

#[test]
fn dm_global_delete_request() {
    roundtrip(&DmGlobalDeleteRequest {
        epoch: 1,
        commit_message: None,
    });
}

#[test]
fn dm_global_delete_response() {
    roundtrip(&DmGlobalDeleteResponse {
        chat_id: ChatId::new(),
        epoch: 2,
        changed_account_ids: vec![AccountId::new()],
        changed_device_ids: vec![DeviceId::new()],
    });
}

#[test]
fn create_message_request() {
    roundtrip(&CreateMessageRequest {
        message_id: MessageId::new(),
        epoch: 1,
        message_kind: MessageKind::Application,
        content_type: ContentType::Text,
        ciphertext_b64: "CIPHER".into(),
        aad_json: None,
    });
}

#[test]
fn create_message_request_with_aad() {
    roundtrip(&CreateMessageRequest {
        message_id: MessageId::new(),
        epoch: 1,
        message_kind: MessageKind::Commit,
        content_type: ContentType::ChatEvent,
        ciphertext_b64: "CIPHER".into(),
        aad_json: Some(serde_json::json!({"seq": 42})),
    });
}

#[test]
fn create_message_response() {
    roundtrip(&CreateMessageResponse {
        message_id: MessageId::new(),
        server_seq: 100,
    });
}

#[test]
fn message_envelope() {
    roundtrip(&MessageEnvelope {
        message_id: MessageId::new(),
        chat_id: ChatId::new(),
        server_seq: 42,
        sender_account_id: AccountId::new(),
        sender_device_id: DeviceId::new(),
        epoch: 1,
        message_kind: MessageKind::Application,
        content_type: ContentType::Text,
        ciphertext_b64: "CIPHER".into(),
        aad_json: serde_json::json!({}),
        created_at_unix: 1234567890,
    });
}

#[test]
fn chat_history_response_empty() {
    roundtrip(&ChatHistoryResponse {
        chat_id: ChatId::new(),
        messages: vec![],
    });
}

#[test]
fn chat_history_response_with_messages() {
    roundtrip(&ChatHistoryResponse {
        chat_id: ChatId::new(),
        messages: vec![MessageEnvelope {
            message_id: MessageId::new(),
            chat_id: ChatId::new(),
            server_seq: 1,
            sender_account_id: AccountId::new(),
            sender_device_id: DeviceId::new(),
            epoch: 0,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: "CIPHER".into(),
            aad_json: serde_json::json!(null),
            created_at_unix: 1000000,
        }],
    });
}

// --- Inbox ---

#[test]
fn inbox_item() {
    roundtrip(&InboxItem {
        inbox_id: 1,
        message: MessageEnvelope {
            message_id: MessageId::new(),
            chat_id: ChatId::new(),
            server_seq: 1,
            sender_account_id: AccountId::new(),
            sender_device_id: DeviceId::new(),
            epoch: 0,
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_b64: "CIPHER".into(),
            aad_json: serde_json::json!({}),
            created_at_unix: 1234567890,
        },
    });
}

#[test]
fn inbox_response_empty() {
    roundtrip(&InboxResponse { items: vec![] });
}

#[test]
fn lease_inbox_request_minimal() {
    roundtrip(&LeaseInboxRequest {
        lease_owner: None,
        limit: None,
        after_inbox_id: None,
        lease_ttl_seconds: None,
    });
}

#[test]
fn lease_inbox_request_full() {
    roundtrip(&LeaseInboxRequest {
        lease_owner: Some("device-1".into()),
        limit: Some(50),
        after_inbox_id: Some(100),
        lease_ttl_seconds: Some(30),
    });
}

#[test]
fn lease_inbox_response() {
    roundtrip(&LeaseInboxResponse {
        lease_owner: "device-1".into(),
        lease_expires_at_unix: 9999999,
        items: vec![],
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

// --- WebSocket frames ---

#[test]
fn websocket_client_frame_ack() {
    roundtrip(&WebSocketClientFrame::Ack {
        inbox_ids: vec![1, 2],
    });
}

#[test]
fn websocket_client_frame_presence_ping_with_nonce() {
    roundtrip(&WebSocketClientFrame::PresencePing {
        nonce: Some("abc".into()),
    });
}

#[test]
fn websocket_client_frame_presence_ping_no_nonce() {
    roundtrip(&WebSocketClientFrame::PresencePing { nonce: None });
}

#[test]
fn websocket_client_frame_typing_update() {
    roundtrip(&WebSocketClientFrame::TypingUpdate {
        chat_id: ChatId::new(),
        is_typing: true,
    });
}

#[test]
fn websocket_client_frame_typing_update_stopped() {
    roundtrip(&WebSocketClientFrame::TypingUpdate {
        chat_id: ChatId::new(),
        is_typing: false,
    });
}

#[test]
fn websocket_client_frame_history_sync_progress() {
    roundtrip(&WebSocketClientFrame::HistorySyncProgress {
        job_id: "j1".into(),
        cursor_json: None,
        completed_chunks: Some(5),
    });
}

#[test]
fn websocket_client_frame_history_sync_progress_with_cursor() {
    roundtrip(&WebSocketClientFrame::HistorySyncProgress {
        job_id: "j1".into(),
        cursor_json: Some(serde_json::json!({"offset": 42})),
        completed_chunks: None,
    });
}

#[test]
fn websocket_server_frame_hello() {
    roundtrip(&WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    });
}

#[test]
fn websocket_server_frame_inbox_items_empty() {
    roundtrip(&WebSocketServerFrame::InboxItems {
        lease_owner: "o".into(),
        lease_expires_at_unix: 999,
        items: vec![],
    });
}

#[test]
fn websocket_server_frame_acked() {
    roundtrip(&WebSocketServerFrame::Acked {
        acked_inbox_ids: vec![1, 2, 3],
    });
}

#[test]
fn websocket_server_frame_pong_with_nonce() {
    roundtrip(&WebSocketServerFrame::Pong {
        nonce: Some("ping-nonce".into()),
        server_unix: 1234567890,
    });
}

#[test]
fn websocket_server_frame_pong_no_nonce() {
    roundtrip(&WebSocketServerFrame::Pong {
        nonce: None,
        server_unix: 123,
    });
}

#[test]
fn websocket_server_frame_session_replaced() {
    roundtrip(&WebSocketServerFrame::SessionReplaced {
        reason: "new_login".into(),
    });
}

#[test]
fn websocket_server_frame_error() {
    roundtrip(&WebSocketServerFrame::Error {
        code: "auth_failed".into(),
        message: "Authentication failed".into(),
    });
}

// --- Error types ---

#[test]
fn error_response() {
    roundtrip(&ErrorResponse {
        code: "not_found".into(),
        message: "Chat not found".into(),
    });
}

// --- System types ---

#[test]
fn health_response() {
    roundtrip(&HealthResponse {
        service: "trixd".into(),
        status: ServiceStatus::Ok,
        version: "0.1.0".into(),
        uptime_ms: 12345,
    });
}

#[test]
fn health_response_degraded() {
    roundtrip(&HealthResponse {
        service: "trixd".into(),
        status: ServiceStatus::Degraded,
        version: "0.1.0".into(),
        uptime_ms: 0,
    });
}

#[test]
fn version_response() {
    roundtrip(&VersionResponse {
        service: "trixd".into(),
        version: "0.1.0".into(),
        git_sha: Some("abc123".into()),
    });
}

#[test]
fn version_response_no_sha() {
    roundtrip(&VersionResponse {
        service: "trixd".into(),
        version: "0.1.0".into(),
        git_sha: None,
    });
}

// --- Blob types ---

#[test]
fn create_blob_upload_request() {
    roundtrip(&CreateBlobUploadRequest {
        chat_id: ChatId::new(),
        mime_type: "image/png".into(),
        size_bytes: 1024,
        sha256_b64: "AAAA".into(),
    });
}

#[test]
fn create_blob_upload_response_needs_upload() {
    roundtrip(&CreateBlobUploadResponse {
        blob_id: "blob-123".into(),
        upload_url: "https://example.com/upload".into(),
        upload_status: BlobUploadStatus::PendingUpload,
        needs_upload: true,
        max_upload_bytes: 10485760,
    });
}

#[test]
fn create_blob_upload_response_already_available() {
    roundtrip(&CreateBlobUploadResponse {
        blob_id: "blob-123".into(),
        upload_url: "".into(),
        upload_status: BlobUploadStatus::Available,
        needs_upload: false,
        max_upload_bytes: 10485760,
    });
}

#[test]
fn blob_metadata_response() {
    roundtrip(&BlobMetadataResponse {
        blob_id: "blob-123".into(),
        mime_type: "image/jpeg".into(),
        size_bytes: 2048,
        sha256_b64: "BBBB".into(),
        upload_status: BlobUploadStatus::Available,
        created_by_device_id: DeviceId::new(),
    });
}

// --- History Sync ---

#[test]
fn history_sync_job_summary() {
    roundtrip(&HistorySyncJobSummary {
        job_id: "job-1".into(),
        job_type: HistorySyncJobType::InitialSync,
        job_status: HistorySyncJobStatus::Running,
        source_device_id: DeviceId::new(),
        target_device_id: DeviceId::new(),
        chat_id: None,
        cursor_json: serde_json::json!({}),
        created_at_unix: 1000000,
        updated_at_unix: 1000001,
    });
}

#[test]
fn history_sync_job_summary_with_chat() {
    roundtrip(&HistorySyncJobSummary {
        job_id: "job-2".into(),
        job_type: HistorySyncJobType::ChatBackfill,
        job_status: HistorySyncJobStatus::Completed,
        source_device_id: DeviceId::new(),
        target_device_id: DeviceId::new(),
        chat_id: Some(ChatId::new()),
        cursor_json: serde_json::json!({"page": 3}),
        created_at_unix: 1000000,
        updated_at_unix: 1000100,
    });
}

#[test]
fn history_sync_job_list_response() {
    roundtrip(&HistorySyncJobListResponse { jobs: vec![] });
}

#[test]
fn request_history_sync_repair_request() {
    roundtrip(&RequestHistorySyncRepairRequest {
        chat_id: ChatId::new(),
        repair_from_server_seq: 10,
        repair_through_server_seq: 20,
        reason: "missing messages".into(),
    });
}

#[test]
fn request_history_sync_repair_response() {
    roundtrip(&RequestHistorySyncRepairResponse { jobs: vec![] });
}

#[test]
fn request_chat_backfill_request() {
    roundtrip(&RequestChatBackfillRequest {
        chat_id: ChatId::new(),
    });
}

#[test]
fn request_chat_backfill_response() {
    roundtrip(&RequestChatBackfillResponse {
        job_id: "job-1".into(),
        source_device_id: DeviceId::new(),
    });
}

#[test]
fn history_sync_chunk_summary() {
    roundtrip(&HistorySyncChunkSummary {
        chunk_id: 1,
        sequence_no: 0,
        payload_b64: "PAYLOAD".into(),
        cursor_json: None,
        is_final: false,
        uploaded_at_unix: 1234567890,
    });
}

#[test]
fn history_sync_chunk_list_response() {
    roundtrip(&HistorySyncChunkListResponse {
        job_id: "job-1".into(),
        role: HistorySyncJobRole::Source,
        chunks: vec![],
    });
}

#[test]
fn append_history_sync_chunk_request_minimal() {
    roundtrip(&AppendHistorySyncChunkRequest {
        sequence_no: 1,
        payload_b64: "AAAA".into(),
        cursor_json: None,
        is_final: false,
    });
}

#[test]
fn append_history_sync_chunk_request_final_with_cursor() {
    roundtrip(&AppendHistorySyncChunkRequest {
        sequence_no: 5,
        payload_b64: "BBBB".into(),
        cursor_json: Some(serde_json::json!({"done": true})),
        is_final: true,
    });
}

#[test]
fn append_history_sync_chunk_response() {
    roundtrip(&AppendHistorySyncChunkResponse {
        job_id: "job-1".into(),
        chunk_id: 3,
        job_status: HistorySyncJobStatus::Running,
    });
}

#[test]
fn complete_history_sync_job_request_no_cursor() {
    roundtrip(&CompleteHistorySyncJobRequest { cursor_json: None });
}

#[test]
fn complete_history_sync_job_request_with_cursor() {
    roundtrip(&CompleteHistorySyncJobRequest {
        cursor_json: Some(serde_json::json!({"final": true})),
    });
}

#[test]
fn complete_history_sync_job_response() {
    roundtrip(&CompleteHistorySyncJobResponse {
        job_id: "job-1".into(),
        job_status: HistorySyncJobStatus::Completed,
    });
}

// --- Message Repair types ---

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
        ciphertext_sha256_b64: "SHA256HASH".into(),
    });
}

#[test]
fn request_message_repair_witness_request() {
    roundtrip(&RequestMessageRepairWitnessRequest {
        binding: MessageRepairBinding {
            chat_id: ChatId::new(),
            message_id: MessageId::new(),
            server_seq: 10,
            epoch: 1,
            sender_account_id: AccountId::new(),
            sender_device_id: DeviceId::new(),
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_sha256_b64: "HASH".into(),
        },
    });
}

#[test]
fn message_repair_witness_request_summary_minimal() {
    roundtrip(&MessageRepairWitnessRequestSummary {
        request_id: "req-1".into(),
        binding: MessageRepairBinding {
            chat_id: ChatId::new(),
            message_id: MessageId::new(),
            server_seq: 5,
            epoch: 1,
            sender_account_id: AccountId::new(),
            sender_device_id: DeviceId::new(),
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_sha256_b64: "HASH".into(),
        },
        target_device_id: DeviceId::new(),
        witness_account_id: AccountId::new(),
        witness_device_id: DeviceId::new(),
        status: MessageRepairRequestStatus::Pending,
        target_transport_pubkey_b64: None,
        result_payload_b64: None,
        submitted_by_device_id: None,
        unavailable_reason: None,
        created_at_unix: 1000000,
        updated_at_unix: 1000001,
        expires_at_unix: 1001000,
    });
}

#[test]
fn request_message_repair_witness_response_none() {
    roundtrip(&RequestMessageRepairWitnessResponse { request: None });
}

#[test]
fn witness_message_repair_request_list_response() {
    roundtrip(&WitnessMessageRepairRequestListResponse { requests: vec![] });
}

#[test]
fn target_message_repair_request_list_response() {
    roundtrip(&TargetMessageRepairRequestListResponse { requests: vec![] });
}

#[test]
fn submit_message_repair_witness_result_request_completed() {
    roundtrip(&SubmitMessageRepairWitnessResultRequest {
        binding: MessageRepairBinding {
            chat_id: ChatId::new(),
            message_id: MessageId::new(),
            server_seq: 5,
            epoch: 1,
            sender_account_id: AccountId::new(),
            sender_device_id: DeviceId::new(),
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_sha256_b64: "HASH".into(),
        },
        outcome: MessageRepairWitnessOutcome::Completed,
        payload_b64: Some("PAYLOAD".into()),
        unavailable_reason: None,
    });
}

#[test]
fn submit_message_repair_witness_result_request_unavailable() {
    roundtrip(&SubmitMessageRepairWitnessResultRequest {
        binding: MessageRepairBinding {
            chat_id: ChatId::new(),
            message_id: MessageId::new(),
            server_seq: 5,
            epoch: 1,
            sender_account_id: AccountId::new(),
            sender_device_id: DeviceId::new(),
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_sha256_b64: "HASH".into(),
        },
        outcome: MessageRepairWitnessOutcome::Unavailable,
        payload_b64: None,
        unavailable_reason: Some("message not found".into()),
    });
}

#[test]
fn submit_message_repair_witness_result_response() {
    roundtrip(&SubmitMessageRepairWitnessResultResponse {
        request_id: "req-1".into(),
        status: MessageRepairRequestStatus::Completed,
    });
}

#[test]
fn complete_message_repair_witness_request_applied() {
    roundtrip(&CompleteMessageRepairWitnessRequest {
        outcome: MessageRepairTargetOutcome::Applied,
        rejection_reason: None,
    });
}

#[test]
fn complete_message_repair_witness_request_rejected() {
    roundtrip(&CompleteMessageRepairWitnessRequest {
        outcome: MessageRepairTargetOutcome::Rejected,
        rejection_reason: Some("bad payload".into()),
    });
}

#[test]
fn complete_message_repair_witness_response() {
    roundtrip(&CompleteMessageRepairWitnessResponse {
        request_id: "req-1".into(),
        status: MessageRepairRequestStatus::Consumed,
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

#[test]
fn admin_overview_response() {
    roundtrip(&AdminOverviewResponse {
        status: "ok".into(),
        service: "trixd".into(),
        version: "0.1.0".into(),
        git_sha: Some("abc123".into()),
        health_status: ServiceStatus::Ok,
        uptime_ms: 99999,
        allow_public_account_registration: true,
        user_count: 42,
        disabled_user_count: 0,
        admin_username: "admin".into(),
        admin_session_expires_at_unix: 9999999,
        debug_metrics_enabled: false,
    });
}

#[test]
fn admin_registration_settings_response() {
    roundtrip(&AdminRegistrationSettingsResponse {
        allow_public_account_registration: true,
    });
}

#[test]
fn patch_admin_registration_settings_request() {
    roundtrip(&PatchAdminRegistrationSettingsRequest {
        allow_public_account_registration: false,
    });
}

#[test]
fn admin_server_settings_response() {
    roundtrip(&AdminServerSettingsResponse {
        brand_display_name: Some("My Server".into()),
        support_contact: None,
        policy_text: None,
    });
}

#[test]
fn patch_admin_server_settings_request() {
    roundtrip(&PatchAdminServerSettingsRequest {
        brand_display_name: None,
        support_contact: None,
        policy_text: None,
    });
}

#[test]
fn admin_user_summary() {
    roundtrip(&AdminUserSummary {
        account_id: AccountId::new(),
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: None,
        created_at_unix: 1000000,
        disabled: false,
    });
}

#[test]
fn admin_user_list_response() {
    roundtrip(&AdminUserListResponse {
        users: vec![],
        next_cursor: None,
    });
}

#[test]
fn admin_user_list_response_with_cursor() {
    roundtrip(&AdminUserListResponse {
        users: vec![],
        next_cursor: Some("cursor-abc".into()),
    });
}

#[test]
fn patch_admin_user_request_empty() {
    roundtrip(&PatchAdminUserRequest {
        handle: None,
        profile_name: None,
        profile_bio: None,
    });
}

#[test]
fn patch_admin_user_request_full() {
    // Note: Some(None) represents "clear field" — it serializes as null but
    // deserializes back as None due to #[serde(default)], so only Some(Some(...)) roundtrips.
    roundtrip(&PatchAdminUserRequest {
        handle: Some(Some("newhandle".into())),
        profile_name: Some("New Name".into()),
        profile_bio: Some(Some("new bio".into())),
    });
}

#[test]
fn admin_disable_account_request() {
    roundtrip(&AdminDisableAccountRequest {
        reason: Some("violation".into()),
    });
}

#[test]
fn admin_disable_account_request_no_reason() {
    roundtrip(&AdminDisableAccountRequest { reason: None });
}

#[test]
fn create_admin_user_provision_request() {
    roundtrip(&CreateAdminUserProvisionRequest {
        handle: Some("alice".into()),
        profile_name: "Alice".into(),
        profile_bio: None,
        ttl_seconds: 3600,
    });
}

#[test]
fn create_admin_user_provision_response() {
    roundtrip(&CreateAdminUserProvisionResponse {
        provision_id: "prov-1".into(),
        provision_token: "token-abc".into(),
        expires_at_unix: 9999999,
        profile_name: "Alice".into(),
        handle: Some("alice".into()),
        profile_bio: None,
    });
}

// --- Feature Flags ---

#[test]
fn account_feature_flags_response() {
    use std::collections::BTreeMap;
    let mut flags = BTreeMap::new();
    flags.insert("feature_a".to_string(), true);
    flags.insert("feature_b".to_string(), false);
    roundtrip(&AccountFeatureFlagsResponse { revision: 3, flags });
}

#[test]
fn admin_feature_flag_definition() {
    roundtrip(&AdminFeatureFlagDefinition {
        flag_key: "dark_mode".into(),
        description: "Enable dark mode".into(),
        default_enabled: false,
        deleted_at_unix: None,
        updated_at_unix: 1000000,
    });
}

#[test]
fn admin_feature_flag_definition_deleted() {
    roundtrip(&AdminFeatureFlagDefinition {
        flag_key: "old_feature".into(),
        description: "Old feature".into(),
        default_enabled: true,
        deleted_at_unix: Some(9999999),
        updated_at_unix: 9999999,
    });
}

#[test]
fn admin_feature_flag_definition_list_response() {
    roundtrip(&AdminFeatureFlagDefinitionListResponse {
        definitions: vec![],
    });
}

#[test]
fn create_admin_feature_flag_definition_request() {
    roundtrip(&CreateAdminFeatureFlagDefinitionRequest {
        flag_key: "new_feature".into(),
        description: "A new feature".into(),
        default_enabled: true,
    });
}

#[test]
fn patch_admin_feature_flag_definition_request() {
    roundtrip(&PatchAdminFeatureFlagDefinitionRequest {
        description: Some("Updated description".into()),
        default_enabled: Some(true),
        deleted_at_unix: None,
    });
}

#[test]
fn admin_feature_flag_override_global() {
    roundtrip(&AdminFeatureFlagOverride {
        override_id: "ov-1".into(),
        flag_key: "dark_mode".into(),
        scope: FeatureFlagScope::Global,
        platform: None,
        account_id: None,
        device_id: None,
        enabled: true,
        expires_at_unix: None,
        updated_at_unix: 1000000,
    });
}

#[test]
fn admin_feature_flag_override_account() {
    roundtrip(&AdminFeatureFlagOverride {
        override_id: "ov-2".into(),
        flag_key: "beta_feature".into(),
        scope: FeatureFlagScope::Account,
        platform: None,
        account_id: Some(AccountId::new()),
        device_id: None,
        enabled: true,
        expires_at_unix: Some(9999999),
        updated_at_unix: 1000000,
    });
}

#[test]
fn admin_feature_flag_override_list_response() {
    roundtrip(&AdminFeatureFlagOverrideListResponse { overrides: vec![] });
}

#[test]
fn create_admin_feature_flag_override_request() {
    roundtrip(&CreateAdminFeatureFlagOverrideRequest {
        flag_key: "dark_mode".into(),
        scope: FeatureFlagScope::Platform,
        platform: Some("ios".into()),
        account_id: None,
        device_id: None,
        enabled: true,
        expires_at_unix: None,
    });
}

#[test]
fn patch_admin_feature_flag_override_request() {
    // Note: Some(None) represents "clear field" — it serializes as null but
    // deserializes back as None due to #[serde(default)], so only Some(Some(...)) roundtrips.
    roundtrip(&PatchAdminFeatureFlagOverrideRequest {
        enabled: Some(false),
        expires_at_unix: Some(Some(9999999)),
    });
}

// --- Debug Metrics ---

#[test]
fn account_debug_metrics_status_response_inactive() {
    roundtrip(&AccountDebugMetricsStatusResponse {
        active: false,
        session_id: None,
        user_visible_message: None,
    });
}

#[test]
fn account_debug_metrics_status_response_active() {
    roundtrip(&AccountDebugMetricsStatusResponse {
        active: true,
        session_id: Some("sess-1".into()),
        user_visible_message: Some("Debugging in progress".into()),
    });
}

#[test]
fn submit_debug_metrics_request() {
    roundtrip(&SubmitDebugMetricsRequest {
        session_id: "sess-1".into(),
        payload: serde_json::json!({"cpu": 50, "mem": 200}),
    });
}

#[test]
fn create_admin_debug_metric_session_request() {
    roundtrip(&CreateAdminDebugMetricSessionRequest {
        account_id: AccountId::new(),
        device_id: None,
        user_visible_message: "Debugging your session".into(),
        ttl_seconds: 3600,
    });
}

#[test]
fn create_admin_debug_metric_session_request_with_device() {
    roundtrip(&CreateAdminDebugMetricSessionRequest {
        account_id: AccountId::new(),
        device_id: Some(DeviceId::new()),
        user_visible_message: "Debugging".into(),
        ttl_seconds: 1800,
    });
}

#[test]
fn admin_debug_metric_session() {
    roundtrip(&AdminDebugMetricSession {
        session_id: "sess-1".into(),
        account_id: AccountId::new(),
        device_id: None,
        user_visible_message: "debug msg".into(),
        created_at_unix: 1000000,
        expires_at_unix: 1003600,
        revoked_at_unix: None,
        created_by_admin: "admin".into(),
    });
}

#[test]
fn admin_debug_metric_session_response() {
    roundtrip(&AdminDebugMetricSessionResponse {
        session: AdminDebugMetricSession {
            session_id: "sess-1".into(),
            account_id: AccountId::new(),
            device_id: None,
            user_visible_message: "debug".into(),
            created_at_unix: 1000000,
            expires_at_unix: 1003600,
            revoked_at_unix: None,
            created_by_admin: "admin".into(),
        },
    });
}

#[test]
fn admin_debug_metric_session_list_response() {
    roundtrip(&AdminDebugMetricSessionListResponse { sessions: vec![] });
}

#[test]
fn admin_debug_metric_batch() {
    roundtrip(&AdminDebugMetricBatch {
        batch_id: "batch-1".into(),
        session_id: "sess-1".into(),
        device_id: DeviceId::new(),
        received_at_unix: 1000000,
        payload: serde_json::json!({"metric": "value"}),
    });
}

#[test]
fn admin_debug_metric_batch_list_response() {
    roundtrip(&AdminDebugMetricBatchListResponse { batches: vec![] });
}

// --- Admin Server Logs ---

#[test]
fn admin_server_log_list_response() {
    roundtrip(&AdminServerLogListResponse {
        entries: vec![],
        dropped_entries: 0,
    });
}

// --- Query parameter types ---

#[test]
fn list_history_sync_jobs_query() {
    use trix_types::ListHistorySyncJobsQuery;
    roundtrip_json(&ListHistorySyncJobsQuery {
        role: Some(HistorySyncJobRole::Source),
        status: Some(HistorySyncJobStatus::Running),
        limit: Some(10),
    });
}

#[test]
fn list_history_sync_jobs_query_empty() {
    use trix_types::ListHistorySyncJobsQuery;
    roundtrip_json(&ListHistorySyncJobsQuery {
        role: None,
        status: None,
        limit: None,
    });
}

#[test]
fn chat_history_query() {
    use trix_types::ChatHistoryQuery;
    roundtrip_json(&ChatHistoryQuery {
        after_server_seq: Some(42),
        limit: Some(100),
    });
}

#[test]
fn inbox_query() {
    use trix_types::InboxQuery;
    roundtrip_json(&InboxQuery {
        after_inbox_id: Some(5),
        limit: Some(50),
    });
}

#[test]
fn account_directory_query() {
    use trix_types::AccountDirectoryQuery;
    roundtrip_json(&AccountDirectoryQuery {
        q: Some("alice".into()),
        limit: Some(20),
        exclude_self: true,
    });
}

#[test]
fn admin_list_users_query() {
    use trix_types::AdminListUsersQuery;
    roundtrip_json(&AdminListUsersQuery {
        q: Some("alice".into()),
        status: Some("active".into()),
        cursor: None,
        limit: Some(25),
    });
}

#[test]
fn admin_list_flag_overrides_query() {
    use trix_types::AdminListFlagOverridesQuery;
    roundtrip_json(&AdminListFlagOverridesQuery {
        flag_key: Some("dark_mode".into()),
        scope: Some("global".into()),
        platform: None,
        account_id: None,
        device_id: None,
    });
}

#[test]
fn admin_list_debug_metric_sessions_query() {
    use trix_types::AdminListDebugMetricSessionsQuery;
    roundtrip_json(&AdminListDebugMetricSessionsQuery {
        account_id: None,
        limit: Some(10),
    });
}

#[test]
fn admin_list_debug_metric_batches_query() {
    use trix_types::AdminListDebugMetricBatchesQuery;
    roundtrip_json(&AdminListDebugMetricBatchesQuery { limit: Some(50) });
}

// --- Model enums: all variants ---

#[test]
fn device_status_all_variants() {
    roundtrip(&DeviceStatus::Pending);
    roundtrip(&DeviceStatus::Active);
    roundtrip(&DeviceStatus::Revoked);
}

#[test]
fn chat_type_all_variants() {
    roundtrip(&ChatType::Dm);
    roundtrip(&ChatType::Group);
    roundtrip(&ChatType::AccountSync);
}

#[test]
fn message_kind_all_variants() {
    roundtrip(&MessageKind::Application);
    roundtrip(&MessageKind::Commit);
    roundtrip(&MessageKind::WelcomeRef);
    roundtrip(&MessageKind::System);
}

#[test]
fn content_type_all_variants() {
    roundtrip(&ContentType::Text);
    roundtrip(&ContentType::Reaction);
    roundtrip(&ContentType::Receipt);
    roundtrip(&ContentType::Attachment);
    roundtrip(&ContentType::ChatEvent);
}

#[test]
fn history_sync_job_type_all_variants() {
    roundtrip(&HistorySyncJobType::InitialSync);
    roundtrip(&HistorySyncJobType::ChatBackfill);
    roundtrip(&HistorySyncJobType::DeviceRekey);
    roundtrip(&HistorySyncJobType::TimelineRepair);
}

#[test]
fn history_sync_job_status_all_variants() {
    roundtrip(&HistorySyncJobStatus::Pending);
    roundtrip(&HistorySyncJobStatus::Running);
    roundtrip(&HistorySyncJobStatus::Completed);
    roundtrip(&HistorySyncJobStatus::Failed);
    roundtrip(&HistorySyncJobStatus::Canceled);
}

#[test]
fn history_sync_job_role_all_variants() {
    roundtrip(&HistorySyncJobRole::Source);
    roundtrip(&HistorySyncJobRole::Target);
}

#[test]
fn message_repair_request_status_all_variants() {
    roundtrip(&MessageRepairRequestStatus::Pending);
    roundtrip(&MessageRepairRequestStatus::Completed);
    roundtrip(&MessageRepairRequestStatus::Unavailable);
    roundtrip(&MessageRepairRequestStatus::Consumed);
    roundtrip(&MessageRepairRequestStatus::Expired);
}

#[test]
fn message_repair_witness_outcome_all_variants() {
    roundtrip(&MessageRepairWitnessOutcome::Completed);
    roundtrip(&MessageRepairWitnessOutcome::Unavailable);
}

#[test]
fn message_repair_target_outcome_all_variants() {
    roundtrip(&MessageRepairTargetOutcome::Applied);
    roundtrip(&MessageRepairTargetOutcome::Rejected);
}

#[test]
fn feature_flag_scope_all_variants() {
    roundtrip(&FeatureFlagScope::Global);
    roundtrip(&FeatureFlagScope::Platform);
    roundtrip(&FeatureFlagScope::Account);
    roundtrip(&FeatureFlagScope::Device);
}

#[test]
fn blob_upload_status_all_variants() {
    roundtrip(&BlobUploadStatus::PendingUpload);
    roundtrip(&BlobUploadStatus::Available);
}

#[test]
fn service_status_all_variants() {
    roundtrip(&ServiceStatus::Ok);
    roundtrip(&ServiceStatus::Degraded);
}

#[test]
fn apple_push_environment_all_variants() {
    roundtrip(&ApplePushEnvironment::Sandbox);
    roundtrip(&ApplePushEnvironment::Production);
}

#[test]
fn leave_chat_scope_all_variants() {
    roundtrip(&LeaveChatScope::ThisDevice);
    roundtrip(&LeaveChatScope::AllMyDevices);
}
