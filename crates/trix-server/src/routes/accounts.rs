use axum::{
    Json, Router,
    extract::{Json as ExtractJson, Path, State},
    http::HeaderMap,
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};

use crate::{
    db::CreateAccountInput, error::AppError, signatures::account_bootstrap_message, state::AppState,
};
use trix_types::{
    AccountId, AccountKeyPackagesResponse, AccountProfileResponse, CreateAccountRequest,
    CreateAccountResponse, DeviceId, ReservedKeyPackage,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", post(create_account))
        .route("/me", get(get_me))
        .route("/{account_id}/key-packages", get(get_account_key_packages))
}

async fn create_account(
    State(state): State<AppState>,
    ExtractJson(request): ExtractJson<CreateAccountRequest>,
) -> Result<Json<CreateAccountResponse>, AppError> {
    let credential_identity = decode_b64(&request.credential_identity_b64)?;
    let account_root_pubkey = decode_b64(&request.account_root_pubkey_b64)?;
    let account_root_signature = decode_b64(&request.account_root_signature_b64)?;
    let transport_pubkey = decode_b64(&request.transport_pubkey_b64)?;

    verify_account_bootstrap_signature(
        &account_root_pubkey,
        &account_root_signature,
        &transport_pubkey,
        &credential_identity,
    )?;

    let created = state
        .db
        .create_account(CreateAccountInput {
            handle: request.handle,
            profile_name: request.profile_name,
            profile_bio: request.profile_bio,
            device_display_name: request.device_display_name,
            platform: request.platform,
            credential_identity,
            account_root_pubkey,
            account_root_signature,
            transport_pubkey,
        })
        .await?;

    Ok(Json(CreateAccountResponse {
        account_id: AccountId(created.account_id),
        device_id: trix_types::DeviceId(created.device_id),
        account_sync_chat_id: trix_types::ChatId(created.account_sync_chat_id),
    }))
}

async fn get_me(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AccountProfileResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let profile = state
        .db
        .get_account_profile(principal.account_id, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("account not found"))?;

    Ok(Json(AccountProfileResponse {
        account_id: AccountId(profile.account_id),
        handle: profile.handle,
        profile_name: profile.profile_name,
        profile_bio: profile.profile_bio,
        device_id: trix_types::DeviceId(profile.device_id),
        device_status: profile.device_status,
    }))
}

async fn get_account_key_packages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<AccountId>,
) -> Result<Json<AccountKeyPackagesResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let packages = state
        .db
        .reserve_key_packages_for_account(principal.account_id, account_id.0)
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
    let message = account_bootstrap_message(transport_pubkey, credential_identity);

    verifying_key
        .verify(&message, &signature)
        .map_err(|_| AppError::bad_request("invalid account bootstrap signature"))
}
