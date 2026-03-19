use std::{sync::Arc, time::Instant};

use crate::{
    auth::AuthManager, blobs::LocalBlobStore, build::BuildInfo, config::AppConfig, db::Database,
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
}
