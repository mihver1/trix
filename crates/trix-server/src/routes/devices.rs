use axum::{
    Json, Router,
    routing::{get, post},
};

use crate::error::AppError;

pub fn router() -> Router<crate::state::AppState> {
    Router::new()
        .route("/", get(list_devices))
        .route("/link-intents", post(create_link_intent))
        .route(
            "/link-intents/{link_intent_id}/complete",
            post(complete_link_intent),
        )
        .route("/{device_id}/approve", post(approve_device))
        .route("/{device_id}/revoke", post(revoke_device))
}

async fn list_devices() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device listing is not implemented yet",
    ))
}

async fn create_link_intent() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device link intent flow is not implemented yet",
    ))
}

async fn complete_link_intent() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device link completion flow is not implemented yet",
    ))
}

async fn approve_device() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device approval flow is not implemented yet",
    ))
}

async fn revoke_device() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device revocation flow is not implemented yet",
    ))
}
