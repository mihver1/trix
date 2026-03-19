use axum::{Json, Router, routing::post};

use crate::error::AppError;

pub fn router() -> Router<crate::state::AppState> {
    Router::new()
        .route("/challenge", post(challenge))
        .route("/session", post(session))
}

async fn challenge() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "auth challenge flow is not implemented yet",
    ))
}

async fn session() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "auth session flow is not implemented yet",
    ))
}
