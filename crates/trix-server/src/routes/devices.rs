use axum::{
    Json, Router,
    http::HeaderMap,
    routing::{get, post},
};

use crate::{error::AppError, state::AppState};
use trix_types::{DeviceListResponse, DeviceSummary};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_devices))
        .route("/link-intents", post(create_link_intent))
        .route(
            "/link-intents/{link_intent_id}/complete",
            post(complete_link_intent),
        )
        .route("/{device_id}/approve", post(approve_device))
        .route("/{device_id}/revoke", post(revoke_device))
}

async fn list_devices(
    axum::extract::State(state): axum::extract::State<AppState>,
    headers: HeaderMap,
) -> Result<Json<DeviceListResponse>, AppError> {
    let principal = state.auth.authenticate_headers(&headers)?;
    let devices = state
        .db
        .list_devices_for_account(principal.account_id)
        .await?;

    Ok(Json(DeviceListResponse {
        account_id: trix_types::AccountId(principal.account_id),
        devices: devices
            .into_iter()
            .map(|device| DeviceSummary {
                device_id: trix_types::DeviceId(device.device_id),
                display_name: device.display_name,
                platform: device.platform,
                device_status: device.device_status,
            })
            .collect(),
    }))
}

async fn create_link_intent() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device link intent flow is not implemented yet",
    ))
}

async fn complete_link_intent() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device link completion flow is not implemented yet",
    ))
}

async fn approve_device() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device approval flow is not implemented yet",
    ))
}

async fn revoke_device() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device revocation flow is not implemented yet",
    ))
}
