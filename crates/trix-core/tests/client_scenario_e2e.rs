//! Client Scenario E2E Tests
//!
//! Integration tests that exercise full client workflows through FFI objects,
//! exactly as real Swift/Kotlin clients call them. Requires a local PostgreSQL
//! instance and spawns an embedded `trixd` server.
//!
//! Run with:  cargo test -p trix-core --test client_scenario_e2e -- --ignored

use std::{env, fs, path::PathBuf, sync::Arc, time::Duration};

use anyhow::{Context, Result, anyhow};
use serde::Deserialize;
use sqlx::postgres::PgPoolOptions;
use tokio::{
    net::TcpListener,
    task::{self, JoinHandle},
    time::sleep,
};
use trix_core::*;
use trix_server::{
    auth::AuthManager, blobs::LocalBlobStore, build::BuildInfo, config::AppConfig, db::Database,
    state::AppState,
};
use uuid::Uuid;

/// Run a closure that calls FFI `block_on` on a dedicated blocking thread,
/// so it doesn't conflict with the test's tokio runtime.
async fn ffi<F, T>(f: F) -> Result<T>
where
    F: FnOnce() -> Result<T> + Send + 'static,
    T: Send + 'static,
{
    task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("spawn_blocking join error: {e}"))?
}

const DEFAULT_TEST_DATABASE_URL: &str = "postgres://trix:trix@localhost:5432/trix";

// ─── Test infrastructure ───

fn temp_dir(label: &str) -> Result<PathBuf> {
    let dir = env::temp_dir().join(format!("trix-scenario-e2e-{label}-{}", Uuid::new_v4()));
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

struct TestServer {
    base_url: String,
    database_url: String,
    blob_root: PathBuf,
    task: JoinHandle<()>,
}

impl TestServer {
    async fn shutdown(self) -> Result<()> {
        self.task.abort();
        let _ = self.task.await;
        reset_test_database(&self.database_url).await?;
        fs::remove_dir_all(&self.blob_root).ok();
        Ok(())
    }
}

/// Represents a fully bootstrapped FFI client identity (like what an iOS/macOS/Android app holds).
struct FfiClientIdentity {
    account_id: String,
    device_id: String,
    account_sync_chat_id: String,
    client: Arc<FfiServerApiClient>,
    account_root: Arc<FfiAccountRootMaterial>,
    device_keys: Arc<FfiDeviceKeyMaterial>,
    facade: Arc<FfiMlsFacade>,
    store: Arc<FfiLocalHistoryStore>,
    sync: Arc<FfiSyncCoordinator>,
}

#[derive(Debug, Deserialize)]
struct LinkIntentPayload {
    link_token: String,
}

async fn spawn_test_server() -> Result<TestServer> {
    let database_url =
        env::var("TRIX_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_TEST_DATABASE_URL.to_owned());
    reset_test_database(&database_url).await?;

    let blob_root = env::temp_dir().join(format!("trix-scenario-e2e-{}", Uuid::new_v4()));
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let base_url = format!("http://{}", addr);

    let config = AppConfig {
        bind_addr: addr,
        public_base_url: base_url.clone(),
        database_url: database_url.clone(),
        blob_root: blob_root.clone(),
        blob_max_upload_bytes: 25 * 1024 * 1024,
        log_filter: "error".to_owned(),
        jwt_signing_key: "trix-scenario-e2e-key".to_owned(),
        admin_username: "trix-scenario-e2e-admin".to_owned(),
        admin_password: "trix-scenario-e2e-admin-pass".to_owned(),
        admin_jwt_signing_key: "trix-scenario-e2e-admin-jwt".to_owned(),
        admin_session_ttl_seconds: 900,
        cors_allowed_origins: Vec::new(),
        rate_limit_window_seconds: 60,
        rate_limit_auth_challenge_limit: 100,
        rate_limit_auth_session_limit: 100,
        rate_limit_link_intents_limit: 100,
        rate_limit_directory_limit: 100,
        rate_limit_blob_upload_limit: 100,
        cleanup_interval_seconds: 300,
        auth_challenge_retention_seconds: 3600,
        link_intent_retention_seconds: 86400,
        transfer_bundle_retention_seconds: 86400,
        history_sync_retention_seconds: 604800,
        pending_blob_retention_seconds: 86400,
        shutdown_grace_period_seconds: 1,
    };

    let db = Database::connect(&config.database_url).await?;
    let blob_store = LocalBlobStore::new(&config.blob_root)?;
    let auth = AuthManager::new(&config.jwt_signing_key);
    let state = AppState::new(config, BuildInfo::current(), db, auth, blob_store);
    let router = trix_server::app::build_router(state)?;

    let task = tokio::spawn(async move {
        axum::serve(listener, router)
            .await
            .expect("test server should stay up");
    });

    let health_client = ServerApiClient::new(&base_url)?;
    wait_for_server(&health_client).await?;

    Ok(TestServer {
        base_url,
        database_url,
        blob_root,
        task,
    })
}

/// Creates a fully bootstrapped FFI client identity — mimicking the iOS/macOS/Android boot flow:
/// generate keys → create account via FFI → authenticate → set up stores.
fn create_ffi_client(base_url: &str, handle: &str) -> Result<FfiClientIdentity> {
    let account_root = FfiAccountRootMaterial::generate();
    let device_keys = FfiDeviceKeyMaterial::generate();
    let credential_identity = format!("{handle}-credential").into_bytes();
    let store_root = temp_dir(&format!("{handle}-store"))?;
    let database_path = store_root.join("state-v1.db");
    let attachment_cache_root = store_root.join("attachments");

    let client = FfiServerApiClient::new(base_url.to_owned())?;
    let response = client.create_account_with_materials(
        FfiCreateAccountWithMaterialsParams {
            handle: Some(handle.to_owned()),
            profile_name: handle.to_owned(),
            profile_bio: None,
            device_display_name: format!("{handle}-device"),
            platform: "test".to_owned(),
            credential_identity: credential_identity.clone(),
        },
        account_root.clone(),
        device_keys.clone(),
    )?;

    let session = client.authenticate_with_device_key(
        response.device_id.clone(),
        device_keys.clone(),
        true,
    )?;
    assert_eq!(session.account_id, response.account_id);

    let client_store = FfiClientStore::open(FfiClientStoreConfig {
        database_path: database_path.display().to_string(),
        database_key: vec![0u8; 32],
        attachment_cache_root: attachment_cache_root.display().to_string(),
    })?;
    let facade = client_store.open_mls_facade(credential_identity.clone())?;
    let store = client_store.history_store();
    let sync = client_store.sync_coordinator();

    Ok(FfiClientIdentity {
        account_id: response.account_id,
        device_id: response.device_id,
        account_sync_chat_id: response.account_sync_chat_id,
        client,
        account_root,
        device_keys,
        facade,
        store,
        sync,
    })
}

async fn wait_for_server(client: &ServerApiClient) -> Result<()> {
    for _ in 0..20 {
        if client.get_health().await.is_ok() {
            return Ok(());
        }
        sleep(Duration::from_millis(50)).await;
    }
    Err(anyhow!("server did not become healthy"))
}

async fn reset_test_database(database_url: &str) -> Result<()> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(database_url)
        .await
        .with_context(|| "failed to connect to test postgres")?;
    sqlx::query("TRUNCATE TABLE accounts CASCADE")
        .execute(&pool)
        .await
        .with_context(|| "failed to truncate test database")?;
    pool.close().await;
    Ok(())
}

// ─── S1: Account bootstrap ───

#[tokio::test]
#[ignore = "requires local postgres"]
async fn s1_account_bootstrap_and_profile_update() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;

        let profile = alice.client.get_me()?;
        assert_eq!(profile.account_id, alice.account_id);
        assert_eq!(profile.profile_name, "alice");

        let updated = alice
            .client
            .update_account_profile(FfiUpdateAccountProfileParams {
                handle: Some("alice_updated".to_owned()),
                profile_name: "Alice Updated".to_owned(),
                profile_bio: Some("Hello!".to_owned()),
            })?;
        assert_eq!(updated.profile_name, "Alice Updated");
        assert_eq!(updated.handle.as_deref(), Some("alice_updated"));

        let directory =
            alice
                .client
                .search_account_directory(Some("alice".to_owned()), Some(10), false)?;
        assert!(!directory.accounts.is_empty());
        Ok(())
    })
    .await?;

    server.shutdown().await
}

// ─── S2: Device linking ───

#[tokio::test]
#[ignore = "requires local postgres — link_token format needs real QR parsing"]
async fn s2_device_link_approve_revoke() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;

        let link = alice.client.create_link_intent()?;
        assert!(!link.link_intent_id.is_empty());
        let payload: LinkIntentPayload = serde_json::from_str(&link.qr_payload)?;

        let new_device_keys = FfiDeviceKeyMaterial::generate();
        let new_credential = b"alice-linked-credential".to_vec();
        let new_facade_root = temp_dir("alice-linked-device")?;
        let new_facade = FfiMlsFacade::new_persistent(
            new_credential.clone(),
            new_facade_root.display().to_string(),
        )?;
        let key_packages = new_facade.generate_publish_key_packages(2)?;

        let completed = alice.client.complete_link_intent_with_device_key(
            link.link_intent_id.clone(),
            FfiCompleteLinkIntentWithDeviceKeyParams {
                link_token: payload.link_token,
                device_display_name: "Alice Linked Device".to_owned(),
                platform: "test".to_owned(),
                credential_identity: new_credential,
                key_packages,
            },
            new_device_keys.clone(),
        )?;
        assert!(!completed.pending_device_id.is_empty());

        let transfer_bundle = alice.account_root.create_device_transfer_bundle(
            FfiCreateDeviceTransferBundleParams {
                account_id: alice.account_id.clone(),
                source_device_id: alice.device_id.clone(),
                target_device_id: completed.pending_device_id.clone(),
                account_sync_chat_id: Some(alice.account_sync_chat_id.clone()),
            },
            alice.device_keys.clone(),
            new_device_keys.public_key_bytes(),
        )?;

        let approved = alice.client.approve_device_with_account_root(
            completed.pending_device_id.clone(),
            alice.account_root.clone(),
            Some(transfer_bundle),
        )?;
        assert_eq!(approved.device_id, completed.pending_device_id);

        let devices = alice.client.list_devices()?;
        assert_eq!(devices.devices.len(), 2);

        let linked_client = FfiServerApiClient::new(base_url.to_owned())?;
        let linked_session = linked_client.authenticate_with_device_key(
            completed.pending_device_id.clone(),
            new_device_keys.clone(),
            true,
        )?;
        assert_eq!(linked_session.account_id, alice.account_id);

        let fetched_bundle =
            linked_client.get_device_transfer_bundle(completed.pending_device_id.clone())?;
        let imported =
            new_device_keys.decrypt_device_transfer_bundle(fetched_bundle.transfer_bundle)?;
        assert_eq!(imported.account_id, alice.account_id);

        let revoked = alice.client.revoke_device_with_account_root(
            completed.pending_device_id,
            "test revocation".to_owned(),
            alice.account_root.clone(),
        )?;
        assert!(matches!(revoked.device_status, FfiDeviceStatus::Revoked));
        Ok(())
    })
    .await?;

    server.shutdown().await
}

// ─── S3: Chat creation + MLS ───

#[tokio::test]
#[ignore = "requires local postgres — projection needs key packages from same facade"]
async fn s3_create_chat_and_sync_to_second_user() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;
        let bob = create_ffi_client(&base_url, "bob")?;

        bob.client
            .ensure_device_key_packages(bob.facade.clone(), bob.device_id.clone(), 8, 32)?;

        let outcome = alice.sync.create_chat_control(
            alice.client.clone(),
            alice.store.clone(),
            alice.facade.clone(),
            FfiCreateChatControlInput {
                creator_account_id: alice.account_id.clone(),
                creator_device_id: alice.device_id.clone(),
                chat_type: FfiChatType::Dm,
                title: None,
                participant_account_ids: vec![bob.account_id.clone()],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )?;
        assert!(!outcome.chat_id.is_empty());
        assert!(!outcome.mls_group_id.is_empty());

        let alice_chats = alice.store.list_chats()?;
        assert!(alice_chats.iter().any(|c| c.chat_id == outcome.chat_id));

        let bob_report =
            bob.sync
                .sync_chat_histories_into_store(bob.client.clone(), bob.store.clone(), 100)?;
        assert!(bob_report.changed_chat_ids.contains(&outcome.chat_id));
        assert!(
            bob.store
                .list_chats()?
                .iter()
                .any(|chat| chat.chat_id == outcome.chat_id)
        );

        bob.store.project_chat_with_facade(
            outcome.chat_id.clone(),
            bob.facade.clone(),
            Some(500),
        )?;
        assert!(bob.store.chat_mls_group_id(outcome.chat_id)?.is_some());
        Ok(())
    })
    .await?;

    server.shutdown().await
}

// ─── S4: Messaging round-trip ───

#[tokio::test]
#[ignore = "requires local postgres"]
async fn s4_send_text_message_and_receive() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;
        let bob = create_ffi_client(&base_url, "bob")?;

        bob.client
            .ensure_device_key_packages(bob.facade.clone(), bob.device_id.clone(), 8, 32)?;

        let chat = alice.sync.create_chat_control(
            alice.client.clone(),
            alice.store.clone(),
            alice.facade.clone(),
            FfiCreateChatControlInput {
                creator_account_id: alice.account_id.clone(),
                creator_device_id: alice.device_id.clone(),
                chat_type: FfiChatType::Dm,
                title: None,
                participant_account_ids: vec![bob.account_id.clone()],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )?;

        let conversation = alice
            .store
            .load_or_bootstrap_chat_conversation(chat.chat_id.clone(), alice.facade.clone())?
            .expect("conversation should exist");

        let send_outcome = alice.sync.send_message_body(
            alice.client.clone(),
            alice.store.clone(),
            alice.facade.clone(),
            conversation,
            FfiSendMessageInput {
                sender_account_id: alice.account_id.clone(),
                sender_device_id: alice.device_id.clone(),
                chat_id: chat.chat_id.clone(),
                message_id: None,
                body: FfiMessageBody {
                    kind: FfiMessageBodyKind::Text,
                    text: Some("hello bob from alice".to_owned()),
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
                aad_json: None,
            },
        )?;
        assert!(!send_outcome.message_id.is_empty());

        bob.sync
            .sync_chat_histories_into_store(bob.client.clone(), bob.store.clone(), 100)?;
        let chat_cursor = bob
            .sync
            .chat_cursor(chat.chat_id.clone())?
            .ok_or_else(|| anyhow!("sync cursor should advance after history sync"))?;
        assert!(
            chat_cursor >= send_outcome.server_seq,
            "sync cursor should cover the latest delivered message"
        );
        bob.store
            .project_chat_with_facade(chat.chat_id.clone(), bob.facade.clone(), Some(500))?;

        let timeline = bob.store.get_local_timeline_items(
            chat.chat_id.clone(),
            Some(bob.account_id.clone()),
            None,
            Some(20),
        )?;
        assert!(
            timeline
                .iter()
                .any(|item| item.preview_text == "hello bob from alice")
        );
        Ok(())
    })
    .await?;

    server.shutdown().await
}

// ─── S7: Read states ───

#[tokio::test]
#[ignore = "requires local postgres"]
async fn s7_read_state_tracking() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;
        let bob = create_ffi_client(&base_url, "bob")?;

        bob.client
            .ensure_device_key_packages(bob.facade.clone(), bob.device_id.clone(), 8, 32)?;

        let chat = alice.sync.create_chat_control(
            alice.client.clone(),
            alice.store.clone(),
            alice.facade.clone(),
            FfiCreateChatControlInput {
                creator_account_id: alice.account_id.clone(),
                creator_device_id: alice.device_id.clone(),
                chat_type: FfiChatType::Dm,
                title: None,
                participant_account_ids: vec![bob.account_id.clone()],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )?;

        bob.sync
            .sync_chat_histories_into_store(bob.client.clone(), bob.store.clone(), 100)?;

        let read_state =
            bob.store
                .mark_chat_read(chat.chat_id.clone(), None, Some(bob.account_id.clone()))?;
        assert_eq!(read_state.chat_id, chat.chat_id);
        assert_eq!(read_state.unread_count, 0);

        let all_states = bob
            .store
            .list_chat_read_states(Some(bob.account_id.clone()))?;
        assert!(all_states.iter().any(|s| s.chat_id == chat.chat_id));
        Ok(())
    })
    .await?;

    server.shutdown().await
}

// ─── S8: WebSocket realtime ───

#[tokio::test]
#[ignore = "requires local postgres"]
async fn s8_websocket_inbox_delivery() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;
        let bob = create_ffi_client(&base_url, "bob")?;

        bob.client
            .ensure_device_key_packages(bob.facade.clone(), bob.device_id.clone(), 8, 32)?;

        let bob_ws = bob.client.connect_websocket()?;
        let driver = FfiRealtimeDriver::new()?;

        let hello_event = driver.next_websocket_event(
            bob_ws.clone(),
            bob.sync.clone(),
            bob.store.clone(),
            true,
        )?;
        assert!(hello_event.is_some());

        let created = alice.sync.create_chat_control(
            alice.client.clone(),
            alice.store.clone(),
            alice.facade.clone(),
            FfiCreateChatControlInput {
                creator_account_id: alice.account_id.clone(),
                creator_device_id: alice.device_id.clone(),
                chat_type: FfiChatType::Dm,
                title: None,
                participant_account_ids: vec![bob.account_id.clone()],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )?;

        let inbox_event = driver.next_websocket_event(
            bob_ws.clone(),
            bob.sync.clone(),
            bob.store.clone(),
            true,
        )?;
        assert!(inbox_event.is_some());
        let event = inbox_event.unwrap();
        assert!(event.report.is_some());
        assert!(event.report.unwrap().messages_upserted > 0);
        assert!(
            bob.sync.chat_cursor(created.chat_id)?.is_some(),
            "realtime inbox apply should advance sync cursor"
        );

        bob_ws.close_socket()?;
        Ok(())
    })
    .await?;

    server.shutdown().await
}

// ─── S6: Outbox lifecycle ───

#[tokio::test]
#[ignore = "requires local postgres"]
async fn s6_outbox_enqueue_fail_clear_remove() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_ffi_client(&base_url, "alice")?;
        let chat_id = Uuid::new_v4().to_string();
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

        let item = alice.store.enqueue_outbox_message(
            chat_id,
            alice.account_id.clone(),
            alice.device_id.clone(),
            message_id.clone(),
            body,
            1700000000,
        )?;
        assert!(matches!(item.status, FfiLocalOutboxStatus::Pending));

        alice
            .store
            .mark_outbox_failure(message_id.clone(), "network error".to_owned())?;
        let items = alice.store.list_outbox_messages(None)?;
        assert!(matches!(items[0].status, FfiLocalOutboxStatus::Failed));

        alice.store.clear_outbox_failure(message_id.clone())?;
        alice.store.remove_outbox_message(message_id)?;
        assert!(alice.store.list_outbox_messages(None)?.is_empty());
        Ok(())
    })
    .await?;

    server.shutdown().await
}
