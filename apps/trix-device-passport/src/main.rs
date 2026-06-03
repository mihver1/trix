use std::{
    env,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::PathBuf,
    str::FromStr,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose};
use reqwest::Client;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::Mutex;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};
use uuid::Uuid;

const DEFAULT_APPROVAL_TTL_SECONDS: u64 = 10 * 60;
const MAX_BODY_TEXT_BYTES: usize = 256;
const MAX_QUERY_LIMIT: i64 = 500;

#[tokio::main]
async fn main() -> Result<()> {
    let config = DevicePassportConfig::from_env()?;

    tracing_subscriber::registry()
        .with(EnvFilter::new(config.log_filter.clone()))
        .with(fmt::layer())
        .init();

    let bind_addr = config.bind_addr;
    let store = DevicePassportStore::open(config.database_path.clone())?;
    let state = DevicePassportState {
        config: Arc::new(config),
        http: Client::builder()
            .build()
            .context("failed to build HTTP client")?,
        store: Arc::new(Mutex::new(store)),
    };

    let listener = tokio::net::TcpListener::bind(bind_addr)
        .await
        .with_context(|| format!("failed to bind {bind_addr}"))?;
    tracing::info!("trix-device-passport listening on {}", bind_addr);
    axum::serve(listener, device_passport_router(state)).await?;
    Ok(())
}

fn device_passport_router(state: DevicePassportState) -> Router {
    Router::new()
        .route("/v1/system/health", get(health))
        .route(
            "/v1/device-passport/current-device",
            post(upsert_current_device),
        )
        .route("/v1/device-passport/state", get(passport_state))
        .route(
            "/v1/device-passport/approval-requests",
            post(create_approval_request),
        )
        .route(
            "/v1/device-passport/approval-requests/{request_id}/approve",
            post(approve_request),
        )
        .route(
            "/v1/device-passport/approval-requests/{request_id}/decline",
            post(decline_request),
        )
        .route(
            "/v1/device-passport/directory-claims",
            get(directory_claims),
        )
        .route(
            "/v1/device-passport/notices/{user_id}/dismiss",
            post(dismiss_notice),
        )
        .route(
            "/v1/operator/device-passport/{user_id}/reset",
            post(operator_reset),
        )
        .with_state(state)
}

#[derive(Clone)]
struct DevicePassportState {
    config: Arc<DevicePassportConfig>,
    http: Client,
    store: Arc<Mutex<DevicePassportStore>>,
}

#[derive(Clone)]
struct DevicePassportConfig {
    bind_addr: SocketAddr,
    log_filter: String,
    database_path: PathBuf,
    xmpp_api_url: String,
    xmpp_host: String,
    operator_token: Option<String>,
    approval_ttl_seconds: u64,
    dry_run_auth: bool,
}

impl DevicePassportConfig {
    fn from_env() -> Result<Self> {
        let bind_addr =
            SocketAddr::from_str(&env_or("TRIX_DEVICE_PASSPORT_BIND_ADDR", "127.0.0.1:8094")?)
                .context("invalid TRIX_DEVICE_PASSPORT_BIND_ADDR")?;
        validate_bind_addr(bind_addr)?;

        let operator_token = env::var("TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if let Some(token) = operator_token.as_deref() {
            validate_deployment_secret("TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN", token)?;
        }

        Ok(Self {
            bind_addr,
            log_filter: env_or(
                "TRIX_DEVICE_PASSPORT_LOG",
                "info,trix_device_passport=debug",
            )?,
            database_path: PathBuf::from(env_or(
                "TRIX_DEVICE_PASSPORT_DB_PATH",
                "/var/lib/trix-device-passport/device-passport.sqlite",
            )?),
            xmpp_api_url: env_or("TRIX_XMPP_API_URL", "http://127.0.0.1:5280/api")?,
            xmpp_host: env_or("TRIX_XMPP_HOST", "trix.selfhost.ru")?,
            operator_token,
            approval_ttl_seconds: env_or(
                "TRIX_DEVICE_PASSPORT_APPROVAL_TTL_SECONDS",
                &DEFAULT_APPROVAL_TTL_SECONDS.to_string(),
            )?
            .parse()
            .context("invalid TRIX_DEVICE_PASSPORT_APPROVAL_TTL_SECONDS")?,
            dry_run_auth: env_truthy("TRIX_DEVICE_PASSPORT_DRY_RUN_AUTH"),
        })
    }
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        service: "trix-device-passport",
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

async fn upsert_current_device(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Json(request): Json<CurrentDeviceRequest>,
) -> Result<Json<CurrentDeviceResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let normalized = request.normalized(&account.bare_jid, &state.config.xmpp_host)?;
    let mut store = state.store.lock().await;
    let device = store.upsert_current_device(&normalized)?;
    store.audit(
        "device.upsert",
        &account.bare_jid,
        Some(&device.device_id),
        "normal",
        json!({
            "platform": device.platform,
            "app_version_present": device.app_version.is_some(),
        }),
    )?;

    Ok(Json(CurrentDeviceResponse { device }))
}

async fn passport_state(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
) -> Result<Json<PassportStateResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let device_id = device_id_header(&headers)?;
    let mut store = state.store.lock().await;
    let response = store.passport_state(&account.bare_jid, device_id.as_deref())?;
    Ok(Json(response))
}

async fn create_approval_request(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Json(request): Json<CreateApprovalRequest>,
) -> Result<Json<ApprovalRequestResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let device_id = normalize_device_id(&request.device_id)?;
    let now = unix_now();
    let expires_at = now + state.config.approval_ttl_seconds as i64;
    let mut store = state.store.lock().await;
    let approval = store.create_approval_request(&account.bare_jid, &device_id, expires_at)?;
    store.audit(
        "approval.requested",
        &account.bare_jid,
        Some(&device_id),
        "normal",
        json!({ "approval_request_id": approval.id, "expires_at_unix": approval.expires_at_unix }),
    )?;

    Ok(Json(ApprovalRequestResponse { approval }))
}

async fn approve_request(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Path(request_id): Path<String>,
    Json(request): Json<ApproveRequest>,
) -> Result<Json<ApproveResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let request_id = normalize_identifier(&request_id, "request_id", 128)?;
    let approver_device_id = normalize_device_id(&request.approver_device_id)?;
    let mut store = state.store.lock().await;
    let response = store.approve_request(&account.bare_jid, &request_id, &approver_device_id)?;
    store.audit(
        "approval.approved",
        &account.bare_jid,
        Some(&response.device.device_id),
        "normal",
        json!({
            "approval_request_id": request_id,
            "approver_device_id": approver_device_id,
            "claim_id": response.claim.id,
        }),
    )?;

    Ok(Json(response))
}

async fn decline_request(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Path(request_id): Path<String>,
    Json(request): Json<DeclineRequest>,
) -> Result<Json<ApprovalRequestResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let request_id = normalize_identifier(&request_id, "request_id", 128)?;
    let approver_device_id = normalize_device_id(&request.approver_device_id)?;
    let mut store = state.store.lock().await;
    let approval = store.decline_request(&account.bare_jid, &request_id, &approver_device_id)?;
    store.audit(
        "approval.declined",
        &account.bare_jid,
        Some(&approval.device_id),
        "normal",
        json!({
            "approval_request_id": approval.id,
            "approver_device_id": approver_device_id,
        }),
    )?;

    Ok(Json(ApprovalRequestResponse { approval }))
}

async fn directory_claims(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Query(query): Query<ClaimsQuery>,
) -> Result<Json<DirectoryClaimsResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let since = query.since.unwrap_or(0).max(0);
    let limit = query.limit.unwrap_or(100).clamp(1, MAX_QUERY_LIMIT);
    let store = state.store.lock().await;
    let (claims, next_cursor) = store.directory_claims(&account.bare_jid, since, limit)?;
    Ok(Json(DirectoryClaimsResponse {
        recipient_user_id: account.bare_jid,
        claims,
        next_cursor,
    }))
}

async fn dismiss_notice(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
    Json(request): Json<DismissNoticeRequest>,
) -> Result<Json<DismissNoticeResponse>, PassportError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let target_user_id = normalize_local_jid(&target_user_id, &state.config.xmpp_host)?;
    let severity = request.severity.unwrap_or(NoticeSeverity::Normal);
    let mut store = state.store.lock().await;
    store.dismiss_notice(&account.bare_jid, &target_user_id, severity)?;
    Ok(Json(DismissNoticeResponse {
        recipient_user_id: account.bare_jid,
        target_user_id,
        severity,
        dismissed_at_unix: unix_now(),
    }))
}

async fn operator_reset(
    State(state): State<DevicePassportState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Json(request): Json<OperatorResetRequest>,
) -> Result<Json<OperatorResetResponse>, PassportError> {
    authorize_operator(&state, &headers)?;
    let user_id = normalize_local_jid(&user_id, &state.config.xmpp_host)?;
    let normalized = request.normalized(&user_id)?;
    let mut store = state.store.lock().await;
    let response = store.operator_reset(&user_id, normalized)?;
    store.audit(
        "operator.reset",
        &user_id,
        response
            .root_device
            .as_ref()
            .map(|device| device.device_id.as_str()),
        "high",
        json!({ "generation": response.generation, "claim_id": response.claim.id }),
    )?;

    Ok(Json(response))
}

struct DevicePassportStore {
    connection: Connection,
}

impl DevicePassportStore {
    fn open(path: PathBuf) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let connection =
            Connection::open(path).context("failed to open device-passport database")?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    #[cfg(test)]
    fn open_memory() -> Result<Self> {
        let store = Self {
            connection: Connection::open_in_memory()
                .context("failed to open in-memory device-passport database")?,
        };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        self.connection.execute_batch(
            "
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS trust_generations (
                user_id TEXT PRIMARY KEY,
                generation INTEGER NOT NULL,
                origin TEXT NOT NULL,
                created_at_unix INTEGER NOT NULL,
                reset_at_unix INTEGER
            );
            CREATE TABLE IF NOT EXISTS devices (
                user_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                generation INTEGER NOT NULL,
                state TEXT NOT NULL,
                device_label TEXT NOT NULL,
                platform TEXT NOT NULL,
                fingerprint_hash TEXT NOT NULL,
                app_version TEXT,
                first_seen_at_unix INTEGER NOT NULL,
                last_seen_at_unix INTEGER NOT NULL,
                approved_at_unix INTEGER,
                approved_by_device_id TEXT,
                revoked_at_unix INTEGER,
                PRIMARY KEY (user_id, device_id)
            );
            CREATE INDEX IF NOT EXISTS idx_devices_user_state ON devices(user_id, state);
            CREATE TABLE IF NOT EXISTS approval_requests (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                generation INTEGER NOT NULL,
                challenge TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at_unix INTEGER NOT NULL,
                expires_at_unix INTEGER NOT NULL,
                decided_at_unix INTEGER,
                decided_by_device_id TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_approval_requests_user_status
                ON approval_requests(user_id, status, expires_at_unix);
            CREATE TABLE IF NOT EXISTS directory_claims (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                generation INTEGER NOT NULL,
                kind TEXT NOT NULL,
                severity TEXT NOT NULL,
                fingerprint_hash TEXT NOT NULL,
                proof_required INTEGER NOT NULL,
                created_at_unix INTEGER NOT NULL,
                approved_by_device_id TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_directory_claims_cursor ON directory_claims(id);
            CREATE TABLE IF NOT EXISTS notice_dismissals (
                recipient_user_id TEXT NOT NULL,
                target_user_id TEXT NOT NULL,
                severity TEXT NOT NULL,
                dismissed_at_unix INTEGER NOT NULL,
                PRIMARY KEY (recipient_user_id, target_user_id, severity)
            );
            CREATE TABLE IF NOT EXISTS audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                action TEXT NOT NULL,
                user_id TEXT NOT NULL,
                device_id TEXT,
                severity TEXT NOT NULL,
                detail_json TEXT NOT NULL,
                created_at_unix INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_audit_events_user ON audit_events(user_id, created_at_unix);
            ",
        )?;
        Ok(())
    }

    fn upsert_current_device(
        &mut self,
        request: &NormalizedCurrentDevice,
    ) -> Result<PassportDevice, PassportError> {
        let now = unix_now();
        let generation = self.ensure_generation(&request.user_id, "initial")?;
        let existing_state = self.device_state(&request.user_id, &request.device_id)?;
        let state = existing_state.unwrap_or(DevicePassportStateKind::Pending);
        self.connection.execute(
            "
            INSERT INTO devices (
                user_id, device_id, generation, state, device_label, platform, fingerprint_hash,
                app_version, first_seen_at_unix, last_seen_at_unix
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
            ON CONFLICT(user_id, device_id) DO UPDATE SET
                device_label = excluded.device_label,
                platform = excluded.platform,
                fingerprint_hash = excluded.fingerprint_hash,
                app_version = excluded.app_version,
                last_seen_at_unix = excluded.last_seen_at_unix
            ",
            params![
                request.user_id,
                request.device_id,
                generation,
                state.as_str(),
                request.device_label,
                request.platform,
                request.fingerprint_hash,
                request.app_version,
                now,
            ],
        )?;
        self.device(&request.user_id, &request.device_id)?
            .ok_or(PassportError::Internal)
    }

    fn passport_state(
        &mut self,
        user_id: &str,
        current_device_id: Option<&str>,
    ) -> Result<PassportStateResponse, PassportError> {
        let generation = self.ensure_generation(user_id, "initial")?;
        let current_device = match current_device_id {
            Some(device_id) => self.device(user_id, device_id)?,
            None => None,
        };
        let current_approval_request = match current_device_id {
            Some(device_id) => self.active_request_for_device(user_id, device_id)?,
            None => None,
        };
        let can_approve = current_device.as_ref().is_some_and(|device| {
            matches!(
                device.state,
                DevicePassportStateKind::Approved | DevicePassportStateKind::ResetRoot
            )
        });
        let pending_approval_requests = if can_approve {
            self.pending_requests_for_approver(user_id, current_device_id)?
        } else {
            Vec::new()
        };
        Ok(PassportStateResponse {
            user_id: user_id.to_owned(),
            generation,
            current_device,
            current_approval_request,
            pending_approval_requests,
            server_state_is_trust_authority: false,
        })
    }

    fn create_approval_request(
        &mut self,
        user_id: &str,
        device_id: &str,
        expires_at_unix: i64,
    ) -> Result<ApprovalRequestRecord, PassportError> {
        let device = self
            .device(user_id, device_id)?
            .ok_or(PassportError::BadRequest(
                "current device is not registered",
            ))?;
        if !matches!(
            device.state,
            DevicePassportStateKind::Pending | DevicePassportStateKind::ApprovalRequested
        ) {
            return Err(PassportError::Conflict("device is not pending approval"));
        }
        let now = unix_now();
        if let Some(existing) = self.active_request_for_device(user_id, device_id)? {
            return Ok(existing);
        }
        let id = format!("dpa_{}", Uuid::new_v4());
        let challenge = approval_challenge(&id, device_id);
        self.connection.execute(
            "
            INSERT INTO approval_requests (
                id, user_id, device_id, generation, challenge, status,
                created_at_unix, expires_at_unix
            )
            VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6, ?7)
            ",
            params![
                id,
                user_id,
                device_id,
                device.generation,
                challenge,
                now,
                expires_at_unix
            ],
        )?;
        self.connection.execute(
            "UPDATE devices SET state = 'approval_requested', last_seen_at_unix = ?1 WHERE user_id = ?2 AND device_id = ?3",
            params![now, user_id, device_id],
        )?;
        self.approval_request(&id)?.ok_or(PassportError::Internal)
    }

    fn approve_request(
        &mut self,
        user_id: &str,
        request_id: &str,
        approver_device_id: &str,
    ) -> Result<ApproveResponse, PassportError> {
        let approver =
            self.device(user_id, approver_device_id)?
                .ok_or(PassportError::Forbidden(
                    "approver device is not registered",
                ))?;
        if !matches!(
            approver.state,
            DevicePassportStateKind::Approved | DevicePassportStateKind::ResetRoot
        ) {
            return Err(PassportError::Forbidden("approver device is not approved"));
        }
        let approval = self
            .approval_request(request_id)?
            .ok_or(PassportError::NotFound("approval request was not found"))?;
        if approval.user_id != user_id {
            return Err(PassportError::Forbidden(
                "approval request belongs to another account",
            ));
        }
        if approval.device_id == approver_device_id {
            return Err(PassportError::Forbidden("a device cannot approve itself"));
        }
        if approval.generation != approver.generation {
            return Err(PassportError::Conflict(
                "approval generation does not match",
            ));
        }
        if approval.status != ApprovalRequestStatus::Pending {
            return Err(PassportError::Conflict(
                "approval request is no longer pending",
            ));
        }
        if approval.expires_at_unix < unix_now() {
            return Err(PassportError::Gone("approval request expired"));
        }

        let now = unix_now();
        self.connection.execute(
            "
            UPDATE approval_requests
            SET status = 'approved', decided_at_unix = ?1, decided_by_device_id = ?2
            WHERE id = ?3
            ",
            params![now, approver_device_id, request_id],
        )?;
        self.connection.execute(
            "
            UPDATE devices
            SET state = 'approved', approved_at_unix = ?1, approved_by_device_id = ?2, last_seen_at_unix = ?1
            WHERE user_id = ?3 AND device_id = ?4
            ",
            params![now, approver_device_id, user_id, approval.device_id],
        )?;
        let device = self
            .device(user_id, &approval.device_id)?
            .ok_or(PassportError::Internal)?;
        let claim = self.insert_claim(
            user_id,
            &device.device_id,
            device.generation,
            DirectoryClaimKind::Approved,
            NoticeSeverity::Normal,
            &device.fingerprint_hash,
            Some(approver_device_id),
        )?;
        Ok(ApproveResponse { device, claim })
    }

    fn decline_request(
        &mut self,
        user_id: &str,
        request_id: &str,
        approver_device_id: &str,
    ) -> Result<ApprovalRequestRecord, PassportError> {
        let approver =
            self.device(user_id, approver_device_id)?
                .ok_or(PassportError::Forbidden(
                    "approver device is not registered",
                ))?;
        if !matches!(
            approver.state,
            DevicePassportStateKind::Approved | DevicePassportStateKind::ResetRoot
        ) {
            return Err(PassportError::Forbidden("approver device is not approved"));
        }
        let approval = self
            .approval_request(request_id)?
            .ok_or(PassportError::NotFound("approval request was not found"))?;
        if approval.user_id != user_id {
            return Err(PassportError::Forbidden(
                "approval request belongs to another account",
            ));
        }
        if approval.status != ApprovalRequestStatus::Pending {
            return Err(PassportError::Conflict(
                "approval request is no longer pending",
            ));
        }
        let now = unix_now();
        self.connection.execute(
            "
            UPDATE approval_requests
            SET status = 'declined', decided_at_unix = ?1, decided_by_device_id = ?2
            WHERE id = ?3
            ",
            params![now, approver_device_id, request_id],
        )?;
        self.connection.execute(
            "
            UPDATE devices SET state = 'pending', last_seen_at_unix = ?1
            WHERE user_id = ?2 AND device_id = ?3
            ",
            params![now, user_id, approval.device_id],
        )?;
        self.approval_request(request_id)?
            .ok_or(PassportError::Internal)
    }

    fn operator_reset(
        &mut self,
        user_id: &str,
        request: NormalizedOperatorReset,
    ) -> Result<OperatorResetResponse, PassportError> {
        let now = unix_now();
        let previous_generation = self.current_generation(user_id)?.unwrap_or(0);
        let generation = previous_generation + 1;
        self.connection.execute(
            "
            INSERT INTO trust_generations (user_id, generation, origin, created_at_unix, reset_at_unix)
            VALUES (?1, ?2, 'operator_reset', ?3, ?3)
            ON CONFLICT(user_id) DO UPDATE SET
                generation = excluded.generation,
                origin = excluded.origin,
                reset_at_unix = excluded.reset_at_unix
            ",
            params![user_id, generation, now],
        )?;
        self.connection.execute(
            "
            UPDATE devices
            SET state = 'revoked', revoked_at_unix = ?1
            WHERE user_id = ?2 AND state IN ('pending', 'approval_requested', 'approved', 'reset_root')
            ",
            params![now, user_id],
        )?;
        self.connection.execute(
            "
            UPDATE approval_requests
            SET status = 'expired', decided_at_unix = ?1
            WHERE user_id = ?2 AND status = 'pending'
            ",
            params![now, user_id],
        )?;

        let root_device = if let Some(root) = request.root_device {
            self.connection.execute(
                "
                INSERT INTO devices (
                    user_id, device_id, generation, state, device_label, platform, fingerprint_hash,
                    app_version, first_seen_at_unix, last_seen_at_unix, approved_at_unix
                )
                VALUES (?1, ?2, ?3, 'reset_root', ?4, ?5, ?6, ?7, ?8, ?8, ?8)
                ON CONFLICT(user_id, device_id) DO UPDATE SET
                    generation = excluded.generation,
                    state = excluded.state,
                    device_label = excluded.device_label,
                    platform = excluded.platform,
                    fingerprint_hash = excluded.fingerprint_hash,
                    app_version = excluded.app_version,
                    approved_at_unix = excluded.approved_at_unix,
                    revoked_at_unix = NULL
                ",
                params![
                    user_id,
                    root.device_id,
                    generation,
                    root.device_label,
                    root.platform,
                    root.fingerprint_hash,
                    root.app_version,
                    now,
                ],
            )?;
            self.device(user_id, &root.device_id)?
        } else {
            None
        };
        let claim_device_id = root_device
            .as_ref()
            .map(|device| device.device_id.as_str())
            .unwrap_or("operator-reset");
        let fingerprint_hash = root_device
            .as_ref()
            .map(|device| device.fingerprint_hash.as_str())
            .unwrap_or("operator-reset");
        let claim = self.insert_claim(
            user_id,
            claim_device_id,
            generation,
            DirectoryClaimKind::Reset,
            NoticeSeverity::High,
            fingerprint_hash,
            None,
        )?;

        Ok(OperatorResetResponse {
            user_id: user_id.to_owned(),
            generation,
            root_device,
            claim,
        })
    }

    fn ensure_generation(&mut self, user_id: &str, origin: &str) -> Result<i64, PassportError> {
        if let Some(generation) = self.current_generation(user_id)? {
            return Ok(generation);
        }
        let now = unix_now();
        self.connection.execute(
            "
            INSERT INTO trust_generations (user_id, generation, origin, created_at_unix)
            VALUES (?1, 1, ?2, ?3)
            ",
            params![user_id, origin, now],
        )?;
        Ok(1)
    }

    fn current_generation(&self, user_id: &str) -> Result<Option<i64>, PassportError> {
        Ok(self
            .connection
            .query_row(
                "SELECT generation FROM trust_generations WHERE user_id = ?1",
                params![user_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    fn device_state(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<Option<DevicePassportStateKind>, PassportError> {
        self.connection
            .query_row(
                "SELECT state FROM devices WHERE user_id = ?1 AND device_id = ?2",
                params![user_id, device_id],
                |row| {
                    let raw: String = row.get(0)?;
                    Ok(DevicePassportStateKind::from_db(&raw))
                },
            )
            .optional()?
            .transpose()
    }

    fn device(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<Option<PassportDevice>, PassportError> {
        self.connection
            .query_row(
                "
                SELECT user_id, device_id, generation, state, device_label, platform,
                    fingerprint_hash, app_version, first_seen_at_unix, last_seen_at_unix,
                    approved_at_unix, approved_by_device_id, revoked_at_unix
                FROM devices WHERE user_id = ?1 AND device_id = ?2
                ",
                params![user_id, device_id],
                row_to_device,
            )
            .optional()
            .map_err(PassportError::from)
    }

    fn active_request_for_device(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<Option<ApprovalRequestRecord>, PassportError> {
        self.connection
            .query_row(
                "
                SELECT id, user_id, device_id, generation, challenge, status,
                    created_at_unix, expires_at_unix, decided_at_unix, decided_by_device_id
                FROM approval_requests
                WHERE user_id = ?1 AND device_id = ?2 AND status = 'pending' AND expires_at_unix >= ?3
                ORDER BY created_at_unix DESC
                LIMIT 1
                ",
                params![user_id, device_id, unix_now()],
                row_to_approval_request,
            )
            .optional()
            .map_err(PassportError::from)
    }

    fn pending_requests_for_approver(
        &self,
        user_id: &str,
        approver_device_id: Option<&str>,
    ) -> Result<Vec<ApprovalRequestRecord>, PassportError> {
        let mut statement = self.connection.prepare(
            "
            SELECT id, user_id, device_id, generation, challenge, status,
                created_at_unix, expires_at_unix, decided_at_unix, decided_by_device_id
            FROM approval_requests
            WHERE user_id = ?1 AND status = 'pending' AND expires_at_unix >= ?2
            ORDER BY created_at_unix DESC
            LIMIT 50
            ",
        )?;
        let rows = statement.query_map(params![user_id, unix_now()], row_to_approval_request)?;
        let mut records = Vec::new();
        for row in rows {
            let record = row?;
            if approver_device_id.is_some_and(|device_id| device_id == record.device_id) {
                continue;
            }
            records.push(record);
        }
        Ok(records)
    }

    fn approval_request(&self, id: &str) -> Result<Option<ApprovalRequestRecord>, PassportError> {
        self.connection
            .query_row(
                "
                SELECT id, user_id, device_id, generation, challenge, status,
                    created_at_unix, expires_at_unix, decided_at_unix, decided_by_device_id
                FROM approval_requests WHERE id = ?1
                ",
                params![id],
                row_to_approval_request,
            )
            .optional()
            .map_err(PassportError::from)
    }

    fn insert_claim(
        &mut self,
        user_id: &str,
        device_id: &str,
        generation: i64,
        kind: DirectoryClaimKind,
        severity: NoticeSeverity,
        fingerprint_hash: &str,
        approved_by_device_id: Option<&str>,
    ) -> Result<DirectoryClaim, PassportError> {
        let now = unix_now();
        self.connection.execute(
            "
            INSERT INTO directory_claims (
                user_id, device_id, generation, kind, severity, fingerprint_hash,
                proof_required, created_at_unix, approved_by_device_id
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7, ?8)
            ",
            params![
                user_id,
                device_id,
                generation,
                kind.as_str(),
                severity.as_str(),
                fingerprint_hash,
                now,
                approved_by_device_id,
            ],
        )?;
        let id = self.connection.last_insert_rowid();
        self.claim(id)?.ok_or(PassportError::Internal)
    }

    fn claim(&self, id: i64) -> Result<Option<DirectoryClaim>, PassportError> {
        self.connection
            .query_row(
                "
                SELECT id, user_id, device_id, generation, kind, severity, fingerprint_hash,
                    proof_required, created_at_unix, approved_by_device_id
                FROM directory_claims WHERE id = ?1
                ",
                params![id],
                row_to_claim,
            )
            .optional()
            .map_err(PassportError::from)
    }

    fn directory_claims(
        &self,
        recipient_user_id: &str,
        since: i64,
        limit: i64,
    ) -> Result<(Vec<DirectoryClaim>, i64), PassportError> {
        let next_cursor = self.connection.query_row(
            "
            SELECT COALESCE(MAX(id), ?1) FROM (
                SELECT id FROM directory_claims
                WHERE id > ?1
                ORDER BY id ASC
                LIMIT ?2
            )
            ",
            params![since, limit],
            |row| row.get::<_, i64>(0),
        )?;
        let mut statement = self.connection.prepare(
            "
            WITH claim_window AS (
                SELECT id, user_id, device_id, generation, kind, severity, fingerprint_hash,
                    proof_required, created_at_unix, approved_by_device_id
                FROM directory_claims
                WHERE id > ?1
                ORDER BY id ASC
                LIMIT ?3
            )
            SELECT id, user_id, device_id, generation, kind, severity, fingerprint_hash,
                proof_required, created_at_unix, approved_by_device_id
            FROM claim_window
            WHERE NOT EXISTS (
                SELECT 1 FROM notice_dismissals
                WHERE recipient_user_id = ?2
                    AND target_user_id = claim_window.user_id
                    AND severity = claim_window.severity
            )
            ORDER BY id ASC
            ",
        )?;
        let rows = statement.query_map(params![since, recipient_user_id, limit], row_to_claim)?;
        let mut claims = Vec::new();
        for row in rows {
            claims.push(row?);
        }
        Ok((claims, next_cursor))
    }

    fn dismiss_notice(
        &mut self,
        recipient_user_id: &str,
        target_user_id: &str,
        severity: NoticeSeverity,
    ) -> Result<(), PassportError> {
        self.connection.execute(
            "
            INSERT INTO notice_dismissals (recipient_user_id, target_user_id, severity, dismissed_at_unix)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(recipient_user_id, target_user_id, severity) DO UPDATE SET
                dismissed_at_unix = excluded.dismissed_at_unix
            ",
            params![recipient_user_id, target_user_id, severity.as_str(), unix_now()],
        )?;
        Ok(())
    }

    fn audit(
        &mut self,
        action: &str,
        user_id: &str,
        device_id: Option<&str>,
        severity: &str,
        detail: Value,
    ) -> Result<(), PassportError> {
        self.connection.execute(
            "
            INSERT INTO audit_events (action, user_id, device_id, severity, detail_json, created_at_unix)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ",
            params![
                action,
                user_id,
                device_id,
                severity,
                detail.to_string(),
                unix_now(),
            ],
        )?;
        Ok(())
    }
}

fn row_to_device(row: &rusqlite::Row<'_>) -> rusqlite::Result<PassportDevice> {
    let state: String = row.get(3)?;
    Ok(PassportDevice {
        user_id: row.get(0)?,
        device_id: row.get(1)?,
        generation: row.get(2)?,
        state: DevicePassportStateKind::from_db_result(&state)?,
        device_label: row.get(4)?,
        platform: row.get(5)?,
        fingerprint_hash: row.get(6)?,
        app_version: row.get(7)?,
        first_seen_at_unix: row.get(8)?,
        last_seen_at_unix: row.get(9)?,
        approved_at_unix: row.get(10)?,
        approved_by_device_id: row.get(11)?,
        revoked_at_unix: row.get(12)?,
    })
}

fn row_to_approval_request(row: &rusqlite::Row<'_>) -> rusqlite::Result<ApprovalRequestRecord> {
    let status: String = row.get(5)?;
    Ok(ApprovalRequestRecord {
        id: row.get(0)?,
        user_id: row.get(1)?,
        device_id: row.get(2)?,
        generation: row.get(3)?,
        challenge: row.get(4)?,
        status: ApprovalRequestStatus::from_db_result(&status)?,
        created_at_unix: row.get(6)?,
        expires_at_unix: row.get(7)?,
        decided_at_unix: row.get(8)?,
        decided_by_device_id: row.get(9)?,
    })
}

fn row_to_claim(row: &rusqlite::Row<'_>) -> rusqlite::Result<DirectoryClaim> {
    let kind: String = row.get(4)?;
    let severity: String = row.get(5)?;
    let proof_required_raw: i64 = row.get(7)?;
    Ok(DirectoryClaim {
        id: row.get(0)?,
        user_id: row.get(1)?,
        device_id: row.get(2)?,
        generation: row.get(3)?,
        kind: DirectoryClaimKind::from_db_result(&kind)?,
        severity: NoticeSeverity::from_db_result(&severity)?,
        fingerprint_hash: row.get(6)?,
        proof_required: proof_required_raw != 0,
        created_at_unix: row.get(8)?,
        approved_by_device_id: row.get(9)?,
    })
}

async fn authorize_xmpp_account(
    state: &DevicePassportState,
    headers: &HeaderMap,
) -> Result<AuthorizedAccount, PassportError> {
    let (user_id, password) = basic_credentials(headers)?;
    let bare_jid = normalize_local_jid(&user_id, &state.config.xmpp_host)?;
    if password.is_empty() {
        return Err(PassportError::Unauthorized);
    }
    if state.config.dry_run_auth {
        return Ok(AuthorizedAccount { bare_jid });
    }
    if !check_account_password(state, &bare_jid, &password).await {
        return Err(PassportError::Unauthorized);
    }
    Ok(AuthorizedAccount { bare_jid })
}

async fn check_account_password(
    state: &DevicePassportState,
    bare_jid: &str,
    password: &str,
) -> bool {
    let Some((localpart, _host)) = bare_jid.split_once('@') else {
        return false;
    };
    let response = state
        .http
        .post(format!("{}/check_password", state.config.xmpp_api_url))
        .json(&json!({
            "user": localpart,
            "host": state.config.xmpp_host,
            "password": password,
        }))
        .send()
        .await;
    let Ok(response) = response else {
        return false;
    };
    if !response.status().is_success() {
        return false;
    }
    let Ok(body) = response.text().await else {
        return false;
    };
    let normalized = body.trim();
    if normalized.is_empty() || normalized == "\"\"" {
        return true;
    }
    match serde_json::from_str::<Value>(normalized) {
        Ok(Value::Number(number)) => number.as_i64() == Some(0),
        Ok(Value::String(value)) => value.is_empty(),
        _ => false,
    }
}

fn authorize_operator(
    state: &DevicePassportState,
    headers: &HeaderMap,
) -> Result<(), PassportError> {
    let expected = state
        .config
        .operator_token
        .as_deref()
        .ok_or(PassportError::Unauthorized)?;
    let Some(value) = headers
        .get("Authorization")
        .and_then(|value| value.to_str().ok())
    else {
        return Err(PassportError::Unauthorized);
    };
    let Some(token) = value.strip_prefix("Bearer ") else {
        return Err(PassportError::Unauthorized);
    };
    if token != expected {
        return Err(PassportError::Unauthorized);
    }
    Ok(())
}

fn basic_credentials(headers: &HeaderMap) -> Result<(String, String), PassportError> {
    let Some(value) = headers
        .get("Authorization")
        .and_then(|value| value.to_str().ok())
    else {
        return Err(PassportError::Unauthorized);
    };
    let Some(encoded) = value.strip_prefix("Basic ") else {
        return Err(PassportError::Unauthorized);
    };
    let decoded = general_purpose::STANDARD
        .decode(encoded.trim())
        .map_err(|_| PassportError::Unauthorized)?;
    let decoded = String::from_utf8(decoded).map_err(|_| PassportError::Unauthorized)?;
    let Some((user, password)) = decoded.split_once(':') else {
        return Err(PassportError::Unauthorized);
    };
    Ok((user.to_owned(), password.to_owned()))
}

fn device_id_header(headers: &HeaderMap) -> Result<Option<String>, PassportError> {
    headers
        .get("X-Trix-Device-ID")
        .map(|value| {
            value
                .to_str()
                .map_err(|_| PassportError::BadRequest("X-Trix-Device-ID must be text"))
                .and_then(normalize_device_id)
        })
        .transpose()
}

#[derive(Debug, Clone)]
struct AuthorizedAccount {
    bare_jid: String,
}

#[derive(Debug, Deserialize)]
struct CurrentDeviceRequest {
    user_id: Option<String>,
    omemo_device_id: String,
    device_label: String,
    platform: String,
    fingerprint_hash: String,
    app_version: Option<String>,
}

impl CurrentDeviceRequest {
    fn normalized(
        self,
        authorized_user_id: &str,
        host: &str,
    ) -> Result<NormalizedCurrentDevice, PassportError> {
        if let Some(user_id) = self.user_id.as_deref() {
            let user_id = normalize_local_jid(user_id, host)?;
            if user_id != authorized_user_id {
                return Err(PassportError::Forbidden(
                    "current-device user does not match credentials",
                ));
            }
        }
        Ok(NormalizedCurrentDevice {
            user_id: authorized_user_id.to_owned(),
            device_id: normalize_device_id(&self.omemo_device_id)?,
            device_label: normalize_text_field(self.device_label, "device_label", 80)?,
            platform: normalize_platform(&self.platform)?,
            fingerprint_hash: normalize_fingerprint_hash(&self.fingerprint_hash)?,
            app_version: self
                .app_version
                .map(|value| normalize_text_field(value, "app_version", 64))
                .transpose()?,
        })
    }
}

#[derive(Debug)]
struct NormalizedCurrentDevice {
    user_id: String,
    device_id: String,
    device_label: String,
    platform: String,
    fingerprint_hash: String,
    app_version: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateApprovalRequest {
    device_id: String,
}

#[derive(Debug, Deserialize)]
struct ApproveRequest {
    approver_device_id: String,
}

#[derive(Debug, Deserialize)]
struct DeclineRequest {
    approver_device_id: String,
}

#[derive(Debug, Deserialize)]
struct ClaimsQuery {
    since: Option<i64>,
    limit: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct DismissNoticeRequest {
    severity: Option<NoticeSeverity>,
}

#[derive(Debug, Deserialize)]
struct OperatorResetRequest {
    root_device: Option<OperatorResetRootDevice>,
}

impl OperatorResetRequest {
    fn normalized(self, _user_id: &str) -> Result<NormalizedOperatorReset, PassportError> {
        Ok(NormalizedOperatorReset {
            root_device: self
                .root_device
                .map(OperatorResetRootDevice::normalized)
                .transpose()?,
        })
    }
}

#[derive(Debug, Deserialize)]
struct OperatorResetRootDevice {
    omemo_device_id: String,
    device_label: String,
    platform: String,
    fingerprint_hash: String,
    app_version: Option<String>,
}

impl OperatorResetRootDevice {
    fn normalized(self) -> Result<NormalizedOperatorResetRootDevice, PassportError> {
        Ok(NormalizedOperatorResetRootDevice {
            device_id: normalize_device_id(&self.omemo_device_id)?,
            device_label: normalize_text_field(self.device_label, "device_label", 80)?,
            platform: normalize_platform(&self.platform)?,
            fingerprint_hash: normalize_fingerprint_hash(&self.fingerprint_hash)?,
            app_version: self
                .app_version
                .map(|value| normalize_text_field(value, "app_version", 64))
                .transpose()?,
        })
    }
}

#[derive(Debug)]
struct NormalizedOperatorReset {
    root_device: Option<NormalizedOperatorResetRootDevice>,
}

#[derive(Debug)]
struct NormalizedOperatorResetRootDevice {
    device_id: String,
    device_label: String,
    platform: String,
    fingerprint_hash: String,
    app_version: Option<String>,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    service: &'static str,
    status: &'static str,
    version: &'static str,
}

#[derive(Debug, Serialize)]
struct CurrentDeviceResponse {
    device: PassportDevice,
}

#[derive(Debug, Serialize)]
struct PassportStateResponse {
    user_id: String,
    generation: i64,
    current_device: Option<PassportDevice>,
    current_approval_request: Option<ApprovalRequestRecord>,
    pending_approval_requests: Vec<ApprovalRequestRecord>,
    server_state_is_trust_authority: bool,
}

#[derive(Debug, Serialize)]
struct ApprovalRequestResponse {
    approval: ApprovalRequestRecord,
}

#[derive(Debug, Serialize)]
struct ApproveResponse {
    device: PassportDevice,
    claim: DirectoryClaim,
}

#[derive(Debug, Serialize)]
struct DirectoryClaimsResponse {
    recipient_user_id: String,
    claims: Vec<DirectoryClaim>,
    next_cursor: i64,
}

#[derive(Debug, Serialize)]
struct DismissNoticeResponse {
    recipient_user_id: String,
    target_user_id: String,
    severity: NoticeSeverity,
    dismissed_at_unix: i64,
}

#[derive(Debug, Serialize)]
struct OperatorResetResponse {
    user_id: String,
    generation: i64,
    root_device: Option<PassportDevice>,
    claim: DirectoryClaim,
}

#[derive(Debug, Clone, Serialize)]
struct PassportDevice {
    user_id: String,
    device_id: String,
    generation: i64,
    state: DevicePassportStateKind,
    device_label: String,
    platform: String,
    fingerprint_hash: String,
    app_version: Option<String>,
    first_seen_at_unix: i64,
    last_seen_at_unix: i64,
    approved_at_unix: Option<i64>,
    approved_by_device_id: Option<String>,
    revoked_at_unix: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum DevicePassportStateKind {
    Pending,
    ApprovalRequested,
    Approved,
    Revoked,
    ResetRoot,
}

impl DevicePassportStateKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::ApprovalRequested => "approval_requested",
            Self::Approved => "approved",
            Self::Revoked => "revoked",
            Self::ResetRoot => "reset_root",
        }
    }

    fn from_db(value: &str) -> Result<Self, PassportError> {
        match value {
            "pending" => Ok(Self::Pending),
            "approval_requested" => Ok(Self::ApprovalRequested),
            "approved" => Ok(Self::Approved),
            "revoked" => Ok(Self::Revoked),
            "reset_root" => Ok(Self::ResetRoot),
            _ => Err(PassportError::Internal),
        }
    }

    fn from_db_result(value: &str) -> rusqlite::Result<Self> {
        Self::from_db(value).map_err(|_| {
            rusqlite::Error::InvalidColumnType(0, "state".to_owned(), rusqlite::types::Type::Text)
        })
    }
}

#[derive(Debug, Clone, Serialize)]
struct ApprovalRequestRecord {
    id: String,
    user_id: String,
    device_id: String,
    generation: i64,
    challenge: String,
    status: ApprovalRequestStatus,
    created_at_unix: i64,
    expires_at_unix: i64,
    decided_at_unix: Option<i64>,
    decided_by_device_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ApprovalRequestStatus {
    Pending,
    Approved,
    Declined,
    Expired,
}

impl ApprovalRequestStatus {
    fn from_db_result(value: &str) -> rusqlite::Result<Self> {
        match value {
            "pending" => Ok(Self::Pending),
            "approved" => Ok(Self::Approved),
            "declined" => Ok(Self::Declined),
            "expired" => Ok(Self::Expired),
            _ => Err(rusqlite::Error::InvalidColumnType(
                0,
                "status".to_owned(),
                rusqlite::types::Type::Text,
            )),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct DirectoryClaim {
    id: i64,
    user_id: String,
    device_id: String,
    generation: i64,
    kind: DirectoryClaimKind,
    severity: NoticeSeverity,
    fingerprint_hash: String,
    proof_required: bool,
    created_at_unix: i64,
    approved_by_device_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum DirectoryClaimKind {
    Approved,
    Reset,
    Revoked,
}

impl DirectoryClaimKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::Reset => "reset",
            Self::Revoked => "revoked",
        }
    }

    fn from_db_result(value: &str) -> rusqlite::Result<Self> {
        match value {
            "approved" => Ok(Self::Approved),
            "reset" => Ok(Self::Reset),
            "revoked" => Ok(Self::Revoked),
            _ => Err(rusqlite::Error::InvalidColumnType(
                0,
                "kind".to_owned(),
                rusqlite::types::Type::Text,
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum NoticeSeverity {
    Normal,
    High,
}

impl NoticeSeverity {
    fn as_str(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::High => "high",
        }
    }

    fn from_db_result(value: &str) -> rusqlite::Result<Self> {
        match value {
            "normal" => Ok(Self::Normal),
            "high" => Ok(Self::High),
            _ => Err(rusqlite::Error::InvalidColumnType(
                0,
                "severity".to_owned(),
                rusqlite::types::Type::Text,
            )),
        }
    }
}

#[derive(Debug, Error)]
enum PassportError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("bad request: {0}")]
    BadRequest(&'static str),
    #[error("forbidden: {0}")]
    Forbidden(&'static str),
    #[error("not found: {0}")]
    NotFound(&'static str),
    #[error("conflict: {0}")]
    Conflict(&'static str),
    #[error("gone: {0}")]
    Gone(&'static str),
    #[error("internal error")]
    Internal,
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
}

impl IntoResponse for PassportError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Account credentials or operator token are required.",
            ),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message),
            Self::Forbidden(message) => (StatusCode::FORBIDDEN, "forbidden", message),
            Self::NotFound(message) => (StatusCode::NOT_FOUND, "not_found", message),
            Self::Conflict(message) => (StatusCode::CONFLICT, "conflict", message),
            Self::Gone(message) => (StatusCode::GONE, "gone", message),
            Self::Internal | Self::Sql(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                "Device Passport operation failed.",
            ),
        };
        (status, Json(json!({ "error": code, "message": message }))).into_response()
    }
}

fn normalize_local_jid(value: &str, host: &str) -> Result<String, PassportError> {
    let trimmed = value.trim().to_ascii_lowercase();
    let (localpart, jid_host) = trimmed.split_once('@').ok_or(PassportError::BadRequest(
        "user_id must be a local Trix JID",
    ))?;
    if jid_host != host {
        return Err(PassportError::BadRequest("user_id must use the Trix host"));
    }
    if localpart.is_empty()
        || localpart.len() > 64
        || !localpart.chars().all(|ch| {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '.' | '_' | '-')
        })
    {
        return Err(PassportError::BadRequest("user_id localpart is invalid"));
    }
    Ok(format!("{localpart}@{host}"))
}

fn normalize_device_id(value: &str) -> Result<String, PassportError> {
    normalize_identifier(value, "device_id", 64)
}

fn normalize_identifier(
    value: &str,
    field: &'static str,
    max_len: usize,
) -> Result<String, PassportError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > max_len
        || !trimmed
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
    {
        return Err(PassportError::BadRequest(field));
    }
    Ok(trimmed.to_owned())
}

fn normalize_text_field(
    value: String,
    field: &'static str,
    max_len: usize,
) -> Result<String, PassportError> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.len() > max_len || trimmed.len() > MAX_BODY_TEXT_BYTES {
        return Err(PassportError::BadRequest(field));
    }
    if trimmed.chars().any(|ch| ch.is_control()) {
        return Err(PassportError::BadRequest(field));
    }
    Ok(trimmed.to_owned())
}

fn normalize_platform(value: &str) -> Result<String, PassportError> {
    match value.trim().to_ascii_lowercase().as_str() {
        "ios" => Ok("ios".to_owned()),
        "macos" => Ok("macos".to_owned()),
        "unknown" => Ok("unknown".to_owned()),
        _ => Err(PassportError::BadRequest(
            "platform must be ios, macos, or unknown",
        )),
    }
}

fn normalize_fingerprint_hash(value: &str) -> Result<String, PassportError> {
    let trimmed = value.trim().to_ascii_lowercase();
    if !(16..=128).contains(&trimmed.len()) || !trimmed.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(PassportError::BadRequest("fingerprint_hash must be hex"));
    }
    Ok(trimmed)
}

fn approval_challenge(request_id: &str, device_id: &str) -> String {
    let digest = Sha256::digest(format!("{request_id}:{device_id}").as_bytes());
    let mut value = String::with_capacity(8);
    for byte in digest.iter().take(4) {
        value.push_str(&format!("{byte:02X}"));
    }
    value
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_secs() as i64
}

fn env_or(key: &str, fallback: &str) -> Result<String> {
    Ok(env::var(key)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| fallback.to_owned()))
}

fn env_truthy(key: &str) -> bool {
    matches!(
        env::var(key).ok().as_deref(),
        Some("1" | "true" | "TRUE" | "yes" | "YES")
    )
}

fn validate_bind_addr(bind_addr: SocketAddr) -> Result<()> {
    match bind_addr.ip() {
        IpAddr::V4(ip) if ip == Ipv4Addr::LOCALHOST => Ok(()),
        IpAddr::V6(ip) if ip.is_loopback() => Ok(()),
        _ if env_truthy("TRIX_DEVICE_PASSPORT_ALLOW_NON_LOOPBACK") => Ok(()),
        _ => anyhow::bail!(
            "TRIX_DEVICE_PASSPORT_BIND_ADDR must be loopback unless explicitly allowed"
        ),
    }
}

fn validate_deployment_secret(key: &str, value: &str) -> Result<()> {
    if value.len() < 32 || is_insecure_default_secret(value) {
        anyhow::bail!("{key} must be a non-default secret with at least 32 bytes");
    }
    Ok(())
}

fn is_insecure_default_secret(value: &str) -> bool {
    matches!(
        value,
        "deployment-local-token"
            | "deployment-local-32-byte-minimum-token"
            | "dev-local-device-passport-token-change-me"
            | "change-me"
            | "secret"
            | "password"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn current_device(user_id: &str, device_id: &str) -> NormalizedCurrentDevice {
        NormalizedCurrentDevice {
            user_id: user_id.to_owned(),
            device_id: device_id.to_owned(),
            device_label: "Test iPhone".to_owned(),
            platform: "ios".to_owned(),
            fingerprint_hash: "00112233445566778899aabbccddeeff".to_owned(),
            app_version: Some("0.2.11".to_owned()),
        }
    }

    #[test]
    fn pending_request_is_idempotent_and_approval_requires_approved_device() {
        let mut store = DevicePassportStore::open_memory().expect("store opens");
        let user_id = "alice@trix.selfhost.ru";
        store
            .upsert_current_device(&current_device(user_id, "1001"))
            .expect("device upserts");

        let first = store
            .create_approval_request(user_id, "1001", unix_now() + 600)
            .expect("request is created");
        let second = store
            .create_approval_request(user_id, "1001", unix_now() + 600)
            .expect("request is reused");
        assert_eq!(first.id, second.id);

        let error = store
            .approve_request(user_id, &first.id, "9999")
            .expect_err("unknown approver is rejected");
        assert!(matches!(error, PassportError::Forbidden(_)));
    }

    #[test]
    fn approved_request_writes_directory_claim_with_proof_required() {
        let mut store = DevicePassportStore::open_memory().expect("store opens");
        let user_id = "alice@trix.selfhost.ru";
        let mut approver = current_device(user_id, "1000");
        approver.device_label = "Trusted Mac".to_owned();
        store
            .upsert_current_device(&approver)
            .expect("approver upserts");
        let reset = store
            .operator_reset(
                user_id,
                NormalizedOperatorReset {
                    root_device: Some(NormalizedOperatorResetRootDevice {
                        device_id: "1000".to_owned(),
                        device_label: "Trusted Mac".to_owned(),
                        platform: "macos".to_owned(),
                        fingerprint_hash: approver.fingerprint_hash.clone(),
                        app_version: None,
                    }),
                },
            )
            .expect("operator reset creates root");
        assert_eq!(reset.generation, 2);

        store
            .upsert_current_device(&current_device(user_id, "1001"))
            .expect("new device upserts");
        let request = store
            .create_approval_request(user_id, "1001", unix_now() + 600)
            .expect("request is created");
        let approved = store
            .approve_request(user_id, &request.id, "1000")
            .expect("approved");
        assert_eq!(approved.device.state, DevicePassportStateKind::Approved);
        assert_eq!(approved.claim.kind, DirectoryClaimKind::Approved);
        assert!(approved.claim.proof_required);

        let (claims, _) = store
            .directory_claims("bob@trix.selfhost.ru", 0, 20)
            .expect("claims load");
        assert_eq!(claims.len(), 2);
    }

    #[test]
    fn directory_claims_skip_dismissed_notices_without_stalling_cursor() {
        let mut store = DevicePassportStore::open_memory().expect("store opens");
        let user_id = "alice@trix.selfhost.ru";
        let recipient = "bob@trix.selfhost.ru";
        let reset = store
            .operator_reset(
                user_id,
                NormalizedOperatorReset {
                    root_device: Some(NormalizedOperatorResetRootDevice {
                        device_id: "2000".to_owned(),
                        device_label: "Replacement iPhone".to_owned(),
                        platform: "ios".to_owned(),
                        fingerprint_hash: "ffeeddccbbaa99887766554433221100".to_owned(),
                        app_version: None,
                    }),
                },
            )
            .expect("operator reset");
        assert_eq!(reset.claim.severity, NoticeSeverity::High);

        store
            .dismiss_notice(recipient, user_id, NoticeSeverity::High)
            .expect("notice dismissal persists");
        let (claims, next_cursor) = store
            .directory_claims(recipient, 0, 20)
            .expect("dismissed claims are filtered");
        assert!(claims.is_empty());
        assert_eq!(next_cursor, reset.claim.id);
    }

    #[test]
    fn operator_reset_invalidates_pending_requests_and_marks_high_severity() {
        let mut store = DevicePassportStore::open_memory().expect("store opens");
        let user_id = "alice@trix.selfhost.ru";
        store
            .upsert_current_device(&current_device(user_id, "1001"))
            .expect("device upserts");
        let request = store
            .create_approval_request(user_id, "1001", unix_now() + 600)
            .expect("request is created");
        let reset = store
            .operator_reset(
                user_id,
                NormalizedOperatorReset {
                    root_device: Some(NormalizedOperatorResetRootDevice {
                        device_id: "2000".to_owned(),
                        device_label: "Replacement iPhone".to_owned(),
                        platform: "ios".to_owned(),
                        fingerprint_hash: "ffeeddccbbaa99887766554433221100".to_owned(),
                        app_version: None,
                    }),
                },
            )
            .expect("operator reset");
        assert_eq!(reset.claim.severity, NoticeSeverity::High);
        assert_eq!(
            store.approval_request(&request.id).unwrap().unwrap().status,
            ApprovalRequestStatus::Expired
        );
    }

    #[test]
    fn validation_rejects_secret_like_or_oversized_inputs() {
        assert!(normalize_fingerprint_hash("not-a-hash").is_err());
        assert!(normalize_text_field("\n".to_owned(), "device_label", 80).is_err());
        assert!(normalize_device_id("contains space").is_err());
        assert!(
            validate_deployment_secret(
                "TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN",
                "dev-local-device-passport-token-change-me"
            )
            .is_err()
        );
        assert!(
            validate_deployment_secret(
                "TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN",
                "deployment-local-32-byte-minimum-token"
            )
            .is_err()
        );
    }
}
