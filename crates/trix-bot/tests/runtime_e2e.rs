use std::{env, fs, path::PathBuf, time::Duration};

use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose};
use serde::Deserialize;
use sqlx::postgres::PgPoolOptions;
use tokio::{net::TcpListener, sync::broadcast, task::JoinHandle, time::sleep};
use trix_bot::{Bot, BotEvent, BotInitConfig, BotLoadConfig, ConnectionMode};
use trix_core::{
    AccountRootMaterial, CreateAccountParams, CreateChatControlInput, DeviceKeyMaterial,
    LocalHistoryStore, MessageBody, MlsFacade, ServerApiClient, SyncCoordinator, TextMessageBody,
    prepare_attachment_upload,
};
use trix_server::{
    auth::AuthManager, blobs::LocalBlobStore, build::BuildInfo, config::AppConfig, db::Database,
    signatures::account_bootstrap_message, state::AppState,
};
use trix_types::{AccountId, ChatId, ChatType, DeviceId, MessageId};
use uuid::Uuid;

const DEFAULT_TEST_DATABASE_URL: &str = "postgres://trix:trix@localhost:5432/trix";

struct TestServer {
    base_url: String,
    database_url: String,
    blob_root: PathBuf,
    task: JoinHandle<()>,
}

struct TestIdentity {
    account_id: AccountId,
    device_id: DeviceId,
    client: ServerApiClient,
    facade: MlsFacade,
}

#[derive(Debug, Deserialize)]
struct PlainIdentityFile {
    server_url: String,
    device_id: DeviceId,
    device_private_key_b64: String,
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn bot_receives_text_replies_and_dedupes_after_restart() -> Result<()> {
    let server = spawn_test_server().await?;
    let state_dir = env::temp_dir().join(format!("trix-bot-runtime-{}", Uuid::new_v4()));
    let bot = Bot::init(BotInitConfig {
        server_url: server.base_url.clone(),
        state_dir: state_dir.clone(),
        profile_name: "Echo Bot".to_owned(),
        handle: Some("echo-bot".to_owned()),
        master_secret_env: None,
        plaintext_dev_store: true,
    })
    .await?;

    let mut bot_events = bot.subscribe();
    bot.start().await?;
    wait_for_ready(&mut bot_events).await?;

    let mut alice = create_authenticated_identity(&server.base_url, "alice").await?;
    let mut alice_store = LocalHistoryStore::new();
    let mut alice_sync = SyncCoordinator::new();
    let create_outcome = alice_sync
        .create_chat_control(
            &alice.client,
            &mut alice_store,
            &mut alice.facade,
            CreateChatControlInput {
                creator_account_id: alice.account_id,
                creator_device_id: alice.device_id,
                chat_type: ChatType::Dm,
                title: None,
                participant_account_ids: vec![parse_account_id(&bot.identity().account_id)?],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )
        .await?;

    wait_for_chat(&bot, create_outcome.chat_id).await?;

    let alice_group_id = alice_store
        .chat_mls_group_id(create_outcome.chat_id)
        .ok_or_else(|| anyhow!("alice chat must have an MLS group id"))?;
    let mut alice_group = alice
        .facade
        .load_group(&alice_group_id)?
        .ok_or_else(|| anyhow!("alice group should load"))?;
    alice_sync
        .send_message_body(
            &alice.client,
            &mut alice_store,
            &alice.facade,
            &mut alice_group,
            alice.account_id,
            alice.device_id,
            create_outcome.chat_id,
            None,
            &MessageBody::Text(TextMessageBody {
                text: "hello bot".to_owned(),
            }),
            None,
        )
        .await?;

    let received = wait_for_text_message(&mut bot_events).await?;
    assert_eq!(received.text, "hello bot");
    assert_eq!(received.chat_id, create_outcome.chat_id.0.to_string());
    assert!(!received.message_id.is_empty());
    assert!(received.server_seq > 0);
    assert_eq!(received.sender_account_id, alice.account_id.0.to_string());
    assert_eq!(received.sender_device_id, alice.device_id.0.to_string());
    assert!(received.created_at_unix > 0);

    let sent = bot
        .send_text(create_outcome.chat_id, "pong")
        .await
        .context("bot should send a text reply")?;
    assert_eq!(sent.chat_id, create_outcome.chat_id.0.to_string());

    alice_sync
        .sync_chat_histories_into_store(&alice.client, &mut alice_store, 100)
        .await?;
    alice_store.project_chat_with_facade(create_outcome.chat_id, &alice.facade, None)?;
    let alice_timeline = alice_store.get_local_timeline_items(
        create_outcome.chat_id,
        Some(alice.account_id),
        None,
        Some(20),
    );
    assert!(
        alice_timeline
            .iter()
            .any(|item| item.preview_text == "pong")
    );

    bot.stop().await?;

    let restarted = Bot::load(BotLoadConfig {
        state_dir: state_dir.clone(),
        server_url_override: Some(server.base_url.clone()),
        master_secret_env: None,
        plaintext_dev_store: true,
    })
    .await?;
    let mut restarted_events = restarted.subscribe();
    restarted.start().await?;
    wait_for_ready(&mut restarted_events).await?;
    assert_no_text_message(&mut restarted_events).await?;

    restarted.stop().await?;
    server.shutdown().await?;
    fs::remove_dir_all(state_dir).ok();
    Ok(())
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn bot_falls_back_to_polling_after_session_replaced() -> Result<()> {
    let server = spawn_test_server().await?;
    let state_dir = env::temp_dir().join(format!("trix-bot-session-{}", Uuid::new_v4()));
    let bot = Bot::init(BotInitConfig {
        server_url: server.base_url.clone(),
        state_dir: state_dir.clone(),
        profile_name: "Polling Bot".to_owned(),
        handle: Some("poll-bot".to_owned()),
        master_secret_env: None,
        plaintext_dev_store: true,
    })
    .await?;

    let mut events = bot.subscribe();
    bot.start().await?;
    wait_for_ready(&mut events).await?;
    wait_for_connection_mode(&mut events, ConnectionMode::Websocket).await?;

    let identity = load_plain_identity(&state_dir)?;
    let device_keys =
        DeviceKeyMaterial::from_bytes(decode_private_key(&identity.device_private_key_b64)?);
    let mut replacement_client = ServerApiClient::new(identity.server_url)?;
    authenticate_client_for_test(&mut replacement_client, identity.device_id, &device_keys).await?;
    let mut replacement_ws = replacement_client.connect_websocket().await?;

    wait_for_connection_mode(&mut events, ConnectionMode::Polling).await?;
    replacement_ws.close().await.ok();
    sleep(Duration::from_millis(250)).await;

    let mut alice = create_authenticated_identity(&server.base_url, "alice").await?;
    let mut alice_store = LocalHistoryStore::new();
    let mut alice_sync = SyncCoordinator::new();
    let create_outcome = alice_sync
        .create_chat_control(
            &alice.client,
            &mut alice_store,
            &mut alice.facade,
            CreateChatControlInput {
                creator_account_id: alice.account_id,
                creator_device_id: alice.device_id,
                chat_type: ChatType::Dm,
                title: None,
                participant_account_ids: vec![parse_account_id(&bot.identity().account_id)?],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )
        .await?;

    wait_for_chat(&bot, create_outcome.chat_id).await?;
    bot.stop().await?;
    server.shutdown().await?;
    fs::remove_dir_all(state_dir).ok();
    Ok(())
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn bot_can_manually_republish_key_packages() -> Result<()> {
    let server = spawn_test_server().await?;
    let state_dir = env::temp_dir().join(format!("trix-bot-republish-{}", Uuid::new_v4()));
    let bot = Bot::init(BotInitConfig {
        server_url: server.base_url.clone(),
        state_dir: state_dir.clone(),
        profile_name: "Republish Bot".to_owned(),
        handle: Some("republish-bot".to_owned()),
        master_secret_env: None,
        plaintext_dev_store: true,
    })
    .await?;

    let published = bot.publish_key_packages(3).await?;
    assert_eq!(published, 3);

    server.shutdown().await?;
    fs::remove_dir_all(state_dir).ok();
    Ok(())
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn bot_receives_and_downloads_file_attachments() -> Result<()> {
    let server = spawn_test_server().await?;
    let state_dir = env::temp_dir().join(format!("trix-bot-files-{}", Uuid::new_v4()));
    let bot = Bot::init(BotInitConfig {
        server_url: server.base_url.clone(),
        state_dir: state_dir.clone(),
        profile_name: "File Bot".to_owned(),
        handle: Some("file-bot".to_owned()),
        master_secret_env: None,
        plaintext_dev_store: true,
    })
    .await?;

    let mut bot_events = bot.subscribe();
    bot.start().await?;
    wait_for_ready(&mut bot_events).await?;

    let mut alice = create_authenticated_identity(&server.base_url, "alice").await?;
    let mut alice_store = LocalHistoryStore::new();
    let mut alice_sync = SyncCoordinator::new();
    let create_outcome = alice_sync
        .create_chat_control(
            &alice.client,
            &mut alice_store,
            &mut alice.facade,
            CreateChatControlInput {
                creator_account_id: alice.account_id,
                creator_device_id: alice.device_id,
                chat_type: ChatType::Dm,
                title: None,
                participant_account_ids: vec![parse_account_id(&bot.identity().account_id)?],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )
        .await?;

    wait_for_chat(&bot, create_outcome.chat_id).await?;

    let payload = b"hello attachment".to_vec();
    send_attachment_from_identity(
        &alice,
        &mut alice_store,
        &mut alice_sync,
        create_outcome.chat_id,
        &payload,
        "text/plain",
        Some("note.txt".to_owned()),
    )
    .await?;

    let received = wait_for_file_message(&mut bot_events).await?;
    assert_eq!(received.chat_id, create_outcome.chat_id.0.to_string());
    assert_eq!(received.sender_account_id, alice.account_id.0.to_string());
    assert_eq!(received.sender_device_id, alice.device_id.0.to_string());
    assert!(received.server_seq > 0);
    assert_eq!(received.mime_type, "text/plain");
    assert_eq!(received.file_name.as_deref(), Some("note.txt"));
    assert!(received.size_bytes > 0);
    assert_eq!(received.width_px, None);
    assert_eq!(received.height_px, None);
    assert!(!received.blob_id.is_empty());
    assert!(received.created_at_unix > 0);

    let downloaded = bot
        .download_attachment(
            create_outcome.chat_id,
            parse_message_id(&received.message_id)?,
        )
        .await?;
    assert_eq!(downloaded.plaintext, payload);
    assert_eq!(downloaded.mime_type, "text/plain");
    assert_eq!(downloaded.file_name.as_deref(), Some("note.txt"));

    bot.stop().await?;
    server.shutdown().await?;
    fs::remove_dir_all(state_dir).ok();
    Ok(())
}

async fn spawn_test_server() -> Result<TestServer> {
    let database_url =
        env::var("TRIX_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_TEST_DATABASE_URL.to_owned());
    reset_test_database(&database_url).await?;

    let blob_root = env::temp_dir().join(format!("trix-bot-e2e-blobs-{}", Uuid::new_v4()));
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
        jwt_signing_key: "trix-bot-e2e-test-key".to_owned(),
        cors_allowed_origins: Vec::new(),
        rate_limit_window_seconds: 60,
        rate_limit_auth_challenge_limit: 20,
        rate_limit_auth_session_limit: 20,
        rate_limit_link_intents_limit: 20,
        rate_limit_directory_limit: 120,
        rate_limit_blob_upload_limit: 20,
        cleanup_interval_seconds: 300,
        auth_challenge_retention_seconds: 3600,
        link_intent_retention_seconds: 86400,
        transfer_bundle_retention_seconds: 86400,
        history_sync_retention_seconds: 86400,
        pending_blob_retention_seconds: 86400,
        shutdown_grace_period_seconds: 5,
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

async fn create_authenticated_identity(base_url: &str, handle: &str) -> Result<TestIdentity> {
    let credential_identity = format!("{handle}-credential").into_bytes();
    let account_root = AccountRootMaterial::generate();
    let device_keys = DeviceKeyMaterial::generate();
    let transport_pubkey = device_keys.public_key_bytes();
    let bootstrap_payload = account_bootstrap_message(&transport_pubkey, &credential_identity);

    let mut client = ServerApiClient::new(base_url)?;
    let created = client
        .create_account(CreateAccountParams {
            handle: Some(handle.to_owned()),
            profile_name: handle.to_owned(),
            profile_bio: None,
            device_display_name: format!("{handle}-mac"),
            platform: "macos".to_owned(),
            credential_identity: credential_identity.clone(),
            account_root_pubkey: account_root.public_key_bytes(),
            account_root_signature: account_root.sign(&bootstrap_payload),
            transport_pubkey,
        })
        .await?;

    authenticate_client_for_test(&mut client, created.device_id, &device_keys).await?;

    Ok(TestIdentity {
        account_id: created.account_id,
        device_id: created.device_id,
        client,
        facade: MlsFacade::new(credential_identity)?,
    })
}

async fn authenticate_client_for_test(
    client: &mut ServerApiClient,
    device_id: DeviceId,
    device_keys: &DeviceKeyMaterial,
) -> Result<()> {
    let challenge = client.create_auth_challenge(device_id).await?;
    let session = client
        .create_auth_session(
            device_id,
            challenge.challenge_id,
            &device_keys.sign(&challenge.challenge),
        )
        .await?;
    client.set_access_token(session.access_token);
    Ok(())
}

async fn wait_for_server(client: &ServerApiClient) -> Result<()> {
    let mut last_error = None;
    for _ in 0..20 {
        match client.get_health().await {
            Ok(response) if response.status == trix_types::ServiceStatus::Ok => return Ok(()),
            Ok(response) => {
                last_error = Some(anyhow!("unexpected health status {:?}", response.status));
            }
            Err(err) => last_error = Some(err.into()),
        }
        sleep(Duration::from_millis(50)).await;
    }
    Err(last_error.unwrap_or_else(|| anyhow!("server did not become healthy in time")))
}

async fn wait_for_ready(events: &mut broadcast::Receiver<BotEvent>) -> Result<()> {
    for _ in 0..20 {
        match tokio::time::timeout(Duration::from_secs(1), events.recv()).await {
            Ok(Ok(BotEvent::Ready { .. })) => return Ok(()),
            Ok(Ok(_)) => continue,
            Ok(Err(err)) => return Err(anyhow!("bot event stream failed: {err}")),
            Err(_) => return Err(anyhow!("timed out waiting for ready event")),
        }
    }
    Err(anyhow!("bot did not emit a ready event"))
}

async fn wait_for_connection_mode(
    events: &mut broadcast::Receiver<BotEvent>,
    mode: ConnectionMode,
) -> Result<()> {
    for _ in 0..40 {
        match tokio::time::timeout(Duration::from_secs(1), events.recv()).await {
            Ok(Ok(BotEvent::ConnectionChanged {
                connected: true,
                mode: observed,
            })) if observed == mode => return Ok(()),
            Ok(Ok(_)) => continue,
            Ok(Err(err)) => return Err(anyhow!("bot event stream failed: {err}")),
            Err(_) => return Err(anyhow!("timed out waiting for connection event")),
        }
    }
    Err(anyhow!("bot did not emit the expected connection mode"))
}

async fn wait_for_text_message(
    events: &mut broadcast::Receiver<BotEvent>,
) -> Result<TextMessageEvent> {
    for _ in 0..40 {
        match tokio::time::timeout(Duration::from_secs(1), events.recv()).await {
            Ok(Ok(BotEvent::TextMessage {
                chat_id,
                message_id,
                server_seq,
                sender_account_id,
                sender_device_id,
                text,
                created_at_unix,
            })) => {
                return Ok(TextMessageEvent {
                    chat_id,
                    message_id,
                    server_seq,
                    sender_account_id,
                    sender_device_id,
                    text,
                    created_at_unix,
                });
            }
            Ok(Ok(_)) => continue,
            Ok(Err(err)) => return Err(anyhow!("bot event stream failed: {err}")),
            Err(_) => return Err(anyhow!("timed out waiting for text message event")),
        }
    }
    Err(anyhow!("bot did not emit a text message event"))
}

async fn wait_for_file_message(
    events: &mut broadcast::Receiver<BotEvent>,
) -> Result<FileMessageEvent> {
    for _ in 0..40 {
        match tokio::time::timeout(Duration::from_secs(1), events.recv()).await {
            Ok(Ok(BotEvent::FileMessage {
                chat_id,
                message_id,
                server_seq,
                sender_account_id,
                sender_device_id,
                blob_id,
                mime_type,
                size_bytes,
                file_name,
                width_px,
                height_px,
                created_at_unix,
            })) => {
                return Ok(FileMessageEvent {
                    chat_id,
                    message_id,
                    server_seq,
                    sender_account_id,
                    sender_device_id,
                    blob_id,
                    mime_type,
                    size_bytes,
                    file_name,
                    width_px,
                    height_px,
                    created_at_unix,
                });
            }
            Ok(Ok(_)) => continue,
            Ok(Err(err)) => return Err(anyhow!("bot event stream failed: {err}")),
            Err(_) => return Err(anyhow!("timed out waiting for file message event")),
        }
    }
    Err(anyhow!("bot did not emit a file message event"))
}

async fn assert_no_text_message(events: &mut broadcast::Receiver<BotEvent>) -> Result<()> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(BotEvent::TextMessage { text, .. })) => {
                return Err(anyhow!("unexpected duplicate text event `{text}`"));
            }
            Ok(Ok(_)) => continue,
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(err)) => return Err(anyhow!("bot event stream failed: {err}")),
            Err(_) => return Ok(()),
        }
    }
    Ok(())
}

async fn wait_for_chat(bot: &Bot, chat_id: ChatId) -> Result<()> {
    for _ in 0..40 {
        let chats = bot.list_chats().await?;
        if chats.iter().any(|chat| chat.chat_id == chat_id) {
            return Ok(());
        }
        sleep(Duration::from_millis(150)).await;
    }
    Err(anyhow!("chat {} did not appear in bot store", chat_id.0))
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

fn load_plain_identity(state_dir: &PathBuf) -> Result<PlainIdentityFile> {
    let path = state_dir.join("identity.json");
    let file = fs::File::open(&path)
        .with_context(|| format!("failed to open plain identity file {}", path.display()))?;
    serde_json::from_reader(file)
        .with_context(|| format!("failed to decode plain identity file {}", path.display()))
}

fn decode_private_key(value: &str) -> Result<[u8; 32]> {
    let bytes = general_purpose::STANDARD
        .decode(value)
        .context("failed to decode private key base64")?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("decoded device private key must be 32 bytes"))
}

fn parse_account_id(value: &str) -> Result<AccountId> {
    Ok(AccountId(Uuid::parse_str(value).with_context(|| {
        format!("invalid account id `{value}`")
    })?))
}

fn parse_message_id(value: &str) -> Result<MessageId> {
    Ok(MessageId(Uuid::parse_str(value).with_context(|| {
        format!("invalid message id `{value}`")
    })?))
}

async fn send_attachment_from_identity(
    identity: &TestIdentity,
    store: &mut LocalHistoryStore,
    sync: &mut SyncCoordinator,
    chat_id: ChatId,
    payload: &[u8],
    mime_type: &str,
    file_name: Option<String>,
) -> Result<()> {
    let group_id = store
        .chat_mls_group_id(chat_id)
        .ok_or_else(|| anyhow!("chat {} must have an MLS group id", chat_id.0))?;
    let mut group = identity
        .facade
        .load_group(&group_id)?
        .ok_or_else(|| anyhow!("chat {} group should load", chat_id.0))?;
    let prepared = prepare_attachment_upload(payload, mime_type, file_name, None, None)?;
    let create = identity
        .client
        .create_blob_upload(
            chat_id,
            prepared.mime_type.clone(),
            prepared.encrypted_size_bytes,
            &prepared.encrypted_sha256,
        )
        .await?;
    if create.needs_upload {
        identity
            .client
            .upload_blob(create.blob_id.clone(), &prepared.encrypted_payload)
            .await?;
    } else {
        identity.client.head_blob(create.blob_id.clone()).await?;
    }

    sync.send_message_body(
        &identity.client,
        store,
        &identity.facade,
        &mut group,
        identity.account_id,
        identity.device_id,
        chat_id,
        None,
        &MessageBody::Attachment(prepared.into_message_body(create.blob_id)),
        None,
    )
    .await?;
    Ok(())
}

#[derive(Debug)]
struct TextMessageEvent {
    chat_id: String,
    message_id: String,
    server_seq: u64,
    sender_account_id: String,
    sender_device_id: String,
    text: String,
    created_at_unix: u64,
}

#[derive(Debug)]
struct FileMessageEvent {
    chat_id: String,
    message_id: String,
    server_seq: u64,
    sender_account_id: String,
    sender_device_id: String,
    blob_id: String,
    mime_type: String,
    size_bytes: u64,
    file_name: Option<String>,
    width_px: Option<u32>,
    height_px: Option<u32>,
    created_at_unix: u64,
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
