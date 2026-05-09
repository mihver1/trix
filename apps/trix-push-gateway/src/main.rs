use std::{env, net::SocketAddr, path::PathBuf, str::FromStr, sync::Arc};

use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use tracing::warn;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};
use trix_push::{
    ApnsDeliveryOutcome, ApnsPushClient, ApnsPushConfig, ApnsPushTarget, TrixApnsWakePayload,
    normalize_apns_token_hex,
};
use trix_types::{ApplePushEnvironment, ServiceStatus};

mod store;
mod xmpp_component;

use crate::{store::PushRegistrationStore, xmpp_component::XmppComponentConfig};

#[tokio::main]
async fn main() -> Result<()> {
    let config = GatewayConfig::from_env()?;

    tracing_subscriber::registry()
        .with(EnvFilter::new(config.log_filter.clone()))
        .with(fmt::layer())
        .init();

    let apns = Arc::new(ApnsPushClient::new(config.apns.clone())?);
    let store = Arc::new(PushRegistrationStore::open(config.store_path.clone()).await?);

    if let Some(component) = config.xmpp_component.clone() {
        let component_jid = component.jid.clone();
        let component_store = store.clone();
        let component_apns = apns.clone();
        tokio::spawn(async move {
            xmpp_component::run_component(component, component_store, component_apns).await;
        });
        tracing::info!("XMPP push component enabled as {}", component_jid);
    }

    let bind_addr = config.bind_addr;
    let state = GatewayState {
        shared_token: Arc::new(config.shared_token),
        apns,
    };

    let router = Router::new()
        .route("/v0/system/health", get(health))
        .route("/v0/apns/wake", post(send_wake))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(bind_addr)
        .await
        .with_context(|| format!("failed to bind {bind_addr}"))?;
    tracing::info!("trix-push-gateway listening on {}", bind_addr);
    axum::serve(listener, router).await?;
    Ok(())
}

#[derive(Clone)]
struct GatewayState {
    shared_token: Arc<String>,
    apns: Arc<ApnsPushClient>,
}

#[derive(Clone)]
struct GatewayConfig {
    bind_addr: SocketAddr,
    log_filter: String,
    shared_token: String,
    apns: ApnsPushConfig,
    store_path: PathBuf,
    xmpp_component: Option<XmppComponentConfig>,
}

impl GatewayConfig {
    fn from_env() -> Result<Self> {
        let bind_addr = SocketAddr::from_str(&env_or("TRIX_PUSH_BIND_ADDR", "127.0.0.1:8090")?)
            .context("invalid TRIX_PUSH_BIND_ADDR")?;
        let log_filter = env_or(
            "TRIX_PUSH_LOG",
            "info,trix_push_gateway=debug,trix_push=debug",
        )?;
        let shared_token = env_required("TRIX_PUSH_GATEWAY_TOKEN")?;
        if shared_token.trim().is_empty() || shared_token == "replace-me" {
            anyhow::bail!("TRIX_PUSH_GATEWAY_TOKEN must be a non-default secret");
        }

        let private_key_pem = match (
            env::var("TRIX_APNS_PRIVATE_KEY_PEM").ok(),
            env::var("TRIX_APNS_PRIVATE_KEY_PATH").ok(),
        ) {
            (Some(value), _) => value,
            (None, Some(path)) => {
                let path = PathBuf::from(path);
                std::fs::read_to_string(&path).with_context(|| {
                    format!(
                        "failed to read TRIX_APNS_PRIVATE_KEY_PATH: {}",
                        path.display()
                    )
                })?
            }
            (None, None) => {
                anyhow::bail!("TRIX_APNS_PRIVATE_KEY_PEM or TRIX_APNS_PRIVATE_KEY_PATH is required")
            }
        };

        let apns = ApnsPushConfig::new(
            env_required("TRIX_APNS_TEAM_ID")?.trim().to_owned(),
            env_required("TRIX_APNS_KEY_ID")?.trim().to_owned(),
            env_required("TRIX_APNS_TOPIC")?.trim().to_owned(),
            private_key_pem,
        );
        apns.validate()?;

        let store_path = PathBuf::from(env_or(
            "TRIX_PUSH_STORE_PATH",
            "/var/lib/trix-push-gateway/registrations.json",
        )?);

        let xmpp_component = xmpp_component_from_env()?;

        Ok(Self {
            bind_addr,
            log_filter,
            shared_token,
            apns,
            store_path,
            xmpp_component,
        })
    }
}

fn xmpp_component_from_env() -> Result<Option<XmppComponentConfig>> {
    let enabled = match env::var("TRIX_XMPP_COMPONENT_ENABLED").ok() {
        Some(value) => env_truthy_value(&value),
        None => env::var("TRIX_XMPP_COMPONENT_SECRET").is_ok(),
    };
    if !enabled {
        return Ok(None);
    }

    let shared_secret = env_required("TRIX_XMPP_COMPONENT_SECRET")?;
    if shared_secret.trim().is_empty() || shared_secret == "replace-me" {
        anyhow::bail!("TRIX_XMPP_COMPONENT_SECRET must be a non-default secret");
    }

    let jid = env_or("TRIX_XMPP_COMPONENT_JID", "push.trix.selfhost.ru")?
        .trim()
        .to_owned();
    if jid.is_empty() {
        anyhow::bail!("TRIX_XMPP_COMPONENT_JID must not be empty");
    }

    Ok(Some(XmppComponentConfig {
        host: env_or("TRIX_XMPP_COMPONENT_HOST", "127.0.0.1")?,
        port: env_or("TRIX_XMPP_COMPONENT_PORT", "5347")?
            .parse()
            .context("invalid TRIX_XMPP_COMPONENT_PORT")?,
        jid,
        shared_secret,
    }))
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        service: "trix-push-gateway",
        status: ServiceStatus::Ok,
        version: env!("CARGO_PKG_VERSION"),
    })
}

async fn send_wake(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(request): Json<WakeRequest>,
) -> Result<Json<WakeResponse>, GatewayError> {
    authorize(&headers, &state.shared_token)?;

    let token_hex = normalize_apns_token_hex(&request.token_hex)
        .map_err(|err| GatewayError::BadRequest(err.to_string()))?;
    let target = ApnsPushTarget {
        token_hex,
        environment: request.environment,
    };
    let wake = TrixApnsWakePayload::new(request.account, request.room, request.badge);

    let outcome = state.apns.deliver_wake(target, wake).await.map_err(|_| {
        warn!("failed to deliver APNs wake");
        GatewayError::DeliveryFailed
    })?;

    Ok(Json(match outcome {
        ApnsDeliveryOutcome::Delivered => WakeResponse {
            delivered: true,
            disable_registration: false,
            reason: None,
        },
        ApnsDeliveryOutcome::Rejected {
            reason,
            disable_registration,
        } => WakeResponse {
            delivered: false,
            disable_registration,
            reason: Some(reason),
        },
    }))
}

fn authorize(headers: &HeaderMap, expected_token: &str) -> Result<(), GatewayError> {
    let Some(header) = headers.get(axum::http::header::AUTHORIZATION) else {
        return Err(GatewayError::Unauthorized);
    };
    let Ok(value) = header.to_str() else {
        return Err(GatewayError::Unauthorized);
    };
    let Some(token) = value.strip_prefix("Bearer ") else {
        return Err(GatewayError::Unauthorized);
    };
    if token != expected_token {
        return Err(GatewayError::Unauthorized);
    }
    Ok(())
}

#[derive(Deserialize)]
struct WakeRequest {
    token_hex: String,
    environment: ApplePushEnvironment,
    #[serde(default)]
    account: Option<String>,
    #[serde(default)]
    room: Option<String>,
    #[serde(default)]
    badge: Option<u32>,
}

#[derive(Debug, Serialize)]
struct WakeResponse {
    delivered: bool,
    disable_registration: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    service: &'static str,
    status: ServiceStatus,
    version: &'static str,
}

enum GatewayError {
    Unauthorized,
    BadRequest(String),
    DeliveryFailed,
}

impl IntoResponse for GatewayError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "missing or invalid gateway authorization".to_owned(),
            ),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message),
            Self::DeliveryFailed => (
                StatusCode::BAD_GATEWAY,
                "delivery_failed",
                "APNs delivery request failed".to_owned(),
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

fn env_or(key: &str, default: &str) -> Result<String> {
    Ok(env::var(key).unwrap_or_else(|_| default.to_owned()))
}

fn env_required(key: &str) -> Result<String> {
    env::var(key).with_context(|| format!("{key} is required"))
}

fn env_truthy_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}
