use axum::{
    Json, Router,
    routing::{get, post},
};

use crate::error::AppError;

pub fn router() -> Router<crate::state::AppState> {
    Router::new()
        .route("/", get(list_chats).post(create_chat))
        .route("/{chat_id}", get(get_chat))
        .route("/{chat_id}/messages", post(create_message))
        .route("/{chat_id}/history", get(get_history))
        .route("/{chat_id}/members:add", post(add_members))
        .route("/{chat_id}/members:remove", post(remove_members))
        .route("/inbox", get(get_inbox))
        .route("/inbox/lease", post(lease_inbox))
        .route("/inbox/ack", post(ack_inbox))
        .route("/key-packages:publish", post(publish_key_packages))
}

async fn list_chats() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "chat listing is not implemented yet",
    ))
}

async fn create_chat() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "chat creation is not implemented yet",
    ))
}

async fn get_chat() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "chat fetch is not implemented yet",
    ))
}

async fn create_message() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "message append is not implemented yet",
    ))
}

async fn get_history() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "history fetch is not implemented yet",
    ))
}

async fn add_members() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "member add flow is not implemented yet",
    ))
}

async fn remove_members() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "member remove flow is not implemented yet",
    ))
}

async fn get_inbox() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "inbox fetch is not implemented yet",
    ))
}

async fn lease_inbox() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "inbox lease is not implemented yet",
    ))
}

async fn ack_inbox() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "inbox ack is not implemented yet",
    ))
}

async fn publish_key_packages() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "key package publish is not implemented yet",
    ))
}
