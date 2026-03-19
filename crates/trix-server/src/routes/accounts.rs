use axum::{
    Json, Router,
    routing::{get, post},
};

use crate::error::AppError;

pub fn router() -> Router<crate::state::AppState> {
    Router::new()
        .route("/", post(create_account))
        .route("/me", get(get_me))
        .route("/{account_id}/key-packages", get(get_account_key_packages))
}

async fn create_account() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "account creation flow is not implemented yet",
    ))
}

async fn get_me() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "account profile lookup is not implemented yet",
    ))
}

async fn get_account_key_packages() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "key package lookup is not implemented yet",
    ))
}
