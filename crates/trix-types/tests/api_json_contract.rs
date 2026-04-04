use serde_json::{Value, json};
use trix_types::{
    AccountDirectoryResponse, AccountId, AccountProfileResponse, AuthSessionResponse,
    BlobUploadStatus, ChatId, CreateAccountRequest, CreateLinkIntentResponse, DeviceId,
    DeviceListResponse, DeviceStatus, DeviceSummary, DeviceTransferBundleResponse,
    DeviceTransportKeyResponse, DmGlobalDeleteRequest, DmGlobalDeleteResponse, HealthResponse,
    HistorySyncJobType, LeaveChatRequest, LeaveChatResponse, LeaveChatScope, ServiceStatus,
    VersionResponse,
};
use uuid::Uuid;

fn fixed_uuid(seed: u128) -> Uuid {
    Uuid::from_u128(seed)
}

#[test]
fn service_status_json_values_are_stable() {
    assert_eq!(
        serde_json::to_value(ServiceStatus::Ok).unwrap(),
        json!("ok")
    );
    assert_eq!(
        serde_json::to_value(ServiceStatus::Degraded).unwrap(),
        json!("degraded")
    );
}

#[test]
fn contract_enums_keep_snake_case_wire_values() {
    assert_eq!(
        serde_json::to_value(DeviceStatus::Pending).unwrap(),
        json!("pending")
    );
    assert_eq!(
        serde_json::to_value(BlobUploadStatus::PendingUpload).unwrap(),
        json!("pending_upload")
    );
    assert_eq!(
        serde_json::to_value(HistorySyncJobType::TimelineRepair).unwrap(),
        json!("timeline_repair")
    );
    assert_eq!(
        serde_json::to_value(LeaveChatScope::ThisDevice).unwrap(),
        json!("this_device")
    );
    assert_eq!(
        serde_json::to_value(LeaveChatScope::AllMyDevices).unwrap(),
        json!("all_my_devices")
    );
}

#[test]
fn health_response_json_shape_is_stable() {
    let payload = serde_json::to_value(HealthResponse {
        service: "trixd".to_owned(),
        status: ServiceStatus::Ok,
        version: "0.1.0".to_owned(),
        uptime_ms: 42,
    })
    .unwrap();

    assert_eq!(
        payload,
        json!({
            "service": "trixd",
            "status": "ok",
            "version": "0.1.0",
            "uptime_ms": 42
        })
    );
}

#[test]
fn version_response_json_shape_is_stable() {
    let payload = serde_json::to_value(VersionResponse {
        service: "trixd".to_owned(),
        version: "0.1.0".to_owned(),
        git_sha: Some("abc123".to_owned()),
    })
    .unwrap();

    assert_eq!(
        payload,
        json!({
            "service": "trixd",
            "version": "0.1.0",
            "git_sha": "abc123"
        })
    );
}

#[test]
fn create_account_request_json_shape_is_stable() {
    let payload = serde_json::to_value(CreateAccountRequest {
        handle: Some("alice".to_owned()),
        profile_name: "Alice".to_owned(),
        profile_bio: Some("hello".to_owned()),
        device_display_name: "Alice Phone".to_owned(),
        platform: "ios".to_owned(),
        credential_identity_b64: "cred".to_owned(),
        account_root_pubkey_b64: "root-pub".to_owned(),
        account_root_signature_b64: "root-sig".to_owned(),
        transport_pubkey_b64: "transport".to_owned(),
        provision_token: Some("token".to_owned()),
    })
    .unwrap();

    assert_eq!(
        payload,
        json!({
            "handle": "alice",
            "profile_name": "Alice",
            "profile_bio": "hello",
            "device_display_name": "Alice Phone",
            "platform": "ios",
            "credential_identity_b64": "cred",
            "account_root_pubkey_b64": "root-pub",
            "account_root_signature_b64": "root-sig",
            "transport_pubkey_b64": "transport",
            "provision_token": "token"
        })
    );
}

#[test]
fn auth_session_response_json_shape_is_stable() {
    let payload = serde_json::to_value(AuthSessionResponse {
        access_token: "token".to_owned(),
        expires_at_unix: 1_700_000_000,
        account_id: AccountId(fixed_uuid(1)),
        device_status: DeviceStatus::Active,
    })
    .unwrap();

    assert_eq!(
        payload,
        json!({
            "access_token": "token",
            "expires_at_unix": 1_700_000_000u64,
            "account_id": fixed_uuid(1).to_string(),
            "device_status": "active"
        })
    );
}

#[test]
fn account_profile_response_json_shape_is_stable() {
    let payload = serde_json::to_value(AccountProfileResponse {
        account_id: AccountId(fixed_uuid(2)),
        handle: Some("alice".to_owned()),
        profile_name: "Alice".to_owned(),
        profile_bio: None,
        device_id: DeviceId(fixed_uuid(3)),
        device_status: DeviceStatus::Active,
    })
    .unwrap();

    assert_eq!(
        payload,
        json!({
            "account_id": fixed_uuid(2).to_string(),
            "handle": "alice",
            "profile_name": "Alice",
            "profile_bio": Value::Null,
            "device_id": fixed_uuid(3).to_string(),
            "device_status": "active"
        })
    );
}

#[test]
fn directory_and_device_list_json_shapes_are_stable() {
    let directory = serde_json::to_value(AccountDirectoryResponse {
        accounts: vec![trix_types::DirectoryAccountSummary {
            account_id: AccountId(fixed_uuid(4)),
            handle: Some("bob".to_owned()),
            profile_name: "Bob".to_owned(),
            profile_bio: Some("bio".to_owned()),
        }],
    })
    .unwrap();
    assert_eq!(
        directory,
        json!({
            "accounts": [{
                "account_id": fixed_uuid(4).to_string(),
                "handle": "bob",
                "profile_name": "Bob",
                "profile_bio": "bio"
            }]
        })
    );

    let devices = serde_json::to_value(DeviceListResponse {
        account_id: AccountId(fixed_uuid(5)),
        devices: vec![DeviceSummary {
            device_id: DeviceId(fixed_uuid(6)),
            display_name: "Bob Phone".to_owned(),
            platform: "ios".to_owned(),
            device_status: DeviceStatus::Pending,
            available_key_package_count: 7,
        }],
    })
    .unwrap();
    assert_eq!(
        devices,
        json!({
            "account_id": fixed_uuid(5).to_string(),
            "devices": [{
                "device_id": fixed_uuid(6).to_string(),
                "display_name": "Bob Phone",
                "platform": "ios",
                "device_status": "pending",
                "available_key_package_count": 7
            }]
        })
    );
}

#[test]
fn leave_chat_and_dm_global_delete_json_shapes_are_stable() {
    let leave_req = serde_json::to_value(LeaveChatRequest {
        scope: LeaveChatScope::AllMyDevices,
        epoch: 3,
        commit_message: None,
    })
    .unwrap();
    assert_eq!(
        leave_req,
        json!({
            "scope": "all_my_devices",
            "epoch": 3u64,
            "commit_message": Value::Null
        })
    );

    let leave_res = serde_json::to_value(LeaveChatResponse {
        chat_id: ChatId(fixed_uuid(20)),
        epoch: 4,
        changed_device_ids: vec![DeviceId(fixed_uuid(21))],
    })
    .unwrap();
    assert_eq!(
        leave_res,
        json!({
            "chat_id": fixed_uuid(20).to_string(),
            "epoch": 4u64,
            "changed_device_ids": [fixed_uuid(21).to_string()]
        })
    );

    let dm_req = serde_json::to_value(DmGlobalDeleteRequest {
        epoch: 1,
        commit_message: None,
    })
    .unwrap();
    assert_eq!(
        dm_req,
        json!({
            "epoch": 1u64,
            "commit_message": Value::Null
        })
    );

    let dm_res = serde_json::to_value(DmGlobalDeleteResponse {
        chat_id: ChatId(fixed_uuid(22)),
        epoch: 2,
        changed_account_ids: vec![AccountId(fixed_uuid(23)), AccountId(fixed_uuid(24))],
        changed_device_ids: vec![DeviceId(fixed_uuid(25))],
    })
    .unwrap();
    assert_eq!(
        dm_res,
        json!({
            "chat_id": fixed_uuid(22).to_string(),
            "epoch": 2u64,
            "changed_account_ids": [
                fixed_uuid(23).to_string(),
                fixed_uuid(24).to_string()
            ],
            "changed_device_ids": [fixed_uuid(25).to_string()]
        })
    );
}

#[test]
fn create_link_intent_response_json_shape_is_stable() {
    let payload = serde_json::to_value(CreateLinkIntentResponse {
        link_intent_id: "intent-123".to_owned(),
        qr_payload: "qr-payload".to_owned(),
        expires_at_unix: 1_700_000_100,
    })
    .unwrap();

    assert_eq!(
        payload,
        json!({
            "link_intent_id": "intent-123",
            "qr_payload": "qr-payload",
            "expires_at_unix": 1_700_000_100u64
        })
    );
}

#[test]
fn device_transport_and_transfer_json_shapes_are_stable() {
    let transport = serde_json::to_value(DeviceTransportKeyResponse {
        device_id: DeviceId(fixed_uuid(7)),
        device_status: DeviceStatus::Pending,
        transport_pubkey_b64: "transport-key".to_owned(),
    })
    .unwrap();
    assert_eq!(
        transport,
        json!({
            "device_id": fixed_uuid(7).to_string(),
            "device_status": "pending",
            "transport_pubkey_b64": "transport-key"
        })
    );

    let transfer = serde_json::to_value(DeviceTransferBundleResponse {
        account_id: AccountId(fixed_uuid(8)),
        device_id: DeviceId(fixed_uuid(9)),
        transfer_bundle_b64: "bundle".to_owned(),
        uploaded_at_unix: 1_700_000_200,
    })
    .unwrap();
    assert_eq!(
        transfer,
        json!({
            "account_id": fixed_uuid(8).to_string(),
            "device_id": fixed_uuid(9).to_string(),
            "transfer_bundle_b64": "bundle",
            "uploaded_at_unix": 1_700_000_200u64
        })
    );
}
