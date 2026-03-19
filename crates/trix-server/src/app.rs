use anyhow::Result;
use axum::{Router, routing::get};
use tokio::net::TcpListener;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::info;

use crate::{
    auth::AuthManager, blobs::LocalBlobStore, build::BuildInfo, config::AppConfig, db::Database,
    routes, state::AppState,
};

pub async fn run(config: AppConfig) -> Result<()> {
    let db = Database::connect(&config.database_url).await?;
    let blob_store = LocalBlobStore::new(&config.blob_root)?;
    let auth = AuthManager::new(&config.jwt_signing_key);
    let build = BuildInfo::current();
    let state = AppState::new(config.clone(), build, db, auth, blob_store);
    let app = build_router(state);

    let listener = TcpListener::bind(config.bind_addr).await?;
    info!(addr = %config.bind_addr, "trix server listening");
    axum::serve(listener, app).await?;

    Ok(())
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/", get(routes::root))
        .nest("/v0", routes::v0_router())
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
