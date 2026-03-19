use axum::{Json, Router, routing::get};
use serde_json::{Value, json};

pub mod accounts;
pub mod auth;
pub mod blobs;
pub mod chats;
pub mod devices;
pub mod inbox;
pub mod key_packages;
pub mod system;

pub async fn root() -> Json<Value> {
    Json(json!({
        "service": "trixd",
        "status": "ok",
        "api_base": "/v0"
    }))
}

pub fn v0_router() -> Router<crate::state::AppState> {
    Router::new()
        .route("/system/health", get(system::health))
        .route("/system/version", get(system::version))
        .nest("/auth", auth::router())
        .nest("/accounts", accounts::router())
        .nest("/devices", devices::router())
        .nest("/chats", chats::router())
        .merge(inbox::router())
        .merge(key_packages::router())
        .nest("/blobs", blobs::router())
}
