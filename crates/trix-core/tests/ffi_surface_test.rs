//! FFI Surface Coverage Tests
//!
//! Validates that all FFI-exported types and functions from `trix-core` can be
//! instantiated and exercised without panicking. These tests do NOT require a
//! running server or database — they cover the client-local subset of the FFI
//! surface that Swift, Kotlin, and bot clients rely on.

use std::{env, fs};

use trix_core::*;
use trix_types::ContentType;
use uuid::Uuid;

// ─── Helpers ───

fn temp_dir(label: &str) -> std::path::PathBuf {
    let dir = env::temp_dir().join(format!("trix-ffi-test-{}-{}", label, Uuid::new_v4()));
    fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

// ─── 1. Crypto key material ───

#[test]
fn account_root_material_generate_and_roundtrip() {
    let root = FfiAccountRootMaterial::generate();
    let private_key = root.private_key_bytes();
    assert_eq!(private_key.len(), 32);
    let public_key = root.public_key_bytes();
    assert!(!public_key.is_empty());

    let restored = FfiAccountRootMaterial::from_private_key(private_key.clone()).unwrap();
    assert_eq!(restored.public_key_bytes(), public_key);
    assert_eq!(restored.private_key_bytes(), private_key);
}

#[test]
fn device_key_material_generate_and_roundtrip() {
    let keys = FfiDeviceKeyMaterial::generate();
    let private_key = keys.private_key_bytes();
    assert_eq!(private_key.len(), 32);
    let public_key = keys.public_key_bytes();
    assert!(!public_key.is_empty());

    let restored = FfiDeviceKeyMaterial::from_private_key(private_key.clone()).unwrap();
    assert_eq!(restored.public_key_bytes(), public_key);
}

#[test]
fn account_root_signatures_verify_with_core_key() {
    let root = FfiAccountRootMaterial::generate();
    let payload = b"test-payload".to_vec();
    let signature = root.sign(payload.clone());
    assert!(!signature.is_empty());
    let verifier = AccountRootMaterial::from_bytes(root.private_key_bytes().try_into().unwrap());
    verifier.verify(&payload, &signature).unwrap();

    let tampered = b"tampered".to_vec();
    verifier.verify(&tampered, &signature).unwrap_err();
}

#[test]
fn device_key_signatures_verify_with_core_key() {
    let keys = FfiDeviceKeyMaterial::generate();
    let payload = b"device-payload".to_vec();
    let signature = keys.sign(payload.clone());
    let verifier = DeviceKeyMaterial::from_bytes(keys.private_key_bytes().try_into().unwrap());
    verifier.verify(&payload, &signature).unwrap();

    verifier.verify(b"wrong", &signature).unwrap_err();
}

#[test]
fn sign_auth_challenge_produces_valid_signature() {
    let keys = FfiDeviceKeyMaterial::generate();
    let challenge = b"auth-challenge-bytes".to_vec();
    let sig = keys.sign_auth_challenge(challenge.clone());
    let verifier = DeviceKeyMaterial::from_bytes(keys.private_key_bytes().try_into().unwrap());
    verifier.verify(&challenge, &sig).unwrap();
}

// ─── 2. Account bootstrap & device revoke helpers ───

#[test]
fn account_bootstrap_payload_and_sign() {
    let root = FfiAccountRootMaterial::generate();
    let transport = vec![1, 2, 3];
    let credential = vec![4, 5, 6];
    let verifier = AccountRootMaterial::from_bytes(root.private_key_bytes().try_into().unwrap());
    let payload = root.account_bootstrap_payload(transport.clone(), credential.clone());
    assert!(payload.starts_with(b"trix-account-bootstrap:v1"));

    let signature = root.sign_account_bootstrap(transport.clone(), credential.clone());
    verifier.verify(&payload, &signature).unwrap();

    let standalone = account_bootstrap_message(&transport, &credential);
    assert_eq!(standalone, payload);
}

#[test]
fn device_revoke_payload_and_sign() {
    let root = FfiAccountRootMaterial::generate();
    let device_id = Uuid::new_v4().to_string();
    let reason = "test revocation".to_string();
    let verifier = AccountRootMaterial::from_bytes(root.private_key_bytes().try_into().unwrap());

    let payload = root
        .device_revoke_payload(device_id.clone(), reason.clone())
        .unwrap();
    assert!(payload.starts_with(b"trix-device-revoke:v1"));

    let signature = root
        .sign_device_revoke(device_id.clone(), reason.clone())
        .unwrap();
    verifier.verify(&payload, &signature).unwrap();

    let standalone = device_revoke_message(uuid::Uuid::parse_str(&device_id).unwrap(), &reason);
    assert_eq!(standalone, payload);
}

// ─── 3. Device transfer bundle ───

#[test]
fn device_transfer_bundle_encrypt_decrypt_round_trip() {
    let root = FfiAccountRootMaterial::generate();
    let sender_device = FfiDeviceKeyMaterial::generate();
    let recipient_device = FfiDeviceKeyMaterial::generate();

    let account_id = Uuid::new_v4().to_string();
    let source_device_id = Uuid::new_v4().to_string();
    let target_device_id = Uuid::new_v4().to_string();
    let account_sync_chat_id = Uuid::new_v4().to_string();

    let bundle = root
        .create_device_transfer_bundle(
            FfiCreateDeviceTransferBundleParams {
                account_id: account_id.clone(),
                source_device_id: source_device_id.clone(),
                target_device_id: target_device_id.clone(),
                account_sync_chat_id: Some(account_sync_chat_id.clone()),
            },
            sender_device,
            recipient_device.public_key_bytes(),
        )
        .unwrap();
    assert!(!bundle.is_empty());

    let imported = recipient_device
        .decrypt_device_transfer_bundle(bundle)
        .unwrap();
    assert_eq!(imported.account_id, account_id);
    assert_eq!(imported.source_device_id, source_device_id);
    assert_eq!(imported.target_device_id, target_device_id);
    assert_eq!(imported.account_sync_chat_id, Some(account_sync_chat_id));
    assert_eq!(imported.account_root_public_key, root.public_key_bytes());
    assert!(!imported.account_root_private_key.is_empty());
}

// ─── 4. Message body serialize / parse round-trip ───

#[test]
fn message_body_text_round_trip() {
    let body = MessageBody::Text(TextMessageBody {
        text: "hello".to_owned(),
    });
    let serialized = body.to_bytes().unwrap();
    assert!(!serialized.is_empty());

    let parsed = MessageBody::from_bytes(ContentType::Text, &serialized).unwrap();
    assert_eq!(
        parsed,
        MessageBody::Text(TextMessageBody {
            text: "hello".to_owned()
        })
    );

    // Plaintext fallback
    let plain = MessageBody::from_bytes(ContentType::Text, b"plaintext hello").unwrap();
    assert_eq!(
        plain,
        MessageBody::Text(TextMessageBody {
            text: "plaintext hello".to_owned()
        })
    );
}

#[test]
fn message_body_reaction_round_trip() {
    let target_id = trix_types::MessageId(Uuid::new_v4());
    let body = MessageBody::Reaction(ReactionMessageBody {
        target_message_id: target_id,
        emoji: "🔥".to_owned(),
        action: ReactionAction::Add,
    });

    let serialized = body.to_bytes().unwrap();
    let parsed = MessageBody::from_bytes(ContentType::Reaction, &serialized).unwrap();
    match &parsed {
        MessageBody::Reaction(r) => {
            assert_eq!(r.emoji, "🔥");
            assert_eq!(r.action, ReactionAction::Add);
            assert_eq!(r.target_message_id, target_id);
        }
        _ => panic!("expected reaction body"),
    }
}

#[test]
fn message_body_receipt_round_trip() {
    let target_id = trix_types::MessageId(Uuid::new_v4());
    let body = MessageBody::Receipt(ReceiptMessageBody {
        target_message_id: target_id,
        receipt_type: ReceiptType::Read,
        at_unix: Some(1700000000),
    });

    let serialized = body.to_bytes().unwrap();
    let parsed = MessageBody::from_bytes(ContentType::Receipt, &serialized).unwrap();
    match &parsed {
        MessageBody::Receipt(r) => {
            assert_eq!(r.receipt_type, ReceiptType::Read);
            assert_eq!(r.at_unix, Some(1700000000));
        }
        _ => panic!("expected receipt body"),
    }
}

#[test]
fn message_body_chat_event_round_trip() {
    let body = MessageBody::ChatEvent(ChatEventMessageBody {
        event_type: "member_joined".to_owned(),
        payload_json: serde_json::json!({"account_id": "abc"}),
    });

    let serialized = body.to_bytes().unwrap();
    let parsed = MessageBody::from_bytes(ContentType::ChatEvent, &serialized).unwrap();
    match &parsed {
        MessageBody::ChatEvent(e) => {
            assert_eq!(e.event_type, "member_joined");
        }
        _ => panic!("expected chat event body"),
    }
}

// ─── 5. Attachment helpers ───

#[test]
fn attachment_prepare_and_decrypt_round_trip() {
    let payload = b"attachment plaintext content";
    let prepared = prepare_attachment_upload(
        payload,
        "image/png",
        Some("photo.png".to_owned()),
        Some(640),
        Some(480),
    )
    .unwrap();

    assert_eq!(prepared.mime_type, "image/png");
    assert_eq!(prepared.plaintext_size_bytes, payload.len() as u64);
    assert!(prepared.encrypted_size_bytes >= prepared.plaintext_size_bytes);

    let body = prepared
        .clone()
        .into_message_body("blob-test-123".to_owned());
    assert_eq!(body.blob_id, "blob-test-123");
    assert_eq!(body.mime_type, "image/png");

    let decrypted = decrypt_attachment_payload(&body, &prepared.encrypted_payload).unwrap();
    assert_eq!(decrypted, payload);
}

// ─── 6. MLS facade (persistent) ───

#[test]
fn mls_facade_persistent_create_and_inspect() {
    let root = temp_dir("mls-create");
    let credential = b"test-credential".to_vec();
    let facade =
        FfiMlsFacade::new_persistent(credential.clone(), root.display().to_string()).unwrap();

    assert_eq!(facade.credential_identity().unwrap(), credential);
    assert!(!facade.ciphersuite_label().unwrap().is_empty());
    assert!(!facade.signature_public_key().unwrap().is_empty());

    fs::remove_dir_all(&root).ok();
}

#[test]
fn mls_facade_persistent_create_reload() {
    let root = temp_dir("mls-persist");
    let credential = b"persist-credential".to_vec();
    let facade =
        FfiMlsFacade::new_persistent(credential.clone(), root.display().to_string()).unwrap();
    facade.save_state().unwrap();

    assert_eq!(
        facade.storage_root().unwrap(),
        Some(root.display().to_string())
    );

    let reloaded = FfiMlsFacade::load_persistent(root.display().to_string()).unwrap();
    assert_eq!(reloaded.credential_identity().unwrap(), credential);

    fs::remove_dir_all(&root).ok();
}

#[test]
fn mls_facade_generate_key_packages() {
    let root = temp_dir("mls-key-packages");
    let facade =
        FfiMlsFacade::new_persistent(b"kp-credential".to_vec(), root.display().to_string())
            .unwrap();
    let packages = facade.generate_key_packages(3).unwrap();
    assert_eq!(packages.len(), 3);
    assert!(packages.iter().all(|kp| !kp.is_empty()));

    fs::remove_dir_all(&root).ok();
}

#[test]
fn mls_facade_generate_publish_key_packages_sets_ciphersuite() {
    let root = temp_dir("mls-publish-packages");
    let facade =
        FfiMlsFacade::new_persistent(b"pub-kp-credential".to_vec(), root.display().to_string())
            .unwrap();
    let publish_packages = facade.generate_publish_key_packages(2).unwrap();
    assert_eq!(publish_packages.len(), 2);
    let ciphersuite = facade.ciphersuite_label().unwrap();
    for pkg in &publish_packages {
        assert_eq!(pkg.cipher_suite, ciphersuite);
        assert!(!pkg.key_package.is_empty());
    }

    fs::remove_dir_all(&root).ok();
}

#[test]
fn mls_facade_create_group_and_inspect() {
    let root = temp_dir("mls-group");
    let facade =
        FfiMlsFacade::new_persistent(b"group-credential".to_vec(), root.display().to_string())
            .unwrap();
    let group_id = Uuid::new_v4().as_bytes().to_vec();
    let conversation = facade.create_group(group_id.clone()).unwrap();

    assert_eq!(conversation.group_id().unwrap(), group_id);
    assert_eq!(conversation.epoch().unwrap(), 0);

    let ratchet_tree = conversation.export_ratchet_tree().unwrap();
    assert!(!ratchet_tree.is_empty());

    let members = facade.members(conversation).unwrap();
    assert_eq!(members.len(), 1);
    assert_eq!(members[0].credential_identity, b"group-credential");

    fs::remove_dir_all(&root).ok();
}

#[test]
fn mls_facade_add_member_and_welcome_round_trip() {
    let root_a = temp_dir("mls-alice");
    let root_b = temp_dir("mls-bob");
    let facade_a =
        FfiMlsFacade::new_persistent(b"alice-mls".to_vec(), root_a.display().to_string()).unwrap();
    let facade_b =
        FfiMlsFacade::new_persistent(b"bob-mls".to_vec(), root_b.display().to_string()).unwrap();

    let group_id = Uuid::new_v4().as_bytes().to_vec();
    let conversation_a = facade_a.create_group(group_id.clone()).unwrap();

    let bob_kp = facade_b.generate_key_package().unwrap();
    let commit_bundle = facade_a
        .add_members(conversation_a.clone(), vec![bob_kp])
        .unwrap();
    assert!(!commit_bundle.commit_message.is_empty());
    assert!(commit_bundle.welcome_message.is_some());
    assert_eq!(commit_bundle.epoch, 1);

    // Bob joins via welcome
    let conversation_b = facade_b
        .join_group_from_welcome(
            commit_bundle.welcome_message.unwrap(),
            commit_bundle.ratchet_tree,
        )
        .unwrap();
    assert_eq!(conversation_b.group_id().unwrap(), group_id);
    assert_eq!(conversation_b.epoch().unwrap(), 1);

    // Bob's group has both members
    let bob_members = facade_b.members(conversation_b).unwrap();
    assert_eq!(bob_members.len(), 2);
    let identities: Vec<&[u8]> = bob_members
        .iter()
        .map(|m| m.credential_identity.as_slice())
        .collect();
    assert!(identities.contains(&b"alice-mls".as_slice()));
    assert!(identities.contains(&b"bob-mls".as_slice()));

    fs::remove_dir_all(&root_a).ok();
    fs::remove_dir_all(&root_b).ok();
}

// ─── 7. Local History Store (persistent) ───

#[test]
fn local_history_store_persistent_basic_ops() {
    let root = temp_dir("history-store-basic");
    let db_path = root.join("history.sqlite");
    let store = FfiLocalHistoryStore::new_persistent(db_path.display().to_string()).unwrap();
    let chats = store.list_chats().unwrap();
    assert!(chats.is_empty());
    assert_eq!(
        store.database_path().unwrap(),
        Some(db_path.display().to_string())
    );

    fs::remove_dir_all(&root).ok();
}

#[test]
fn local_history_store_persistent_crud() {
    let root = temp_dir("history-store");
    let db_path = root.join("history.sqlite");

    let store = FfiLocalHistoryStore::new_persistent(db_path.display().to_string()).unwrap();
    store.save_state().unwrap();
    assert_eq!(
        store.database_path().unwrap(),
        Some(db_path.display().to_string())
    );

    let chats = store.list_chats().unwrap();
    assert!(chats.is_empty());

    fs::remove_dir_all(&root).ok();
}

#[test]
fn local_history_store_outbox_lifecycle() {
    let root = temp_dir("history-store-outbox");
    let db_path = root.join("history.sqlite");
    let store = FfiLocalHistoryStore::new_persistent(db_path.display().to_string()).unwrap();
    let chat_id = Uuid::new_v4().to_string();
    let account_id = Uuid::new_v4().to_string();
    let device_id = Uuid::new_v4().to_string();
    let message_id = Uuid::new_v4().to_string();

    let body = FfiMessageBody {
        kind: FfiMessageBodyKind::Text,
        text: Some("outbox test".to_owned()),
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
    };

    let item = store
        .enqueue_outbox_message(
            chat_id.clone(),
            account_id,
            device_id,
            message_id.clone(),
            body,
            1700000000,
        )
        .unwrap();
    assert_eq!(item.message_id, message_id);
    assert!(matches!(item.status, FfiLocalOutboxStatus::Pending));

    let items = store.list_outbox_messages(Some(chat_id)).unwrap();
    assert_eq!(items.len(), 1);

    store
        .mark_outbox_failure(message_id.clone(), "test failure".to_owned())
        .unwrap();
    let items = store.list_outbox_messages(None).unwrap();
    assert_eq!(items[0].failure_message.as_deref(), Some("test failure"));

    store.clear_outbox_failure(message_id.clone()).unwrap();
    store.remove_outbox_message(message_id).unwrap();

    let items = store.list_outbox_messages(None).unwrap();
    assert!(items.is_empty());

    fs::remove_dir_all(&root).ok();
}

// ─── 8. Sync Coordinator ───

#[test]
fn sync_coordinator_persistent_state_snapshot() {
    let root = temp_dir("sync-coord-snapshot");
    let state_path = root.join("sync-state.sqlite");
    let coordinator = FfiSyncCoordinator::new_persistent(state_path.display().to_string()).unwrap();
    let snapshot = coordinator.state_snapshot().unwrap();
    assert!(!snapshot.lease_owner.is_empty());
    assert!(snapshot.last_acked_inbox_id.is_none());
    assert!(snapshot.chat_cursors.is_empty());

    fs::remove_dir_all(&root).ok();
}

#[test]
fn sync_coordinator_persistent() {
    let root = temp_dir("sync-coord");
    let state_path = root.join("sync-state.sqlite");

    let coordinator = FfiSyncCoordinator::new_persistent(state_path.display().to_string()).unwrap();
    coordinator.save_state().unwrap();
    assert_eq!(
        coordinator.state_path().unwrap(),
        Some(state_path.display().to_string())
    );

    let chat_id = Uuid::new_v4().to_string();
    let advanced = coordinator
        .record_chat_server_seq(chat_id.clone(), 42)
        .unwrap();
    assert!(advanced);
    assert_eq!(coordinator.chat_cursor(chat_id).unwrap(), Some(42));

    fs::remove_dir_all(&root).ok();
}

// ─── 9. FfiClientStore ───

#[test]
fn client_store_open_and_access_substores() {
    let root = temp_dir("client-store");
    let db_path = root.join("client.sqlite");
    let cache_root = root.join("attachments");

    let store = FfiClientStore::open(FfiClientStoreConfig {
        database_path: db_path.display().to_string(),
        database_key: vec![0u8; 32],
        attachment_cache_root: cache_root.display().to_string(),
    })
    .unwrap();

    assert_eq!(store.database_path(), db_path.display().to_string());
    assert!(!store.mls_storage_root().is_empty());

    let history = store.history_store();
    let chats = history.list_chats().unwrap();
    assert!(chats.is_empty());

    let sync = store.sync_coordinator();
    let snapshot = sync.state_snapshot().unwrap();
    assert!(!snapshot.lease_owner.is_empty());

    let credential = b"client-store-cred".to_vec();
    let facade = store.open_mls_facade(credential.clone()).unwrap();
    assert_eq!(facade.credential_identity().unwrap(), credential);

    // Re-open to verify persistence
    let facade2 = store.open_mls_facade(credential.clone()).unwrap();
    assert_eq!(facade2.credential_identity().unwrap(), credential);

    fs::remove_dir_all(&root).ok();
}

// ─── 10. Realtime driver ───

#[test]
fn realtime_driver_constructors_work() {
    FfiRealtimeDriver::new().unwrap();

    let custom_config = FfiRealtimeConfig {
        inbox_limit: 10,
        inbox_lease_ttl_seconds: 5,
        poll_interval_ms: 500,
        websocket_retry_delay_ms: 1000,
    };
    FfiRealtimeDriver::with_config(custom_config).unwrap();
}

// ─── 11. Default ciphersuite ───

#[test]
fn default_ciphersuite_label_is_non_empty() {
    let label = trix_core::DEFAULT_CIPHERSUITE.to_string();
    assert!(!label.is_empty());
}

// ─── 12. Read state operations ───

#[test]
fn local_history_store_read_state_operations() {
    let root = temp_dir("history-store-read-state");
    let db_path = root.join("history.sqlite");
    let store = FfiLocalHistoryStore::new_persistent(db_path.display().to_string()).unwrap();
    let chat_id = Uuid::new_v4().to_string();
    let self_account_id = Uuid::new_v4().to_string();

    // No read state before any data
    let state = store
        .get_chat_read_state(chat_id.clone(), Some(self_account_id.clone()))
        .unwrap();
    assert!(state.is_none());

    let all_states = store
        .list_chat_read_states(Some(self_account_id.clone()))
        .unwrap();
    assert!(all_states.is_empty());

    fs::remove_dir_all(&root).ok();
}

// ─── 13. Enum conversions (ensure all variants exist) ───

#[test]
fn ffi_enums_cover_all_variants() {
    // Device status
    let _ = FfiDeviceStatus::Pending;
    let _ = FfiDeviceStatus::Active;
    let _ = FfiDeviceStatus::Revoked;

    // Chat type
    let _ = FfiChatType::Dm;
    let _ = FfiChatType::Group;
    let _ = FfiChatType::AccountSync;

    // Message kind
    let _ = FfiMessageKind::Application;
    let _ = FfiMessageKind::Commit;
    let _ = FfiMessageKind::WelcomeRef;
    let _ = FfiMessageKind::System;

    // Content type
    let _ = FfiContentType::Text;
    let _ = FfiContentType::Reaction;
    let _ = FfiContentType::Receipt;
    let _ = FfiContentType::Attachment;
    let _ = FfiContentType::ChatEvent;

    // Projection kind
    let _ = FfiLocalProjectionKind::ApplicationMessage;
    let _ = FfiLocalProjectionKind::ProposalQueued;
    let _ = FfiLocalProjectionKind::CommitMerged;
    let _ = FfiLocalProjectionKind::WelcomeRef;
    let _ = FfiLocalProjectionKind::System;

    // Realtime
    let _ = FfiRealtimeMode::Websocket;
    let _ = FfiRealtimeMode::Polling;
    let _ = FfiRealtimeMode::Disconnected;

    // MLS process
    let _ = FfiMlsProcessKind::ApplicationMessage;
    let _ = FfiMlsProcessKind::ProposalQueued;
    let _ = FfiMlsProcessKind::CommitMerged;

    // Outbox status
    let _ = FfiLocalOutboxStatus::Pending;
    let _ = FfiLocalOutboxStatus::Failed;

    // History sync
    let _ = FfiHistorySyncJobType::InitialSync;
    let _ = FfiHistorySyncJobType::ChatBackfill;
    let _ = FfiHistorySyncJobType::DeviceRekey;
    let _ = FfiHistorySyncJobStatus::Pending;
    let _ = FfiHistorySyncJobStatus::Running;
    let _ = FfiHistorySyncJobStatus::Completed;
    let _ = FfiHistorySyncJobStatus::Failed;
    let _ = FfiHistorySyncJobStatus::Canceled;
    let _ = FfiHistorySyncJobRole::Source;
    let _ = FfiHistorySyncJobRole::Target;

    // Service status
    let _ = FfiServiceStatus::Ok;
    let _ = FfiServiceStatus::Degraded;

    // Blob upload status
    let _ = FfiBlobUploadStatus::PendingUpload;
    let _ = FfiBlobUploadStatus::Available;
}
