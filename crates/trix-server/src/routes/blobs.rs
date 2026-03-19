use axum::{
    Json, Router,
    routing::{post, put},
};

use crate::error::AppError;

pub fn router() -> Router<crate::state::AppState> {
    Router::new()
        .route("/uploads", post(create_upload))
        .route("/{blob_id}", put(put_blob).get(get_blob).head(head_blob))
}

async fn create_upload() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "blob upload slot creation is not implemented yet",
    ))
}

async fn put_blob() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "blob upload is not implemented yet",
    ))
}

async fn get_blob() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "blob download is not implemented yet",
    ))
}

async fn head_blob() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "blob metadata is not implemented yet",
    ))
}
