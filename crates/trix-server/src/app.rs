use std::time::Duration;

use anyhow::{Context, Result};
use axum::{
    Router,
    http::{
        HeaderValue, Method,
        header::{AUTHORIZATION, CONTENT_TYPE},
    },
    routing::get,
};
use tokio::{net::TcpListener, sync::watch, time::interval};
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info, warn};

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
    let app = build_router(state.clone())?;

    let (cleanup_shutdown_tx, cleanup_shutdown_rx) = watch::channel(false);
    let cleanup_handle = tokio::spawn(run_cleanup_loop(state.clone(), cleanup_shutdown_rx));

    let listener = TcpListener::bind(config.bind_addr).await?;
    info!(addr = %config.bind_addr, "trix server listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            wait_for_shutdown_signal().await;
            info!("shutdown signal received");
            let _ = cleanup_shutdown_tx.send(true);
            state.ws_registry.close_all("server shutting down").await;
            tokio::time::sleep(Duration::from_secs(config.shutdown_grace_period_seconds)).await;
        })
        .await?;

    if let Err(err) = cleanup_handle.await {
        warn!("cleanup loop join error: {err}");
    }

    Ok(())
}

pub fn build_router(state: AppState) -> Result<Router> {
    let router = Router::new()
        .route("/", get(routes::root))
        .nest("/v0", routes::v0_router())
        .layer(TraceLayer::new_for_http())
        .with_state(state.clone());

    if state.config.cors_allowed_origins.is_empty() {
        return Ok(router);
    }

    let origins = state
        .config
        .cors_allowed_origins
        .iter()
        .map(|origin| {
            HeaderValue::from_str(origin)
                .with_context(|| format!("invalid CORS origin configured: {origin}"))
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(router.layer(
        CorsLayer::new()
            .allow_origin(origins)
            .allow_methods([
                Method::GET,
                Method::POST,
                Method::PUT,
                Method::PATCH,
                Method::DELETE,
                Method::HEAD,
                Method::OPTIONS,
            ])
            .allow_headers([AUTHORIZATION, CONTENT_TYPE]),
    ))
}

async fn run_cleanup_loop(state: AppState, mut shutdown_rx: watch::Receiver<bool>) {
    let mut tick = interval(Duration::from_secs(state.config.cleanup_interval_seconds));
    loop {
        tokio::select! {
            _ = tick.tick() => {
                if let Err(err) = run_cleanup_pass(&state).await {
                    error!("cleanup pass failed: {err}");
                }
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

async fn run_cleanup_pass(state: &AppState) -> Result<()> {
    let deleted_auth_challenges = state
        .db
        .cleanup_expired_auth_challenges(state.config.auth_challenge_retention_seconds)
        .await?;
    let expired_key_packages = state.db.expire_stale_reserved_key_packages().await?;
    let cleaned_link_intents = state
        .db
        .cleanup_device_link_intents(
            state.config.link_intent_retention_seconds,
            state.config.transfer_bundle_retention_seconds,
        )
        .await?;
    let cleaned_history_sync = state
        .db
        .cleanup_history_sync_data(state.config.history_sync_retention_seconds)
        .await?;
    let cleaned_blobs = state
        .db
        .cleanup_orphaned_blobs(state.config.pending_blob_retention_seconds)
        .await?;

    for blob in &cleaned_blobs {
        if let Err(err) = state.blob_store.delete_if_exists(&blob.blob_id).await {
            warn!(blob_id = %blob.blob_id, "failed to delete orphaned blob data: {err}");
        }
    }

    if deleted_auth_challenges > 0
        || expired_key_packages > 0
        || cleaned_link_intents > 0
        || cleaned_history_sync > 0
        || !cleaned_blobs.is_empty()
    {
        info!(
            deleted_auth_challenges,
            expired_key_packages,
            cleaned_link_intents,
            cleaned_history_sync,
            cleaned_blobs = cleaned_blobs.len(),
            "cleanup pass completed"
        );
    }

    Ok(())
}

async fn wait_for_shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};

        let mut terminate =
            signal(SignalKind::terminate()).expect("failed to install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
