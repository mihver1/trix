use axum::{
    Json, Router,
    extract::{Json as ExtractJson, Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    db::CreateAccountInput, error::AppError, signatures::account_bootstrap_message, state::AppState,
};
use trix_types::{
    AccountDebugMetricsStatusResponse, AccountDirectoryResponse, AccountFeatureFlagsResponse,
    AccountId, AccountKeyPackagesResponse, AccountProfileResponse, CreateAccountRequest,
    CreateAccountResponse, DeviceId, DirectoryAccountSummary, ReservedKeyPackage,
    SubmitDebugMetricsRequest, UpdateAccountProfileRequest,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", post(create_account))
        .route("/me", get(get_me).patch(update_me))
        .route("/me/feature-flags", get(get_my_feature_flags))
        .route(
            "/me/debug/metrics",
            get(get_debug_metrics_status).post(submit_debug_metrics),
        )
        .route("/directory", get(search_directory))
        .route("/{account_id}", get(get_account))
        .route("/{account_id}/key-packages", get(get_account_key_packages))
}

#[derive(Debug, Default, Deserialize)]
struct AccountDirectoryQuery {
    q: Option<String>,
    limit: Option<usize>,
    exclude_self: Option<bool>,
}

async fn create_account(
    State(state): State<AppState>,
    ExtractJson(request): ExtractJson<CreateAccountRequest>,
) -> Result<Json<CreateAccountResponse>, AppError> {
    let handle = normalize_handle(request.handle)?;
    let profile_name = normalize_profile_name(request.profile_name)?;
    let profile_bio = normalize_profile_bio(request.profile_bio);
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

    let settings = state.db.get_admin_runtime_settings().await?;
    let handle_for_provision = handle.clone();

    let created = if !settings.allow_public_account_registration {
        let token = request
            .provision_token
            .as_deref()
            .ok_or_else(|| {
                AppError::bad_request(
                    "provision_token is required when public account registration is disabled",
                )
            })?
            .trim();
        if token.is_empty() {
            return Err(AppError::bad_request(
                "provision_token is required when public account registration is disabled",
            ));
        }

        state
            .db
            .create_account_with_provision_token(
                CreateAccountInput {
                    handle,
                    profile_name,
                    profile_bio,
                    device_display_name: request.device_display_name,
                    platform: request.platform,
                    credential_identity,
                    account_root_pubkey,
                    account_root_signature,
                    transport_pubkey,
                },
                token,
                handle_for_provision,
            )
            .await?
    } else {
        state
            .db
            .create_account(CreateAccountInput {
                handle,
                profile_name,
                profile_bio,
                device_display_name: request.device_display_name,
                platform: request.platform,
                credential_identity,
                account_root_pubkey,
                account_root_signature,
                transport_pubkey,
            })
            .await?
    };

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

async fn get_my_feature_flags(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AccountFeatureFlagsResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let platform = state
        .db
        .get_device_platform(principal.device_id)
        .await?
        .unwrap_or_else(|| "unknown".to_owned());
    let (revision, flags) = state
        .db
        .resolve_feature_flags_for_device(
            principal.account_id,
            principal.device_id,
            &platform,
        )
        .await?;
    Ok(Json(AccountFeatureFlagsResponse { revision, flags }))
}

async fn get_debug_metrics_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AccountDebugMetricsStatusResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    if !state.config.debug_metrics_enabled {
        return Err(AppError::not_found("not found"));
    }
    let row = state
        .db
        .get_active_debug_metric_session_for_device(principal.account_id, principal.device_id)
        .await?;
    Ok(Json(match row {
        Some(s) => AccountDebugMetricsStatusResponse {
            active: true,
            session_id: Some(s.session_id.to_string()),
            user_visible_message: Some(s.user_visible_message),
        },
        None => AccountDebugMetricsStatusResponse {
            active: false,
            session_id: None,
            user_visible_message: None,
        },
    }))
}

async fn submit_debug_metrics(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<SubmitDebugMetricsRequest>,
) -> Result<StatusCode, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    if !state.config.debug_metrics_enabled {
        return Err(AppError::not_found("not found"));
    }
    state
        .enforce_rate_limit(
            "debug_metrics_post",
            principal.device_id.to_string(),
            60,
        )
        .await?;

    let session_id = Uuid::parse_str(body.session_id.trim())
        .map_err(|_| AppError::bad_request("invalid session_id"))?;

    if !body.payload.is_object() {
        return Err(AppError::bad_request("payload must be a JSON object"));
    }
    let ser = serde_json::to_vec(&body.payload)
        .map_err(|e| AppError::bad_request(format!("invalid payload: {e}")))?;
    if ser.len() > 65_536 {
        return Err(AppError::bad_request("payload too large"));
    }

    state
        .db
        .insert_debug_metric_batch(session_id, principal.device_id, body.payload)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn update_me(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(request): ExtractJson<UpdateAccountProfileRequest>,
) -> Result<Json<AccountProfileResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let handle = normalize_handle(request.handle)?;
    let profile_name = normalize_profile_name(request.profile_name)?;
    let profile_bio = normalize_profile_bio(request.profile_bio);

    let updated = state
        .db
        .update_account_profile(crate::db::UpdateAccountProfileInput {
            account_id: principal.account_id,
            handle,
            profile_name,
            profile_bio,
        })
        .await?;

    if !updated {
        return Err(AppError::not_found("account not found"));
    }

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

async fn get_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<AccountId>,
) -> Result<Json<DirectoryAccountSummary>, AppError> {
    let _principal = state.authenticate_active_headers(&headers).await?;
    let account = state
        .db
        .get_account_directory_entry(account_id.0)
        .await?
        .ok_or_else(|| AppError::not_found("account not found"))?;

    Ok(Json(DirectoryAccountSummary {
        account_id: AccountId(account.account_id),
        handle: account.handle,
        profile_name: account.profile_name,
        profile_bio: account.profile_bio,
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

async fn search_directory(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AccountDirectoryQuery>,
) -> Result<Json<AccountDirectoryResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    state
        .enforce_rate_limit(
            "account_directory",
            principal.account_id.to_string(),
            state.config.rate_limit_directory_limit,
        )
        .await?;
    let accounts = state
        .db
        .search_account_directory(
            principal.account_id,
            query.q.as_deref(),
            query.exclude_self.unwrap_or(true),
            query.limit,
        )
        .await?;

    Ok(Json(AccountDirectoryResponse {
        accounts: accounts
            .into_iter()
            .map(|account| DirectoryAccountSummary {
                account_id: AccountId(account.account_id),
                handle: account.handle,
                profile_name: account.profile_name,
                profile_bio: account.profile_bio,
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

fn normalize_handle(handle: Option<String>) -> Result<Option<String>, AppError> {
    let Some(handle) = handle else {
        return Ok(None);
    };

    let trimmed = handle.trim();
    if trimmed.is_empty() {
        return Err(AppError::bad_request("handle must not be empty"));
    }

    if !(3..=32).contains(&trimmed.len()) {
        return Err(AppError::bad_request(
            "handle length must be between 3 and 32 characters",
        ));
    }

    let normalized = trimmed.to_ascii_lowercase();
    if !normalized
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '_' | '-' | '.'))
    {
        return Err(AppError::bad_request(
            "handle may contain only lowercase letters, digits, '.', '-', and '_'",
        ));
    }

    Ok(Some(normalized))
}

fn normalize_profile_name(profile_name: String) -> Result<String, AppError> {
    let normalized = profile_name.trim();
    if normalized.is_empty() {
        return Err(AppError::bad_request("profile_name must not be empty"));
    }
    if normalized.len() > 120 {
        return Err(AppError::bad_request(
            "profile_name must be at most 120 characters",
        ));
    }
    Ok(normalized.to_owned())
}

fn normalize_profile_bio(profile_bio: Option<String>) -> Option<String> {
    profile_bio.and_then(|bio| {
        let trimmed = bio.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        }
    })
}
