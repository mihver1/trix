use std::{sync::Arc, time::Instant};

use crate::{blobs::LocalBlobStore, build::BuildInfo, config::AppConfig};

#[derive(Debug, Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub build: BuildInfo,
    pub started_at: Instant,
    pub blob_store: Arc<LocalBlobStore>,
}

impl AppState {
    pub fn new(config: AppConfig, build: BuildInfo, blob_store: LocalBlobStore) -> Self {
        Self {
            config,
            build,
            started_at: Instant::now(),
            blob_store: Arc::new(blob_store),
        }
    }
}
