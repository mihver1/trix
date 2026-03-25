use axum::{Json, Router, extract::State, http::HeaderMap, routing::post};
use base64::{Engine as _, engine::general_purpose};

use crate::{db::PublishKeyPackageInput, error::AppError, state::AppState};
use trix_types::{
    AccountKeyPackagesResponse, DeviceId, PublishKeyPackagesRequest, PublishKeyPackagesResponse,
    PublishedKeyPackage, ReserveKeyPackagesRequest, ReservedKeyPackage,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/key-packages:publish", post(publish_key_packages))
        .route("/key-packages:reserve", post(reserve_key_packages))
}

async fn publish_key_packages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PublishKeyPackagesRequest>,
) -> Result<Json<PublishKeyPackagesResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let packages = request
        .packages
        .into_iter()
        .map(|package| {
            Ok(PublishKeyPackageInput {
                device_id: principal.device_id,
                cipher_suite: package.cipher_suite,
                key_package_bytes: decode_b64(&package.key_package_b64)?,
            })
        })
        .collect::<Result<Vec<_>, AppError>>()?;

    let published = state
        .db
        .publish_key_packages(principal.device_id, packages)
        .await?;

    Ok(Json(PublishKeyPackagesResponse {
        device_id: DeviceId(principal.device_id),
        packages: published
            .into_iter()
            .map(|package| PublishedKeyPackage {
                key_package_id: package.key_package_id.to_string(),
                cipher_suite: package.cipher_suite,
            })
            .collect(),
    }))
}

async fn reserve_key_packages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ReserveKeyPackagesRequest>,
) -> Result<Json<AccountKeyPackagesResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    if request.device_ids.is_empty() {
        return Err(AppError::bad_request("at least one device id is required"));
    }
    let account_id = request.account_id;
    let device_ids = request
        .device_ids
        .into_iter()
        .map(|device_id| device_id.0)
        .collect();

    let packages = state
        .db
        .reserve_key_packages_for_devices(principal.account_id, account_id.0, device_ids)
        .await?;

    Ok(Json(AccountKeyPackagesResponse {
        account_id,
        packages: packages
            .into_iter()
            .map(|package| ReservedKeyPackage {
                key_package_id: package.key_package_id.to_string(),
                device_id: DeviceId(package.device_id),
                cipher_suite: package.cipher_suite,
                key_package_b64: general_purpose::STANDARD.encode(package.key_package_bytes),
            })
            .collect(),
    }))
}

fn decode_b64(value: &str) -> Result<Vec<u8>, AppError> {
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
