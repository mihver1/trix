use std::{
    env,
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::{Path as AxumPath, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post, put},
};
use reqwest::Client;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt},
    sync::Mutex,
};
use tracing::warn;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() -> Result<()> {
    let config = AdminConfig::from_env()?;

    tracing_subscriber::registry()
        .with(EnvFilter::new(config.log_filter.clone()))
        .with(fmt::layer())
        .init();

    let bind_addr = config.bind_addr;
    let state = AdminState {
        config: Arc::new(config),
        http: Client::builder()
            .build()
            .context("failed to build HTTP client")?,
        flags_lock: Arc::new(Mutex::new(())),
        audit_lock: Arc::new(Mutex::new(())),
    };

    let router = admin_router(state);
    let listener = tokio::net::TcpListener::bind(bind_addr)
        .await
        .with_context(|| format!("failed to bind {bind_addr}"))?;
    tracing::info!("trix-admin-api listening on {}", bind_addr);
    axum::serve(listener, router).await?;
    Ok(())
}

fn admin_router(state: AdminState) -> Router {
    Router::new()
        .route("/v1/system/health", get(health))
        .route("/v1/feature-flags/snapshot", get(client_feature_flags))
        .route("/v1/admin/session", get(admin_session))
        .route("/v1/admin/users", get(search_users).post(provision_user))
        .route(
            "/v1/admin/users/{localpart}/reset-password",
            post(reset_password),
        )
        .route("/v1/admin/users/{localpart}/disable", post(disable_user))
        .route("/v1/admin/users/{localpart}/enable", post(enable_user))
        .route("/v1/admin/push/test/wake", post(send_test_wake_push))
        .route("/v1/admin/push/test/voip", post(send_test_voip_push))
        .route("/v1/admin/media/storage", get(media_storage))
        .route("/v1/admin/ops/status", get(ops_status))
        .route("/v1/admin/metrics/summary", get(metrics_summary))
        .route("/v1/admin/logs/recent", get(recent_logs))
        .route("/v1/admin/audit/recent", get(recent_audit))
        .route(
            "/v1/admin/feature-flags",
            get(admin_feature_flags).post(create_feature_flag),
        )
        .route(
            "/v1/admin/feature-flags/{key}",
            put(update_feature_flag).delete(delete_feature_flag),
        )
        .with_state(state)
}

#[derive(Clone)]
struct AdminState {
    config: Arc<AdminConfig>,
    http: Client,
    flags_lock: Arc<Mutex<()>>,
    audit_lock: Arc<Mutex<()>>,
}

#[derive(Clone)]
struct AdminConfig {
    bind_addr: SocketAddr,
    log_filter: String,
    admin_token: String,
    xmpp_api_url: String,
    xmpp_host: String,
    push_gateway_url: String,
    push_gateway_token: Option<String>,
    upload_dir: PathBuf,
    feature_flags_path: PathBuf,
    audit_log_path: PathBuf,
    log_dir: Option<PathBuf>,
    max_log_bytes: usize,
}

impl AdminConfig {
    fn from_env() -> Result<Self> {
        let bind_addr = SocketAddr::from_str(&env_or("TRIX_ADMIN_BIND_ADDR", "127.0.0.1:8093")?)
            .context("invalid TRIX_ADMIN_BIND_ADDR")?;
        let admin_token = env_required("TRIX_ADMIN_API_TOKEN")?;
        validate_deployment_secret("TRIX_ADMIN_API_TOKEN", &admin_token)?;

        let push_gateway_token = env::var("TRIX_PUSH_GATEWAY_TOKEN")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if let Some(token) = push_gateway_token.as_deref() {
            validate_deployment_secret("TRIX_PUSH_GATEWAY_TOKEN", token)?;
        }

        let log_dir = env::var("TRIX_ADMIN_LOG_DIR")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let xmpp_api_url = env_or("TRIX_XMPP_API_URL", "http://127.0.0.1:5280/api")?;
        let push_gateway_url = env_or("TRIX_PUSH_GATEWAY_URL", "http://127.0.0.1:8090")?;

        validate_bind_addr(bind_addr)?;
        validate_private_service_url("TRIX_XMPP_API_URL", &xmpp_api_url, &["ejabberd"])?;
        validate_private_service_url(
            "TRIX_PUSH_GATEWAY_URL",
            &push_gateway_url,
            &["push-gateway"],
        )?;

        Ok(Self {
            bind_addr,
            log_filter: env_or("TRIX_ADMIN_LOG", "info,trix_admin_api=debug")?,
            admin_token,
            xmpp_api_url,
            xmpp_host: env_or("TRIX_XMPP_HOST", "trix.selfhost.ru")?,
            push_gateway_url,
            push_gateway_token,
            upload_dir: PathBuf::from(env_or(
                "TRIX_ADMIN_UPLOAD_DIR",
                "/var/lib/trix-admin-api/upload",
            )?),
            feature_flags_path: PathBuf::from(env_or(
                "TRIX_FEATURE_FLAGS_PATH",
                "/var/lib/trix-admin-api/feature-flags.json",
            )?),
            audit_log_path: PathBuf::from(env_or(
                "TRIX_ADMIN_AUDIT_LOG_PATH",
                "/var/lib/trix-admin-api/audit.jsonl",
            )?),
            log_dir,
            max_log_bytes: env_or("TRIX_ADMIN_MAX_LOG_BYTES", "262144")?
                .parse()
                .context("invalid TRIX_ADMIN_MAX_LOG_BYTES")?,
        })
    }
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        service: "trix-admin-api",
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

async fn admin_session(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<AdminSessionResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;

    Ok(Json(AdminSessionResponse {
        role: "operator",
        server_time_unix: unix_now(),
        capabilities: vec![
            "users",
            "test_pushes",
            "media_storage",
            "metrics",
            "logs",
            "audit",
            "feature_flags",
        ],
    }))
}

async fn search_users(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Query(query): Query<UserSearchQuery>,
) -> Result<Json<UserSearchResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;

    let registered = ejabberd_post::<Vec<String>>(
        &state,
        "registered_users",
        json!({ "host": state.config.xmpp_host }),
    )
    .await?;
    let needle = query.query.unwrap_or_default().trim().to_ascii_lowercase();
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let mut users = Vec::new();

    for localpart in registered {
        if !needle.is_empty()
            && !localpart.to_ascii_lowercase().contains(&needle)
            && !format!("{}@{}", localpart, state.config.xmpp_host).contains(&needle)
        {
            continue;
        }

        users.push(AdminUser {
            localpart: localpart.clone(),
            jid: format!("{}@{}", localpart, state.config.xmpp_host),
            display_name: None,
            status: "unknown".to_owned(),
        });
        if users.len() >= limit {
            break;
        }
    }

    Ok(Json(UserSearchResponse { users }))
}

async fn provision_user(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Json(request): Json<ProvisionUserRequest>,
) -> Result<Json<UserMutationResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let localpart = normalize_localpart(&request.localpart)?;
    validate_password(&request.password)?;

    ejabberd_post::<Value>(
        &state,
        "register",
        json!({
            "user": localpart,
            "host": state.config.xmpp_host,
            "password": request.password
        }),
    )
    .await?;
    audit_action(
        &state,
        actor,
        "user.provision",
        format!("{}@{}", localpart, state.config.xmpp_host),
        "success",
        None,
    )
    .await;

    Ok(Json(UserMutationResponse {
        jid: format!("{}@{}", localpart, state.config.xmpp_host),
        changed: true,
    }))
}

async fn reset_password(
    State(state): State<AdminState>,
    headers: HeaderMap,
    AxumPath(localpart): AxumPath<String>,
    Json(request): Json<PasswordRequest>,
) -> Result<Json<UserMutationResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let localpart = normalize_localpart(&localpart)?;
    validate_password(&request.password)?;

    ejabberd_post::<Value>(
        &state,
        "change_password",
        json!({
            "user": localpart,
            "host": state.config.xmpp_host,
            "newpass": request.password
        }),
    )
    .await?;
    audit_action(
        &state,
        actor,
        "user.reset_password",
        format!("{}@{}", localpart, state.config.xmpp_host),
        "success",
        None,
    )
    .await;

    Ok(Json(UserMutationResponse {
        jid: format!("{}@{}", localpart, state.config.xmpp_host),
        changed: true,
    }))
}

async fn disable_user(
    State(state): State<AdminState>,
    headers: HeaderMap,
    AxumPath(localpart): AxumPath<String>,
    Json(request): Json<DisableUserRequest>,
) -> Result<Json<UserMutationResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let localpart = normalize_localpart(&localpart)?;
    let reason = request
        .reason
        .unwrap_or_else(|| "disabled by Trix operator".to_owned());

    ejabberd_post::<Value>(
        &state,
        "ban_account",
        json!({
            "user": localpart,
            "host": state.config.xmpp_host,
            "reason": reason
        }),
    )
    .await?;
    audit_action(
        &state,
        actor,
        "user.disable",
        format!("{}@{}", localpart, state.config.xmpp_host),
        "success",
        Some("reason redacted".to_owned()),
    )
    .await;

    Ok(Json(UserMutationResponse {
        jid: format!("{}@{}", localpart, state.config.xmpp_host),
        changed: true,
    }))
}

async fn enable_user(
    State(state): State<AdminState>,
    headers: HeaderMap,
    AxumPath(localpart): AxumPath<String>,
) -> Result<Json<UserMutationResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let localpart = normalize_localpart(&localpart)?;

    ejabberd_post::<Value>(
        &state,
        "unban_account",
        json!({
            "user": localpart,
            "host": state.config.xmpp_host
        }),
    )
    .await?;
    audit_action(
        &state,
        actor,
        "user.enable",
        format!("{}@{}", localpart, state.config.xmpp_host),
        "success",
        None,
    )
    .await;

    Ok(Json(UserMutationResponse {
        jid: format!("{}@{}", localpart, state.config.xmpp_host),
        changed: true,
    }))
}

async fn send_test_wake_push(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Json(request): Json<TestWakePushRequest>,
) -> Result<Json<Value>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let audit_target = request
        .account
        .as_deref()
        .or(request.room.as_deref())
        .unwrap_or("apns-token-redacted")
        .to_owned();
    let token =
        state
            .config
            .push_gateway_token
            .as_deref()
            .ok_or(AdminError::DependencyDisabled(
                "push gateway token is not configured",
            ))?;

    let response = proxy_push_request(
        &state,
        token,
        "/v0/apns/wake",
        json!({
            "token_hex": request.token_hex,
            "environment": request.environment,
            "account": request.account,
            "room": request.room,
            "badge": request.badge,
        }),
    )
    .await?;
    audit_action(
        &state,
        actor,
        "push.test_wake",
        audit_target,
        "success",
        Some("apns token redacted".to_owned()),
    )
    .await;
    Ok(response)
}

async fn send_test_voip_push(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Json(request): Json<TestVoipPushRequest>,
) -> Result<Json<Value>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let audit_target = request.account.clone();
    let token =
        state
            .config
            .push_gateway_token
            .as_deref()
            .ok_or(AdminError::DependencyDisabled(
                "push gateway token is not configured",
            ))?;

    let response = proxy_push_request(
        &state,
        token,
        "/v0/apns/voip/call",
        json!({
            "account": request.account,
            "call_id": request.call_id,
        }),
    )
    .await?;
    audit_action(
        &state,
        actor,
        "push.test_voip",
        audit_target,
        "success",
        Some("call id redacted".to_owned()),
    )
    .await;
    Ok(response)
}

async fn media_storage(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<MediaStorageResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    Ok(Json(media_storage_snapshot(&state.config.upload_dir)))
}

async fn ops_status(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<OpsStatusResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    Ok(Json(OpsStatusResponse {
        ejabberd_api: dependency_status(
            ejabberd_post::<Value>(&state, "status", json!({}))
                .await
                .is_ok(),
        ),
        push_gateway: dependency_status(push_gateway_health(&state).await),
        media_storage: media_storage_snapshot(&state.config.upload_dir).status,
    }))
}

async fn metrics_summary(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<MetricsSummaryResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let flags = load_flag_store(&state.config.feature_flags_path).await?;
    let media = media_storage_snapshot(&state.config.upload_dir);

    Ok(Json(MetricsSummaryResponse {
        checked_at_unix: unix_now(),
        enabled_feature_flags: flags.flags.iter().filter(|flag| flag.enabled).count(),
        total_feature_flags: flags.flags.len(),
        media_total_bytes: media.total_bytes,
        media_file_count: media.file_count,
        ejabberd_api_reachable: ejabberd_post::<Value>(&state, "status", json!({}))
            .await
            .is_ok(),
        push_gateway_reachable: push_gateway_health(&state).await,
    }))
}

async fn recent_logs(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Query(query): Query<LogsQuery>,
) -> Result<Json<RecentLogsResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let service = validate_service_name(query.service.as_deref().unwrap_or("trix-admin-api"))?;
    let Some(log_dir) = &state.config.log_dir else {
        return Ok(Json(RecentLogsResponse {
            service,
            status: "unavailable",
            lines: Vec::new(),
        }));
    };

    let path = log_dir.join(format!("{service}.log"));
    let bytes = read_log_tail(&path, state.config.max_log_bytes).await?;
    let text = String::from_utf8_lossy(&bytes);
    let limit = query.limit.unwrap_or(200).clamp(1, 1000);
    let mut lines = text
        .lines()
        .rev()
        .take(limit)
        .map(sanitize_log_line)
        .collect::<Vec<_>>();
    lines.reverse();

    Ok(Json(RecentLogsResponse {
        service,
        status: "ok",
        lines,
    }))
}

async fn recent_audit(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Query(query): Query<AuditQuery>,
) -> Result<Json<RecentAuditResponse>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let limit = query.limit.unwrap_or(200).clamp(1, 1000);
    let events = read_recent_audit_events(&state.config.audit_log_path, limit).await?;
    Ok(Json(RecentAuditResponse {
        status: if events.is_empty() { "empty" } else { "ok" },
        events,
    }))
}

async fn admin_feature_flags(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<FeatureFlagSnapshot>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    Ok(Json(
        load_flag_store(&state.config.feature_flags_path).await?,
    ))
}

async fn client_feature_flags(
    State(state): State<AdminState>,
) -> Result<Json<FeatureFlagSnapshot>, AdminError> {
    let store = load_flag_store(&state.config.feature_flags_path).await?;
    Ok(Json(FeatureFlagSnapshot {
        version: store.version,
        updated_at_unix: store.updated_at_unix,
        flags: store
            .flags
            .into_iter()
            .filter(|flag| flag.client_visible)
            .collect(),
    }))
}

async fn create_feature_flag(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Json(request): Json<FeatureFlagUpdateRequest>,
) -> Result<Json<FeatureFlagSnapshot>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let key = validate_flag_key(&request.key)?;
    write_feature_flag(state, actor, key, request).await
}

async fn update_feature_flag(
    State(state): State<AdminState>,
    headers: HeaderMap,
    AxumPath(key): AxumPath<String>,
    Json(mut request): Json<FeatureFlagUpdateRequest>,
) -> Result<Json<FeatureFlagSnapshot>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let key = validate_flag_key(&key)?;
    request.key = key.clone();
    write_feature_flag(state, actor, key, request).await
}

async fn delete_feature_flag(
    State(state): State<AdminState>,
    headers: HeaderMap,
    AxumPath(key): AxumPath<String>,
) -> Result<Json<FeatureFlagSnapshot>, AdminError> {
    authorize_admin(&headers, &state.config)?;
    let actor = actor_from_headers(&headers);
    let key = validate_flag_key(&key)?;
    let _guard = state.flags_lock.lock().await;
    let mut store = load_flag_store(&state.config.feature_flags_path).await?;
    store.flags.retain(|flag| flag.key != key);
    store.version += 1;
    store.updated_at_unix = unix_now();
    save_flag_store(&state.config.feature_flags_path, &store).await?;
    audit_action(&state, actor, "feature_flag.delete", key, "success", None).await;
    Ok(Json(store))
}

async fn write_feature_flag(
    state: AdminState,
    actor: String,
    key: String,
    request: FeatureFlagUpdateRequest,
) -> Result<Json<FeatureFlagSnapshot>, AdminError> {
    validate_rollout_percentage(request.rollout_percentage)?;
    if let Some(description) = request.description.as_deref() {
        if description.len() > 1000 {
            return Err(AdminError::BadRequest(
                "description must be at most 1000 bytes".to_owned(),
            ));
        }
    }

    let _guard = state.flags_lock.lock().await;
    let mut store = load_flag_store(&state.config.feature_flags_path).await?;
    let now = unix_now();
    let flag = FeatureFlag {
        key: key.clone(),
        enabled: request.enabled,
        rollout_percentage: request.rollout_percentage,
        client_visible: request.client_visible,
        description: request.description.unwrap_or_default(),
        updated_at_unix: now,
    };

    let action = if let Some(existing) = store.flags.iter_mut().find(|flag| flag.key == key) {
        *existing = flag;
        "feature_flag.update"
    } else {
        store.flags.push(flag);
        store.flags.sort_by(|left, right| left.key.cmp(&right.key));
        "feature_flag.create"
    };
    store.version += 1;
    store.updated_at_unix = now;
    save_flag_store(&state.config.feature_flags_path, &store).await?;
    audit_action(&state, actor, action, key, "success", None).await;
    Ok(Json(store))
}

async fn ejabberd_post<T: DeserializeOwned>(
    state: &AdminState,
    command: &str,
    payload: Value,
) -> Result<T, AdminError> {
    let url = format!(
        "{}/{}",
        state.config.xmpp_api_url.trim_end_matches('/'),
        command
    );
    let response = state
        .http
        .post(url)
        .json(&payload)
        .send()
        .await
        .map_err(|_| AdminError::BackendUnavailable("ejabberd api unavailable"))?;
    if !response.status().is_success() {
        return Err(AdminError::BackendUnavailable(
            "ejabberd api rejected request",
        ));
    }
    let body = response
        .bytes()
        .await
        .map_err(|_| AdminError::BackendUnavailable("ejabberd api response was invalid"))?;
    decode_ejabberd_response(&body)
}

async fn proxy_push_request(
    state: &AdminState,
    token: &str,
    path: &str,
    payload: Value,
) -> Result<Json<Value>, AdminError> {
    let response = state
        .http
        .post(format!(
            "{}{}",
            state.config.push_gateway_url.trim_end_matches('/'),
            path
        ))
        .bearer_auth(token)
        .json(&payload)
        .send()
        .await
        .map_err(|_| AdminError::BackendUnavailable("push gateway unavailable"))?;
    let status = response.status();
    let body = response
        .json::<Value>()
        .await
        .unwrap_or_else(|_| json!({ "status": status.as_u16() }));
    if !status.is_success() {
        return Err(AdminError::BadGateway(body));
    }
    Ok(Json(body))
}

async fn push_gateway_health(state: &AdminState) -> bool {
    state
        .http
        .get(format!(
            "{}/v0/system/health",
            state.config.push_gateway_url.trim_end_matches('/')
        ))
        .send()
        .await
        .map(|response| response.status().is_success())
        .unwrap_or(false)
}

fn media_storage_snapshot(root: &Path) -> MediaStorageResponse {
    match directory_usage(root) {
        Ok(usage) => MediaStorageResponse {
            status: "ok",
            root_path: root.display().to_string(),
            total_bytes: usage.total_bytes,
            file_count: usage.file_count,
            newest_modified_unix: usage.newest_modified_unix,
        },
        Err(_) => MediaStorageResponse {
            status: "unavailable",
            root_path: root.display().to_string(),
            total_bytes: 0,
            file_count: 0,
            newest_modified_unix: None,
        },
    }
}

fn directory_usage(root: &Path) -> std::io::Result<DirectoryUsage> {
    let mut usage = DirectoryUsage::default();
    visit_directory(root, &mut usage)?;
    Ok(usage)
}

fn visit_directory(path: &Path, usage: &mut DirectoryUsage) -> std::io::Result<()> {
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            visit_directory(&entry.path(), usage)?;
        } else if metadata.is_file() {
            usage.file_count += 1;
            usage.total_bytes += metadata.len();
            if let Ok(modified) = metadata.modified() {
                let modified = unix_time(modified);
                usage.newest_modified_unix = usage.newest_modified_unix.max(Some(modified));
            }
        }
    }
    Ok(())
}

async fn read_log_tail(path: &Path, max_bytes: usize) -> Result<Vec<u8>, AdminError> {
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|_| AdminError::NotFound)?;
    let length = file
        .metadata()
        .await
        .map_err(|_| AdminError::NotFound)?
        .len();
    let max_bytes = u64::try_from(max_bytes).unwrap_or(u64::MAX);
    let start = length.saturating_sub(max_bytes);
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(|_| AdminError::InvalidState)?;

    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .await
        .map_err(|_| AdminError::InvalidState)?;
    Ok(bytes)
}

async fn load_flag_store(path: &Path) -> Result<FeatureFlagSnapshot, AdminError> {
    match tokio::fs::read(path).await {
        Ok(data) => serde_json::from_slice(&data).map_err(|_| AdminError::InvalidState),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(FeatureFlagSnapshot {
            version: 1,
            updated_at_unix: 0,
            flags: default_feature_flags(),
        }),
        Err(_) => Err(AdminError::InvalidState),
    }
}

async fn save_flag_store(path: &Path, store: &FeatureFlagSnapshot) -> Result<(), AdminError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|_| AdminError::InvalidState)?;
    }
    let data = serde_json::to_vec_pretty(store).map_err(|_| AdminError::InvalidState)?;
    let tmp = path.with_extension("json.tmp");
    tokio::fs::write(&tmp, data)
        .await
        .map_err(|_| AdminError::InvalidState)?;
    tokio::fs::rename(&tmp, path)
        .await
        .map_err(|_| AdminError::InvalidState)?;
    Ok(())
}

async fn audit_action(
    state: &AdminState,
    actor: String,
    action: &'static str,
    target: String,
    outcome: &'static str,
    detail: Option<String>,
) {
    let event = AuditEvent {
        timestamp_unix: unix_now(),
        actor,
        action: action.to_owned(),
        target: sanitize_audit_text(&target),
        outcome: outcome.to_owned(),
        detail: detail.map(|value| sanitize_audit_text(&value)),
    };

    let _guard = state.audit_lock.lock().await;
    if let Err(error) = append_audit_event(&state.config.audit_log_path, &event).await {
        warn!(?error, action, "failed to write admin audit event");
    }
}

async fn append_audit_event(path: &Path, event: &AuditEvent) -> Result<(), AdminError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|_| AdminError::InvalidState)?;
    }

    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await
        .map_err(|_| AdminError::InvalidState)?;
    let line = serde_json::to_vec(event).map_err(|_| AdminError::InvalidState)?;
    file.write_all(&line)
        .await
        .map_err(|_| AdminError::InvalidState)?;
    file.write_all(b"\n")
        .await
        .map_err(|_| AdminError::InvalidState)?;
    Ok(())
}

async fn read_recent_audit_events(
    path: &Path,
    limit: usize,
) -> Result<Vec<AuditEvent>, AdminError> {
    let data = match tokio::fs::read(path).await {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err(AdminError::InvalidState),
    };
    let text = String::from_utf8_lossy(&data);
    let mut events = text
        .lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<AuditEvent>(line).ok())
        .take(limit)
        .collect::<Vec<_>>();
    events.reverse();
    Ok(events)
}

fn decode_ejabberd_response<T: DeserializeOwned>(body: &[u8]) -> Result<T, AdminError> {
    let body = trim_ascii_bytes(body);
    let body = if body.is_empty() || body == br#""""# {
        b"null".as_slice()
    } else {
        body
    };
    serde_json::from_slice(body)
        .map_err(|_| AdminError::BackendUnavailable("ejabberd api response was invalid"))
}

fn trim_ascii_bytes(value: &[u8]) -> &[u8] {
    let mut start = 0;
    let mut end = value.len();
    while start < end && value[start].is_ascii_whitespace() {
        start += 1;
    }
    while end > start && value[end - 1].is_ascii_whitespace() {
        end -= 1;
    }
    &value[start..end]
}

fn default_feature_flags() -> Vec<FeatureFlag> {
    vec![
        FeatureFlag {
            key: "admin.users".to_owned(),
            enabled: true,
            rollout_percentage: 100,
            client_visible: false,
            description: "Enables user-management controls in the Trix admin app.".to_owned(),
            updated_at_unix: 0,
        },
        FeatureFlag {
            key: "client.calls.encrypted_media".to_owned(),
            enabled: false,
            rollout_percentage: 0,
            client_visible: true,
            description: "Gates signed-device encrypted media-call surfaces.".to_owned(),
            updated_at_unix: 0,
        },
    ]
}

fn authorize_admin(headers: &HeaderMap, config: &AdminConfig) -> Result<(), AdminError> {
    let Some(header) = headers.get(header::AUTHORIZATION) else {
        return Err(AdminError::Unauthorized);
    };
    let Ok(value) = header.to_str() else {
        return Err(AdminError::Unauthorized);
    };
    let Some(token) = value.strip_prefix("Bearer ") else {
        return Err(AdminError::Unauthorized);
    };
    if token != config.admin_token {
        return Err(AdminError::Unauthorized);
    }
    Ok(())
}

fn actor_from_headers(headers: &HeaderMap) -> String {
    headers
        .get("x-trix-operator")
        .and_then(|value| value.to_str().ok())
        .map(sanitize_actor)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "operator".to_owned())
}

fn normalize_localpart(value: &str) -> Result<String, AdminError> {
    let value = value.trim().to_ascii_lowercase();
    if value.is_empty()
        || value.len() > 128
        || value.contains('@')
        || value.contains('/')
        || value.contains(':')
        || value.chars().any(char::is_whitespace)
    {
        return Err(AdminError::BadRequest(
            "localpart must be a bare local XMPP username".to_owned(),
        ));
    }
    Ok(value)
}

fn validate_password(value: &str) -> Result<(), AdminError> {
    if value.len() < 12 {
        return Err(AdminError::BadRequest(
            "password must be at least 12 bytes".to_owned(),
        ));
    }
    Ok(())
}

fn validate_flag_key(value: &str) -> Result<String, AdminError> {
    let key = value.trim().to_ascii_lowercase();
    let valid = !key.is_empty()
        && key.len() <= 80
        && key.chars().all(|ch| {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '.' | '_' | '-')
        })
        && key.chars().any(|ch| ch.is_ascii_alphabetic());
    if !valid {
        return Err(AdminError::BadRequest(
            "feature flag key must be lowercase ascii, digits, dot, dash, or underscore".to_owned(),
        ));
    }
    Ok(key)
}

fn validate_rollout_percentage(value: u8) -> Result<(), AdminError> {
    if value > 100 {
        return Err(AdminError::BadRequest(
            "rollout_percentage must be between 0 and 100".to_owned(),
        ));
    }
    Ok(())
}

fn validate_service_name(value: &str) -> Result<String, AdminError> {
    let value = value.trim();
    let valid = !value.is_empty()
        && value.len() <= 80
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'));
    if !valid {
        return Err(AdminError::BadRequest(
            "service must be a simple service name".to_owned(),
        ));
    }
    Ok(value.to_owned())
}

fn sanitize_actor(value: &str) -> String {
    let actor = value.trim();
    let valid = !actor.is_empty()
        && actor.len() <= 120
        && actor
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '@' | '.' | '_' | '-' | '+'));
    if valid {
        actor.to_owned()
    } else {
        "operator".to_owned()
    }
}

fn sanitize_audit_text(value: &str) -> String {
    let lowered = value.to_ascii_lowercase();
    if [
        "password",
        "token",
        "secret",
        "private_key",
        "authorization",
        "sasl",
        "omemo",
        "apns",
        "credential",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
    {
        return "[redacted]".to_owned();
    }
    value.chars().take(240).collect()
}

fn sanitize_log_line(value: &str) -> String {
    let lowered = value.to_ascii_lowercase();
    if [
        "password",
        "token",
        "secret",
        "private_key",
        "authorization",
        "sasl",
        "omemo",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
    {
        return "[redacted sensitive log line]".to_owned();
    }
    value.chars().take(2000).collect()
}

fn dependency_status(ok: bool) -> &'static str {
    if ok { "ok" } else { "unavailable" }
}

fn unix_now() -> u64 {
    unix_time(SystemTime::now())
}

fn unix_time(value: SystemTime) -> u64 {
    value
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn validate_bind_addr(bind_addr: SocketAddr) -> Result<()> {
    validate_bind_addr_with_override(bind_addr, env_flag("TRIX_ADMIN_ALLOW_NON_LOOPBACK_BIND"))
}

fn validate_bind_addr_with_override(bind_addr: SocketAddr, allow_non_loopback: bool) -> Result<()> {
    if bind_addr.ip().is_loopback() || allow_non_loopback {
        return Ok(());
    }
    anyhow::bail!(
        "TRIX_ADMIN_BIND_ADDR must be loopback unless TRIX_ADMIN_ALLOW_NON_LOOPBACK_BIND=1"
    );
}

fn validate_private_service_url(key: &str, value: &str, allowed_hosts: &[&str]) -> Result<()> {
    validate_private_service_url_with_override(
        key,
        value,
        allowed_hosts,
        env_flag("TRIX_ADMIN_ALLOW_NON_PRIVATE_UPSTREAMS"),
    )
}

fn validate_private_service_url_with_override(
    key: &str,
    value: &str,
    allowed_hosts: &[&str],
    allow_non_private: bool,
) -> Result<()> {
    if allow_non_private {
        return Ok(());
    }

    let url = reqwest::Url::parse(value).with_context(|| format!("invalid {key}"))?;
    if url.username() != "" || url.password().is_some() {
        anyhow::bail!("{key} must not contain URL credentials");
    }
    match url.scheme() {
        "http" | "https" => {}
        _ => anyhow::bail!("{key} must use http or https"),
    }

    let Some(host) = url.host_str() else {
        anyhow::bail!("{key} must include a host");
    };
    let host = host.trim_matches(['[', ']']).to_ascii_lowercase();
    if host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
        || allowed_hosts.iter().any(|allowed| *allowed == host)
    {
        return Ok(());
    }

    anyhow::bail!(
        "{key} must point to loopback or an allowed private Compose service host unless TRIX_ADMIN_ALLOW_NON_PRIVATE_UPSTREAMS=1"
    );
}

fn validate_deployment_secret(key: &str, value: &str) -> Result<()> {
    let value = value.trim();
    if is_insecure_default_secret(value) || value.len() < 32 {
        anyhow::bail!("{key} must be a non-default secret of at least 32 bytes");
    }
    Ok(())
}

fn env_flag(key: &str) -> bool {
    matches!(env::var(key).as_deref(), Ok("1") | Ok("true") | Ok("TRUE"))
}

fn env_or(key: &str, default: &str) -> Result<String> {
    Ok(env::var(key).unwrap_or_else(|_| default.to_owned()))
}

fn env_required(key: &str) -> Result<String> {
    env::var(key).with_context(|| format!("{key} is required"))
}

fn is_insecure_default_secret(value: &str) -> bool {
    matches!(
        value.trim(),
        "" | "replace-me"
            | "change-me"
            | "deployment-local-token"
            | "dev-local-admin-api-token-change-me"
            | "dev-local-push-gateway-token-change-me"
            | "dev-local-push-component-secret-change-me"
    )
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    service: &'static str,
    status: &'static str,
    version: &'static str,
}

#[derive(Debug, Serialize)]
struct AdminSessionResponse {
    role: &'static str,
    server_time_unix: u64,
    capabilities: Vec<&'static str>,
}

#[derive(Debug, Deserialize)]
struct UserSearchQuery {
    query: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct UserSearchResponse {
    users: Vec<AdminUser>,
}

#[derive(Debug, Serialize)]
struct AdminUser {
    localpart: String,
    jid: String,
    display_name: Option<String>,
    status: String,
}

#[derive(Debug, Deserialize)]
struct ProvisionUserRequest {
    localpart: String,
    password: String,
}

#[derive(Debug, Deserialize)]
struct PasswordRequest {
    password: String,
}

#[derive(Debug, Deserialize)]
struct DisableUserRequest {
    reason: Option<String>,
}

#[derive(Debug, Serialize)]
struct UserMutationResponse {
    jid: String,
    changed: bool,
}

#[derive(Debug, Deserialize)]
struct TestWakePushRequest {
    token_hex: String,
    environment: String,
    account: Option<String>,
    room: Option<String>,
    badge: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct TestVoipPushRequest {
    account: String,
    call_id: String,
}

#[derive(Debug, Serialize)]
struct MediaStorageResponse {
    status: &'static str,
    root_path: String,
    total_bytes: u64,
    file_count: u64,
    newest_modified_unix: Option<u64>,
}

#[derive(Default)]
struct DirectoryUsage {
    total_bytes: u64,
    file_count: u64,
    newest_modified_unix: Option<u64>,
}

#[derive(Debug, Serialize)]
struct OpsStatusResponse {
    ejabberd_api: &'static str,
    push_gateway: &'static str,
    media_storage: &'static str,
}

#[derive(Debug, Serialize)]
struct MetricsSummaryResponse {
    checked_at_unix: u64,
    enabled_feature_flags: usize,
    total_feature_flags: usize,
    media_total_bytes: u64,
    media_file_count: u64,
    ejabberd_api_reachable: bool,
    push_gateway_reachable: bool,
}

#[derive(Debug, Deserialize)]
struct LogsQuery {
    service: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct RecentLogsResponse {
    service: String,
    status: &'static str,
    lines: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct AuditQuery {
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct RecentAuditResponse {
    status: &'static str,
    events: Vec<AuditEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct AuditEvent {
    timestamp_unix: u64,
    actor: String,
    action: String,
    target: String,
    outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FeatureFlagSnapshot {
    version: u64,
    updated_at_unix: u64,
    flags: Vec<FeatureFlag>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FeatureFlag {
    key: String,
    enabled: bool,
    rollout_percentage: u8,
    client_visible: bool,
    description: String,
    updated_at_unix: u64,
}

#[derive(Debug, Deserialize)]
struct FeatureFlagUpdateRequest {
    key: String,
    enabled: bool,
    rollout_percentage: u8,
    #[serde(default = "default_true")]
    client_visible: bool,
    #[serde(default)]
    description: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug)]
enum AdminError {
    Unauthorized,
    BadRequest(String),
    NotFound,
    DependencyDisabled(&'static str),
    BackendUnavailable(&'static str),
    BadGateway(Value),
    InvalidState,
}

impl IntoResponse for AdminError {
    fn into_response(self) -> Response {
        let (status, code, message, extra) = match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "missing or invalid admin authorization".to_owned(),
                None,
            ),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message, None),
            Self::NotFound => (
                StatusCode::NOT_FOUND,
                "not_found",
                "requested admin resource was not found".to_owned(),
                None,
            ),
            Self::DependencyDisabled(message) => (
                StatusCode::PRECONDITION_FAILED,
                "dependency_disabled",
                message.to_owned(),
                None,
            ),
            Self::BackendUnavailable(message) => (
                StatusCode::BAD_GATEWAY,
                "backend_unavailable",
                message.to_owned(),
                None,
            ),
            Self::BadGateway(value) => (
                StatusCode::BAD_GATEWAY,
                "bad_gateway",
                "upstream request failed".to_owned(),
                Some(value),
            ),
            Self::InvalidState => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "invalid_state",
                "admin api state is unavailable".to_owned(),
                None,
            ),
        };

        (
            status,
            Json(ErrorResponse {
                code,
                message,
                upstream: extra,
            }),
        )
            .into_response()
    }
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    code: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    upstream: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unsafe_localparts() {
        assert!(normalize_localpart("alice").is_ok());
        assert!(normalize_localpart("Alice").is_ok());
        assert!(normalize_localpart("alice@trix.selfhost.ru").is_err());
        assert!(normalize_localpart("alice/phone").is_err());
        assert!(normalize_localpart("alice phone").is_err());
    }

    #[test]
    fn validates_feature_flag_keys() {
        assert_eq!(
            validate_flag_key("Client.Calls-Enabled_1").unwrap(),
            "client.calls-enabled_1"
        );
        assert!(validate_flag_key("123").is_err());
        assert!(validate_flag_key("client calls").is_err());
        assert!(validate_flag_key("").is_err());
    }

    #[test]
    fn redacts_sensitive_log_lines() {
        assert_eq!(
            sanitize_log_line("Authorization: Bearer abc"),
            "[redacted sensitive log line]"
        );
        assert_eq!(sanitize_log_line("ejabberd_api=ok"), "ejabberd_api=ok");
    }

    #[test]
    fn validates_admin_secret_and_private_urls() {
        assert!(
            validate_deployment_secret("TRIX_ADMIN_API_TOKEN", "deployment-local-token").is_err()
        );
        assert!(validate_deployment_secret("TRIX_ADMIN_API_TOKEN", "short").is_err());
        assert!(
            validate_deployment_secret("TRIX_ADMIN_API_TOKEN", "0123456789abcdef0123456789abcdef")
                .is_ok()
        );
        assert!(
            validate_private_service_url_with_override(
                "TRIX_XMPP_API_URL",
                "http://127.0.0.1:5280/api",
                &["ejabberd"],
                false
            )
            .is_ok()
        );
        assert!(
            validate_private_service_url_with_override(
                "TRIX_XMPP_API_URL",
                "http://ejabberd:5280/api",
                &["ejabberd"],
                false
            )
            .is_ok()
        );
        assert!(
            validate_private_service_url_with_override(
                "TRIX_XMPP_API_URL",
                "https://example.com/api",
                &["ejabberd"],
                false
            )
            .is_err()
        );
        assert!(validate_bind_addr_with_override("127.0.0.1:8093".parse().unwrap(), false).is_ok());
        assert!(validate_bind_addr_with_override("0.0.0.0:8093".parse().unwrap(), false).is_err());
        assert!(validate_bind_addr_with_override("0.0.0.0:8093".parse().unwrap(), true).is_ok());
    }

    #[test]
    fn accepts_empty_ejabberd_success_for_value_routes() {
        assert_eq!(decode_ejabberd_response::<Value>(b"").unwrap(), Value::Null);
        assert_eq!(
            decode_ejabberd_response::<Value>(br#""""#).unwrap(),
            Value::Null
        );
        assert_eq!(
            decode_ejabberd_response::<Value>(br#"{"status":"ok"}"#).unwrap(),
            json!({ "status": "ok" })
        );
    }

    #[test]
    fn sanitizes_audit_text_and_actor_headers() {
        assert_eq!(
            sanitize_audit_text("password reset for alice"),
            "[redacted]"
        );
        assert_eq!(
            sanitize_audit_text("alice@trix.selfhost.ru"),
            "alice@trix.selfhost.ru"
        );
        assert_eq!(
            sanitize_actor("ops+alice@trix.selfhost.ru"),
            "ops+alice@trix.selfhost.ru"
        );
        assert_eq!(sanitize_actor("bad actor"), "operator");
    }

    #[tokio::test]
    async fn audit_log_round_trips_recent_events() {
        let path = env::temp_dir().join(format!(
            "trix-admin-audit-test-{}-{}.jsonl",
            std::process::id(),
            unix_now()
        ));
        let first = AuditEvent {
            timestamp_unix: 1,
            actor: "operator".to_owned(),
            action: "user.enable".to_owned(),
            target: "alice@trix.selfhost.ru".to_owned(),
            outcome: "success".to_owned(),
            detail: None,
        };
        let second = AuditEvent {
            timestamp_unix: 2,
            actor: "operator".to_owned(),
            action: "feature_flag.update".to_owned(),
            target: "client.calls.encrypted_media".to_owned(),
            outcome: "success".to_owned(),
            detail: None,
        };

        append_audit_event(&path, &first).await.unwrap();
        append_audit_event(&path, &second).await.unwrap();

        let events = read_recent_audit_events(&path, 1).await.unwrap();
        assert_eq!(events, vec![second]);

        let _ = tokio::fs::remove_file(path).await;
    }

    #[tokio::test]
    async fn reads_only_log_tail() {
        let path = env::temp_dir().join(format!(
            "trix-admin-log-tail-test-{}-{}.log",
            std::process::id(),
            unix_now()
        ));
        tokio::fs::write(&path, b"first\nsecond\nthird\n")
            .await
            .unwrap();

        let tail = read_log_tail(&path, 13).await.unwrap();
        assert_eq!(String::from_utf8(tail).unwrap(), "second\nthird\n");

        let _ = tokio::fs::remove_file(path).await;
    }
}
