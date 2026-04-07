use axum::{Json, Router, routing::get};
use serde_json::{Value, json};
use trix_types::contract::{self, ApiEndpoint};

pub mod accounts;
pub mod admin;
pub mod admin_debug_metrics;
pub mod admin_feature_flags;
pub mod admin_logs;
pub mod auth;
pub mod blobs;
pub mod chats;
pub mod devices;
pub mod history_sync;
pub mod inbox;
pub mod key_packages;
pub mod message_repairs;
pub mod system;
pub mod ws;

/// Strip a nesting prefix from an absolute contract path to get the relative
/// path expected by axum's `.nest()`.
///
/// When the path exactly equals the prefix (root route), returns `"/"`.
pub(crate) fn rel(prefix: &str, path: &'static str) -> &'static str {
    match path.strip_prefix(prefix) {
        Some("") => "/",
        Some(rest) => rest,
        None => panic!("contract path `{path}` doesn't start with `{prefix}`"),
    }
}

pub async fn root() -> Json<Value> {
    Json(json!({
        "service": "trixd",
        "status": "ok",
        "api_base": "/v0"
    }))
}

pub fn v0_router() -> Router<crate::state::AppState> {
    Router::new()
        .route(rel("/v0", contract::Health::PATH), get(system::health))
        .route(rel("/v0", contract::Version::PATH), get(system::version))
        .nest("/auth", auth::router())
        .nest("/admin", admin::router())
        .nest("/accounts", accounts::router())
        .nest("/devices", devices::router())
        .nest("/chats", chats::router())
        .nest("/history-sync", history_sync::router())
        .merge(message_repairs::router())
        .merge(inbox::router())
        .merge(key_packages::router())
        .nest("/blobs", blobs::router())
        .merge(ws::router())
}
