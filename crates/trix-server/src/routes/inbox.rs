use axum::{
    Json, Router,
    extract::{Query, State},
    http::HeaderMap,
    routing::{get, post},
};
use serde::Deserialize;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

use crate::{db::InboxItemRow, error::AppError, state::AppState};
use trix_types::{
    AckInboxRequest, AckInboxResponse, InboxItem, InboxResponse, LeaseInboxRequest,
    LeaseInboxResponse,
};

use super::chats::message_to_api;

const DEFAULT_INBOX_LEASE_TTL_SECONDS: u64 = 30;
const MAX_INBOX_LEASE_TTL_SECONDS: u64 = 5 * 60;

#[derive(Debug, Deserialize)]
struct InboxQuery {
    after_inbox_id: Option<u64>,
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
        .get_inbox_for_device(principal.device_id, query.after_inbox_id, query.limit)
        .await?;

    Ok(Json(InboxResponse {
        items: items.into_iter().map(inbox_item_to_api).collect(),
    }))
}

async fn lease_inbox(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Option<Json<LeaseInboxRequest>>,
) -> Result<Json<LeaseInboxResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let request = request
        .map(|Json(request)| request)
        .unwrap_or(LeaseInboxRequest {
            lease_owner: None,
            limit: None,
            after_inbox_id: None,
            lease_ttl_seconds: None,
        });
    let lease_owner = request
        .lease_owner
        .unwrap_or_else(|| format!("device:{}:{}", principal.device_id, Uuid::new_v4().simple()));
    let lease_ttl_seconds = request
        .lease_ttl_seconds
        .unwrap_or(DEFAULT_INBOX_LEASE_TTL_SECONDS)
        .clamp(1, MAX_INBOX_LEASE_TTL_SECONDS);

    let items = state
        .db
        .lease_inbox_for_device(
            principal.device_id,
            &lease_owner,
            request.after_inbox_id,
            request.limit,
            Some(lease_ttl_seconds),
        )
        .await?;

    Ok(Json(LeaseInboxResponse {
        lease_owner,
        lease_expires_at_unix: unix_now().saturating_add(lease_ttl_seconds),
        items: items.into_iter().map(inbox_item_to_api).collect(),
    }))
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

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
