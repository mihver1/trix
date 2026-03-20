use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::http::HeaderMap;
use tokio::sync::{Mutex, mpsc};
use trix_types::WebSocketServerFrame;
use uuid::Uuid;

use crate::{
    auth::{AuthManager, SessionPrincipal},
    blobs::LocalBlobStore,
    build::BuildInfo,
    config::AppConfig,
    db::Database,
    error::AppError,
    rate_limit::{RateLimitRule, RateLimiter},
};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub build: BuildInfo,
    pub started_at: Instant,
    pub db: Arc<Database>,
    pub auth: Arc<AuthManager>,
    pub blob_store: Arc<LocalBlobStore>,
    pub ws_registry: Arc<WebSocketSessionRegistry>,
    pub rate_limiter: Arc<RateLimiter>,
}

impl AppState {
    pub fn new(
        config: AppConfig,
        build: BuildInfo,
        db: Database,
        auth: AuthManager,
        blob_store: LocalBlobStore,
    ) -> Self {
        Self {
            config,
            build,
            started_at: Instant::now(),
            db: Arc::new(db),
            auth: Arc::new(auth),
            blob_store: Arc::new(blob_store),
            ws_registry: Arc::new(WebSocketSessionRegistry::default()),
            rate_limiter: Arc::new(RateLimiter::new()),
        }
    }

    pub async fn authenticate_active_headers(
        &self,
        headers: &HeaderMap,
    ) -> Result<SessionPrincipal, AppError> {
        let principal = self.auth.authenticate_headers(headers)?;
        self.db
            .ensure_active_device_session(principal.account_id, principal.device_id)
            .await?;
        Ok(principal)
    }

    pub async fn enforce_rate_limit(
        &self,
        scope: &str,
        key: impl AsRef<str>,
        limit: usize,
    ) -> Result<(), AppError> {
        let window = Duration::from_secs(self.config.rate_limit_window_seconds);
        let rule = RateLimitRule { window, limit };
        if let Some(decision) = self.rate_limiter.check(scope, key, &rule).await {
            return Err(AppError::too_many_requests(
                format!("rate limit exceeded for {scope}"),
                decision.retry_after_seconds,
            ));
        }
        Ok(())
    }

    pub async fn notify_pending_inbox_for_chat(&self, chat_id: Uuid) {
        if let Ok(device_ids) = self
            .db
            .list_pending_inbox_device_ids_for_chat(chat_id)
            .await
        {
            self.ws_registry.notify_inbox_many(&device_ids).await;
        }
    }
}

#[derive(Debug, Clone)]
pub enum WebSocketSessionCommand {
    Frame(WebSocketServerFrame),
    DeliverInbox,
}

#[derive(Default)]
pub struct WebSocketSessionRegistry {
    sessions: Mutex<HashMap<Uuid, WebSocketSessionEntry>>,
}

#[derive(Clone)]
struct WebSocketSessionEntry {
    session_id: Uuid,
    sender: mpsc::UnboundedSender<WebSocketSessionCommand>,
}

impl WebSocketSessionRegistry {
    pub async fn register(
        &self,
        device_id: Uuid,
        sender: mpsc::UnboundedSender<WebSocketSessionCommand>,
    ) -> Uuid {
        let session_id = Uuid::new_v4();
        let replaced = {
            let mut sessions = self.sessions.lock().await;
            sessions.insert(device_id, WebSocketSessionEntry { session_id, sender })
        };

        if let Some(previous) = replaced {
            let _ = previous.sender.send(WebSocketSessionCommand::Frame(
                WebSocketServerFrame::SessionReplaced {
                    reason: "replaced by a newer websocket session".to_owned(),
                },
            ));
        }

        session_id
    }

    pub async fn unregister(&self, device_id: Uuid, session_id: Uuid) {
        let mut sessions = self.sessions.lock().await;
        let should_remove = sessions
            .get(&device_id)
            .map(|entry| entry.session_id == session_id)
            .unwrap_or(false);
        if should_remove {
            sessions.remove(&device_id);
        }
    }

    pub async fn notify_inbox(&self, device_id: Uuid) -> bool {
        let sessions = self.sessions.lock().await;
        sessions
            .get(&device_id)
            .map(|entry| {
                entry
                    .sender
                    .send(WebSocketSessionCommand::DeliverInbox)
                    .is_ok()
            })
            .unwrap_or(false)
    }

    pub async fn notify_inbox_many(&self, device_ids: &[Uuid]) {
        for device_id in device_ids {
            let _ = self.notify_inbox(*device_id).await;
        }
    }

    pub async fn close_all(&self, reason: &str) {
        let sessions = self.sessions.lock().await;
        for entry in sessions.values() {
            let _ = entry.sender.send(WebSocketSessionCommand::Frame(
                WebSocketServerFrame::SessionReplaced {
                    reason: reason.to_owned(),
                },
            ));
        }
    }
}
