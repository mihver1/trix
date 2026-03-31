use axum::{
    Json, Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post, put},
};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::json;
use uuid::Uuid;

use crate::{
    db::{
        ApprovePendingDeviceInput, CompleteLinkIntentInput, KeyPackageBytesInput,
        RegisterApplePushTokenInput, RevokeDeviceInput,
    },
    error::AppError,
    signatures::{account_bootstrap_message, device_revoke_message},
    state::AppState,
};
use trix_types::{
    ApproveDeviceRequest, ApproveDeviceResponse, CompleteLinkIntentRequest,
    CompleteLinkIntentResponse, CreateLinkIntentResponse, DeviceApprovePayloadResponse, DeviceId,
    DeviceListResponse, DeviceSummary, DeviceTransferBundleResponse, DeviceTransportKeyResponse,
    RegisterApplePushTokenRequest, RegisterApplePushTokenResponse, RevokeDeviceRequest,
    RevokeDeviceResponse,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_devices))
        .route(
            "/push-token",
            put(register_apple_push_token).delete(delete_apple_push_token),
        )
        .route("/link-intents", post(create_link_intent))
        .route(
            "/link-intents/{link_intent_id}/complete",
            post(complete_link_intent),
        )
        .route("/{device_id}/transfer-bundle", get(get_transfer_bundle))
        .route("/{device_id}/transport-key", get(get_transport_key))
        .route("/{device_id}/approve-payload", get(get_approve_payload))
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
                available_key_package_count: device.available_key_package_count,
            })
            .collect(),
    }))
}

async fn create_link_intent(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<CreateLinkIntentResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    state
        .enforce_rate_limit(
            "device_link_intent",
            principal.account_id.to_string(),
            state.config.rate_limit_link_intents_limit,
        )
        .await?;
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

async fn register_apple_push_token(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RegisterApplePushTokenRequest>,
) -> Result<Json<RegisterApplePushTokenResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let token_hex = normalize_apns_token_hex(&request.token_hex)?;

    state
        .db
        .register_device_apns_token(RegisterApplePushTokenInput {
            device_id: principal.device_id,
            token_hex,
            environment: request.environment,
        })
        .await?;

    Ok(Json(RegisterApplePushTokenResponse {
        device_id: DeviceId(principal.device_id),
        environment: request.environment,
        push_delivery_enabled: state.push_notifications.is_delivery_enabled(),
    }))
}

async fn delete_apple_push_token(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<StatusCode, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    state
        .db
        .delete_device_apns_token(principal.device_id)
        .await?;
    Ok(StatusCode::NO_CONTENT)
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

    let bootstrap_payload_b64 = general_purpose::STANDARD.encode(account_bootstrap_message(
        &transport_pubkey,
        &credential_identity,
    ));

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
        bootstrap_payload_b64,
    }))
}

async fn get_approve_payload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<DeviceId>,
) -> Result<Json<DeviceApprovePayloadResponse>, AppError> {
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

    Ok(Json(pending_bootstrap_to_api(bootstrap)))
}

async fn get_transfer_bundle(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<DeviceId>,
) -> Result<Json<DeviceTransferBundleResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    if principal.device_id != device_id.0 {
        return Err(AppError::unauthorized(
            "transfer bundle can only be fetched by the target device",
        ));
    }

    let bundle = state
        .db
        .get_device_transfer_bundle(principal.account_id, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("transfer bundle not found"))?;

    Ok(Json(DeviceTransferBundleResponse {
        account_id: trix_types::AccountId(bundle.account_id),
        device_id: DeviceId(bundle.device_id),
        transfer_bundle_b64: general_purpose::STANDARD.encode(bundle.transfer_bundle_ciphertext),
        uploaded_at_unix: bundle.uploaded_at_unix,
    }))
}

async fn get_transport_key(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<DeviceId>,
) -> Result<Json<DeviceTransportKeyResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let device = state
        .db
        .get_device_transport_key_for_account(principal.account_id, device_id.0)
        .await?
        .ok_or_else(|| AppError::not_found("device not found"))?;

    Ok(Json(DeviceTransportKeyResponse {
        device_id: DeviceId(device.device_id),
        device_status: device.device_status,
        transport_pubkey_b64: general_purpose::STANDARD.encode(device.transport_pubkey),
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
    let transfer_bundle_ciphertext = request
        .transfer_bundle_b64
        .as_deref()
        .map(decode_b64)
        .transpose()?;
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
            transfer_bundle_ciphertext,
        })
        .await?;

    Ok(Json(ApproveDeviceResponse {
        account_id: trix_types::AccountId(approved.account_id),
        device_id: DeviceId(approved.device_id),
        device_status: approved.device_status,
    }))
}

async fn revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<DeviceId>,
    Json(request): Json<RevokeDeviceRequest>,
) -> Result<Json<RevokeDeviceResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let reason = request.reason.trim().to_owned();
    if reason.is_empty() {
        return Err(AppError::bad_request("reason must not be empty"));
    }

    let revoke_context = state
        .db
        .get_device_revoke_context(device_id.0)
        .await?
        .ok_or_else(|| AppError::not_found("target device not found"))?;

    if revoke_context.account_id != principal.account_id {
        return Err(AppError::unauthorized(
            "target device does not belong to the authenticated account",
        ));
    }

    let account_root_signature = decode_b64(&request.account_root_signature_b64)?;
    verify_account_root_signature(
        &revoke_context.account_root_pubkey,
        &account_root_signature,
        &device_revoke_message(device_id.0, &reason),
        "invalid device revoke signature",
    )?;

    let revoked = state
        .db
        .revoke_device(RevokeDeviceInput {
            actor_account_id: principal.account_id,
            actor_device_id: principal.device_id,
            target_device_id: device_id.0,
            reason,
        })
        .await?;

    Ok(Json(RevokeDeviceResponse {
        account_id: trix_types::AccountId(revoked.account_id),
        device_id: DeviceId(revoked.device_id),
        device_status: revoked.device_status,
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

fn verify_account_bootstrap_signature(
    account_root_pubkey: &[u8],
    account_root_signature: &[u8],
    transport_pubkey: &[u8],
    credential_identity: &[u8],
) -> Result<(), AppError> {
    verify_account_root_signature(
        account_root_pubkey,
        account_root_signature,
        &account_bootstrap_message(transport_pubkey, credential_identity),
        "invalid account bootstrap signature",
    )
}

fn verify_account_root_signature(
    account_root_pubkey: &[u8],
    account_root_signature: &[u8],
    message: &[u8],
    error_message: &str,
) -> Result<(), AppError> {
    let account_root_pubkey: [u8; 32] = account_root_pubkey
        .try_into()
        .map_err(|_| AppError::bad_request("account root public key must be 32 bytes"))?;
    let verifying_key = VerifyingKey::from_bytes(&account_root_pubkey)
        .map_err(|_| AppError::bad_request("invalid account root public key"))?;
    let signature = Signature::from_slice(account_root_signature)
        .map_err(|_| AppError::bad_request("invalid account root signature length"))?;

    verifying_key
        .verify(message, &signature)
        .map_err(|_| AppError::bad_request(error_message))
}

fn pending_bootstrap_to_api(
    bootstrap: crate::db::PendingDeviceBootstrapRow,
) -> DeviceApprovePayloadResponse {
    DeviceApprovePayloadResponse {
        account_id: trix_types::AccountId(bootstrap.account_id),
        device_id: DeviceId(bootstrap.device_id),
        device_display_name: bootstrap.device_display_name,
        platform: bootstrap.platform,
        device_status: bootstrap.device_status,
        credential_identity_b64: general_purpose::STANDARD.encode(&bootstrap.credential_identity),
        transport_pubkey_b64: general_purpose::STANDARD.encode(&bootstrap.transport_pubkey),
        bootstrap_payload_b64: general_purpose::STANDARD.encode(account_bootstrap_message(
            &bootstrap.transport_pubkey,
            &bootstrap.credential_identity,
        )),
    }
}

fn normalize_apns_token_hex(raw_value: &str) -> Result<String, AppError> {
    let normalized: String = raw_value
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .map(|character| character.to_ascii_lowercase())
        .collect();

    if normalized.is_empty() {
        return Err(AppError::bad_request("token_hex must not be empty"));
    }
    if normalized.len() % 2 != 0 {
        return Err(AppError::bad_request(
            "token_hex must contain an even number of hex characters",
        ));
    }
    if !normalized
        .chars()
        .all(|character| character.is_ascii_hexdigit())
    {
        return Err(AppError::bad_request(
            "token_hex must be a hex-encoded APNs token",
        ));
    }

    Ok(normalized)
}
