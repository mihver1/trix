use std::{path::Path, path::PathBuf, sync::Arc};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use tokio::{
    sync::{Mutex, broadcast, watch},
    task::JoinHandle,
    time::{Duration, Instant, sleep},
};
use trix_core::{
    CreateAccountParams, LocalChatListItem, LocalHistoryStore, LocalProjectionKind,
    LocalTimelineItem, MessageBody, MlsFacade, PublishKeyPackageMaterial, ServerApiClient,
    SyncCoordinator, TextMessageBody,
};
use trix_types::{ChatId, ContentType, DeviceId, InboxItem, WebSocketServerFrame};
use uuid::Uuid;

use crate::{
    identity::{BotIdentity, IdentityStoreConfig},
    state::{BotStateLayout, RuntimeState},
};

const INITIAL_KEY_PACKAGE_COUNT: usize = 128;
const HISTORY_SYNC_LIMIT: usize = 200;
const INBOX_LEASE_LIMIT: usize = 100;
const INBOX_LEASE_TTL_SECONDS: u64 = 30;
const POLL_INTERVAL: Duration = Duration::from_millis(750);
const WEBSOCKET_RETRY_DELAY: Duration = Duration::from_secs(3);

#[derive(Debug, Clone)]
pub struct BotInitConfig {
    pub server_url: String,
    pub state_dir: PathBuf,
    pub profile_name: String,
    pub handle: Option<String>,
    pub master_secret_env: Option<String>,
    pub plaintext_dev_store: bool,
}

#[derive(Debug, Clone)]
pub struct BotLoadConfig {
    pub state_dir: PathBuf,
    pub server_url_override: Option<String>,
    pub master_secret_env: Option<String>,
    pub plaintext_dev_store: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BotIdentitySnapshot {
    pub account_id: String,
    pub device_id: String,
    pub account_sync_chat_id: String,
    pub server_url: String,
    pub profile_name: String,
    pub handle: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SentTextMessage {
    pub chat_id: String,
    pub message_id: String,
    pub server_seq: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionMode {
    Websocket,
    Polling,
    Disconnected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BotEvent {
    Ready {
        account_id: String,
        device_id: String,
    },
    ConnectionChanged {
        connected: bool,
        mode: ConnectionMode,
    },
    TextMessage {
        chat_id: String,
        message_id: String,
        server_seq: u64,
        sender_account_id: String,
        sender_device_id: String,
        text: String,
        created_at_unix: u64,
    },
    UnsupportedMessage {
        chat_id: String,
        message_id: String,
        server_seq: u64,
        content_type: String,
        projection_kind: String,
        created_at_unix: u64,
    },
    Error {
        message: String,
    },
}

#[derive(Clone)]
pub struct Bot {
    inner: Arc<BotInner>,
}

struct BotInner {
    identity: BotIdentity,
    layout: BotStateLayout,
    client: Mutex<ServerApiClient>,
    store: Mutex<LocalHistoryStore>,
    sync: Mutex<SyncCoordinator>,
    facade: Mutex<MlsFacade>,
    runtime_state: Mutex<RuntimeState>,
    events: broadcast::Sender<BotEvent>,
    running: Mutex<Option<RunningLoop>>,
}

struct RunningLoop {
    stop_tx: watch::Sender<bool>,
    task: JoinHandle<()>,
}

impl Bot {
    pub async fn init(config: BotInitConfig) -> Result<Self> {
        let layout = BotStateLayout::new(&config.state_dir);
        layout.ensure_root()?;

        let identity_store = IdentityStoreConfig {
            plaintext_dev_store: config.plaintext_dev_store,
            master_secret_env: config.master_secret_env.clone(),
        };
        if identity_store.exists(&layout) {
            return Self::load(BotLoadConfig {
                state_dir: config.state_dir,
                server_url_override: Some(config.server_url),
                master_secret_env: config.master_secret_env,
                plaintext_dev_store: config.plaintext_dev_store,
            })
            .await;
        }

        let credential_identity = format!("bot-device:{}", Uuid::new_v4()).into_bytes();
        let account_root = trix_core::AccountRootMaterial::generate();
        let device_keys = trix_core::DeviceKeyMaterial::generate();
        let facade =
            MlsFacade::new_persistent(credential_identity.clone(), &layout.mls_storage_root)
                .with_context(|| {
                    format!(
                        "failed to initialize persistent MLS state at {}",
                        layout.mls_storage_root.display()
                    )
                })?;
        let mut client = ServerApiClient::new(&config.server_url)?;

        let created = client
            .create_account(CreateAccountParams {
                handle: config.handle.clone(),
                profile_name: config.profile_name.clone(),
                profile_bio: None,
                device_display_name: config
                    .handle
                    .clone()
                    .unwrap_or_else(|| "trix-bot".to_owned()),
                platform: "bot".to_owned(),
                credential_identity: credential_identity.clone(),
                account_root_pubkey: account_root.public_key_bytes(),
                account_root_signature: account_root.sign(&trix_core::account_bootstrap_message(
                    &device_keys.public_key_bytes(),
                    &credential_identity,
                )),
                transport_pubkey: device_keys.public_key_bytes(),
            })
            .await?;
        authenticate_client(&mut client, created.device_id, &device_keys).await?;
        publish_key_packages(&client, &facade, INITIAL_KEY_PACKAGE_COUNT).await?;

        let identity = BotIdentity {
            server_url: config.server_url,
            profile_name: config.profile_name,
            handle: config.handle,
            account_id: created.account_id,
            device_id: created.device_id,
            account_sync_chat_id: created.account_sync_chat_id,
            credential_identity,
            account_root,
            device_keys,
        };
        identity_store.save(&layout, &identity)?;

        Self::from_parts(layout, identity, client, facade)
    }

    pub async fn load(config: BotLoadConfig) -> Result<Self> {
        let layout = BotStateLayout::new(&config.state_dir);
        layout.ensure_root()?;

        let identity_store = IdentityStoreConfig {
            plaintext_dev_store: config.plaintext_dev_store,
            master_secret_env: config.master_secret_env,
        };
        let mut identity = identity_store.load(&layout)?;
        if let Some(server_url) = config.server_url_override {
            identity.server_url = server_url;
        }

        let client = ServerApiClient::new(&identity.server_url)?;
        let facade = MlsFacade::load_persistent(&layout.mls_storage_root).with_context(|| {
            format!(
                "failed to load persistent MLS state from {}",
                layout.mls_storage_root.display()
            )
        })?;

        Self::from_parts(layout, identity, client, facade)
    }

    fn from_parts(
        layout: BotStateLayout,
        identity: BotIdentity,
        client: ServerApiClient,
        facade: MlsFacade,
    ) -> Result<Self> {
        let store = LocalHistoryStore::new_persistent(&layout.history_store_path)?;
        let sync = SyncCoordinator::new_persistent(&layout.sync_state_path)?;
        let runtime_state = RuntimeState::load_or_create(&layout.runtime_state_path)?;
        let (events, _) = broadcast::channel(256);

        Ok(Self {
            inner: Arc::new(BotInner {
                identity,
                layout,
                client: Mutex::new(client),
                store: Mutex::new(store),
                sync: Mutex::new(sync),
                facade: Mutex::new(facade),
                runtime_state: Mutex::new(runtime_state),
                events,
                running: Mutex::new(None),
            }),
        })
    }

    pub fn identity(&self) -> BotIdentitySnapshot {
        self.inner.identity_snapshot()
    }

    pub fn state_dir(&self) -> &Path {
        &self.inner.layout.state_dir
    }

    pub fn subscribe(&self) -> broadcast::Receiver<BotEvent> {
        self.inner.events.subscribe()
    }

    pub async fn start(&self) -> Result<()> {
        let mut running = self.inner.running.lock().await;
        if running.is_some() {
            return Ok(());
        }

        let (stop_tx, stop_rx) = watch::channel(false);
        let inner = Arc::clone(&self.inner);
        let task = tokio::spawn(async move {
            run_loop(inner, stop_rx).await;
        });
        *running = Some(RunningLoop { stop_tx, task });
        Ok(())
    }

    pub async fn stop(&self) -> Result<()> {
        let running = self.inner.running.lock().await.take();
        if let Some(running) = running {
            let _ = running.stop_tx.send(true);
            let _ = running.task.await;
        }
        Ok(())
    }

    pub async fn list_chats(&self) -> Result<Vec<LocalChatListItem>> {
        let store = self.inner.store.lock().await;
        Ok(store.list_local_chat_list_items(Some(self.inner.identity.account_id)))
    }

    pub async fn get_timeline(
        &self,
        chat_id: ChatId,
        limit: Option<usize>,
    ) -> Result<Vec<LocalTimelineItem>> {
        let store = self.inner.store.lock().await;
        Ok(store.get_local_timeline_items(
            chat_id,
            Some(self.inner.identity.account_id),
            None,
            limit,
        ))
    }

    pub async fn send_text(
        &self,
        chat_id: ChatId,
        text: impl Into<String>,
    ) -> Result<SentTextMessage> {
        let client = self.inner.reauthenticate().await?;
        let mut sync = self.inner.sync.lock().await;
        let mut store = self.inner.store.lock().await;
        let facade = self.inner.facade.lock().await;
        let mut conversation = store
            .load_or_bootstrap_chat_mls_conversation(chat_id, &facade)?
            .ok_or_else(|| {
                anyhow!(
                    "chat {} has no local MLS state; start the bot first",
                    chat_id.0
                )
            })?;
        let outcome = sync
            .send_message_body(
                &client,
                &mut store,
                &facade,
                &mut conversation,
                self.inner.identity.account_id,
                self.inner.identity.device_id,
                chat_id,
                None,
                &MessageBody::Text(TextMessageBody { text: text.into() }),
                None,
            )
            .await?;
        drop(facade);
        drop(store);
        drop(sync);
        self.inner.emit_chat_events(chat_id).await?;

        Ok(SentTextMessage {
            chat_id: outcome.chat_id.0.to_string(),
            message_id: outcome.message_id.0.to_string(),
            server_seq: outcome.server_seq,
        })
    }

    pub async fn publish_key_packages(&self, count: usize) -> Result<usize> {
        let client = self.inner.reauthenticate().await?;
        let facade = self.inner.facade.lock().await;
        publish_key_packages(&client, &facade, count).await?;
        Ok(count)
    }
}

impl BotInner {
    fn identity_snapshot(&self) -> BotIdentitySnapshot {
        BotIdentitySnapshot {
            account_id: self.identity.account_id.0.to_string(),
            device_id: self.identity.device_id.0.to_string(),
            account_sync_chat_id: self.identity.account_sync_chat_id.0.to_string(),
            server_url: self.identity.server_url.clone(),
            profile_name: self.identity.profile_name.clone(),
            handle: self.identity.handle.clone(),
        }
    }

    fn publish_event(&self, event: BotEvent) {
        let _ = self.events.send(event);
    }

    fn publish_error(&self, message: impl Into<String>) {
        self.publish_event(BotEvent::Error {
            message: message.into(),
        });
    }

    async fn current_client(&self) -> ServerApiClient {
        self.client.lock().await.clone()
    }

    async fn reauthenticate(&self) -> Result<ServerApiClient> {
        let mut client = self.client.lock().await;
        authenticate_client(
            &mut client,
            self.identity.device_id,
            &self.identity.device_keys,
        )
        .await?;
        Ok(client.clone())
    }

    async fn sync_histories(&self, client: &ServerApiClient) -> Result<()> {
        let changed_chat_ids = {
            let mut sync = self.sync.lock().await;
            let mut store = self.store.lock().await;
            sync.sync_chat_histories_into_store(client, &mut store, HISTORY_SYNC_LIMIT)
                .await?
                .changed_chat_ids
        };
        self.apply_changed_chat_updates(client, changed_chat_ids)
            .await
    }

    async fn poll_once(&self, client: &ServerApiClient) -> Result<()> {
        let lease = {
            let sync = self.sync.lock().await;
            sync.lease_inbox(
                client,
                Some(INBOX_LEASE_LIMIT),
                Some(INBOX_LEASE_TTL_SECONDS),
            )
            .await?
        };

        if lease.items.is_empty() {
            return Ok(());
        }

        let inbox_ids = lease
            .items
            .iter()
            .map(|item| item.inbox_id)
            .collect::<Vec<_>>();
        self.process_incoming_items(client, &lease.items).await?;
        let mut sync = self.sync.lock().await;
        sync.ack_inbox(client, inbox_ids).await?;
        Ok(())
    }

    async fn process_incoming_items(
        &self,
        client: &ServerApiClient,
        items: &[InboxItem],
    ) -> Result<()> {
        let changed_chat_ids = {
            let mut sync = self.sync.lock().await;
            let mut store = self.store.lock().await;
            let report = store.apply_inbox_items(items)?;
            for item in items {
                sync.record_chat_server_seq(item.message.chat_id, item.message.server_seq)?;
            }
            report.changed_chat_ids
        };
        self.apply_changed_chat_updates(client, changed_chat_ids)
            .await
    }

    async fn apply_changed_chat_updates(
        &self,
        client: &ServerApiClient,
        changed_chat_ids: Vec<ChatId>,
    ) -> Result<()> {
        for chat_id in changed_chat_ids {
            let detail = client.get_chat(chat_id).await?;
            {
                let mut store = self.store.lock().await;
                store.apply_chat_detail(&detail)?;
            }
            {
                let mut store = self.store.lock().await;
                let facade = self.facade.lock().await;
                store.project_chat_with_facade(chat_id, &facade, None)?;
            }
            self.emit_chat_events(chat_id).await?;
        }
        Ok(())
    }

    async fn emit_chat_events(&self, chat_id: ChatId) -> Result<()> {
        let after_server_seq = {
            let state = self.runtime_state.lock().await;
            state.emitted_cursor(chat_id)
        };
        let items = {
            let store = self.store.lock().await;
            store.get_local_timeline_items(
                chat_id,
                Some(self.identity.account_id),
                after_server_seq,
                None,
            )
        };

        if items.is_empty() {
            return Ok(());
        }

        for item in &items {
            if item.is_outgoing {
                continue;
            }

            if item.projection_kind == LocalProjectionKind::ApplicationMessage
                && item.content_type == ContentType::Text
            {
                if let Some(MessageBody::Text(body)) = &item.body {
                    self.publish_event(BotEvent::TextMessage {
                        chat_id: chat_id.0.to_string(),
                        message_id: item.message_id.0.to_string(),
                        server_seq: item.server_seq,
                        sender_account_id: item.sender_account_id.0.to_string(),
                        sender_device_id: item.sender_device_id.0.to_string(),
                        text: body.text.clone(),
                        created_at_unix: item.created_at_unix,
                    });
                    continue;
                }
            }

            if item.projection_kind == LocalProjectionKind::ApplicationMessage {
                self.publish_event(BotEvent::UnsupportedMessage {
                    chat_id: chat_id.0.to_string(),
                    message_id: item.message_id.0.to_string(),
                    server_seq: item.server_seq,
                    content_type: content_type_label(item.content_type).to_owned(),
                    projection_kind: projection_kind_label(item.projection_kind).to_owned(),
                    created_at_unix: item.created_at_unix,
                });
            }
        }

        if let Some(max_server_seq) = items.iter().map(|item| item.server_seq).max() {
            let mut state = self.runtime_state.lock().await;
            state.record_emitted_cursor(chat_id, max_server_seq)?;
        }
        Ok(())
    }
}

async fn run_loop(inner: Arc<BotInner>, mut stop_rx: watch::Receiver<bool>) {
    if let Err(err) = inner.run_loop_inner(&mut stop_rx).await {
        inner.publish_error(err.to_string());
    }
    inner.publish_event(BotEvent::ConnectionChanged {
        connected: false,
        mode: ConnectionMode::Disconnected,
    });
}

impl BotInner {
    async fn run_loop_inner(&self, stop_rx: &mut watch::Receiver<bool>) -> Result<()> {
        let client = self.reauthenticate().await?;
        self.sync_histories(&client).await?;
        self.publish_event(BotEvent::Ready {
            account_id: self.identity.account_id.0.to_string(),
            device_id: self.identity.device_id.0.to_string(),
        });

        loop {
            if *stop_rx.borrow() {
                return Ok(());
            }

            let client = self.reauthenticate().await?;
            match client.connect_websocket().await {
                Ok(mut websocket) => {
                    self.publish_event(BotEvent::ConnectionChanged {
                        connected: true,
                        mode: ConnectionMode::Websocket,
                    });
                    if let Err(err) = self.run_websocket(&mut websocket, stop_rx).await {
                        self.publish_error(format!("websocket loop failed: {err}"));
                    }
                }
                Err(err) => {
                    self.publish_error(format!("websocket connect failed: {err}"));
                }
            }

            if *stop_rx.borrow() {
                return Ok(());
            }

            self.publish_event(BotEvent::ConnectionChanged {
                connected: true,
                mode: ConnectionMode::Polling,
            });
            let retry_deadline = Instant::now() + WEBSOCKET_RETRY_DELAY;
            while Instant::now() < retry_deadline {
                tokio::select! {
                    changed = stop_rx.changed() => {
                        if changed.is_ok() && *stop_rx.borrow() {
                            return Ok(());
                        }
                    }
                    _ = sleep(POLL_INTERVAL) => {}
                }

                let client = self.current_client().await;
                if let Err(err) = self.poll_once(&client).await {
                    self.publish_error(format!("polling failed: {err}"));
                    let _ = self.reauthenticate().await;
                }
            }
        }
    }

    async fn run_websocket(
        &self,
        websocket: &mut trix_core::ServerWebSocketClient,
        stop_rx: &mut watch::Receiver<bool>,
    ) -> Result<()> {
        loop {
            tokio::select! {
                changed = stop_rx.changed() => {
                    if changed.is_ok() && *stop_rx.borrow() {
                        websocket.close().await.ok();
                        return Ok(());
                    }
                }
                frame = websocket.next_frame() => {
                    match frame? {
                        Some(WebSocketServerFrame::Hello { .. }) => {}
                        Some(WebSocketServerFrame::InboxItems { items, .. }) => {
                            if items.is_empty() {
                                continue;
                            }
                            let inbox_ids = items.iter().map(|item| item.inbox_id).collect::<Vec<_>>();
                            let client = self.current_client().await;
                            self.process_incoming_items(&client, &items).await?;
                            websocket.send_ack(inbox_ids).await?;
                        }
                        Some(WebSocketServerFrame::Acked { .. }) | Some(WebSocketServerFrame::Pong { .. }) => {}
                        Some(WebSocketServerFrame::SessionReplaced { reason }) => {
                            self.publish_error(format!("websocket session replaced: {reason}"));
                            return Ok(());
                        }
                        Some(WebSocketServerFrame::Error { code, message }) => {
                            return Err(anyhow!("websocket error {code}: {message}"));
                        }
                        None => return Ok(()),
                    }
                }
            }
        }
    }
}

async fn authenticate_client(
    client: &mut ServerApiClient,
    device_id: DeviceId,
    device_keys: &trix_core::DeviceKeyMaterial,
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

async fn publish_key_packages(
    client: &ServerApiClient,
    facade: &MlsFacade,
    count: usize,
) -> Result<()> {
    let packages = facade
        .generate_key_packages(count)?
        .into_iter()
        .map(|key_package| PublishKeyPackageMaterial {
            cipher_suite: facade.ciphersuite_label(),
            key_package,
        })
        .collect::<Vec<_>>();
    client.publish_key_packages(packages).await?;
    Ok(())
}

fn content_type_label(value: ContentType) -> &'static str {
    match value {
        ContentType::Text => "text",
        ContentType::Reaction => "reaction",
        ContentType::Receipt => "receipt",
        ContentType::Attachment => "attachment",
        ContentType::ChatEvent => "chat_event",
    }
}

fn projection_kind_label(value: LocalProjectionKind) -> &'static str {
    match value {
        LocalProjectionKind::ApplicationMessage => "application_message",
        LocalProjectionKind::ProposalQueued => "proposal_queued",
        LocalProjectionKind::CommitMerged => "commit_merged",
        LocalProjectionKind::WelcomeRef => "welcome_ref",
        LocalProjectionKind::System => "system",
    }
}
