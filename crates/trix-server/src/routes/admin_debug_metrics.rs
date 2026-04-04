use axum::{
    Json, Router,
    extract::{Json as ExtractJson, Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{delete, get},
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{error::AppError, state::AppState};
use trix_types::{
    AdminDebugMetricBatch, AdminDebugMetricBatchListResponse, AdminDebugMetricSession,
    AdminDebugMetricSessionListResponse, AdminDebugMetricSessionResponse,
    CreateAdminDebugMetricSessionRequest, DeviceId,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/debug/metric-sessions",
            get(list_sessions).post(create_session),
        )
        .route(
            "/debug/metric-sessions/{session_id}",
            delete(revoke_session),
        )
        .route(
            "/debug/metric-sessions/{session_id}/batches",
            get(list_batches),
        )
}

fn ensure_debug_enabled(state: &AppState) -> Result<(), AppError> {
    if !state.config.debug_metrics_enabled {
        return Err(AppError::not_found(
            "debug metrics are not enabled on this server",
        ));
    }
    Ok(())
}

fn row_to_session(row: crate::db::DebugMetricSessionRow) -> AdminDebugMetricSession {
    AdminDebugMetricSession {
        session_id: row.session_id.to_string(),
        account_id: trix_types::AccountId(row.account_id),
        device_id: row.device_id.map(DeviceId),
        user_visible_message: row.user_visible_message,
        created_at_unix: row.created_at_unix,
        expires_at_unix: row.expires_at_unix,
        revoked_at_unix: row.revoked_at_unix,
        created_by_admin: row.created_by_admin,
    }
}

#[derive(Debug, Default, Deserialize)]
struct ListSessionsQuery {
    account_id: Option<Uuid>,
    limit: Option<i64>,
}

async fn create_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<CreateAdminDebugMetricSessionRequest>,
) -> Result<Json<AdminDebugMetricSessionResponse>, AppError> {
    let principal = state.authenticate_admin_headers(&headers)?;
    ensure_debug_enabled(&state)?;
    let msg = body.user_visible_message.trim();
    if msg.is_empty() {
        return Err(AppError::bad_request(
            "user_visible_message must not be empty",
        ));
    }
    if msg.len() > 2000 {
        return Err(AppError::bad_request(
            "user_visible_message must be at most 2000 characters",
        ));
    }

    let row = state
        .db
        .create_debug_metric_session(&crate::db::CreateDebugMetricSessionInput {
            account_id: body.account_id.0,
            device_id: body.device_id.map(|d| d.0),
            user_visible_message: msg.to_owned(),
            ttl_seconds: body.ttl_seconds,
            created_by_admin: principal.username.clone(),
        })
        .await?;

    Ok(Json(AdminDebugMetricSessionResponse {
        session: row_to_session(row),
    }))
}

async fn list_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<ListSessionsQuery>,
) -> Result<Json<AdminDebugMetricSessionListResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    ensure_debug_enabled(&state)?;
    let limit = q.limit.unwrap_or(100);
    let rows = state
        .db
        .list_debug_metric_sessions_admin(q.account_id, limit)
        .await?;
    Ok(Json(AdminDebugMetricSessionListResponse {
        sessions: rows.into_iter().map(row_to_session).collect(),
    }))
}

async fn revoke_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
) -> Result<StatusCode, AppError> {
    state.authenticate_admin_headers(&headers)?;
    ensure_debug_enabled(&state)?;
    state.db.revoke_debug_metric_session(session_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Default, Deserialize)]
struct ListBatchesQuery {
    limit: Option<i64>,
}

async fn list_batches(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
    Query(q): Query<ListBatchesQuery>,
) -> Result<Json<AdminDebugMetricBatchListResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    ensure_debug_enabled(&state)?;
    let limit = q.limit.unwrap_or(100);
    let rows = state
        .db
        .list_debug_metric_batches_admin(session_id, limit)
        .await?;
    let batches = rows
        .into_iter()
        .map(|row| AdminDebugMetricBatch {
            batch_id: row.batch_id.to_string(),
            session_id: row.session_id.to_string(),
            device_id: DeviceId(row.device_id),
            received_at_unix: row.received_at_unix,
            payload: row.payload,
        })
        .collect();
    Ok(Json(AdminDebugMetricBatchListResponse { batches }))
}
