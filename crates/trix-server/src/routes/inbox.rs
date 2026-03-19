use axum::{
    Json, Router,
    extract::{Query, State},
    http::HeaderMap,
    routing::{get, post},
};
use serde::Deserialize;

use crate::{db::InboxItemRow, error::AppError, state::AppState};
use trix_types::{AckInboxRequest, AckInboxResponse, InboxItem, InboxResponse};

use super::chats::message_to_api;

#[derive(Debug, Deserialize)]
struct InboxQuery {
    limit: Option<usize>,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/inbox", get(get_inbox))
        .route("/inbox/lease", post(lease_inbox))
        .route("/inbox/ack", post(ack_inbox))
}

async fn get_inbox(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<InboxQuery>,
) -> Result<Json<InboxResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let items = state
        .db
        .get_inbox_for_device(principal.device_id, query.limit)
        .await?;

    Ok(Json(InboxResponse {
        items: items.into_iter().map(inbox_item_to_api).collect(),
    }))
}

async fn lease_inbox() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "inbox lease is not implemented yet",
    ))
}

async fn ack_inbox(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<AckInboxRequest>,
) -> Result<Json<AckInboxResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let inbox_ids = request
        .inbox_ids
        .into_iter()
        .map(|inbox_id| {
            i64::try_from(inbox_id)
                .map_err(|_| AppError::bad_request("inbox id exceeds supported range"))
        })
        .collect::<Result<Vec<_>, _>>()?;

    let acked_inbox_ids = state
        .db
        .ack_inbox_items(principal.device_id, inbox_ids)
        .await?;

    Ok(Json(AckInboxResponse { acked_inbox_ids }))
}

fn inbox_item_to_api(item: InboxItemRow) -> InboxItem {
    InboxItem {
        inbox_id: item.inbox_id,
        message: message_to_api(item.message),
    }
}
