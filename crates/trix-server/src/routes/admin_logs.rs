use axum::{
    Json, Router,
    extract::{Query, State},
    http::HeaderMap,
    routing::get,
};
use serde::Deserialize;

use crate::{error::AppError, state::AppState};
use trix_types::AdminServerLogListResponse;

const DEFAULT_LIMIT: usize = 200;
const MAX_LIMIT: usize = 1_000;

pub fn router() -> Router<AppState> {
    Router::new().route("/server/logs", get(list_server_logs))
}

#[derive(Debug, Default, Deserialize)]
struct ListServerLogsQuery {
    limit: Option<usize>,
}

async fn list_server_logs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListServerLogsQuery>,
) -> Result<Json<AdminServerLogListResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let limit = match query.limit.unwrap_or(DEFAULT_LIMIT) {
        1..=MAX_LIMIT => query.limit.unwrap_or(DEFAULT_LIMIT),
        _ => return Err(AppError::bad_request("limit must be between 1 and 1000")),
    };
    Ok(Json(state.admin_log_buffer.snapshot(limit)))
}
