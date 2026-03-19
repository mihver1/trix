use std::{sync::Arc, time::Instant};

use axum::http::HeaderMap;

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
