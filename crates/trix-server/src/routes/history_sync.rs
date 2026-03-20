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
    AppendHistorySyncChunkRequest, AppendHistorySyncChunkResponse, CompleteHistorySyncJobRequest,
    CompleteHistorySyncJobResponse, HistorySyncChunkListResponse, HistorySyncChunkSummary,
    HistorySyncJobListResponse, HistorySyncJobRole, HistorySyncJobStatus, HistorySyncJobSummary,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/jobs", get(list_jobs))
        .route("/jobs/{job_id}/chunks", get(list_chunks).post(append_chunk))
        .route("/jobs/{job_id}/complete", post(complete_job))
}

#[derive(Debug, Deserialize)]
struct ListJobsQuery {
    role: Option<HistorySyncJobRole>,
    status: Option<HistorySyncJobStatus>,
    limit: Option<usize>,
}

async fn list_jobs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListJobsQuery>,
) -> Result<Json<HistorySyncJobListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let jobs = match query.role.unwrap_or(HistorySyncJobRole::Source) {
        HistorySyncJobRole::Source => {
            state
                .db
                .list_history_sync_jobs_for_source_device(
                    principal.account_id,
                    principal.device_id,
                    query.status,
                    query.limit,
                )
                .await?
        }
        HistorySyncJobRole::Target => {
            state
                .db
                .list_history_sync_jobs_for_target_device(
                    principal.account_id,
                    principal.device_id,
                    query.status,
                    query.limit,
                )
                .await?
        }
    };

    Ok(Json(HistorySyncJobListResponse {
        jobs: jobs.into_iter().map(job_to_api).collect(),
    }))
}

async fn append_chunk(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(job_id): Path<String>,
    Json(request): Json<AppendHistorySyncChunkRequest>,
) -> Result<Json<AppendHistorySyncChunkResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let job_id = Uuid::parse_str(&job_id).map_err(|_| AppError::bad_request("invalid job id"))?;
    let payload = decode_b64(&request.payload_b64)?;

    let appended = state
        .db
        .append_history_sync_chunk_for_source_device(
            principal.account_id,
            principal.device_id,
            job_id,
            request.sequence_no,
            payload,
            request.cursor_json,
            request.is_final,
        )
        .await?
        .ok_or_else(|| AppError::not_found("history sync job not found"))?;

    Ok(Json(AppendHistorySyncChunkResponse {
        job_id: job_id.to_string(),
        chunk_id: appended.chunk_id,
        job_status: appended.job_status,
    }))
}

async fn list_chunks(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(job_id): Path<String>,
) -> Result<Json<HistorySyncChunkListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let job_id = Uuid::parse_str(&job_id).map_err(|_| AppError::bad_request("invalid job id"))?;

    let chunks = state
        .db
        .list_history_sync_chunks_for_target_device(
            principal.account_id,
            principal.device_id,
            job_id,
        )
        .await?
        .ok_or_else(|| AppError::not_found("history sync job not found"))?;

    Ok(Json(HistorySyncChunkListResponse {
        job_id: job_id.to_string(),
        role: HistorySyncJobRole::Target,
        chunks: chunks.into_iter().map(chunk_to_api).collect(),
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

fn chunk_to_api(chunk: crate::db::HistorySyncChunkRow) -> HistorySyncChunkSummary {
    use base64::{Engine as _, engine::general_purpose};

    HistorySyncChunkSummary {
        chunk_id: chunk.chunk_id,
        sequence_no: chunk.sequence_no,
        payload_b64: general_purpose::STANDARD.encode(chunk.payload),
        cursor_json: chunk.cursor_json,
        is_final: chunk.is_final,
        uploaded_at_unix: chunk.uploaded_at_unix,
    }
}

fn decode_b64(value: &str) -> Result<Vec<u8>, AppError> {
    use base64::{Engine as _, engine::general_purpose};

    for engine in [
        &general_purpose::STANDARD,
        &general_purpose::STANDARD_NO_PAD,
        &general_purpose::URL_SAFE,
        &general_purpose::URL_SAFE_NO_PAD,
    ] {
        if let Ok(bytes) = engine.decode(value) {
            return Ok(bytes);
        }
    }

    Err(AppError::bad_request("invalid base64 payload"))
}
