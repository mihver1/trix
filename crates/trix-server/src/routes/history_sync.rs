use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::HeaderMap,
    routing::{get, post},
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{error::AppError, state::AppState};
use trix_types::{
    CompleteHistorySyncJobRequest, CompleteHistorySyncJobResponse, HistorySyncJobListResponse,
    HistorySyncJobStatus, HistorySyncJobSummary,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/jobs", get(list_jobs))
        .route("/jobs/{job_id}/complete", post(complete_job))
}

#[derive(Debug, Deserialize)]
struct ListJobsQuery {
    status: Option<HistorySyncJobStatus>,
    limit: Option<usize>,
}

async fn list_jobs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListJobsQuery>,
) -> Result<Json<HistorySyncJobListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let jobs = state
        .db
        .list_history_sync_jobs_for_source_device(
            principal.account_id,
            principal.device_id,
            query.status,
            query.limit,
        )
        .await?;

    Ok(Json(HistorySyncJobListResponse {
        jobs: jobs.into_iter().map(job_to_api).collect(),
    }))
}

async fn complete_job(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(job_id): Path<String>,
    Json(request): Json<CompleteHistorySyncJobRequest>,
) -> Result<Json<CompleteHistorySyncJobResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let job_id = Uuid::parse_str(&job_id).map_err(|_| AppError::bad_request("invalid job id"))?;

    let job_status = state
        .db
        .complete_history_sync_job_for_source_device(
            principal.account_id,
            principal.device_id,
            job_id,
            request.cursor_json,
        )
        .await?
        .ok_or_else(|| AppError::not_found("history sync job not found"))?;

    Ok(Json(CompleteHistorySyncJobResponse {
        job_id: job_id.to_string(),
        job_status,
    }))
}

fn job_to_api(job: crate::db::HistorySyncJobRow) -> HistorySyncJobSummary {
    HistorySyncJobSummary {
        job_id: job.job_id.to_string(),
        job_type: job.job_type,
        job_status: job.job_status,
        source_device_id: trix_types::DeviceId(job.source_device_id),
        target_device_id: trix_types::DeviceId(job.target_device_id),
        chat_id: job.chat_id.map(trix_types::ChatId),
        cursor_json: job.cursor_json,
        created_at_unix: job.created_at_unix,
        updated_at_unix: job.updated_at_unix,
    }
}
