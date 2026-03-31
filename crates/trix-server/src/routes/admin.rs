use axum::{
    Json, Router,
    body::Bytes,
    extract::{Json as ExtractJson, Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post},
};
use serde::Deserialize;
use subtle::ConstantTimeEq;

use crate::{
    db::{
        CreateAdminUserProvisionInput, ListAdminUsersInput, PatchAdminAccountInput,
        UpdateAdminRuntimeSettingsInput,
    },
    error::AppError,
    state::AppState,
};
use trix_types::{
    AccountId, AdminDisableAccountRequest, AdminOverviewResponse,
    AdminRegistrationSettingsResponse, AdminServerSettingsResponse, AdminSessionRequest,
    AdminSessionResponse, AdminUserListResponse, AdminUserSummary, CreateAdminUserProvisionRequest,
    CreateAdminUserProvisionResponse, PatchAdminRegistrationSettingsRequest,
    PatchAdminServerSettingsRequest, PatchAdminUserRequest, ServiceStatus,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/session", post(create_session).delete(delete_session))
        .route("/overview", get(overview))
        .route(
            "/settings/registration",
            get(get_registration_settings).patch(patch_registration_settings),
        )
        .route(
            "/settings/server",
            get(get_server_settings).patch(patch_server_settings),
        )
        .route(
            "/users",
            get(list_admin_users).post(create_admin_user_provision),
        )
        .route("/users/{account_id}/disable", post(disable_admin_user))
        .route(
            "/users/{account_id}/reactivate",
            post(reactivate_admin_user),
        )
        .route(
            "/users/{account_id}",
            get(get_admin_user).patch(patch_admin_user),
        )
}

#[derive(Debug, Default, Deserialize)]
struct ListAdminUsersQuery {
    q: Option<String>,
    status: Option<String>,
    cursor: Option<String>,
    limit: Option<usize>,
}

fn admin_credentials_match(
    expected_username: &str,
    expected_password: &str,
    offered_username: &str,
    offered_password: &str,
) -> bool {
    fn ct_eq_bytes(left: &[u8], right: &[u8]) -> bool {
        if left.len() != right.len() {
            return false;
        }
        bool::from(left.ct_eq(right))
    }

    let username_ok = ct_eq_bytes(expected_username.as_bytes(), offered_username.as_bytes());
    let password_ok = ct_eq_bytes(expected_password.as_bytes(), offered_password.as_bytes());
    username_ok & password_ok
}

async fn create_session(
    State(state): State<AppState>,
    ExtractJson(request): ExtractJson<AdminSessionRequest>,
) -> Result<Json<AdminSessionResponse>, AppError> {
    let username = request.username.trim();
    let password = request.password.trim();
    if username.is_empty() || password.is_empty() {
        return Err(AppError::bad_request("username and password are required"));
    }

    if !admin_credentials_match(
        state.config.admin_username.as_str(),
        state.config.admin_password.as_str(),
        username,
        password,
    ) {
        return Err(AppError::unauthorized("invalid admin credentials"));
    }

    let (access_token, expires_at_unix) = state.admin_auth.issue_token(username.to_owned())?;

    Ok(Json(AdminSessionResponse {
        access_token,
        expires_at_unix,
        username: username.to_owned(),
    }))
}

async fn delete_session(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<StatusCode, AppError> {
    state.authenticate_admin_headers(&headers)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn overview(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminOverviewResponse>, AppError> {
    let principal = state.authenticate_admin_headers(&headers)?;
    let db_ok = state.db.ping().await.is_ok();
    let blob_ok = state.blob_store.root().exists();
    let health_status = if db_ok && blob_ok {
        ServiceStatus::Ok
    } else {
        ServiceStatus::Degraded
    };
    let settings = state.db.get_admin_runtime_settings().await?;
    let stats = state.db.get_admin_account_stats().await?;
    let status = match health_status {
        ServiceStatus::Ok => "ok",
        ServiceStatus::Degraded => "degraded",
    };
    Ok(Json(AdminOverviewResponse {
        status: status.to_owned(),
        service: state.build.service.to_owned(),
        version: state.build.version.to_owned(),
        git_sha: state.build.git_sha.map(str::to_owned),
        health_status,
        uptime_ms: state.started_at.elapsed().as_millis() as u64,
        allow_public_account_registration: settings.allow_public_account_registration,
        user_count: stats.user_count,
        disabled_user_count: stats.disabled_user_count,
        admin_username: principal.username,
        admin_session_expires_at_unix: principal.expires_at_unix,
    }))
}

async fn get_registration_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminRegistrationSettingsResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let settings = state.db.get_admin_runtime_settings().await?;
    Ok(Json(AdminRegistrationSettingsResponse {
        allow_public_account_registration: settings.allow_public_account_registration,
    }))
}

async fn patch_registration_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<PatchAdminRegistrationSettingsRequest>,
) -> Result<Json<AdminRegistrationSettingsResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    state
        .db
        .update_admin_runtime_settings(&UpdateAdminRuntimeSettingsInput {
            allow_public_account_registration: Some(body.allow_public_account_registration),
            ..Default::default()
        })
        .await?;
    let settings = state.db.get_admin_runtime_settings().await?;
    Ok(Json(AdminRegistrationSettingsResponse {
        allow_public_account_registration: settings.allow_public_account_registration,
    }))
}

async fn get_server_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminServerSettingsResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let settings = state.db.get_admin_runtime_settings().await?;
    Ok(Json(AdminServerSettingsResponse {
        brand_display_name: settings.brand_display_name,
        support_contact: settings.support_contact,
        policy_text: settings.policy_text,
    }))
}

async fn list_admin_users(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListAdminUsersQuery>,
) -> Result<Json<AdminUserListResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let out = state
        .db
        .list_admin_users(ListAdminUsersInput {
            query: query.q,
            status: query.status,
            cursor: query.cursor,
            limit: query.limit.unwrap_or(0),
        })
        .await?;
    Ok(Json(AdminUserListResponse {
        users: out
            .users
            .into_iter()
            .map(|u| AdminUserSummary {
                account_id: AccountId(u.account_id),
                handle: u.handle,
                profile_name: u.profile_name,
                profile_bio: u.profile_bio,
                created_at_unix: u.created_at_unix,
                disabled: u.disabled,
            })
            .collect(),
        next_cursor: out.next_cursor,
    }))
}

async fn get_admin_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<AccountId>,
) -> Result<Json<AdminUserSummary>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let u = state
        .db
        .get_admin_user(account_id.0)
        .await?
        .ok_or_else(|| AppError::not_found("account not found"))?;
    Ok(Json(AdminUserSummary {
        account_id: AccountId(u.account_id),
        handle: u.handle,
        profile_name: u.profile_name,
        profile_bio: u.profile_bio,
        created_at_unix: u.created_at_unix,
        disabled: u.disabled,
    }))
}

async fn disable_admin_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<AccountId>,
    body: Bytes,
) -> Result<StatusCode, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let parsed: AdminDisableAccountRequest = if body.is_empty() {
        AdminDisableAccountRequest::default()
    } else {
        serde_json::from_slice(&body).map_err(|_| AppError::bad_request("invalid request body"))?
    };
    let reason = parsed
        .reason
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    state.db.disable_account(account_id.0, reason).await?;
    let device_ids = state
        .db
        .list_active_device_ids_for_account(account_id.0)
        .await?;
    state
        .ws_registry
        .close_many(&device_ids, "account disabled")
        .await;
    Ok(StatusCode::NO_CONTENT)
}

async fn reactivate_admin_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<AccountId>,
) -> Result<StatusCode, AppError> {
    state.authenticate_admin_headers(&headers)?;
    state.db.reactivate_account(account_id.0).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn patch_admin_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(account_id): Path<AccountId>,
    ExtractJson(body): ExtractJson<PatchAdminUserRequest>,
) -> Result<Json<AdminUserSummary>, AppError> {
    state.authenticate_admin_headers(&headers)?;

    let handle = match &body.handle {
        None => None,
        Some(None) => Some(None),
        Some(Some(h)) => Some(Some(normalize_admin_handle(Some(h.clone()))?.ok_or_else(
            || AppError::bad_request("handle must not be empty when provided"),
        )?)),
    };

    let profile_name = match &body.profile_name {
        None => None,
        Some(name) => Some(normalize_admin_profile_name(name.clone())?),
    };

    let profile_bio = body.profile_bio.clone();

    let patch = PatchAdminAccountInput {
        handle,
        profile_name,
        profile_bio,
    };

    if patch.handle.is_none() && patch.profile_name.is_none() && patch.profile_bio.is_none() {
        return Err(AppError::bad_request(
            "at least one profile field must be provided",
        ));
    }

    let u = state
        .db
        .update_admin_account_profile(account_id.0, &patch)
        .await?
        .ok_or_else(|| AppError::not_found("account not found"))?;

    Ok(Json(AdminUserSummary {
        account_id: AccountId(u.account_id),
        handle: u.handle,
        profile_name: u.profile_name,
        profile_bio: u.profile_bio,
        created_at_unix: u.created_at_unix,
        disabled: u.disabled,
    }))
}

async fn create_admin_user_provision(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<CreateAdminUserProvisionRequest>,
) -> Result<Json<CreateAdminUserProvisionResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let profile_name = normalize_admin_profile_name(body.profile_name.clone())?;
    let handle = normalize_admin_handle(body.handle.clone())?;
    let profile_bio = body.profile_bio.clone();
    let created = state
        .db
        .create_admin_user_provision(CreateAdminUserProvisionInput {
            handle: handle.clone(),
            profile_name: profile_name.clone(),
            profile_bio: profile_bio.clone(),
            ttl_seconds: body.ttl_seconds,
        })
        .await?;
    Ok(Json(CreateAdminUserProvisionResponse {
        provision_id: created.provision_id.to_string(),
        provision_token: created.plaintext_token,
        expires_at_unix: created.expires_at_unix,
        profile_name,
        handle,
        profile_bio,
    }))
}

fn normalize_admin_handle(handle: Option<String>) -> Result<Option<String>, AppError> {
    let Some(handle) = handle else {
        return Ok(None);
    };
    let trimmed = handle.trim();
    if trimmed.is_empty() {
        return Ok(None);
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

fn normalize_admin_profile_name(profile_name: String) -> Result<String, AppError> {
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

async fn patch_server_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
    ExtractJson(body): ExtractJson<PatchAdminServerSettingsRequest>,
) -> Result<Json<AdminServerSettingsResponse>, AppError> {
    state.authenticate_admin_headers(&headers)?;
    let mut input = UpdateAdminRuntimeSettingsInput::default();
    if body.brand_display_name.is_some() {
        input.brand_display_name = body.brand_display_name;
    }
    if body.support_contact.is_some() {
        input.support_contact = body.support_contact;
    }
    if body.policy_text.is_some() {
        input.policy_text = body.policy_text;
    }
    state.db.update_admin_runtime_settings(&input).await?;
    let settings = state.db.get_admin_runtime_settings().await?;
    Ok(Json(AdminServerSettingsResponse {
        brand_display_name: settings.brand_display_name,
        support_contact: settings.support_contact,
        policy_text: settings.policy_text,
    }))
}

#[cfg(test)]
mod tests {
    use std::{env, time::Duration};

    use axum::{
        Router,
        body::Body,
        body::to_bytes,
        http::{Method, Request, StatusCode, header},
        response::Response,
    };
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use ed25519_dalek::Signer;
    use rand::RngCore;
    use serde_json::json;
    use tower::ServiceExt;
    use trix_types::{
        AdminOverviewResponse, AdminRegistrationSettingsResponse, AdminSessionResponse,
        AdminUserListResponse, AdminUserSummary, CreateAccountResponse,
        CreateAdminUserProvisionResponse,
    };
    use uuid::Uuid;

    use super::*;
    use crate::{
        admin_auth::AdminAuthManager, app::build_router, auth::AuthManager, blobs::LocalBlobStore,
        build::BuildInfo, config::AppConfig, db::Database, test_support::POSTGRES_TEST_LOCK,
    };

    const TEST_CONSUMER_JWT_KEY: &str = "trix-admin-routes-test-consumer-jwt-key";
    const TEST_ADMIN_JWT_KEY: &str = "trix-admin-routes-test-admin-jwt-key";
    const DEFAULT_TEST_DATABASE_URL: &str = "postgres://trix:trix@localhost:5432/trix";

    fn test_app() -> Router {
        let database_url = "postgres://127.0.0.1:65534/trix_admin_route_tests_offline";
        let db = Database::connect_lazy_without_migrations(database_url)
            .expect("lazy postgres pool (no server required until first query)");
        let blob_root =
            std::env::temp_dir().join(format!("trix-admin-route-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&blob_root).expect("blob root");

        let bind_addr: std::net::SocketAddr = "127.0.0.1:0".parse().unwrap();
        let config = AppConfig {
            bind_addr,
            public_base_url: "http://127.0.0.1:8080".to_owned(),
            database_url: database_url.to_owned(),
            blob_root,
            blob_max_upload_bytes: 1024,
            log_filter: "error".to_owned(),
            jwt_signing_key: TEST_CONSUMER_JWT_KEY.to_owned(),
            admin_username: "ops-admin".to_owned(),
            admin_password: "ops-admin-secret".to_owned(),
            admin_jwt_signing_key: TEST_ADMIN_JWT_KEY.to_owned(),
            admin_session_ttl_seconds: 900,
            cors_allowed_origins: Vec::new(),
            rate_limit_window_seconds: 60,
            rate_limit_auth_challenge_limit: 100,
            rate_limit_auth_session_limit: 100,
            rate_limit_link_intents_limit: 100,
            rate_limit_directory_limit: 100,
            rate_limit_blob_upload_limit: 100,
            cleanup_interval_seconds: 300,
            auth_challenge_retention_seconds: 3600,
            link_intent_retention_seconds: 86400,
            transfer_bundle_retention_seconds: 86400,
            history_sync_retention_seconds: 604800,
            pending_blob_retention_seconds: 86400,
            shutdown_grace_period_seconds: 1,
            apns_team_id: None,
            apns_key_id: None,
            apns_topic: None,
            apns_private_key_pem: None,
        };

        let auth = AuthManager::new(&config.jwt_signing_key);
        let blob_store = LocalBlobStore::new(&config.blob_root).expect("blob store");
        let state =
            AppState::new(config, BuildInfo::current(), db, auth, blob_store).expect("app state");
        build_router(state).expect("router")
    }

    async fn reset_admin_route_test_db(db: &Database) {
        sqlx::query("TRUNCATE TABLE admin_user_provisions, accounts CASCADE")
            .execute(db.pool())
            .await
            .unwrap();

        sqlx::query("DELETE FROM admin_runtime_settings")
            .execute(db.pool())
            .await
            .unwrap();

        sqlx::query(
            "INSERT INTO admin_runtime_settings (singleton) VALUES (TRUE) ON CONFLICT (singleton) DO NOTHING",
        )
        .execute(db.pool())
        .await
        .unwrap();
    }

    async fn test_app_with_db() -> Router {
        let database_url = env::var("TRIX_TEST_DATABASE_URL")
            .unwrap_or_else(|_| DEFAULT_TEST_DATABASE_URL.to_owned());
        let db = Database::connect(&database_url)
            .await
            .expect("connect test database for admin route tests");
        reset_admin_route_test_db(&db).await;

        let blob_root =
            std::env::temp_dir().join(format!("trix-admin-route-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&blob_root).expect("blob root");

        let bind_addr: std::net::SocketAddr = "127.0.0.1:0".parse().unwrap();
        let config = AppConfig {
            bind_addr,
            public_base_url: "http://127.0.0.1:8080".to_owned(),
            database_url: database_url.clone(),
            blob_root,
            blob_max_upload_bytes: 1024,
            log_filter: "error".to_owned(),
            jwt_signing_key: TEST_CONSUMER_JWT_KEY.to_owned(),
            admin_username: "ops-admin".to_owned(),
            admin_password: "ops-admin-secret".to_owned(),
            admin_jwt_signing_key: TEST_ADMIN_JWT_KEY.to_owned(),
            admin_session_ttl_seconds: 900,
            cors_allowed_origins: Vec::new(),
            rate_limit_window_seconds: 60,
            rate_limit_auth_challenge_limit: 100,
            rate_limit_auth_session_limit: 100,
            rate_limit_link_intents_limit: 100,
            rate_limit_directory_limit: 100,
            rate_limit_blob_upload_limit: 100,
            cleanup_interval_seconds: 300,
            auth_challenge_retention_seconds: 3600,
            link_intent_retention_seconds: 86400,
            transfer_bundle_retention_seconds: 86400,
            history_sync_retention_seconds: 604800,
            pending_blob_retention_seconds: 86400,
            shutdown_grace_period_seconds: 1,
            apns_team_id: None,
            apns_key_id: None,
            apns_topic: None,
            apns_private_key_pem: None,
        };

        let auth = AuthManager::new(&config.jwt_signing_key);
        let blob_store = LocalBlobStore::new(&config.blob_root).expect("blob store");
        let state =
            AppState::new(config, BuildInfo::current(), db, auth, blob_store).expect("app state");
        build_router(state).expect("router")
    }

    async fn admin_json(
        app: &Router,
        method: Method,
        uri: &str,
        token: &str,
        body: serde_json::Value,
    ) -> Response {
        let body = serde_json::to_vec(&body).unwrap();
        app.clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap()
    }

    async fn admin_empty(app: &Router, method: Method, uri: &str, token: &str) -> Response {
        app.clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap()
    }

    async fn read_json_body<T: serde::de::DeserializeOwned>(response: Response) -> T {
        let bytes = to_bytes(response.into_body(), 65_536).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    fn bootstrap_create_account_json(
        handle: Option<&str>,
        profile_name: &str,
        provision_token: Option<&str>,
    ) -> serde_json::Value {
        let mut rng = rand::rng();
        let mut secret = [0u8; 32];
        rng.fill_bytes(&mut secret);
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&secret);
        let mut transport = [0u8; 32];
        rng.fill_bytes(&mut transport);
        let credential_identity: Vec<u8> = format!("ci-{}", Uuid::new_v4()).into_bytes();
        let message =
            crate::signatures::account_bootstrap_message(&transport, &credential_identity);
        let signature = signing_key.sign(&message);
        let mut v = json!({
            "profile_name": profile_name,
            "profile_bio": serde_json::Value::Null,
            "device_display_name": "test device",
            "platform": "test",
            "credential_identity_b64": STANDARD.encode(&credential_identity),
            "account_root_pubkey_b64": STANDARD.encode(signing_key.verifying_key().to_bytes()),
            "account_root_signature_b64": STANDARD.encode(signature.to_bytes()),
            "transport_pubkey_b64": STANDARD.encode(transport),
        });
        match handle {
            Some(h) => {
                v["handle"] = json!(h);
            }
            None => {
                v["handle"] = serde_json::Value::Null;
            }
        }
        if let Some(t) = provision_token {
            v["provision_token"] = json!(t);
        }
        v
    }

    async fn post_public_json(app: &Router, uri: &str, body: serde_json::Value) -> Response {
        let body = serde_json::to_vec(&body).unwrap();
        app.clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri(uri)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap()
    }

    fn issue_consumer_token_for_tests(_app: &Router) -> String {
        let manager = AuthManager::new(TEST_CONSUMER_JWT_KEY);
        let (token, _) = manager
            .issue_token(Uuid::new_v4(), Uuid::new_v4())
            .expect("consumer token");
        token
    }

    fn issue_admin_token_for_tests(_app: &Router) -> String {
        let manager = AdminAuthManager::new(TEST_ADMIN_JWT_KEY, Duration::from_secs(900));
        manager
            .issue_token("ops".to_owned())
            .expect("admin token")
            .0
    }

    #[tokio::test]
    #[ignore = "requires local postgres"]
    async fn admin_users_route_lists_empty_registry() {
        let _db_guard = POSTGRES_TEST_LOCK.lock().await;
        let app = test_app_with_db().await;
        let admin_token = issue_admin_token_for_tests(&app);
        let response = admin_empty(&app, Method::GET, "/v0/admin/users", &admin_token).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: AdminUserListResponse = read_json_body(response).await;
        assert!(body.users.is_empty());
        assert_eq!(body.next_cursor, None);
    }

    #[tokio::test]
    #[ignore = "requires local postgres"]
    async fn admin_users_route_creates_provision_with_token() {
        let _db_guard = POSTGRES_TEST_LOCK.lock().await;
        let app = test_app_with_db().await;
        let admin_token = issue_admin_token_for_tests(&app);
        let response = admin_json(
            &app,
            Method::POST,
            "/v0/admin/users",
            &admin_token,
            json!({
                "profile_name": "Ops User",
                "ttl_seconds": 7200,
                "handle": "opsuser"
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: CreateAdminUserProvisionResponse = read_json_body(response).await;
        assert!(!body.provision_token.is_empty());
        assert_eq!(body.profile_name, "Ops User");
    }

    /// Replaces the prior DB-only consume test: proves `POST /v0/accounts` with a valid bootstrap
    /// payload and provision token when public registration is off.
    #[tokio::test]
    #[ignore = "requires local postgres"]
    async fn provision_token_allows_account_bootstrap_when_public_registration_is_disabled() {
        let _db_guard = POSTGRES_TEST_LOCK.lock().await;
        let app = test_app_with_db().await;
        let admin_token = issue_admin_token_for_tests(&app);

        let patch_reg = admin_json(
            &app,
            Method::PATCH,
            "/v0/admin/settings/registration",
            &admin_token,
            json!({ "allow_public_account_registration": false }),
        )
        .await;
        assert_eq!(patch_reg.status(), StatusCode::OK);

        let prov_resp = admin_json(
            &app,
            Method::POST,
            "/v0/admin/users",
            &admin_token,
            json!({
                "profile_name": "Provisioned Alice",
                "ttl_seconds": 86400,
                "handle": "alice"
            }),
        )
        .await;
        assert_eq!(prov_resp.status(), StatusCode::OK);
        let provision: CreateAdminUserProvisionResponse = read_json_body(prov_resp).await;

        let reject = post_public_json(
            &app,
            "/v0/accounts",
            bootstrap_create_account_json(Some("alice"), "ignored", None),
        )
        .await;
        assert_eq!(reject.status(), StatusCode::BAD_REQUEST);

        let ok = post_public_json(
            &app,
            "/v0/accounts",
            bootstrap_create_account_json(
                Some("alice"),
                "ignored",
                Some(&provision.provision_token),
            ),
        )
        .await;
        assert_eq!(ok.status(), StatusCode::OK);
        let created: CreateAccountResponse = read_json_body(ok).await;

        let get_u = admin_empty(
            &app,
            Method::GET,
            &format!("/v0/admin/users/{}", created.account_id.0),
            &admin_token,
        )
        .await;
        assert_eq!(get_u.status(), StatusCode::OK);
        let profile: AdminUserSummary = read_json_body(get_u).await;
        assert_eq!(profile.profile_name, "Provisioned Alice");
        assert_eq!(profile.handle.as_deref(), Some("alice"));
    }

    #[tokio::test]
    #[ignore = "requires local postgres"]
    async fn admin_users_route_get_patch_list_query_pagination() {
        let _db_guard = POSTGRES_TEST_LOCK.lock().await;
        let app = test_app_with_db().await;
        let admin_token = issue_admin_token_for_tests(&app);

        for (handle, profile) in [
            ("alice", "Alice Primary"),
            ("bob", "Bob Primary"),
            ("carol", "Carol Primary"),
        ] {
            let r = post_public_json(
                &app,
                "/v0/accounts",
                bootstrap_create_account_json(Some(handle), profile, None),
            )
            .await;
            assert_eq!(r.status(), StatusCode::OK, "create {handle}");
        }

        let p1 = admin_empty(&app, Method::GET, "/v0/admin/users?limit=2", &admin_token).await;
        assert_eq!(p1.status(), StatusCode::OK);
        let first: AdminUserListResponse = read_json_body(p1).await;
        assert_eq!(first.users.len(), 2);
        let cursor = first
            .next_cursor
            .clone()
            .expect("pagination cursor after partial page");

        let p2 = admin_empty(
            &app,
            Method::GET,
            &format!("/v0/admin/users?limit=2&cursor={cursor}"),
            &admin_token,
        )
        .await;
        assert_eq!(p2.status(), StatusCode::OK);
        let second: AdminUserListResponse = read_json_body(p2).await;
        assert_eq!(second.users.len(), 1);
        assert_eq!(second.users[0].handle.as_deref(), Some("alice"));

        let q = admin_empty(
            &app,
            Method::GET,
            "/v0/admin/users?q=bo&status=active&limit=10",
            &admin_token,
        )
        .await;
        assert_eq!(q.status(), StatusCode::OK);
        let filtered: AdminUserListResponse = read_json_body(q).await;
        assert_eq!(filtered.users.len(), 1);
        assert_eq!(filtered.users[0].handle.as_deref(), Some("bob"));

        let bob_id = filtered.users[0].account_id.0;
        let patch = admin_json(
            &app,
            Method::PATCH,
            &format!("/v0/admin/users/{bob_id}"),
            &admin_token,
            json!({ "profile_name": "Bob Updated" }),
        )
        .await;
        assert_eq!(patch.status(), StatusCode::OK);
        let updated: AdminUserSummary = read_json_body(patch).await;
        assert_eq!(updated.profile_name, "Bob Updated");

        let get_bob = admin_empty(
            &app,
            Method::GET,
            &format!("/v0/admin/users/{bob_id}"),
            &admin_token,
        )
        .await;
        assert_eq!(get_bob.status(), StatusCode::OK);
        let fetched: AdminUserSummary = read_json_body(get_bob).await;
        assert_eq!(fetched.profile_name, "Bob Updated");
    }

    #[tokio::test]
    #[ignore = "requires local postgres"]
    async fn admin_can_toggle_public_registration_and_read_it_back() {
        let _db_guard = POSTGRES_TEST_LOCK.lock().await;
        let app = test_app_with_db().await;
        let admin_token = issue_admin_token_for_tests(&app);

        let patch = serde_json::json!({
            "allow_public_account_registration": false
        });

        let patch_response = admin_json(
            &app,
            Method::PATCH,
            "/v0/admin/settings/registration",
            &admin_token,
            patch,
        )
        .await;
        assert_eq!(patch_response.status(), StatusCode::OK);

        let get_response = admin_empty(
            &app,
            Method::GET,
            "/v0/admin/settings/registration",
            &admin_token,
        )
        .await;
        assert_eq!(get_response.status(), StatusCode::OK);

        let body: AdminRegistrationSettingsResponse = read_json_body(get_response).await;
        assert!(!body.allow_public_account_registration);
    }

    #[tokio::test]
    #[ignore = "requires local postgres"]
    async fn overview_reports_user_count_and_registration_state() {
        let _db_guard = POSTGRES_TEST_LOCK.lock().await;
        let app = test_app_with_db().await;
        let admin_token = issue_admin_token_for_tests(&app);

        let response = admin_empty(&app, Method::GET, "/v0/admin/overview", &admin_token).await;
        assert_eq!(response.status(), StatusCode::OK);

        let body: AdminOverviewResponse = read_json_body(response).await;
        assert_eq!(body.user_count, 0);
        assert!(body.allow_public_account_registration);
    }

    #[tokio::test]
    async fn admin_routes_reject_consumer_bearer_tokens() {
        let app = test_app();
        let consumer_token = issue_consumer_token_for_tests(&app);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/v0/admin/overview")
                    .header(header::AUTHORIZATION, format!("Bearer {consumer_token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn consumer_routes_reject_admin_bearer_tokens() {
        let app = test_app();
        let admin_token = issue_admin_token_for_tests(&app);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/v0/accounts/me")
                    .header(header::AUTHORIZATION, format!("Bearer {admin_token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn admin_session_rejects_invalid_credentials() {
        let app = test_app();
        let body =
            serde_json::to_vec(&json!({ "username": "ops-admin", "password": "wrong-password" }))
                .unwrap();

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/v0/admin/session")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn admin_session_accepts_valid_credentials_without_database() {
        let app = test_app();
        let body =
            serde_json::to_vec(&json!({ "username": "ops-admin", "password": "ops-admin-secret" }))
                .unwrap();

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/v0/admin/session")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 65_536).await.unwrap();
        let parsed: AdminSessionResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.username, "ops-admin");
        assert!(!parsed.access_token.is_empty());
    }
}
