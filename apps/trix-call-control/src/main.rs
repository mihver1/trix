use std::{collections::HashMap, env, net::SocketAddr, str::FromStr, sync::Arc};

use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose};
use hmac::{Hmac, Mac};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use tracing::warn;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};
use uuid::Uuid;

type HmacSha1 = Hmac<Sha1>;

const DEFAULT_TOKEN_TTL_SECONDS: u64 = 15 * 60;
const DEFAULT_TURN_TTL_SECONDS: u64 = 15 * 60;

#[tokio::main]
async fn main() -> Result<()> {
    let config = CallControlConfig::from_env()?;

    tracing_subscriber::registry()
        .with(EnvFilter::new(config.log_filter.clone()))
        .with(fmt::layer())
        .init();

    let bind_addr = config.bind_addr;
    let state = CallControlState {
        config: Arc::new(config),
        http: Client::builder()
            .build()
            .context("failed to build HTTP client")?,
        active_calls: Arc::new(Mutex::new(HashMap::new())),
    };

    let router = Router::new()
        .route("/v1/system/health", get(health))
        .route("/v1/calls/dm-video", post(create_dm_video_call))
        .route("/v1/calls/dm-video/join", post(join_dm_video_call))
        .route("/v1/calls/group-voice/join", post(join_group_voice_call))
        .route("/v1/calls/end", post(end_call))
        .route("/v1/turn/credentials", post(issue_turn_credentials))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(bind_addr)
        .await
        .with_context(|| format!("failed to bind {bind_addr}"))?;
    tracing::info!("trix-call-control listening on {}", bind_addr);
    axum::serve(listener, router).await?;
    Ok(())
}

#[derive(Clone)]
struct CallControlState {
    config: Arc<CallControlConfig>,
    http: Client,
    active_calls: Arc<Mutex<HashMap<String, ActiveCall>>>,
}

#[derive(Debug, Clone)]
struct ActiveCall {
    kind: CallKind,
    livekit_room: String,
    participant_jids: Vec<String>,
}

#[derive(Clone)]
struct CallControlConfig {
    bind_addr: SocketAddr,
    log_filter: String,
    xmpp_api_url: String,
    xmpp_host: String,
    conference_host: String,
    livekit_url: String,
    livekit_api_key: String,
    livekit_api_secret: String,
    turn_uris: Vec<String>,
    turn_shared_secret: String,
    token_ttl_seconds: u64,
    token_not_before_leeway_seconds: u64,
    turn_ttl_seconds: u64,
    call_push_url: Option<String>,
    call_push_token: Option<String>,
    skip_muc_membership_check: bool,
    dry_run_auth: bool,
}

impl CallControlConfig {
    fn from_env() -> Result<Self> {
        let bind_addr = SocketAddr::from_str(&env_or("TRIX_CALL_BIND_ADDR", "127.0.0.1:8092")?)
            .context("invalid TRIX_CALL_BIND_ADDR")?;
        let log_filter = env_or("TRIX_CALL_LOG", "info,trix_call_control=debug")?;
        let xmpp_host = env_or("TRIX_XMPP_HOST", "trix.selfhost.ru")?;
        let conference_host = env_or("TRIX_XMPP_CONFERENCE_HOST", "conference.trix.selfhost.ru")?;
        let livekit_url = env_required("TRIX_LIVEKIT_URL")?.trim().to_owned();
        let livekit_api_key = env_required("TRIX_LIVEKIT_API_KEY")?.trim().to_owned();
        let livekit_api_secret = env_required("TRIX_LIVEKIT_API_SECRET")?;
        let turn_shared_secret = env_required("TRIX_TURN_SHARED_SECRET")?;

        for (key, value) in [
            ("TRIX_LIVEKIT_API_KEY", livekit_api_key.as_str()),
            ("TRIX_LIVEKIT_API_SECRET", livekit_api_secret.as_str()),
            ("TRIX_TURN_SHARED_SECRET", turn_shared_secret.as_str()),
        ] {
            if is_insecure_default_secret(value) {
                anyhow::bail!("{key} must be a non-default secret");
            }
        }

        let turn_uris = env_or(
            "TRIX_TURN_URIS",
            "turn:trix.selfhost.ru:3478?transport=udp,turns:trix.selfhost.ru:5349?transport=tcp",
        )?
        .split(',')
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
        if turn_uris.is_empty() {
            anyhow::bail!("TRIX_TURN_URIS must contain at least one URI");
        }

        let call_push_token = env::var("TRIX_CALL_PUSH_GATEWAY_TOKEN")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if let Some(token) = call_push_token.as_deref() {
            if is_insecure_default_secret(token) {
                anyhow::bail!("TRIX_CALL_PUSH_GATEWAY_TOKEN must be a non-default secret");
            }
        }
        let call_push_url = if call_push_token.is_some() {
            Some(env_or(
                "TRIX_CALL_PUSH_GATEWAY_URL",
                "http://push-gateway:8090/v0/apns/voip/call",
            )?)
        } else {
            None
        };

        Ok(Self {
            bind_addr,
            log_filter,
            xmpp_api_url: env_or("TRIX_XMPP_API_URL", "http://ejabberd:5280/api")?,
            xmpp_host,
            conference_host,
            livekit_url,
            livekit_api_key,
            livekit_api_secret,
            turn_uris,
            turn_shared_secret,
            token_ttl_seconds: env_or(
                "TRIX_CALL_TOKEN_TTL_SECONDS",
                &DEFAULT_TOKEN_TTL_SECONDS.to_string(),
            )?
            .parse()
            .context("invalid TRIX_CALL_TOKEN_TTL_SECONDS")?,
            token_not_before_leeway_seconds: env_or("TRIX_CALL_TOKEN_NBF_LEEWAY_SECONDS", "5")?
                .parse()
                .context("invalid TRIX_CALL_TOKEN_NBF_LEEWAY_SECONDS")?,
            turn_ttl_seconds: env_or(
                "TRIX_TURN_TTL_SECONDS",
                &DEFAULT_TURN_TTL_SECONDS.to_string(),
            )?
            .parse()
            .context("invalid TRIX_TURN_TTL_SECONDS")?,
            call_push_url,
            call_push_token,
            skip_muc_membership_check: env_truthy("TRIX_CALL_SKIP_MUC_MEMBERSHIP_CHECK"),
            dry_run_auth: env_truthy("TRIX_CALL_DRY_RUN_AUTH"),
        })
    }
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        service: "trix-call-control",
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

async fn create_dm_video_call(
    State(state): State<CallControlState>,
    headers: HeaderMap,
    Json(request): Json<DirectCallRequest>,
) -> Result<Json<CallJoinResponse>, CallControlError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let peer =
        normalize_local_jid(&request.peer_user_id, &state.config.xmpp_host).ok_or_else(|| {
            CallControlError::BadRequest("peer_user_id must be a local Trix JID".to_owned())
        })?;
    if peer == account.bare_jid {
        return Err(CallControlError::BadRequest(
            "peer_user_id must be different from the caller".to_owned(),
        ));
    }

    let response = call_join_response(
        &state.config,
        &account,
        request.device_id.as_deref(),
        CallKind::DirectVideo,
        Some(peer.clone()),
        None,
        true,
        true,
    )?;
    remember_active_call(&state, &response).await;
    send_call_push(&state, &peer, &response.call_id).await;
    Ok(Json(response))
}

async fn join_dm_video_call(
    State(state): State<CallControlState>,
    headers: HeaderMap,
    Json(request): Json<DirectCallJoinRequest>,
) -> Result<Json<CallJoinResponse>, CallControlError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let call_id = request.call_id.trim();
    if call_id.is_empty() {
        return Err(CallControlError::BadRequest(
            "call_id must not be empty".to_owned(),
        ));
    }

    let active_call = state
        .active_calls
        .lock()
        .await
        .get(call_id)
        .cloned()
        .ok_or(CallControlError::Forbidden)?;

    if !matches!(active_call.kind, CallKind::DirectVideo)
        || !active_call
            .participant_jids
            .iter()
            .any(|jid| jid.eq_ignore_ascii_case(&account.bare_jid))
    {
        return Err(CallControlError::Forbidden);
    }

    Ok(Json(existing_call_join_response(
        &state.config,
        &account,
        request.device_id.as_deref(),
        call_id,
        active_call.kind,
        active_call.livekit_room,
        true,
        true,
    )?))
}

async fn join_group_voice_call(
    State(state): State<CallControlState>,
    headers: HeaderMap,
    Json(request): Json<GroupVoiceRequest>,
) -> Result<Json<CallJoinResponse>, CallControlError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    let room =
        parse_muc_room_id(&request.room_id, &state.config.conference_host).ok_or_else(|| {
            CallControlError::BadRequest("room_id must be a local Trix MUC JID".to_owned())
        })?;

    if !state.config.skip_muc_membership_check
        && !is_muc_member(&state, &room.localpart, &account).await?
    {
        return Err(CallControlError::Forbidden);
    }

    let response = call_join_response(
        &state.config,
        &account,
        request.device_id.as_deref(),
        CallKind::GroupVoice,
        None,
        Some(room),
        true,
        false,
    )?;
    remember_active_call(&state, &response).await;
    Ok(Json(response))
}

async fn end_call(
    State(state): State<CallControlState>,
    headers: HeaderMap,
    Json(request): Json<EndCallRequest>,
) -> Result<Json<EndCallResponse>, CallControlError> {
    let _account = authorize_xmpp_account(&state, &headers).await?;
    let call_id = request.call_id.trim();
    if call_id.is_empty() {
        return Err(CallControlError::BadRequest(
            "call_id must not be empty".to_owned(),
        ));
    }

    let ended = state.active_calls.lock().await.remove(call_id).is_some();

    Ok(Json(EndCallResponse {
        call_id: call_id.to_owned(),
        ended,
    }))
}

async fn issue_turn_credentials(
    State(state): State<CallControlState>,
    headers: HeaderMap,
) -> Result<Json<TurnCredentials>, CallControlError> {
    let account = authorize_xmpp_account(&state, &headers).await?;
    Ok(Json(turn_credentials(&state.config, &account)?))
}

async fn authorize_xmpp_account(
    state: &CallControlState,
    headers: &HeaderMap,
) -> Result<AuthorizedAccount, CallControlError> {
    let (bare_jid, password) = basic_credentials(headers, &state.config.xmpp_host)?;
    if !state.config.dry_run_auth && !check_password(state, &bare_jid, &password).await? {
        return Err(CallControlError::Unauthorized);
    }

    Ok(AuthorizedAccount { bare_jid })
}

fn basic_credentials(
    headers: &HeaderMap,
    xmpp_host: &str,
) -> Result<(String, String), CallControlError> {
    let Some(header) = headers.get(axum::http::header::AUTHORIZATION) else {
        return Err(CallControlError::Unauthorized);
    };
    let Ok(value) = header.to_str() else {
        return Err(CallControlError::Unauthorized);
    };
    let Some(encoded) = value.strip_prefix("Basic ") else {
        return Err(CallControlError::Unauthorized);
    };
    let decoded = general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| CallControlError::Unauthorized)?;
    let decoded = String::from_utf8(decoded).map_err(|_| CallControlError::Unauthorized)?;
    let Some((jid, password)) = decoded.split_once(':') else {
        return Err(CallControlError::Unauthorized);
    };
    let bare_jid = normalize_local_jid(jid, xmpp_host).ok_or(CallControlError::Unauthorized)?;
    if password.trim().is_empty() {
        return Err(CallControlError::Unauthorized);
    }
    Ok((bare_jid, password.to_owned()))
}

async fn check_password(
    state: &CallControlState,
    bare_jid: &str,
    password: &str,
) -> Result<bool, CallControlError> {
    let (user, host) = split_jid(bare_jid).ok_or(CallControlError::Unauthorized)?;
    let value = ejabberd_api_post(
        state,
        "check_password",
        json!({
            "user": user,
            "host": host,
            "password": password,
        }),
    )
    .await?;

    Ok(match value {
        Value::Null => true,
        Value::String(value) => value.is_empty(),
        Value::Number(number) => number.as_i64() == Some(0),
        _ => false,
    })
}

async fn is_muc_member(
    state: &CallControlState,
    room_localpart: &str,
    account: &AuthorizedAccount,
) -> Result<bool, CallControlError> {
    if state.config.dry_run_auth {
        return Ok(true);
    }

    let value = ejabberd_api_post(
        state,
        "get_room_affiliations",
        muc_affiliations_payload(room_localpart, &state.config.conference_host),
    )
    .await?;

    Ok(json_contains_jid(&value, &account.bare_jid))
}

fn muc_affiliations_payload(room_localpart: &str, conference_host: &str) -> Value {
    json!({
        "room": room_localpart,
        "service": conference_host,
    })
}

async fn ejabberd_api_post(
    state: &CallControlState,
    command: &str,
    payload: Value,
) -> Result<Value, CallControlError> {
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
        .map_err(|_| {
            warn!("ejabberd API request failed");
            CallControlError::BackendUnavailable
        })?;

    if !response.status().is_success() {
        warn!("ejabberd API returned non-success status");
        return Err(CallControlError::BackendUnavailable);
    }

    let body = response.text().await.unwrap_or_default();
    if body.trim().is_empty() || body.trim() == "\"\"" {
        return Ok(Value::Null);
    }
    serde_json::from_str(&body).map_err(|_| CallControlError::BackendUnavailable)
}

fn call_join_response(
    config: &CallControlConfig,
    account: &AuthorizedAccount,
    device_id: Option<&str>,
    kind: CallKind,
    peer: Option<String>,
    room: Option<MucRoom>,
    publish_audio: bool,
    publish_video: bool,
) -> Result<CallJoinResponse, CallControlError> {
    let call_id = Uuid::new_v4().to_string();
    let livekit_room = livekit_room_name(
        &kind,
        &call_id,
        &account.bare_jid,
        peer.as_deref(),
        room.as_ref(),
    );
    let participant_jids = match &kind {
        CallKind::DirectVideo => {
            let mut participants = vec![account.bare_jid.clone()];
            if let Some(peer) = peer {
                participants.push(peer);
            }
            participants
        }
        CallKind::GroupVoice => vec![account.bare_jid.clone()],
    };
    let now = unix_now();
    let expires_at = now.saturating_add(config.token_ttl_seconds);
    let livekit_identity = livekit_participant_identity(account, device_id);
    let token = livekit_token(config, &livekit_identity, &livekit_room, expires_at)?;

    Ok(CallJoinResponse {
        call_id,
        kind,
        livekit_url: config.livekit_url.clone(),
        livekit_room,
        livekit_token: token,
        livekit_token_expires_at_unix: expires_at,
        turn: turn_credentials(config, account)?,
        e2ee_required: true,
        publish_audio,
        publish_video,
        subscribe_audio: true,
        subscribe_video: publish_video,
        participant_jids,
    })
}

fn existing_call_join_response(
    config: &CallControlConfig,
    account: &AuthorizedAccount,
    device_id: Option<&str>,
    call_id: &str,
    kind: CallKind,
    livekit_room: String,
    publish_audio: bool,
    publish_video: bool,
) -> Result<CallJoinResponse, CallControlError> {
    let now = unix_now();
    let expires_at = now.saturating_add(config.token_ttl_seconds);
    let livekit_identity = livekit_participant_identity(account, device_id);
    let token = livekit_token(config, &livekit_identity, &livekit_room, expires_at)?;

    Ok(CallJoinResponse {
        call_id: call_id.to_owned(),
        kind,
        livekit_url: config.livekit_url.clone(),
        livekit_room,
        livekit_token: token,
        livekit_token_expires_at_unix: expires_at,
        turn: turn_credentials(config, account)?,
        e2ee_required: true,
        publish_audio,
        publish_video,
        subscribe_audio: true,
        subscribe_video: publish_video,
        participant_jids: vec![account.bare_jid.clone()],
    })
}

async fn remember_active_call(state: &CallControlState, response: &CallJoinResponse) {
    state
        .active_calls
        .lock()
        .await
        .insert(
            response.call_id.clone(),
            ActiveCall {
                kind: response.kind.clone(),
                livekit_room: response.livekit_room.clone(),
                participant_jids: response.participant_jids.clone(),
            },
        );
}

async fn send_call_push(state: &CallControlState, account: &str, call_id: &str) {
    let (Some(url), Some(token)) = (
        state.config.call_push_url.as_deref(),
        state.config.call_push_token.as_deref(),
    ) else {
        return;
    };

    let response = state
        .http
        .post(url)
        .bearer_auth(token)
        .json(&CallPushRequest { account, call_id })
        .send()
        .await;

    match response {
        Ok(response)
            if response.status().is_success() || response.status() == StatusCode::NOT_FOUND => {}
        Ok(_) => warn!("call push gateway rejected VoIP call push"),
        Err(_) => warn!("failed to reach call push gateway"),
    }
}

fn livekit_token(
    config: &CallControlConfig,
    identity: &str,
    room: &str,
    expires_at: u64,
) -> Result<String, CallControlError> {
    let claims = LiveKitClaims {
        iss: config.livekit_api_key.clone(),
        sub: identity.to_owned(),
        nbf: unix_now().saturating_sub(config.token_not_before_leeway_seconds),
        exp: expires_at,
        video: LiveKitVideoGrant {
            room_join: true,
            room: room.to_owned(),
            can_publish: true,
            can_subscribe: true,
            can_publish_data: true,
        },
    };

    let header = Header::new(Algorithm::HS256);
    jsonwebtoken::encode(
        &header,
        &claims,
        &EncodingKey::from_secret(config.livekit_api_secret.as_bytes()),
    )
    .map_err(|_| CallControlError::BackendUnavailable)
}

fn turn_credentials(
    config: &CallControlConfig,
    account: &AuthorizedAccount,
) -> Result<TurnCredentials, CallControlError> {
    let expires_at = unix_now().saturating_add(config.turn_ttl_seconds);
    let username = format!("{}:{}", expires_at, account.bare_jid);
    let mut mac = HmacSha1::new_from_slice(config.turn_shared_secret.as_bytes())
        .map_err(|_| CallControlError::BackendUnavailable)?;
    mac.update(username.as_bytes());
    let credential = general_purpose::STANDARD.encode(mac.finalize().into_bytes());

    Ok(TurnCredentials {
        uris: config.turn_uris.clone(),
        username,
        credential,
        expires_at_unix: expires_at,
    })
}

fn livekit_participant_identity(account: &AuthorizedAccount, device_id: Option<&str>) -> String {
    sanitized_device_id(device_id)
        .map(|device_id| format!("{}/{}", account.bare_jid, device_id))
        .unwrap_or_else(|| account.bare_jid.clone())
}

fn sanitized_device_id(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if trimmed.is_empty() {
        return None;
    }

    let mut sanitized = String::with_capacity(trimmed.len().min(64));
    let mut previous_was_separator = false;
    for character in trimmed.chars().take(64) {
        let next = if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
            character
        } else {
            '-'
        };
        if next == '-' {
            if previous_was_separator {
                continue;
            }
            previous_was_separator = true;
        } else {
            previous_was_separator = false;
        }
        sanitized.push(next);
    }

    let sanitized = sanitized.trim_matches('-').to_owned();
    if sanitized.is_empty() {
        None
    } else {
        Some(sanitized)
    }
}

fn livekit_room_name(
    kind: &CallKind,
    call_id: &str,
    account: &str,
    peer: Option<&str>,
    room: Option<&MucRoom>,
) -> String {
    let mut hasher = Sha256::new();
    match kind {
        CallKind::DirectVideo => {
            let mut participants = vec![account.to_owned(), peer.unwrap_or_default().to_owned()];
            participants.sort();
            hasher.update(participants.join("|"));
            hasher.update(call_id);
            format!("trix-dm-{}", hex_prefix(hasher.finalize().as_slice(), 24))
        }
        CallKind::GroupVoice => {
            hasher.update(room.map(|room| room.room_id.as_str()).unwrap_or_default());
            format!(
                "trix-group-{}",
                hex_prefix(hasher.finalize().as_slice(), 24)
            )
        }
    }
}

fn hex_prefix(bytes: &[u8], chars: usize) -> String {
    bytes
        .iter()
        .flat_map(|byte| [byte >> 4, byte & 0x0f])
        .take(chars)
        .map(|nibble| char::from_digit(nibble as u32, 16).unwrap_or('0'))
        .collect()
}

fn normalize_local_jid(value: &str, expected_host: &str) -> Option<String> {
    let trimmed = value.trim().to_ascii_lowercase();
    let normalized = if trimmed.starts_with('@') {
        let (localpart, host) = trimmed.trim_start_matches('@').split_once(':')?;
        format!("{localpart}@{host}")
    } else {
        trimmed
    };
    let (localpart, host) = split_jid(&normalized)?;
    if localpart.is_empty() || host != expected_host || normalized.contains(char::is_whitespace) {
        return None;
    }
    Some(normalized)
}

fn split_jid(value: &str) -> Option<(&str, &str)> {
    let (localpart, host) = value.split_once('@')?;
    if localpart.is_empty() || host.is_empty() {
        return None;
    }
    Some((localpart, host))
}

fn parse_muc_room_id(value: &str, expected_host: &str) -> Option<MucRoom> {
    let room_id = value.trim().to_ascii_lowercase();
    let (localpart, host) = split_jid(&room_id)?;
    if localpart.is_empty() || host != expected_host || room_id.contains(char::is_whitespace) {
        return None;
    }
    let localpart = localpart.to_owned();
    Some(MucRoom { room_id, localpart })
}

fn json_contains_jid(value: &Value, bare_jid: &str) -> bool {
    match value {
        Value::String(value) => value.eq_ignore_ascii_case(bare_jid),
        Value::Array(values) => values
            .iter()
            .any(|value| json_contains_jid(value, bare_jid)),
        Value::Object(map) => map.values().any(|value| json_contains_jid(value, bare_jid)),
        _ => false,
    }
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn env_or(key: &str, default: &str) -> Result<String> {
    Ok(env::var(key).unwrap_or_else(|_| default.to_owned()))
}

fn env_required(key: &str) -> Result<String> {
    env::var(key).with_context(|| format!("{key} is required"))
}

fn env_truthy(key: &str) -> bool {
    env::var(key)
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn is_insecure_default_secret(value: &str) -> bool {
    matches!(
        value.trim(),
        "" | "replace-me"
            | "change-me"
            | "dev-local-push-gateway-token-change-me"
            | "dev-local-livekit-api-secret-change-me"
            | "dev-local-turn-shared-secret-change-me"
    )
}

#[derive(Debug, Clone)]
struct AuthorizedAccount {
    bare_jid: String,
}

#[derive(Debug, Clone)]
struct MucRoom {
    room_id: String,
    localpart: String,
}

#[derive(Debug, Deserialize)]
struct DirectCallRequest {
    peer_user_id: String,
    device_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DirectCallJoinRequest {
    call_id: String,
    device_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GroupVoiceRequest {
    room_id: String,
    device_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct EndCallRequest {
    call_id: String,
}

#[derive(Debug, Serialize)]
struct EndCallResponse {
    call_id: String,
    ended: bool,
}

#[derive(Serialize)]
struct CallPushRequest<'a> {
    account: &'a str,
    call_id: &'a str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
enum CallKind {
    DirectVideo,
    GroupVoice,
}

#[derive(Debug, Serialize)]
struct CallJoinResponse {
    call_id: String,
    kind: CallKind,
    livekit_url: String,
    livekit_room: String,
    livekit_token: String,
    livekit_token_expires_at_unix: u64,
    turn: TurnCredentials,
    e2ee_required: bool,
    publish_audio: bool,
    publish_video: bool,
    subscribe_audio: bool,
    subscribe_video: bool,
    #[serde(skip)]
    participant_jids: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct TurnCredentials {
    uris: Vec<String>,
    username: String,
    credential: String,
    expires_at_unix: u64,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    service: &'static str,
    status: &'static str,
    version: &'static str,
}

#[derive(Debug, Serialize)]
struct LiveKitClaims {
    iss: String,
    sub: String,
    nbf: u64,
    exp: u64,
    video: LiveKitVideoGrant,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveKitVideoGrant {
    room_join: bool,
    room: String,
    can_publish: bool,
    can_subscribe: bool,
    can_publish_data: bool,
}

enum CallControlError {
    Unauthorized,
    Forbidden,
    BadRequest(String),
    BackendUnavailable,
}

impl IntoResponse for CallControlError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "missing or invalid account authorization".to_owned(),
            ),
            Self::Forbidden => (
                StatusCode::FORBIDDEN,
                "forbidden",
                "call membership could not be verified".to_owned(),
            ),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message),
            Self::BackendUnavailable => (
                StatusCode::BAD_GATEWAY,
                "backend_unavailable",
                "call control backend is unavailable".to_owned(),
            ),
        };

        (
            status,
            Json(ErrorResponse {
                code,
                message: message.to_owned(),
            }),
        )
            .into_response()
    }
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    code: &'static str,
    message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_matrix_style_and_xmpp_style_local_jids() {
        assert_eq!(
            normalize_local_jid("@alice:trix.selfhost.ru", "trix.selfhost.ru").as_deref(),
            Some("alice@trix.selfhost.ru")
        );
        assert_eq!(
            normalize_local_jid("Alice@trix.selfhost.ru", "trix.selfhost.ru").as_deref(),
            Some("alice@trix.selfhost.ru")
        );
        assert_eq!(
            normalize_local_jid("alice@example.org", "trix.selfhost.ru"),
            None
        );
    }

    #[test]
    fn recognizes_muc_membership_from_nested_api_payloads() {
        let payload = json!([
            {"jid": "alice@trix.selfhost.ru", "affiliation": "member"},
            {"jid": "friend@trix.selfhost.ru", "affiliation": "admin"}
        ]);

        assert!(json_contains_jid(&payload, "alice@trix.selfhost.ru"));
        assert!(!json_contains_jid(&payload, "other@trix.selfhost.ru"));
    }

    #[test]
    fn muc_affiliations_payload_matches_ejabberd_24_12_api_shape() {
        let payload = muc_affiliations_payload("friends", "conference.trix.selfhost.ru");

        assert_eq!(payload["room"], "friends");
        assert_eq!(payload["service"], "conference.trix.selfhost.ru");
        assert!(payload.get("name").is_none());
    }

    #[test]
    fn rejects_placeholder_secrets() {
        assert!(is_insecure_default_secret(""));
        assert!(is_insecure_default_secret("replace-me"));
        assert!(is_insecure_default_secret(
            "dev-local-push-gateway-token-change-me"
        ));
        assert!(is_insecure_default_secret(
            "dev-local-livekit-api-secret-change-me"
        ));
        assert!(!is_insecure_default_secret("deployment-local-secret"));
    }

    #[test]
    fn livekit_identity_is_device_scoped_without_changing_membership_jid() {
        let account = AuthorizedAccount {
            bare_jid: "alice@trix.selfhost.ru".to_owned(),
        };

        assert_eq!(
            livekit_participant_identity(&account, Some("Trix macOS/01")),
            "alice@trix.selfhost.ru/Trix-macOS-01"
        );
        assert_eq!(
            livekit_participant_identity(&account, Some("   ")),
            "alice@trix.selfhost.ru"
        );
    }
}
