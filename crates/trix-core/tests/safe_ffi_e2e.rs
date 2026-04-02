//! Safe Messenger FFI E2E Tests
//!
//! Integration tests that exercise the high-level `FfiMessengerClient` ABI
//! through the same Rust/UniFFI boundary used by production clients.
//!
//! Run with:
//! `cargo test -p trix-core --test safe_ffi_e2e -- --ignored --test-threads=1`

use std::{
    env, fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, params};
use serde_json::Value;
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

const DEFAULT_TEST_DATABASE_URL: &str = "postgres://trix:trix@localhost:5432/trix";

async fn ffi<F, T>(f: F) -> Result<T>
where
    F: FnOnce() -> Result<T> + Send + 'static,
    T: Send + 'static,
{
    task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("spawn_blocking join error: {e}"))?
}

fn temp_dir(label: &str) -> Result<PathBuf> {
    let dir = env::temp_dir().join(format!("trix-safe-ffi-e2e-{label}-{}", Uuid::new_v4()));
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

struct SafeClientIdentity {
    account_id: String,
    device_id: String,
    account_sync_chat_id: String,
    root_path: String,
    database_key: Vec<u8>,
    credential_identity: Vec<u8>,
    client: Arc<FfiMessengerClient>,
}

struct PendingSafeClientIdentity {
    root_path: String,
    database_key: Vec<u8>,
    client: Arc<FfiMessengerClient>,
}

async fn spawn_test_server() -> Result<TestServer> {
    let database_url =
        env::var("TRIX_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_TEST_DATABASE_URL.to_owned());
    reset_test_database(&database_url).await?;

    let blob_root = env::temp_dir().join(format!("trix-safe-ffi-e2e-{}", Uuid::new_v4()));
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
        jwt_signing_key: "trix-safe-ffi-e2e-key".to_owned(),
        admin_username: "trix-safe-ffi-e2e-admin".to_owned(),
        admin_password: "trix-safe-ffi-e2e-admin-pass".to_owned(),
        admin_jwt_signing_key: "trix-safe-ffi-e2e-admin-jwt".to_owned(),
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
        apns_team_id: None,
        apns_key_id: None,
        apns_topic: None,
        apns_private_key_pem: None,
    };

    let db = Database::connect(&config.database_url).await?;
    let blob_store = LocalBlobStore::new(&config.blob_root)?;
    let auth = AuthManager::new(&config.jwt_signing_key);
    let state = AppState::new(config, BuildInfo::current(), db, auth, blob_store)?;
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

fn create_safe_client(
    base_url: &str,
    handle: &str,
    include_access_token: bool,
) -> Result<SafeClientIdentity> {
    let account_root = FfiAccountRootMaterial::generate();
    let device_keys = FfiDeviceKeyMaterial::generate();
    let credential_identity = format!("{handle}-credential").into_bytes();
    let device_display_name = format!("{handle}-device");
    let platform = "test".to_owned();

    let transport = FfiServerApiClient::new(base_url.to_owned())?;
    let account = transport.create_account_with_materials(
        FfiCreateAccountWithMaterialsParams {
            handle: Some(handle.to_owned()),
            profile_name: handle.to_owned(),
            profile_bio: None,
            device_display_name: device_display_name.clone(),
            platform: platform.clone(),
            credential_identity: credential_identity.clone(),
        },
        account_root.clone(),
        device_keys.clone(),
    )?;
    let session = transport.authenticate_with_device_key(
        account.device_id.clone(),
        device_keys.clone(),
        true,
    )?;

    let root_path = temp_dir(&format!("{handle}-safe-root"))?;
    let database_key = vec![handle.as_bytes().first().copied().unwrap_or(b'x'); 32];
    let client = FfiMessengerClient::open(FfiMessengerOpenConfig {
        root_path: root_path.display().to_string(),
        database_key: database_key.clone(),
        base_url: base_url.to_owned(),
        access_token: include_access_token.then_some(session.access_token),
        account_id: Some(account.account_id.clone()),
        device_id: Some(account.device_id.clone()),
        account_sync_chat_id: Some(account.account_sync_chat_id.clone()),
        device_display_name: Some(device_display_name),
        platform: Some(platform),
        credential_identity: Some(credential_identity.clone()),
        account_root_private_key: Some(account_root.private_key_bytes()),
        transport_private_key: Some(device_keys.private_key_bytes()),
    })?;

    Ok(SafeClientIdentity {
        account_id: account.account_id,
        device_id: account.device_id,
        account_sync_chat_id: account.account_sync_chat_id,
        root_path: root_path.display().to_string(),
        database_key,
        credential_identity,
        client,
    })
}

fn create_pending_safe_client(base_url: &str, label: &str) -> Result<Arc<FfiMessengerClient>> {
    Ok(create_pending_safe_client_identity(base_url, label)?.client)
}

fn create_pending_safe_client_identity(
    base_url: &str,
    label: &str,
) -> Result<PendingSafeClientIdentity> {
    let device_keys = FfiDeviceKeyMaterial::generate();
    let credential_identity = format!("{label}-credential").into_bytes();
    let root_path = temp_dir(&format!("{label}-pending-safe-root"))?;
    let database_key = vec![label.as_bytes().first().copied().unwrap_or(b'p'); 32];
    let client = FfiMessengerClient::open(FfiMessengerOpenConfig {
        root_path: root_path.display().to_string(),
        database_key: database_key.clone(),
        base_url: base_url.to_owned(),
        access_token: None,
        account_id: None,
        device_id: None,
        account_sync_chat_id: None,
        device_display_name: Some(format!("{label}-device")),
        platform: Some("test".to_owned()),
        credential_identity: Some(credential_identity.clone()),
        account_root_private_key: None,
        transport_private_key: Some(device_keys.private_key_bytes()),
    })?;

    Ok(PendingSafeClientIdentity {
        root_path: root_path.display().to_string(),
        database_key,
        client,
    })
}

fn reopen_safe_client(
    base_url: &str,
    root_path: &str,
    database_key: Vec<u8>,
) -> Result<Arc<FfiMessengerClient>> {
    Ok(FfiMessengerClient::open(FfiMessengerOpenConfig {
        root_path: root_path.to_owned(),
        database_key,
        base_url: base_url.to_owned(),
        access_token: None,
        account_id: None,
        device_id: None,
        account_sync_chat_id: None,
        device_display_name: None,
        platform: None,
        credential_identity: None,
        account_root_private_key: None,
        transport_private_key: None,
    })?)
}

fn client_store_config(root_path: &str, database_key: Vec<u8>) -> FfiClientStoreConfig {
    FfiClientStoreConfig {
        database_path: format!("{root_path}/client-store.sqlite"),
        database_key,
        attachment_cache_root: format!("{root_path}/attachments"),
    }
}

fn encode_hex(input: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(input.len() * 2);
    for byte in input {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn open_encrypted_connection(path: &Path, database_key: &[u8]) -> Result<Connection> {
    let connection = Connection::open(path)
        .with_context(|| format!("failed to open sqlite store {}", path.display()))?;
    let encoded_key = encode_hex(database_key);
    connection
        .execute_batch(&format!(
            "PRAGMA key = \"x'{encoded_key}'\"; PRAGMA cipher_compatibility = 4;"
        ))
        .with_context(|| format!("failed to configure SQLCipher for {}", path.display()))?;
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        })
        .with_context(|| format!("failed to validate SQLCipher key for {}", path.display()))?;
    Ok(connection)
}

fn dematerialize_projected_message(
    root_path: &str,
    database_key: &[u8],
    conversation_id: &str,
    server_seq: u64,
) -> Result<()> {
    let database_path = PathBuf::from(root_path).join("client-store.sqlite");
    let connection = open_encrypted_connection(&database_path, database_key)?;
    let projected_json: String = connection
        .query_row(
            r#"
            SELECT projected_json
            FROM local_history_projected_messages
            WHERE chat_id = ?1 AND server_seq = ?2
            "#,
            params![conversation_id, server_seq as i64],
            |row| row.get(0),
        )
        .with_context(|| {
            format!(
                "missing projected message {server_seq} in {}",
                database_path.display()
            )
        })?;
    let mut projected_value: Value =
        serde_json::from_str(&projected_json).context("failed to parse projected_json")?;
    let projected_object = projected_value
        .as_object_mut()
        .ok_or_else(|| anyhow!("projected_json is not a JSON object"))?;
    projected_object.insert("materialized_body_b64".to_owned(), Value::Null);
    let updated_projected_json =
        serde_json::to_string(&projected_value).context("failed to serialize projected_json")?;
    let updated = connection
        .execute(
            r#"
            UPDATE local_history_projected_messages
            SET projected_json = ?3
            WHERE chat_id = ?1 AND server_seq = ?2
            "#,
            params![conversation_id, server_seq as i64, updated_projected_json],
        )
        .context("failed to update projected message materialization")?;
    if updated != 1 {
        return Err(anyhow!(
            "expected to update one projected message row, updated {updated}"
        ));
    }
    Ok(())
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

async fn purge_server_message_for_device_gap(
    database_url: &str,
    device_id: &str,
    conversation_id: &str,
    server_seq: u64,
) -> Result<()> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(database_url)
        .await
        .with_context(|| "failed to connect to test postgres for inbox mutation")?;
    let device_id = Uuid::parse_str(device_id).context("invalid device_id for inbox mutation")?;
    let conversation_id =
        Uuid::parse_str(conversation_id).context("invalid conversation_id for inbox mutation")?;
    let deleted = sqlx::query(
        r#"
        DELETE FROM device_inbox di
        USING messages m
        WHERE di.message_id = m.message_id
          AND di.device_id = $1
          AND di.chat_id = $2
          AND m.chat_id = $2
          AND m.server_seq = $3
        "#,
    )
    .bind(device_id)
    .bind(conversation_id)
    .bind(i64::try_from(server_seq).context("server_seq does not fit into i64")?)
    .execute(&pool)
    .await
    .with_context(|| "failed to delete missed device inbox item")?;
    if deleted.rows_affected() != 1 {
        return Err(anyhow!(
            "expected to delete one device_inbox row for server_seq {server_seq}, deleted {}",
            deleted.rows_affected()
        ));
    }
    let deleted_message = sqlx::query(
        r#"
        DELETE FROM messages
        WHERE chat_id = $1
          AND server_seq = $2
        "#,
    )
    .bind(conversation_id)
    .bind(i64::try_from(server_seq).context("server_seq does not fit into i64")?)
    .execute(&pool)
    .await
    .with_context(|| "failed to delete server message for device gap simulation")?;
    pool.close().await;
    if deleted_message.rows_affected() != 1 {
        return Err(anyhow!(
            "expected to delete one server message row for server_seq {server_seq}, deleted {}",
            deleted_message.rows_affected()
        ));
    }
    Ok(())
}

fn dm_request(participant_account_id: &str) -> FfiMessengerCreateConversationRequest {
    FfiMessengerCreateConversationRequest {
        conversation_type: FfiChatType::Dm,
        title: None,
        participant_account_ids: vec![participant_account_id.to_owned()],
    }
}

fn group_request(
    title: &str,
    participant_account_ids: Vec<String>,
) -> FfiMessengerCreateConversationRequest {
    FfiMessengerCreateConversationRequest {
        conversation_type: FfiChatType::Group,
        title: Some(title.to_owned()),
        participant_account_ids,
    }
}

fn text_request(conversation_id: &str, text: &str) -> FfiMessengerSendMessageRequest {
    FfiMessengerSendMessageRequest {
        conversation_id: conversation_id.to_owned(),
        message_id: None,
        kind: FfiMessengerMessageBodyKind::Text,
        text: Some(text.to_owned()),
        target_message_id: None,
        emoji: None,
        reaction_action: None,
        receipt_type: None,
        receipt_at_unix: None,
        event_type: None,
        event_json: None,
        attachment_tokens: Vec::new(),
    }
}

fn attachment_request(conversation_id: &str, token: &str) -> FfiMessengerSendMessageRequest {
    FfiMessengerSendMessageRequest {
        conversation_id: conversation_id.to_owned(),
        message_id: None,
        kind: FfiMessengerMessageBodyKind::Attachment,
        text: None,
        target_message_id: None,
        emoji: None,
        reaction_action: None,
        receipt_type: None,
        receipt_at_unix: None,
        event_type: None,
        event_json: None,
        attachment_tokens: vec![token.to_owned()],
    }
}

fn assert_local_leaf_mapping_matches_mls(
    identity: &SafeClientIdentity,
    conversation_id: &str,
) -> Result<()> {
    assert_local_leaf_mapping_matches_mls_at(
        &identity.root_path,
        &identity.database_key,
        &identity.credential_identity,
        conversation_id,
    )
}

fn assert_local_leaf_mapping_matches_mls_at(
    root_path: &str,
    database_key: &[u8],
    credential_identity: &[u8],
    conversation_id: &str,
) -> Result<()> {
    let store = FfiClientStore::open(FfiClientStoreConfig {
        database_path: format!("{root_path}/client-store.sqlite"),
        database_key: database_key.to_vec(),
        attachment_cache_root: format!("{root_path}/attachments"),
    })?;
    let history = store.history_store();
    let detail = history
        .get_chat(conversation_id.to_owned())?
        .ok_or_else(|| anyhow!("missing local chat detail for {conversation_id}"))?;
    let group_id = history
        .chat_mls_group_id(conversation_id.to_owned())?
        .ok_or_else(|| anyhow!("missing local chat group id for {conversation_id}"))?;
    let facade = store.open_mls_facade(credential_identity.to_vec())?;
    let conversation = facade
        .load_group(group_id)?
        .ok_or_else(|| anyhow!("missing local MLS conversation for {conversation_id}"))?;
    let mut local = detail
        .device_members
        .into_iter()
        .map(|member| (member.leaf_index, member.credential_identity))
        .collect::<Vec<_>>();
    let mut mls = facade
        .members(conversation)?
        .into_iter()
        .map(|member| (member.leaf_index, member.credential_identity))
        .collect::<Vec<_>>();
    local.sort_by(|left, right| left.1.cmp(&right.1));
    mls.sort_by(|left, right| left.1.cmp(&right.1));
    assert_eq!(
        local, mls,
        "local device_members leaf mapping diverged from MLS"
    );
    Ok(())
}

fn message_text(message: &FfiMessengerMessageRecord) -> Option<&str> {
    message.body.as_ref()?.text.as_deref()
}

fn expect_checkpoint(batch: &FfiMessengerEventBatch) -> Result<String> {
    batch
        .checkpoint
        .clone()
        .ok_or_else(|| anyhow!("expected checkpoint to be present"))
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s1_snapshot_messages_paging_and_read_state() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", false)?;
        let bob = create_safe_client(&base_url, "bob", true)?;

        let alice_snapshot = alice.client.load_snapshot()?;
        assert_eq!(
            alice_snapshot.account_id.as_deref(),
            Some(alice.account_id.as_str())
        );
        assert_eq!(
            alice_snapshot.device_id.as_deref(),
            Some(alice.device_id.as_str())
        );
        assert!(alice_snapshot.capabilities.safe_messaging);
        assert!(alice_snapshot.capabilities.attachments);

        let bob_snapshot = bob.client.load_snapshot()?;
        assert_eq!(
            bob_snapshot.account_id.as_deref(),
            Some(bob.account_id.as_str())
        );

        let created = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        let conversation_id = created.conversation_id.clone();
        assert_eq!(
            created
                .conversation
                .as_ref()
                .map(|conversation| conversation.conversation_id.as_str()),
            Some(conversation_id.as_str())
        );

        let conversation_batch = bob.client.get_new_events(None)?;
        assert!(conversation_batch.events.iter().any(|event| {
            matches!(event.kind, FfiMessengerEventKind::ConversationUpdated)
                && event.conversation_id.as_deref() == Some(conversation_id.as_str())
        }));

        alice.client.set_typing(conversation_id.clone(), true)?;
        alice.client.set_typing(conversation_id.clone(), false)?;

        alice
            .client
            .send_message(text_request(&conversation_id, "hello bob one"))?;
        let second_send = alice
            .client
            .send_message(text_request(&conversation_id, "hello bob two"))?;
        assert_eq!(message_text(&second_send.message), Some("hello bob two"));

        let message_batch = bob
            .client
            .get_new_events(conversation_batch.checkpoint.clone())?;
        let delivered_texts = message_batch
            .events
            .iter()
            .filter_map(|event| event.message.as_ref())
            .filter_map(message_text)
            .collect::<Vec<_>>();
        assert!(delivered_texts.contains(&"hello bob one"));
        assert!(delivered_texts.contains(&"hello bob two"));

        let first_page = bob
            .client
            .get_messages(conversation_id.clone(), None, Some(2))?;
        assert_eq!(first_page.messages.len(), 2);
        let cursor = first_page
            .next_cursor
            .clone()
            .ok_or_else(|| anyhow!("expected next cursor on first page"))?;
        let second_page =
            bob.client
                .get_messages(conversation_id.clone(), Some(cursor), Some(2))?;
        assert!(!second_page.messages.is_empty());
        assert!(first_page.messages.iter().all(|message| {
            second_page
                .messages
                .iter()
                .all(|other| other.message_id != message.message_id)
        }));

        let mut text_messages = first_page
            .messages
            .iter()
            .chain(second_page.messages.iter())
            .filter_map(|message| {
                message_text(message).map(|text| {
                    (
                        message.server_seq,
                        message.message_id.clone(),
                        text.to_owned(),
                    )
                })
            })
            .collect::<Vec<_>>();
        text_messages.sort_by_key(|(server_seq, _, _)| *server_seq);
        assert_eq!(text_messages.len(), 2);
        assert_eq!(text_messages[0].2, "hello bob one");
        assert_eq!(text_messages[1].2, "hello bob two");

        let read = bob
            .client
            .mark_read(conversation_id, Some(text_messages[1].1.clone()))?;
        assert_eq!(read.unread_count, 0);
        assert_eq!(read.read_cursor_server_seq, text_messages[1].0);

        let repeated_batch = bob
            .client
            .get_new_events(message_batch.checkpoint.clone())?;
        assert!(repeated_batch.events.is_empty());

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s2_attachment_contracts_and_download() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;

        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let created = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        let conversation_id = created.conversation_id;
        let conversation_batch = bob.client.get_new_events(None)?;
        let conversation_checkpoint = expect_checkpoint(&conversation_batch)?;

        let invalid = alice.client.send_message(FfiMessengerSendMessageRequest {
            conversation_id: conversation_id.clone(),
            message_id: None,
            kind: FfiMessengerMessageBodyKind::Attachment,
            text: None,
            target_message_id: None,
            emoji: None,
            reaction_action: None,
            receipt_type: None,
            receipt_at_unix: None,
            event_type: None,
            event_json: None,
            attachment_tokens: Vec::new(),
        });
        assert!(matches!(
            invalid,
            Err(FfiMessengerError::AttachmentInvalid(_))
        ));

        let payload = b"safe ffi attachment payload".to_vec();
        let token = alice.client.send_attachment(
            conversation_id.clone(),
            payload.clone(),
            FfiMessengerAttachmentMetadata {
                mime_type: "text/plain".to_owned(),
                file_name: Some("note.txt".to_owned()),
                width_px: None,
                height_px: None,
            },
        )?;
        let send_result = alice
            .client
            .send_message(attachment_request(&conversation_id, &token.token))?;
        let sent_attachment = send_result
            .message
            .body
            .as_ref()
            .and_then(|body| body.attachment.as_ref())
            .ok_or_else(|| {
                anyhow!("attachment message should carry a safe attachment descriptor")
            })?;
        assert_eq!(sent_attachment.mime_type, "text/plain");
        assert_eq!(sent_attachment.file_name.as_deref(), Some("note.txt"));

        let repeated = alice
            .client
            .send_message(attachment_request(&conversation_id, &token.token));
        assert!(matches!(
            repeated,
            Err(FfiMessengerError::AttachmentExpired(_))
        ));

        let message_batch = bob.client.get_new_events(Some(conversation_checkpoint))?;
        assert!(message_batch.events.iter().any(|event| {
            event
                .message
                .as_ref()
                .and_then(|message| message.body.as_ref())
                .and_then(|body| body.attachment.as_ref())
                .is_some()
        }));

        let page = bob.client.get_messages(conversation_id, None, Some(20))?;
        let attachment_message = page
            .messages
            .into_iter()
            .find(|message| {
                message
                    .body
                    .as_ref()
                    .and_then(|body| body.attachment.as_ref())
                    .is_some()
            })
            .ok_or_else(|| anyhow!("expected attachment message in receiver timeline"))?;
        let descriptor = attachment_message
            .body
            .as_ref()
            .and_then(|body| body.attachment.as_ref())
            .cloned()
            .ok_or_else(|| anyhow!("attachment descriptor is missing"))?;

        let attachment = bob
            .client
            .get_attachment(descriptor.attachment_ref.clone())?;
        assert_eq!(attachment.attachment_ref, descriptor.attachment_ref);
        assert_eq!(attachment.mime_type, "text/plain");
        assert_eq!(attachment.file_name.as_deref(), Some("note.txt"));
        assert_eq!(fs::read(&attachment.local_path)?, payload);

        let cached_attachment = bob.client.get_attachment(descriptor.attachment_ref)?;
        assert_eq!(cached_attachment.local_path, attachment.local_path);

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s1b_realtime_facade_delivers_batches() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;

        bob.client.load_snapshot()?;

        let created = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        let conversation_id = created.conversation_id.clone();

        let conversation_batch = bob.client.get_new_events_realtime(None)?;
        assert!(conversation_batch.events.iter().any(|event| {
            matches!(event.kind, FfiMessengerEventKind::ConversationUpdated)
                && event.conversation_id.as_deref() == Some(conversation_id.as_str())
        }));

        bob.client
            .send_presence_ping(Some("safe-ffi-ping".to_owned()))?;

        alice
            .client
            .send_message(text_request(&conversation_id, "hello from realtime facade"))?;

        let message_batch = bob
            .client
            .get_new_events_realtime(conversation_batch.checkpoint.clone())?;
        let delivered_texts = message_batch
            .events
            .iter()
            .filter_map(|event| event.message.as_ref())
            .filter_map(message_text)
            .collect::<Vec<_>>();
        assert!(delivered_texts.contains(&"hello from realtime facade"));

        bob.client.close_realtime()?;
        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s3_attachment_tokens_are_chat_scoped() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        let charlie = create_safe_client(&base_url, "charlie", true)?;

        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;
        charlie.client.load_snapshot()?;

        let dm_with_bob = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        let dm_with_charlie = alice
            .client
            .create_conversation(dm_request(&charlie.account_id))?;

        let token = alice.client.send_attachment(
            dm_with_bob.conversation_id.clone(),
            b"scoped attachment".to_vec(),
            FfiMessengerAttachmentMetadata {
                mime_type: "text/plain".to_owned(),
                file_name: Some("scoped.txt".to_owned()),
                width_px: None,
                height_px: None,
            },
        )?;

        let wrong_chat = alice.client.send_message(attachment_request(
            &dm_with_charlie.conversation_id,
            &token.token,
        ));
        assert!(matches!(
            wrong_chat,
            Err(FfiMessengerError::AttachmentInvalid(_))
        ));
        let correct_chat = alice.client.send_message(attachment_request(
            &dm_with_bob.conversation_id,
            &token.token,
        ))?;
        assert!(
            correct_chat
                .message
                .body
                .as_ref()
                .and_then(|body| body.attachment.as_ref())
                .is_some()
        );

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s4_device_link_approve_and_unlink() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let trusted = create_safe_client(&base_url, "alice", true)?;
        let trusted_snapshot = trusted.client.load_snapshot()?;
        let trusted_checkpoint = trusted_snapshot.checkpoint.clone();

        let intent = trusted.client.create_link_device_intent()?;
        assert!(!intent.link_intent_id.is_empty());
        assert!(!intent.payload.is_empty());

        let linked = create_pending_safe_client(&base_url, "alice-linked")?;
        let pending =
            linked.complete_link_device(intent.payload, "Alice Linked Device".to_owned())?;
        assert_eq!(pending.account_id, trusted.account_id);
        assert!(matches!(pending.device_status, FfiDeviceStatus::Pending));

        let trusted_devices = trusted.client.list_devices()?;
        assert!(trusted_devices.iter().any(|device| {
            device.device_id == pending.device_id
                && matches!(device.device_status, FfiDeviceStatus::Pending)
        }));
        let snapshot_after_list = trusted.client.load_snapshot()?;
        assert_eq!(snapshot_after_list.checkpoint, trusted_checkpoint);
        let pending_batch = trusted
            .client
            .get_new_events(snapshot_after_list.checkpoint.clone())?;
        assert!(pending_batch.events.iter().any(|event| {
            matches!(event.kind, FfiMessengerEventKind::DevicePending)
                && event
                    .device
                    .as_ref()
                    .map(|device| device.device_id.as_str())
                    == Some(pending.device_id.as_str())
        }));
        let pending_checkpoint = expect_checkpoint(&pending_batch)?;

        let approved = trusted
            .client
            .approve_linked_device(pending.device_id.clone())?;
        assert!(matches!(approved.device_status, FfiDeviceStatus::Active));
        assert_eq!(
            approved.account_id.as_deref(),
            Some(trusted.account_id.as_str())
        );
        assert!(approved.devices.iter().any(|device| {
            device.device_id == pending.device_id
                && matches!(device.device_status, FfiDeviceStatus::Active)
        }));
        let snapshot_after_approve = trusted.client.load_snapshot()?;
        assert_eq!(
            snapshot_after_approve.checkpoint.as_deref(),
            Some(pending_checkpoint.as_str())
        );
        let approved_batch = trusted
            .client
            .get_new_events(snapshot_after_approve.checkpoint.clone())?;
        assert!(approved_batch.events.iter().any(|event| {
            matches!(event.kind, FfiMessengerEventKind::DeviceApproved)
                && event
                    .device
                    .as_ref()
                    .map(|device| device.device_id.as_str())
                    == Some(pending.device_id.as_str())
        }));
        let approved_checkpoint = expect_checkpoint(&approved_batch)?;

        let linked_snapshot = linked.load_snapshot()?;
        assert_eq!(
            linked_snapshot.account_id.as_deref(),
            Some(trusted.account_id.as_str())
        );
        assert_eq!(
            linked_snapshot.device_id.as_deref(),
            Some(pending.device_id.as_str())
        );
        assert_eq!(
            linked_snapshot.account_sync_chat_id.as_deref(),
            Some(trusted.account_sync_chat_id.as_str())
        );

        let linked_devices = linked.list_devices()?;
        assert!(linked_devices.iter().any(|device| {
            device.device_id == pending.device_id
                && device.is_current_device
                && matches!(device.device_status, FfiDeviceStatus::Active)
        }));

        let revoked = trusted
            .client
            .revoke_device(FfiMessengerRevokeDeviceRequest {
                device_id: pending.device_id.clone(),
                reason: Some("custom safe ffi revoke reason".to_owned()),
            })?;
        assert!(matches!(revoked.device_status, FfiDeviceStatus::Revoked));
        assert!(revoked.devices.iter().any(|device| {
            device.device_id == pending.device_id
                && matches!(device.device_status, FfiDeviceStatus::Revoked)
        }));
        let snapshot_after_revoke = trusted.client.load_snapshot()?;
        assert_eq!(
            snapshot_after_revoke.checkpoint.as_deref(),
            Some(approved_checkpoint.as_str())
        );
        let revoked_batch = trusted
            .client
            .get_new_events(snapshot_after_revoke.checkpoint.clone())?;
        assert!(revoked_batch.events.iter().any(|event| {
            matches!(event.kind, FfiMessengerEventKind::DeviceRevoked)
                && event
                    .device
                    .as_ref()
                    .map(|device| device.device_id.as_str())
                    == Some(pending.device_id.as_str())
        }));

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s4b_linked_device_history_sync_backfills_prior_messages() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let dm = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        bob.client.get_new_events(None)?;

        let sent = alice
            .client
            .send_message(text_request(&dm.conversation_id, "hello before linking"))?;
        assert_eq!(message_text(&sent.message), Some("hello before linking"));

        let intent = alice.client.create_link_device_intent()?;
        let linked = create_pending_safe_client(&base_url, "alice-linked-history")?;
        let pending =
            linked.complete_link_device(intent.payload, "Alice Linked History".to_owned())?;
        alice
            .client
            .approve_linked_device(pending.device_id.clone())?;

        let linked_snapshot = linked.load_snapshot()?;
        let before_sync = linked.get_messages(dm.conversation_id.clone(), None, None)?;
        if let Some(message) = before_sync.messages.first() {
            assert_eq!(message_text(message), None);
        }

        alice.client.load_snapshot()?;

        let linked_batch = linked.get_new_events(linked_snapshot.checkpoint.clone())?;
        let backfilled_message = linked_batch
            .events
            .iter()
            .filter_map(|event| event.message.as_ref())
            .find(|message| {
                message.conversation_id == dm.conversation_id
                    && message_text(message) == Some("hello before linking")
            })
            .ok_or_else(|| anyhow!("expected history sync message event"))?;
        assert_eq!(
            message_text(backfilled_message),
            Some("hello before linking")
        );
        assert!(linked_batch.checkpoint.is_some());

        let after_sync = linked.get_messages(dm.conversation_id.clone(), None, None)?;
        assert!(
            after_sync
                .messages
                .iter()
                .any(|message| message_text(message) == Some("hello before linking"))
        );

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s5_conversation_device_removals() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let group = alice.client.create_conversation(group_request(
            "safe ffi device removals",
            vec![bob.account_id.clone()],
        ))?;
        let conversation_id = group.conversation_id.clone();
        bob.client.get_new_events(None)?;

        let link_intent = alice.client.create_link_device_intent()?;
        let linked = create_pending_safe_client(&base_url, "alice-secondary")?;
        let pending =
            linked.complete_link_device(link_intent.payload, "Alice Secondary".to_owned())?;
        alice
            .client
            .approve_linked_device(pending.device_id.clone())?;
        linked.load_snapshot()?;

        let added_device = alice.client.update_conversation_devices(
            FfiMessengerUpdateConversationDevicesRequest {
                conversation_id: conversation_id.clone(),
                device_ids: vec![pending.device_id.clone()],
            },
        )?;
        assert_eq!(added_device.conversation_id, conversation_id);
        assert!(added_device.changed_device_ids.contains(&pending.device_id));

        let removed_device = alice.client.remove_conversation_devices(
            FfiMessengerUpdateConversationDevicesRequest {
                conversation_id,
                device_ids: vec![pending.device_id.clone()],
            },
        )?;
        assert!(
            removed_device
                .changed_device_ids
                .contains(&pending.device_id)
        );
        assert!(!removed_device.messages.is_empty());

        let revoked = alice
            .client
            .revoke_device(FfiMessengerRevokeDeviceRequest {
                device_id: pending.device_id.clone(),
                reason: Some(" device-removal-safe-ffi ".to_owned()),
            })?;
        assert!(matches!(revoked.device_status, FfiDeviceStatus::Revoked));
        assert!(revoked.devices.iter().any(|device| {
            device.device_id == pending.device_id
                && matches!(device.device_status, FfiDeviceStatus::Revoked)
        }));

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s6_conversation_member_removals() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        let charlie = create_safe_client(&base_url, "charlie", true)?;
        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;
        charlie.client.load_snapshot()?;

        let group = alice.client.create_conversation(group_request(
            "safe ffi member removals",
            vec![bob.account_id.clone()],
        ))?;
        let conversation_id = group.conversation_id.clone();
        assert_local_leaf_mapping_matches_mls(&alice, &conversation_id)?;

        let removed_bob = alice
            .client
            .remove_conversation_members(FfiMessengerUpdateConversationMembersRequest {
                conversation_id: conversation_id.clone(),
                participant_account_ids: vec![bob.account_id.clone()],
            })
            .context("remove initial member bob")?;
        assert!(removed_bob.changed_account_ids.contains(&bob.account_id));
        assert!(!removed_bob.messages.is_empty());
        assert_local_leaf_mapping_matches_mls(&alice, &conversation_id)?;

        let added_charlie = alice
            .client
            .update_conversation_members(FfiMessengerUpdateConversationMembersRequest {
                conversation_id: conversation_id.clone(),
                participant_account_ids: vec![charlie.account_id.clone()],
            })
            .context("add charlie after bob removal")?;
        assert!(
            added_charlie
                .changed_account_ids
                .contains(&charlie.account_id)
        );
        assert!(!added_charlie.messages.is_empty());
        assert_local_leaf_mapping_matches_mls(&alice, &conversation_id)?;

        let removed_charlie = alice
            .client
            .remove_conversation_members(FfiMessengerUpdateConversationMembersRequest {
                conversation_id: conversation_id.clone(),
                participant_account_ids: vec![charlie.account_id.clone()],
            })
            .context("remove charlie after add")?;
        assert!(
            removed_charlie
                .changed_account_ids
                .contains(&charlie.account_id)
        );
        assert!(!removed_charlie.messages.is_empty());
        assert_local_leaf_mapping_matches_mls(&alice, &conversation_id)?;

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s7_snapshot_migrates_legacy_mls_root_and_restores_messages() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let group = alice.client.create_conversation(group_request(
            "safe ffi restore bootstrap",
            vec![bob.account_id.clone()],
        ))?;
        let conversation_id = group.conversation_id.clone();
        alice
            .client
            .send_message(text_request(&conversation_id, "hello before bob migration"))?;

        bob.client
            .load_snapshot()
            .context("bob initial snapshot before legacy MLS root migration")?;

        let bob_root_path = bob.root_path.clone();
        let bob_database_key = bob.database_key.clone();
        let bob_credential_identity = bob.credential_identity.clone();
        let mls_root = PathBuf::from(&bob_root_path).join("mls");
        let legacy_mls_root = PathBuf::from(&bob_root_path).join("mls-state");
        let metadata_path = mls_root.join("metadata.json");
        let storage_path = mls_root.join("storage.json");
        assert!(
            metadata_path.exists() && storage_path.exists(),
            "expected bob MLS state to exist before migration"
        );
        drop(bob);
        fs::rename(&mls_root, &legacy_mls_root).context("move bob MLS state into legacy root")?;
        assert!(
            !metadata_path.exists() && !storage_path.exists(),
            "expected bob MLS state to move out of the new root"
        );

        let bob = reopen_safe_client(&base_url, &bob_root_path, bob_database_key.clone())?;
        bob.load_snapshot()
            .context("bob snapshot after migrating legacy MLS root")?;
        assert!(
            metadata_path.exists() && storage_path.exists(),
            "expected bob MLS state to be restored into the new root"
        );
        assert!(
            !legacy_mls_root.exists(),
            "expected legacy MLS root to be consumed during migration"
        );
        assert_local_leaf_mapping_matches_mls_at(
            &bob_root_path,
            &bob_database_key,
            &bob_credential_identity,
            &conversation_id,
        )?;

        let page = bob.get_messages(conversation_id, None, Some(20))?;
        let texts = page
            .messages
            .iter()
            .filter_map(message_text)
            .collect::<Vec<_>>();
        assert!(texts.contains(&"hello before bob migration"));

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s8_materialized_history_and_attachments_survive_reopen_without_mls_state()
-> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        alice.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let created = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        let conversation_id = created.conversation_id.clone();
        let conversation_batch = bob.client.get_new_events(None)?;
        let conversation_checkpoint = expect_checkpoint(&conversation_batch)?;

        alice
            .client
            .send_message(text_request(&conversation_id, "hello durable history"))?;
        let payload = b"durable attachment payload".to_vec();
        let token = alice.client.send_attachment(
            conversation_id.clone(),
            payload.clone(),
            FfiMessengerAttachmentMetadata {
                mime_type: "text/plain".to_owned(),
                file_name: Some("durable.txt".to_owned()),
                width_px: None,
                height_px: None,
            },
        )?;
        alice
            .client
            .send_message(attachment_request(&conversation_id, &token.token))?;

        bob.client
            .get_new_events(Some(conversation_checkpoint))
            .context("bob receives durable text and attachment")?;
        let page = bob
            .client
            .get_messages(conversation_id.clone(), None, Some(20))?;
        assert!(
            page.messages
                .iter()
                .filter_map(message_text)
                .any(|text| text == "hello durable history")
        );
        let descriptor = page
            .messages
            .iter()
            .find_map(|message| {
                message
                    .body
                    .as_ref()
                    .and_then(|body| body.attachment.as_ref())
                    .cloned()
            })
            .ok_or_else(|| anyhow!("expected durable attachment descriptor"))?;
        let downloaded = bob
            .client
            .get_attachment(descriptor.attachment_ref.clone())
            .context("bob initial attachment download")?;
        assert_eq!(fs::read(&downloaded.local_path)?, payload);

        let bob_root_path = bob.root_path.clone();
        let bob_database_key = bob.database_key.clone();
        drop(bob);

        let bob_mls_root = PathBuf::from(&bob_root_path).join("mls");
        fs::remove_dir_all(&bob_mls_root).ok();
        fs::remove_file(&downloaded.local_path).ok();

        let bob = reopen_safe_client(&base_url, &bob_root_path, bob_database_key)?;
        let restored_page = bob
            .get_messages(conversation_id, None, Some(20))
            .context("get_messages should read materialized history without MLS replay")?;
        assert!(
            restored_page
                .messages
                .iter()
                .filter_map(message_text)
                .any(|text| text == "hello durable history")
        );

        let restored_attachment = bob
            .get_attachment(descriptor.attachment_ref)
            .context("attachment descriptor should survive reopen without MLS state")?;
        assert_eq!(fs::read(&restored_attachment.local_path)?, payload);

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s9_stale_checkpoint_requires_resync_and_snapshot_rebaseline() -> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;

        alice.client.load_snapshot()?;
        let initial_snapshot = bob.client.load_snapshot()?;
        let initial_checkpoint = initial_snapshot.checkpoint.clone();

        let created = alice
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        let conversation_id = created.conversation_id.clone();

        let conversation_batch = bob.client.get_new_events(initial_checkpoint.clone())?;
        let conversation_checkpoint = expect_checkpoint(&conversation_batch)?;

        alice
            .client
            .send_message(text_request(&conversation_id, "first checkpointed message"))?;
        let first_message_batch = bob
            .client
            .get_new_events(Some(conversation_checkpoint.clone()))?;
        let first_message_checkpoint = expect_checkpoint(&first_message_batch)?;

        alice.client.send_message(text_request(
            &conversation_id,
            "message behind stale checkpoint",
        ))?;
        let stale = bob
            .client
            .get_new_events(Some(conversation_checkpoint.clone()));
        assert!(matches!(stale, Err(FfiMessengerError::RequiresResync(_))));

        let rebased_snapshot = bob.client.load_snapshot()?;
        assert_eq!(
            rebased_snapshot.checkpoint.as_deref(),
            Some(first_message_checkpoint.as_str())
        );

        alice
            .client
            .send_message(text_request(&conversation_id, "message after rebaseline"))?;
        let resumed_batch = bob
            .client
            .get_new_events(rebased_snapshot.checkpoint.clone())?;
        assert!(resumed_batch.events.iter().any(|event| {
            event
                .message
                .as_ref()
                .and_then(|message| message_text(message))
                == Some("message after rebaseline")
        }));

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s10_same_device_pool_recovers_unmaterialized_message_from_sibling_history()
-> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();

    ffi(move || {
        let alice_primary = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        alice_primary.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let intent = alice_primary.client.create_link_device_intent()?;
        let alice_secondary =
            create_pending_safe_client_identity(&base_url, "alice-secondary-recovery")?;
        let pending = alice_secondary
            .client
            .complete_link_device(intent.payload, "Alice Secondary Recovery".to_owned())?;
        alice_primary
            .client
            .approve_linked_device(pending.device_id.clone())?;
        alice_secondary.client.load_snapshot()?;

        let dm = alice_primary
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        bob.client.get_new_events(None)?;
        alice_secondary.client.load_snapshot()?;

        let primary_snapshot = alice_primary.client.load_snapshot()?;
        let first_send = alice_secondary
            .client
            .send_message(text_request(&dm.conversation_id, "secondary-first-gap"))?;
        let second_send = alice_secondary
            .client
            .send_message(text_request(&dm.conversation_id, "secondary-second-gap"))?;
        assert_eq!(
            message_text(&first_send.message),
            Some("secondary-first-gap")
        );
        assert_eq!(
            message_text(&second_send.message),
            Some("secondary-second-gap")
        );

        let primary_batch = alice_primary
            .client
            .get_new_events(primary_snapshot.checkpoint.clone())?;
        let primary_texts = primary_batch
            .events
            .iter()
            .filter_map(|event| event.message.as_ref())
            .filter_map(message_text)
            .collect::<Vec<_>>();
        assert!(primary_texts.contains(&"secondary-first-gap"));
        assert!(primary_texts.contains(&"secondary-second-gap"));

        let secondary_root_path = alice_secondary.root_path.clone();
        let secondary_database_key = alice_secondary.database_key.clone();
        drop(alice_secondary);

        dematerialize_projected_message(
            &secondary_root_path,
            &secondary_database_key,
            &dm.conversation_id,
            first_send.message.server_seq,
        )?;
        fs::remove_dir_all(PathBuf::from(&secondary_root_path).join("mls")).ok();

        let secondary = reopen_safe_client(
            &base_url,
            &secondary_root_path,
            secondary_database_key.clone(),
        )?;
        let store = FfiClientStore::open(client_store_config(
            &secondary_root_path,
            secondary_database_key.clone(),
        ))?;
        let projected = store.history_store().get_projected_messages(
            dm.conversation_id.clone(),
            None,
            Some(20),
        )?;
        let first_projected = projected
            .iter()
            .find(|message| message.server_seq == first_send.message.server_seq)
            .ok_or_else(|| anyhow!("expected first projected message in secondary store"))?;
        assert_eq!(
            first_projected
                .body
                .as_ref()
                .and_then(|body| body.text.as_deref()),
            None
        );
        let second_projected = projected
            .iter()
            .find(|message| message.server_seq == second_send.message.server_seq)
            .ok_or_else(|| anyhow!("expected second projected message in secondary store"))?;
        assert_eq!(
            second_projected
                .body
                .as_ref()
                .and_then(|body| body.text.as_deref()),
            Some("secondary-second-gap")
        );
        drop(store);

        let secondary_snapshot = secondary
            .load_snapshot()
            .context("secondary should reload snapshot and request same-pool recovery")?;
        alice_primary
            .client
            .load_snapshot()
            .context("primary should tick same-pool recovery source side after repair request")?;
        let _resume_batch = secondary
            .get_new_events(secondary_snapshot.checkpoint.clone())
            .context("secondary should process same-pool recovery events")?;

        let recovered_page = secondary
            .get_messages(dm.conversation_id.clone(), None, Some(20))
            .context("secondary should read recovered messages after same-pool resume cycle")?;
        let recovered_first = recovered_page
            .messages
            .iter()
            .find(|message| message.server_seq == first_send.message.server_seq)
            .and_then(message_text);
        assert_eq!(recovered_first, Some("secondary-first-gap"));
        assert!(
            recovered_page
                .messages
                .iter()
                .any(|message| message_text(message) == Some("secondary-second-gap"))
        );

        Ok(())
    })
    .await?;

    server.shutdown().await
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn safe_s11_same_device_pool_recovers_missed_offline_message_from_sibling_history()
-> Result<()> {
    let server = spawn_test_server().await?;
    let base_url = server.base_url.clone();
    let database_url = server.database_url.clone();

    ffi(move || {
        let alice_primary = create_safe_client(&base_url, "alice", true)?;
        let bob = create_safe_client(&base_url, "bob", true)?;
        alice_primary.client.load_snapshot()?;
        bob.client.load_snapshot()?;

        let intent = alice_primary.client.create_link_device_intent()?;
        let alice_secondary =
            create_pending_safe_client_identity(&base_url, "alice-secondary-offline-gap")?;
        let pending = alice_secondary
            .client
            .complete_link_device(intent.payload, "Alice Secondary Offline Gap".to_owned())?;
        alice_primary
            .client
            .approve_linked_device(pending.device_id.clone())?;
        alice_secondary.client.load_snapshot()?;

        let dm = alice_primary
            .client
            .create_conversation(dm_request(&bob.account_id))?;
        bob.client.get_new_events(None)?;
        let secondary_initial_snapshot = alice_secondary.client.load_snapshot()?;

        let secondary_root_path = alice_secondary.root_path.clone();
        let secondary_database_key = alice_secondary.database_key.clone();
        let secondary_device_id = pending.device_id.clone();
        drop(alice_secondary);

        let primary_snapshot = alice_primary.client.load_snapshot()?;
        let first_send = bob
            .client
            .send_message(text_request(&dm.conversation_id, "bob-offline-gap"))?;
        assert_eq!(message_text(&first_send.message), Some("bob-offline-gap"));

        let primary_batch = alice_primary
            .client
            .get_new_events(primary_snapshot.checkpoint.clone())?;
        assert!(primary_batch.events.iter().any(|event| {
            event
                .message
                .as_ref()
                .and_then(|message| message_text(message))
                == Some("bob-offline-gap")
        }));

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("failed to build runtime for inbox mutation")?;
        runtime.block_on(purge_server_message_for_device_gap(
            &database_url,
            &secondary_device_id,
            &dm.conversation_id,
            first_send.message.server_seq,
        ))?;

        let secondary = reopen_safe_client(
            &base_url,
            &secondary_root_path,
            secondary_database_key.clone(),
        )?;
        let secondary_snapshot = secondary
            .load_snapshot()
            .context("secondary should reload snapshot after offline window")?;
        assert_eq!(
            secondary_snapshot.checkpoint, secondary_initial_snapshot.checkpoint,
            "secondary should still be positioned before the missed message"
        );

        let second_send = bob
            .client
            .send_message(text_request(&dm.conversation_id, "bob-after-gap"))?;
        assert_eq!(message_text(&second_send.message), Some("bob-after-gap"));

        let resumed_batch = secondary
            .get_new_events(secondary_snapshot.checkpoint.clone())
            .context("secondary should resume from its pre-gap checkpoint")?;
        assert!(resumed_batch.events.iter().any(|event| {
            event
                .message
                .as_ref()
                .and_then(|message| message_text(message))
                == Some("bob-after-gap")
        }));

        let before_recovery = secondary
            .get_messages(dm.conversation_id.clone(), None, Some(20))
            .context("secondary should inspect local history before sibling recovery")?;
        let missing_first = before_recovery
            .messages
            .iter()
            .find(|message| message.server_seq == first_send.message.server_seq)
            .and_then(message_text);
        assert_eq!(missing_first, None);
        assert!(
            before_recovery
                .messages
                .iter()
                .any(|message| message_text(message) == Some("bob-after-gap"))
        );

        alice_primary
            .client
            .load_snapshot()
            .context("primary should tick sibling history export for missed offline message")?;
        let recovery_snapshot = secondary
            .load_snapshot()
            .context("secondary should reload snapshot before same-pool gap recovery")?;
        let _recovery_batch = secondary
            .get_new_events(recovery_snapshot.checkpoint.clone())
            .context("secondary should process same-pool history recovery after reconnect")?;

        let recovered_page = secondary
            .get_messages(dm.conversation_id.clone(), None, Some(20))
            .context("secondary should read recovered history after same-pool gap recovery")?;
        let recovered_first = recovered_page
            .messages
            .iter()
            .find(|message| message.server_seq == first_send.message.server_seq)
            .and_then(message_text);
        assert_eq!(recovered_first, Some("bob-offline-gap"));
        assert!(
            recovered_page
                .messages
                .iter()
                .any(|message| message_text(message) == Some("bob-after-gap"))
        );

        Ok(())
    })
    .await?;

    server.shutdown().await
}
