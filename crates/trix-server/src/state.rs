use std::{collections::HashMap, sync::Arc, time::Instant};

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
}

#[derive(Default)]
pub struct WebSocketSessionRegistry {
    sessions: Mutex<HashMap<Uuid, WebSocketSessionEntry>>,
}

#[derive(Clone)]
struct WebSocketSessionEntry {
    session_id: Uuid,
    sender: mpsc::UnboundedSender<WebSocketServerFrame>,
}

impl WebSocketSessionRegistry {
    pub async fn register(
        &self,
        device_id: Uuid,
        sender: mpsc::UnboundedSender<WebSocketServerFrame>,
    ) -> Uuid {
        let session_id = Uuid::new_v4();
        let replaced = {
            let mut sessions = self.sessions.lock().await;
            sessions.insert(device_id, WebSocketSessionEntry { session_id, sender })
        };

        if let Some(previous) = replaced {
            let _ = previous.sender.send(WebSocketServerFrame::SessionReplaced {
                reason: "replaced by a newer websocket session".to_owned(),
            });
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
}
