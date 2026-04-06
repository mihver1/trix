use axum::{
    Json, Router,
    extract::{Path, State},
    http::HeaderMap,
    routing::{get, post},
};
use uuid::Uuid;

use crate::{error::AppError, state::AppState};
use trix_types::{
    CompleteMessageRepairWitnessRequest, CompleteMessageRepairWitnessResponse,
    MessageRepairWitnessRequestSummary, RequestMessageRepairWitnessRequest,
    RequestMessageRepairWitnessResponse, SubmitMessageRepairWitnessResultRequest,
    SubmitMessageRepairWitnessResultResponse, TargetMessageRepairRequestListResponse,
    WitnessMessageRepairRequestListResponse,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/message-repairs:request", post(request_message_repair))
        .route("/message-repairs/witness", get(list_witness_requests))
        .route("/message-repairs/target", get(list_target_requests))
        .route(
            "/message-repairs/{request_id}/submit",
            post(submit_witness_result),
        )
        .route(
            "/message-repairs/{request_id}/complete",
            post(complete_target_result),
        )
}

async fn request_message_repair(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RequestMessageRepairWitnessRequest>,
) -> Result<Json<RequestMessageRepairWitnessResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let request = state
        .db
        .request_message_repair_witness(principal.account_id, principal.device_id, &request.binding)
        .await?;
    Ok(Json(RequestMessageRepairWitnessResponse {
        request: request.map(|row| message_repair_request_to_api(row, false)),
    }))
}

async fn list_witness_requests(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<WitnessMessageRepairRequestListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let rows = state
        .db
        .list_message_repair_requests_for_witness_device(
            principal.account_id,
            principal.device_id,
            None,
        )
        .await?;
    Ok(Json(WitnessMessageRepairRequestListResponse {
        requests: rows
            .into_iter()
            .map(|row| message_repair_request_to_api(row, true))
            .collect(),
    }))
}

async fn list_target_requests(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<TargetMessageRepairRequestListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let rows = state
        .db
        .list_message_repair_requests_for_target_device(
            principal.account_id,
            principal.device_id,
            None,
        )
        .await?;
    Ok(Json(TargetMessageRepairRequestListResponse {
        requests: rows
            .into_iter()
            .map(|row| message_repair_request_to_api(row, false))
            .collect(),
    }))
}

async fn submit_witness_result(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(request_id): Path<String>,
    Json(request): Json<SubmitMessageRepairWitnessResultRequest>,
) -> Result<Json<SubmitMessageRepairWitnessResultResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let request_id =
        Uuid::parse_str(&request_id).map_err(|_| AppError::bad_request("invalid request id"))?;
    let payload = request
        .payload_b64
        .as_deref()
        .map(|value| decode_b64(value, "payload_b64"))
        .transpose()?;
    let row = state
        .db
        .submit_message_repair_witness_result(
            principal.account_id,
            principal.device_id,
            request_id,
            &request.binding,
            request.outcome,
            payload,
            request.unavailable_reason.as_deref(),
        )
        .await?
        .ok_or_else(|| AppError::not_found("message repair request not found"))?;
    Ok(Json(SubmitMessageRepairWitnessResultResponse {
        request_id: row.request_id.to_string(),
        status: row.status,
    }))
}

async fn complete_target_result(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(request_id): Path<String>,
    Json(request): Json<CompleteMessageRepairWitnessRequest>,
) -> Result<Json<CompleteMessageRepairWitnessResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let request_id =
        Uuid::parse_str(&request_id).map_err(|_| AppError::bad_request("invalid request id"))?;
    let row = state
        .db
        .complete_message_repair_witness(
            principal.account_id,
            principal.device_id,
            request_id,
            request.outcome,
            request.rejection_reason.as_deref(),
        )
        .await?
        .ok_or_else(|| AppError::not_found("message repair request not found"))?;
    Ok(Json(CompleteMessageRepairWitnessResponse {
        request_id: row.request_id.to_string(),
        status: row.status,
    }))
}

fn message_repair_request_to_api(
    row: crate::db::MessageRepairWitnessRequestRow,
    include_target_transport_pubkey: bool,
) -> MessageRepairWitnessRequestSummary {
    MessageRepairWitnessRequestSummary {
        request_id: row.request_id.to_string(),
        binding: row.binding,
        target_device_id: trix_types::DeviceId(row.target_device_id),
        witness_account_id: trix_types::AccountId(row.witness_account_id),
        witness_device_id: trix_types::DeviceId(row.witness_device_id),
        status: row.status,
        target_transport_pubkey_b64: include_target_transport_pubkey
            .then(|| encode_b64(&row.target_transport_pubkey)),
        result_payload_b64: row.result_payload.map(|payload| encode_b64(&payload)),
        submitted_by_device_id: row.submitted_by_device_id.map(trix_types::DeviceId),
        unavailable_reason: row.unavailable_reason,
        created_at_unix: row.created_at_unix,
        updated_at_unix: row.updated_at_unix,
        expires_at_unix: row.expires_at_unix,
    }
}

fn decode_b64(value: &str, field: &str) -> Result<Vec<u8>, AppError> {
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

    Err(AppError::bad_request(format!("invalid base64 for {field}")))
}

fn encode_b64(bytes: &[u8]) -> String {
    use base64::{Engine as _, engine::general_purpose};

    general_purpose::STANDARD.encode(bytes)
}
