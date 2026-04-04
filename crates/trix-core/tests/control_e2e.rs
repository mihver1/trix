use std::{env, fs, path::PathBuf, time::Duration};

use anyhow::{Context, Result, anyhow};
use sqlx::postgres::PgPoolOptions;
use tokio::{
    net::TcpListener,
    task::JoinHandle,
    time::{sleep, timeout},
};
use trix_core::{
    AccountRootMaterial, CreateAccountParams, CreateChatControlInput, DeviceKeyMaterial,
    LocalHistoryStore, LocalProjectionKind, MessageBody, MlsFacade, ModifyChatMembersControlInput,
    PublishKeyPackageMaterial, ServerApiClient, SyncCoordinator, TextMessageBody,
};
use trix_server::{
    auth::AuthManager, blobs::LocalBlobStore, build::BuildInfo, config::AppConfig, db::Database,
    signatures::account_bootstrap_message, state::AppState,
};
use trix_types::{AccountId, ChatType, DeviceId, MessageId, MessageKind, WebSocketServerFrame};
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

#[tokio::test]
#[ignore = "requires local postgres"]
async fn smoke_create_chat_control_and_rollback_invalid_member_remove() -> Result<()> {
    let server = spawn_test_server().await?;

    let mut alice = create_authenticated_identity(&server.base_url, "alice").await?;
    let bob = create_authenticated_identity(&server.base_url, "bob").await?;

    bob.client
        .publish_key_packages(vec![PublishKeyPackageMaterial {
            cipher_suite: bob.facade.ciphersuite_label(),
            key_package: bob.facade.generate_key_package()?,
        }])
        .await?;

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
                participant_account_ids: vec![bob.account_id],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )
        .await?;

    assert_eq!(create_outcome.chat_type, ChatType::Dm);
    assert_eq!(
        alice_store.chat_mls_group_id(create_outcome.chat_id),
        Some(create_outcome.mls_group_id.clone())
    );

    let local_chat = alice_store
        .get_chat(create_outcome.chat_id)
        .ok_or_else(|| anyhow!("local chat should exist after create_chat_control"))?;
    assert_eq!(local_chat.members.len(), 2);
    assert_eq!(local_chat.device_members.len(), 2);

    let projected = alice_store.get_projected_messages(create_outcome.chat_id, None, Some(10));
    assert_eq!(projected.len(), 2);
    assert!(projected.iter().any(|message| {
        matches!(message.projection_kind, LocalProjectionKind::CommitMerged)
            && message.merged_epoch == Some(1)
    }));
    assert!(projected.iter().any(|message| {
        matches!(message.projection_kind, LocalProjectionKind::WelcomeRef)
            && message.payload.as_ref().is_some()
    }));

    let bob_chats = bob.client.list_chats().await?;
    assert!(
        bob_chats
            .chats
            .iter()
            .any(|chat| chat.chat_id == create_outcome.chat_id)
    );
    let bob_inbox = bob.client.get_inbox(None, Some(10)).await?;
    assert_eq!(bob_inbox.items.len(), 2);
    assert!(bob_inbox.items.iter().any(|item| {
        item.message.message_kind == trix_types::MessageKind::Commit
            && item.message.chat_id == create_outcome.chat_id
    }));
    assert!(bob_inbox.items.iter().any(|item| {
        item.message.message_kind == trix_types::MessageKind::WelcomeRef
            && item.message.chat_id == create_outcome.chat_id
    }));

    let group_before = alice
        .facade
        .load_group(&create_outcome.mls_group_id)?
        .ok_or_else(|| anyhow!("alice group should exist after create_chat_control"))?;
    let members_before = alice.facade.members(&group_before)?;
    assert_eq!(members_before.len(), 2);
    assert!(
        members_before
            .iter()
            .any(|member| member.credential_identity == b"alice-credential")
    );
    assert!(
        members_before
            .iter()
            .any(|member| member.credential_identity == b"bob-credential")
    );

    let failed_message_id = MessageId::new();
    let error = alice_sync
        .remove_chat_members_control(
            &alice.client,
            &mut alice_store,
            &mut alice.facade,
            ModifyChatMembersControlInput {
                actor_account_id: alice.account_id,
                actor_device_id: alice.device_id,
                chat_id: create_outcome.chat_id,
                participant_account_ids: vec![bob.account_id],
                commit_aad_json: Some(serde_json::json!({ "message_id": failed_message_id.0 })),
                welcome_aad_json: None,
            },
        )
        .await
        .expect_err("dm member removal should fail on server and trigger rollback");
    let error_text = error.to_string();
    assert!(
        error_text.contains("member changes are only supported for group chats")
            || error_text.contains("group chats")
            || error_text.contains("bad request")
            || error_text.contains("bad_request")
    );

    let group_after = alice
        .facade
        .load_group(&create_outcome.mls_group_id)?
        .ok_or_else(|| anyhow!("alice group should still exist after rollback"))?;
    let members_after = alice.facade.members(&group_after)?;
    assert_eq!(members_after.len(), 2);
    assert_eq!(
        members_after
            .iter()
            .map(|member| member.credential_identity.clone())
            .collect::<Vec<_>>(),
        members_before
            .iter()
            .map(|member| member.credential_identity.clone())
            .collect::<Vec<_>>()
    );

    server.shutdown().await?;
    Ok(())
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn inbound_welcome_bootstrap_projects_text_and_persists_group_mapping() -> Result<()> {
    let server = spawn_test_server().await?;

    let mut alice = create_authenticated_identity(&server.base_url, "alice").await?;
    let bot_root = env::temp_dir().join(format!("trix-core-bot-{}", Uuid::new_v4()));
    let bot =
        create_authenticated_identity_persistent(&server.base_url, "echo-bot", &bot_root).await?;

    bot.client
        .publish_key_packages(vec![PublishKeyPackageMaterial {
            cipher_suite: bot.facade.ciphersuite_label(),
            key_package: bot.facade.generate_key_package()?,
        }])
        .await?;

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
                participant_account_ids: vec![bot.account_id],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )
        .await?;

    let bot_history_path = bot_root.join("history.json");
    let bot_sync_path = bot_root.join("sync-state.json");
    let mut bot_store = LocalHistoryStore::new_persistent(&bot_history_path)?;
    let mut bot_sync = SyncCoordinator::new_persistent(&bot_sync_path)?;

    let initial_report = bot_sync
        .sync_chat_histories_into_store(&bot.client, &mut bot_store, 100)
        .await?;
    assert!(
        initial_report
            .changed_chat_ids
            .contains(&create_outcome.chat_id)
    );

    let bootstrap_projection =
        bot_store.project_chat_with_facade(create_outcome.chat_id, &bot.facade, None)?;
    assert_eq!(bootstrap_projection.processed_messages, 0);
    assert!(
        bot_store
            .chat_mls_group_id(create_outcome.chat_id)
            .is_some()
    );

    let alice_group_id = alice_store
        .chat_mls_group_id(create_outcome.chat_id)
        .ok_or_else(|| anyhow!("alice chat should have an MLS group id"))?;
    let mut alice_group = alice
        .facade
        .load_group(&alice_group_id)?
        .ok_or_else(|| anyhow!("alice group should load after create_chat_control"))?;

    alice_sync
        .send_message_body(
            &alice.client,
            &mut alice_store,
            &mut alice.facade,
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

    bot_sync
        .sync_chat_histories_into_store(&bot.client, &mut bot_store, 100)
        .await?;
    let message_projection =
        bot_store.project_chat_with_facade(create_outcome.chat_id, &bot.facade, None)?;
    assert_eq!(message_projection.advanced_to_server_seq, Some(3));

    let timeline = bot_store.get_local_timeline_items(
        create_outcome.chat_id,
        Some(bot.account_id),
        None,
        Some(10),
    );
    assert!(timeline.iter().any(|item| {
        item.preview_text == "hello bot"
            && item.body
                == Some(MessageBody::Text(TextMessageBody {
                    text: "hello bot".to_owned(),
                }))
    }));

    let persisted_group_id = bot_store
        .chat_mls_group_id(create_outcome.chat_id)
        .ok_or_else(|| anyhow!("bot chat should persist MLS group id"))?;
    bot.facade.save_state()?;
    bot_store.save_state()?;

    let mut restored_store = LocalHistoryStore::new_persistent(&bot_history_path)?;
    assert_eq!(
        restored_store.chat_mls_group_id(create_outcome.chat_id),
        Some(persisted_group_id.clone())
    );

    let restored_facade = MlsFacade::load_persistent(bot_root.join("mls"))?;
    let restored_projection =
        restored_store.project_chat_with_facade(create_outcome.chat_id, &restored_facade, None)?;
    assert_eq!(restored_projection.processed_messages, 0);
    assert!(
        restored_facade.load_group(&persisted_group_id)?.is_some(),
        "reloaded facade should still have the bootstrapped group"
    );

    server.shutdown().await?;
    fs::remove_dir_all(&bot_root).ok();
    Ok(())
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn smoke_websocket_delivers_inbox_items_and_acknowledges() -> Result<()> {
    let server = spawn_test_server().await?;

    let mut alice = create_authenticated_identity(&server.base_url, "alice").await?;
    let bob = create_authenticated_identity(&server.base_url, "bob").await?;

    bob.client
        .publish_key_packages(vec![PublishKeyPackageMaterial {
            cipher_suite: bob.facade.ciphersuite_label(),
            key_package: bob.facade.generate_key_package()?,
        }])
        .await?;

    let mut bob_ws = bob.client.connect_websocket().await?;
    let hello = timeout(Duration::from_secs(2), bob_ws.next_frame()).await??;
    match hello {
        Some(WebSocketServerFrame::Hello {
            account_id,
            device_id,
            lease_owner,
            lease_ttl_seconds,
            ..
        }) => {
            assert_eq!(account_id, bob.account_id);
            assert_eq!(device_id, bob.device_id);
            assert!(lease_owner.starts_with(&format!("ws:{}:", bob.device_id.0)));
            assert_eq!(lease_ttl_seconds, 30);
        }
        other => return Err(anyhow!("expected websocket hello frame, got {other:?}")),
    }

    bob_ws
        .send_presence_ping(Some("ws-smoke".to_owned()))
        .await?;
    let pong = timeout(Duration::from_secs(2), bob_ws.next_frame()).await??;
    match pong {
        Some(WebSocketServerFrame::Pong { nonce, server_unix }) => {
            assert_eq!(nonce.as_deref(), Some("ws-smoke"));
            assert!(server_unix > 0);
        }
        other => return Err(anyhow!("expected websocket pong frame, got {other:?}")),
    }

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
                participant_account_ids: vec![bob.account_id],
                group_id: None,
                commit_aad_json: None,
                welcome_aad_json: None,
            },
        )
        .await?;

    let inbox_frame = timeout(Duration::from_secs(3), bob_ws.next_frame()).await??;
    let items = match inbox_frame {
        Some(WebSocketServerFrame::InboxItems {
            lease_owner,
            lease_expires_at_unix,
            items,
        }) => {
            assert!(lease_owner.starts_with(&format!("ws:{}:", bob.device_id.0)));
            assert!(lease_expires_at_unix > 0);
            items
        }
        other => return Err(anyhow!("expected websocket inbox frame, got {other:?}")),
    };

    assert_eq!(items.len(), 2);
    assert!(
        items
            .iter()
            .all(|item| item.message.chat_id == create_outcome.chat_id)
    );
    assert!(
        items
            .iter()
            .any(|item| item.message.message_kind == MessageKind::Commit)
    );
    assert!(
        items
            .iter()
            .any(|item| item.message.message_kind == MessageKind::WelcomeRef)
    );

    let mut bob_store = LocalHistoryStore::new();
    let mut bob_sync = SyncCoordinator::new();
    let report = bob_sync.apply_inbox_items_into_store(&mut bob_store, &items)?;
    assert_eq!(report.messages_upserted, 2);
    assert_eq!(
        bob_sync.chat_cursor(create_outcome.chat_id),
        Some(
            items
                .iter()
                .map(|item| item.message.server_seq)
                .max()
                .unwrap_or_default()
        )
    );

    let ack_ids = items.iter().map(|item| item.inbox_id).collect::<Vec<_>>();
    bob_ws.send_ack(ack_ids.clone()).await?;
    let acked = timeout(Duration::from_secs(2), bob_ws.next_frame()).await??;
    match acked {
        Some(WebSocketServerFrame::Acked { acked_inbox_ids }) => {
            assert_eq!(acked_inbox_ids, ack_ids);
            bob_sync.record_acked_inbox_ids(&acked_inbox_ids)?;
            let remaining = bob.client.get_inbox(None, Some(10)).await?;
            assert!(remaining.items.is_empty());
        }
        other => return Err(anyhow!("expected websocket ack frame, got {other:?}")),
    }

    bob_ws.close().await?;
    server.shutdown().await?;
    Ok(())
}

#[tokio::test]
#[ignore = "requires local postgres"]
async fn smoke_cors_only_allows_listed_origins() -> Result<()> {
    let server = spawn_test_server_with_cors(vec!["http://allowed.local".to_owned()]).await?;
    let client = reqwest::Client::new();

    let denied = client
        .get(format!("{}/v0/system/health", server.base_url))
        .header("Origin", "http://denied.local")
        .send()
        .await?;
    assert_eq!(denied.status(), reqwest::StatusCode::OK);
    assert!(
        denied
            .headers()
            .get("access-control-allow-origin")
            .is_none()
    );

    let allowed = client
        .get(format!("{}/v0/system/health", server.base_url))
        .header("Origin", "http://allowed.local")
        .send()
        .await?;
    assert_eq!(allowed.status(), reqwest::StatusCode::OK);
    assert_eq!(
        allowed
            .headers()
            .get("access-control-allow-origin")
            .and_then(|value| value.to_str().ok()),
        Some("http://allowed.local")
    );

    server.shutdown().await?;
    Ok(())
}

async fn spawn_test_server() -> Result<TestServer> {
    spawn_test_server_with_cors(Vec::new()).await
}

async fn spawn_test_server_with_cors(cors_allowed_origins: Vec<String>) -> Result<TestServer> {
    let database_url =
        env::var("TRIX_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_TEST_DATABASE_URL.to_owned());
    reset_test_database(&database_url).await?;

    let blob_root = env::temp_dir().join(format!("trix-core-e2e-blobs-{}", Uuid::new_v4()));
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
        jwt_signing_key: "trix-core-e2e-test-key".to_owned(),
        admin_username: "trix-core-e2e-admin".to_owned(),
        admin_password: "trix-core-e2e-admin-pass".to_owned(),
        admin_jwt_signing_key: "trix-core-e2e-admin-jwt".to_owned(),
        admin_session_ttl_seconds: 900,
        cors_allowed_origins,
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
        debug_metrics_enabled: false,
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

    let challenge = client.create_auth_challenge(created.device_id).await?;
    let session = client
        .create_auth_session(
            created.device_id,
            challenge.challenge_id,
            &device_keys.sign(&challenge.challenge),
        )
        .await?;
    client.set_access_token(session.access_token);

    Ok(TestIdentity {
        account_id: created.account_id,
        device_id: created.device_id,
        client,
        facade: MlsFacade::new(credential_identity)?,
    })
}

async fn create_authenticated_identity_persistent(
    base_url: &str,
    handle: &str,
    storage_root: &PathBuf,
) -> Result<TestIdentity> {
    let identity = create_authenticated_identity(base_url, handle).await?;
    fs::create_dir_all(storage_root)?;
    let persistent_facade = MlsFacade::new_persistent(
        format!("{handle}-credential").into_bytes(),
        storage_root.join("mls"),
    )?;

    Ok(TestIdentity {
        facade: persistent_facade,
        ..identity
    })
}

async fn wait_for_server(client: &ServerApiClient) -> Result<()> {
    let mut last_error = None;
    for _ in 0..20 {
        match client.get_health().await {
            Ok(response) if response.status == trix_types::ServiceStatus::Ok => return Ok(()),
            Ok(response) => {
                last_error = Some(anyhow!("unexpected health status {:?}", response.status));
            }
            Err(err) => {
                last_error = Some(err.into());
            }
        }
        sleep(Duration::from_millis(50)).await;
    }
    Err(last_error.unwrap_or_else(|| anyhow!("server did not become healthy in time")))
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

impl TestServer {
    async fn shutdown(self) -> Result<()> {
        self.task.abort();
        let _ = self.task.await;
        reset_test_database(&self.database_url).await?;
        fs::remove_dir_all(&self.blob_root).ok();
        Ok(())
    }
}
