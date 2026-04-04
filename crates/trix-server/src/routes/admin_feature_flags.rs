use axum::{
    Json, Router,
    extract::{Json as ExtractJson, Path, Query, State},
    http::HeaderMap,
    routing::{get, patch},
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    db::{
        CreateFeatureFlagDefinitionInput, CreateFeatureFlagOverrideInput,
        ListFeatureFlagOverridesInput, PatchFeatureFlagDefinitionInput,
        PatchFeatureFlagOverrideInput,
    },
    error::AppError,
    state::AppState,
};
use trix_types::{
    AdminFeatureFlagDefinition, AdminFeatureFlagDefinitionListResponse, AdminFeatureFlagOverride,
    AdminFeatureFlagOverrideListResponse, CreateAdminFeatureFlagDefinitionRequest,
    CreateAdminFeatureFlagOverrideRequest, FeatureFlagScope,
    PatchAdminFeatureFlagDefinitionRequest, PatchAdminFeatureFlagOverrideRequest,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/feature-flags/definitions",
            get(list_definitions).post(create_definition),
        )
        .route(
            "/feature-flags/definitions/{flag_key}",
            get(get_definition).patch(patch_definition),
        )
        .route(
            "/feature-flags/overrides",
            get(list_overrides).post(create_override),
        )
        .route(
            "/feature-flags/overrides/{override_id}",
            patch(patch_override).delete(delete_override),
        )
}

#[derive(Debug, Default, Deserialize)]
struct ListOverridesQuery {
    flag_key: Option<String>,
    scope: Option<String>,
    platform: Option<String>,
    account_id: Option<Uuid>,
    device_id: Option<Uuid>,
}

fn validate_flag_key(key: &str) -> Result<(), AppError> {
    let key = key.trim();
    let len = key.len();
    if !(2..=64).contains(&len) {
        return Err(AppError::bad_request(
            "flag_key length must be between 2 and 64",
        ));
    }
    let mut chars = key.chars();
    let Some(first) = chars.next() else {
        return Err(AppError::bad_request("flag_key must not be empty"));
    };
    if !first.is_ascii_lowercase() {
        return Err(AppError::bad_request(
            "flag_key must start with a lowercase letter",
        ));
    }
    if !chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
        return Err(AppError::bad_request(
            "flag_key may contain only lowercase letters, digits, and underscore",
        ));
    }
    Ok(())
}

fn scope_to_str(s: FeatureFlagScope) -> &'static str {
    match s {
        FeatureFlagScope::Global => "global",
        FeatureFlagScope::Platform => "platform",
        FeatureFlagScope::Account => "account",
        FeatureFlagScope::Device => "device",
    }
}

fn parse_scope(text: &str) -> Result<FeatureFlagScope, AppError> {
    match text {
        "global" => Ok(FeatureFlagScope::Global),
        "platform" => Ok(FeatureFlagScope::Platform),
        "account" => Ok(FeatureFlagScope::Account),
        "device" => Ok(FeatureFlagScope::Device),
        _ => Err(AppError::bad_request("invalid feature flag scope")),
    }
}

fn row_to_admin_override(
    row: crate::db::FeatureFlagOverrideRow,
) -> Result<AdminFeatureFlagOverride, AppError> {
    Ok(AdminFeatureFlagOverride {
        override_id: row.override_id.to_string(),
        flag_key: row.flag_key,
        scope: parse_scope(&row.scope)?,
        platform: row.platform,
        account_id: row.account_id.map(trix_types::AccountId),
        device_id: row.device_id.map(trix_types::DeviceId),
        enabled: row.enabled,
        expires_at_unix: row.expires_at_unix,
        updated_at_unix: row.updated_at_unix,
    })
}

fn row_to_admin_definition(row: crate::db::FeatureFlagDefinitionRow) -> AdminFeatureFlagDefinition {
    AdminFeatureFlagDefinition {
        flag_key: row.flag_key,
        description: row.description,
        default_enabled: row.default_enabled,
        deleted_at_unix: row.deleted_at_unix,
        updated_at_unix: row.updated_at_unix,
    }
}

async fn list_definitions(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminFeatureFlagDefinitionListResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let rows = state.db.list_feature_flag_definitions_admin().await?;
    Ok(Json(AdminFeatureFlagDefinitionListResponse {
        definitions: rows.into_iter().map(row_to_admin_definition).collect(),
    }))
}

async fn create_definition(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<CreateAdminFeatureFlagDefinitionRequest>,
) -> Result<Json<AdminFeatureFlagDefinition>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    validate_flag_key(&body.flag_key)?;
    let row = state
        .db
        .create_feature_flag_definition(&CreateFeatureFlagDefinitionInput {
            flag_key: body.flag_key.trim().to_owned(),
            description: body.description.trim().to_owned(),
            default_enabled: body.default_enabled,
        })
        .await?;
    Ok(Json(row_to_admin_definition(row)))
}

async fn get_definition(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(flag_key): Path<String>,
) -> Result<Json<AdminFeatureFlagDefinition>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let row = state
        .db
        .get_feature_flag_definition_admin(flag_key.trim())
        .await?
        .ok_or_else(|| AppError::not_found("feature flag definition not found"))?;
    Ok(Json(row_to_admin_definition(row)))
}

async fn patch_definition(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(flag_key): Path<String>,
    ExtractJson(body): ExtractJson<PatchAdminFeatureFlagDefinitionRequest>,
) -> Result<Json<AdminFeatureFlagDefinition>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    if body.description.is_none()
        && body.default_enabled.is_none()
        && body.deleted_at_unix.is_none()
    {
        return Err(AppError::bad_request("at least one field must be provided"));
    }
    let patch = PatchFeatureFlagDefinitionInput {
        description: body.description,
        default_enabled: body.default_enabled,
        deleted_at_unix: body.deleted_at_unix,
    };
    let row = state
        .db
        .patch_feature_flag_definition(flag_key.trim(), &patch)
        .await?;
    Ok(Json(row_to_admin_definition(row)))
}

fn normalize_list_overrides_scope(raw: Option<String>) -> Result<Option<String>, AppError> {
    let Some(s) = raw else {
        return Ok(None);
    };
    let s = s.trim();
    if s.is_empty() {
        return Err(AppError::bad_request(
            "scope query parameter must not be empty",
        ));
    }
    let scope = parse_scope(s)?;
    Ok(Some(scope_to_str(scope).to_owned()))
}

async fn list_overrides(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<ListOverridesQuery>,
) -> Result<Json<AdminFeatureFlagOverrideListResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let scope = normalize_list_overrides_scope(q.scope)?;
    let rows = state
        .db
        .list_feature_flag_overrides_admin(&ListFeatureFlagOverridesInput {
            flag_key: q.flag_key,
            scope,
            platform: q.platform,
            account_id: q.account_id,
            device_id: q.device_id,
        })
        .await?;
    let overrides = rows
        .into_iter()
        .map(row_to_admin_override)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(AdminFeatureFlagOverrideListResponse { overrides }))
}

fn validate_override_request(body: &CreateAdminFeatureFlagOverrideRequest) -> Result<(), AppError> {
    match body.scope {
        FeatureFlagScope::Global => {
            if body.platform.is_some() || body.account_id.is_some() || body.device_id.is_some() {
                return Err(AppError::bad_request(
                    "global scope must not include platform, account_id, or device_id",
                ));
            }
        }
        FeatureFlagScope::Platform => {
            let Some(ref p) = body.platform else {
                return Err(AppError::bad_request(
                    "platform is required for platform scope",
                ));
            };
            if p.trim().is_empty() {
                return Err(AppError::bad_request("platform must not be empty"));
            }
            if body.account_id.is_some() || body.device_id.is_some() {
                return Err(AppError::bad_request(
                    "platform scope must not include account_id or device_id",
                ));
            }
        }
        FeatureFlagScope::Account => {
            if body.account_id.is_none() {
                return Err(AppError::bad_request(
                    "account_id is required for account scope",
                ));
            }
            if body.platform.is_some() || body.device_id.is_some() {
                return Err(AppError::bad_request(
                    "account scope must not include platform or device_id",
                ));
            }
        }
        FeatureFlagScope::Device => {
            if body.account_id.is_none() || body.device_id.is_none() {
                return Err(AppError::bad_request(
                    "account_id and device_id are required for device scope",
                ));
            }
            if body.platform.is_some() {
                return Err(AppError::bad_request(
                    "device scope must not include platform",
                ));
            }
        }
    }
    Ok(())
}

async fn create_override(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<CreateAdminFeatureFlagOverrideRequest>,
) -> Result<Json<AdminFeatureFlagOverride>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    validate_flag_key(&body.flag_key)?;
    validate_override_request(&body)?;
    let row = state
        .db
        .create_feature_flag_override(&CreateFeatureFlagOverrideInput {
            flag_key: body.flag_key.trim().to_owned(),
            scope: scope_to_str(body.scope).to_owned(),
            platform: body.platform.map(|p| p.trim().to_owned()),
            account_id: body.account_id.map(|a| a.0),
            device_id: body.device_id.map(|d| d.0),
            enabled: body.enabled,
            expires_at_unix: body.expires_at_unix,
        })
        .await?;
    Ok(Json(row_to_admin_override(row)?))
}

async fn patch_override(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(override_id): Path<Uuid>,
    ExtractJson(body): ExtractJson<PatchAdminFeatureFlagOverrideRequest>,
) -> Result<Json<AdminFeatureFlagOverride>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    if body.enabled.is_none() && body.expires_at_unix.is_none() {
        return Err(AppError::bad_request("at least one field must be provided"));
    }
    let patch = PatchFeatureFlagOverrideInput {
        enabled: body.enabled,
        expires_at_unix: body.expires_at_unix,
    };
    let row = state
        .db
        .patch_feature_flag_override(override_id, &patch)
        .await?;
    Ok(Json(row_to_admin_override(row)?))
}

async fn delete_override(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(override_id): Path<Uuid>,
) -> Result<axum::http::StatusCode, AppError> {
    state.authenticate_admin_headers(&headers)?;
    state.db.delete_feature_flag_override(override_id).await?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}
