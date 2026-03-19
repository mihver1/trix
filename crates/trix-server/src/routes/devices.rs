use axum::{
    Json, Router,
    extract::{Path, State},
    http::HeaderMap,
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::json;
use uuid::Uuid;

use crate::{
    db::{ApprovePendingDeviceInput, CompleteLinkIntentInput, KeyPackageBytesInput},
    error::AppError,
    state::AppState,
};
use trix_types::{
    ApproveDeviceRequest, ApproveDeviceResponse, CompleteLinkIntentRequest,
    CompleteLinkIntentResponse, CreateLinkIntentResponse, DeviceId, DeviceListResponse,
    DeviceSummary,
};

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
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<DeviceListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let devices = state
        .db
        .list_devices_for_account(principal.account_id)
        .await?;

    Ok(Json(DeviceListResponse {
        account_id: trix_types::AccountId(principal.account_id),
        devices: devices
            .into_iter()
            .map(|device| DeviceSummary {
                device_id: DeviceId(device.device_id),
                display_name: device.display_name,
                platform: device.platform,
                device_status: device.device_status,
            })
            .collect(),
    }))
}

async fn create_link_intent(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<CreateLinkIntentResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let created = state
        .db
        .create_link_intent(principal.account_id, principal.device_id)
        .await?;

    let qr_payload = json!({
        "version": 1,
        "base_url": state.config.public_base_url,
        "account_id": created.account_id,
        "link_intent_id": created.link_intent_id,
        "link_token": created.link_token,
    })
    .to_string();

    Ok(Json(CreateLinkIntentResponse {
        link_intent_id: created.link_intent_id.to_string(),
        qr_payload,
        expires_at_unix: created.expires_at_unix,
    }))
}

async fn complete_link_intent(
    State(state): State<AppState>,
    Path(link_intent_id): Path<String>,
    Json(request): Json<CompleteLinkIntentRequest>,
) -> Result<Json<CompleteLinkIntentResponse>, AppError> {
    let link_intent_id = Uuid::parse_str(&link_intent_id)
        .map_err(|_| AppError::bad_request("invalid link intent id"))?;
    let link_token = Uuid::parse_str(&request.link_token)
        .map_err(|_| AppError::bad_request("invalid link token"))?;
    let credential_identity = decode_b64(&request.credential_identity_b64)?;
    let transport_pubkey = decode_b64(&request.transport_pubkey_b64)?;

    if request.device_display_name.trim().is_empty() {
        return Err(AppError::bad_request(
            "device_display_name must not be empty",
        ));
    }
    if request.platform.trim().is_empty() {
        return Err(AppError::bad_request("platform must not be empty"));
    }

    let key_packages = request
        .key_packages
        .into_iter()
        .map(|package| {
            Ok(KeyPackageBytesInput {
                cipher_suite: package.cipher_suite,
                key_package_bytes: decode_b64(&package.key_package_b64)?,
            })
        })
        .collect::<Result<Vec<_>, AppError>>()?;

    let completed = state
        .db
        .complete_link_intent(CompleteLinkIntentInput {
            link_intent_id,
            link_token,
            device_display_name: request.device_display_name,
            platform: request.platform,
            credential_identity,
            transport_pubkey,
            key_packages,
        })
        .await?;

    Ok(Json(CompleteLinkIntentResponse {
        account_id: trix_types::AccountId(completed.account_id),
        pending_device_id: DeviceId(completed.pending_device_id),
        device_status: completed.device_status,
    }))
}

async fn approve_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<DeviceId>,
    Json(request): Json<ApproveDeviceRequest>,
) -> Result<Json<ApproveDeviceResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let bootstrap = state
        .db
        .get_pending_device_bootstrap(device_id.0)
        .await?
        .ok_or_else(|| AppError::not_found("target device not found"))?;

    if bootstrap.account_id != principal.account_id {
        return Err(AppError::unauthorized(
            "target device does not belong to the authenticated account",
        ));
    }
    if bootstrap.device_status != trix_types::DeviceStatus::Pending {
        return Err(AppError::conflict("device is not pending approval"));
    }

    let account_root_signature = decode_b64(&request.account_root_signature_b64)?;
    verify_account_bootstrap_signature(
        &bootstrap.account_root_pubkey,
        &account_root_signature,
        &bootstrap.transport_pubkey,
        &bootstrap.credential_identity,
    )?;

    let approved = state
        .db
        .approve_pending_device(ApprovePendingDeviceInput {
            actor_account_id: principal.account_id,
            actor_device_id: principal.device_id,
            target_device_id: device_id.0,
            account_root_signature,
        })
        .await?;

    Ok(Json(ApproveDeviceResponse {
        account_id: trix_types::AccountId(approved.account_id),
        device_id: DeviceId(approved.device_id),
        device_status: approved.device_status,
    }))
}

async fn revoke_device() -> Result<Json<serde_json::Value>, AppError> {
    Err(AppError::not_implemented(
        "device revocation flow is not implemented yet",
    ))
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

fn verify_account_bootstrap_signature(
    account_root_pubkey: &[u8],
    account_root_signature: &[u8],
    transport_pubkey: &[u8],
    credential_identity: &[u8],
) -> Result<(), AppError> {
    let account_root_pubkey: [u8; 32] = account_root_pubkey
        .try_into()
        .map_err(|_| AppError::bad_request("account root public key must be 32 bytes"))?;
    let verifying_key = VerifyingKey::from_bytes(&account_root_pubkey)
        .map_err(|_| AppError::bad_request("invalid account root public key"))?;
    let signature = Signature::from_slice(account_root_signature)
        .map_err(|_| AppError::bad_request("invalid account root signature length"))?;
    let message = bootstrap_message(transport_pubkey, credential_identity);

    verifying_key
        .verify(&message, &signature)
        .map_err(|_| AppError::bad_request("invalid account bootstrap signature"))
}

fn bootstrap_message(transport_pubkey: &[u8], credential_identity: &[u8]) -> Vec<u8> {
    let mut message = Vec::with_capacity(
        b"trix-account-bootstrap:v1".len() + 8 + transport_pubkey.len() + credential_identity.len(),
    );
    message.extend_from_slice(b"trix-account-bootstrap:v1");
    message.extend_from_slice(&(transport_pubkey.len() as u32).to_be_bytes());
    message.extend_from_slice(transport_pubkey);
    message.extend_from_slice(&(credential_identity.len() as u32).to_be_bytes());
    message.extend_from_slice(credential_identity);
    message
}
