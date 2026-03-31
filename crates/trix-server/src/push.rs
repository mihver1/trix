use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use futures_util::stream::{self, StreamExt};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tracing::warn;
use uuid::Uuid;

use crate::{config::AppConfig, db::{Database, DeviceApnsRegistrationRow}};
use trix_types::ApplePushEnvironment;

const APNS_AUTH_TOKEN_TTL_SECONDS: u64 = 50 * 60;
const APNS_PUSH_TYPE_BACKGROUND: &str = "background";
const APNS_PRIORITY_BACKGROUND: &str = "5";
const APNS_COLLAPSE_ID: &str = "trix-inbox";

#[derive(Clone, Default)]
pub struct PushNotificationService {
    apns: Option<Arc<ApnsPushClient>>,
}

impl PushNotificationService {
    pub fn from_config(config: &AppConfig) -> Result<Self> {
        let apns = match (
            config.apns_team_id.as_deref(),
            config.apns_key_id.as_deref(),
            config.apns_topic.as_deref(),
            config.apns_private_key_pem.as_deref(),
        ) {
            (Some(team_id), Some(key_id), Some(topic), Some(private_key_pem)) => Some(Arc::new(
                ApnsPushClient::new(team_id, key_id, topic, private_key_pem)?,
            )),
            _ => None,
        };

        Ok(Self { apns })
    }

    pub fn is_delivery_enabled(&self) -> bool {
        self.apns.is_some()
    }

    pub async fn notify_inbox_for_devices(&self, db: Arc<Database>, device_ids: Vec<Uuid>) {
        let Some(apns) = &self.apns else {
            return;
        };
        if device_ids.is_empty() {
            return;
        }

        let registrations = match db.list_device_apns_registrations(&device_ids).await {
            Ok(registrations) => registrations,
            Err(err) => {
                warn!("failed to load APNs registrations: {err}");
                return;
            }
        };
        if registrations.is_empty() {
            return;
        }

        stream::iter(registrations.into_iter())
            .for_each_concurrent(8, |registration| {
                let apns = apns.clone();
                let db = db.clone();
                async move {
                    if let Err(err) = apns.deliver_inbox_update(db, registration).await {
                        warn!("failed to deliver APNs inbox update: {err}");
                    }
                }
            })
            .await;
    }
}

struct ApnsPushClient {
    client: Client,
    team_id: String,
    key_id: String,
    topic: String,
    encoding_key: EncodingKey,
    cached_auth_token: Mutex<Option<CachedApnsAuthToken>>,
}

impl ApnsPushClient {
    fn new(team_id: &str, key_id: &str, topic: &str, private_key_pem: &str) -> Result<Self> {
        let encoding_key = EncodingKey::from_ec_pem(private_key_pem.as_bytes())
            .context("failed to parse APNs EC private key")?;

        Ok(Self {
            client: Client::builder()
                .build()
                .context("failed to build APNs HTTP client")?,
            team_id: team_id.to_owned(),
            key_id: key_id.to_owned(),
            topic: topic.to_owned(),
            encoding_key,
            cached_auth_token: Mutex::new(None),
        })
    }

    async fn deliver_inbox_update(
        &self,
        db: Arc<Database>,
        registration: DeviceApnsRegistrationRow,
    ) -> Result<()> {
        let payload = ApnsPushPayload::default();
        let authorization = self.authorization_header().await?;
        let url = format!(
            "https://{}/3/device/{}",
            apns_host_for_environment(registration.environment),
            registration.token_hex
        );
        let response = self
            .client
            .post(url)
            .header("authorization", authorization)
            .header("apns-topic", &self.topic)
            .header("apns-push-type", APNS_PUSH_TYPE_BACKGROUND)
            .header("apns-priority", APNS_PRIORITY_BACKGROUND)
            .header("apns-collapse-id", APNS_COLLAPSE_ID)
            .json(&payload)
            .send()
            .await
            .context("failed to send APNs request")?;

        let status = response.status();
        if status == StatusCode::OK {
            db.mark_device_apns_delivery_success(registration.device_id)
                .await?;
            return Ok(());
        }

        let response_body = response.text().await.unwrap_or_default();
        let apns_reason = serde_json::from_str::<ApnsErrorResponse>(&response_body)
            .ok()
            .map(|body| body.reason)
            .filter(|reason| !reason.is_empty())
            .unwrap_or_else(|| {
                if response_body.is_empty() {
                    status.to_string()
                } else {
                    format!("{status}: {response_body}")
                }
            });
        let disable_registration = should_disable_registration(status, &apns_reason);

        db.record_device_apns_delivery_failure(
            registration.device_id,
            &apns_reason,
            disable_registration,
        )
        .await?;

        Ok(())
    }

    async fn authorization_header(&self) -> Result<String> {
        let now = unix_now();
        let mut cached = self.cached_auth_token.lock().await;
        if let Some(token) = cached.as_ref() {
            if token.expires_at_unix > now + 30 {
                return Ok(format!("bearer {}", token.value));
            }
        }

        let claims = ApnsTokenClaims {
            iss: self.team_id.clone(),
            iat: now,
        };
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());

        let value = jsonwebtoken::encode(&header, &claims, &self.encoding_key)
            .context("failed to encode APNs auth token")?;
        *cached = Some(CachedApnsAuthToken {
            value: value.clone(),
            expires_at_unix: now.saturating_add(APNS_AUTH_TOKEN_TTL_SECONDS),
        });

        Ok(format!("bearer {}", value))
    }
}

struct CachedApnsAuthToken {
    value: String,
    expires_at_unix: u64,
}

#[derive(Serialize)]
struct ApnsTokenClaims {
    iss: String,
    iat: u64,
}

#[derive(Serialize)]
struct ApnsPushPayload {
    aps: ApnsPayloadAps,
    trix: TrixInboxPushPayload,
}

impl Default for ApnsPushPayload {
    fn default() -> Self {
        Self {
            aps: ApnsPayloadAps {
                content_available: 1,
            },
            trix: TrixInboxPushPayload {
                event: "inbox_update",
                version: 1,
            },
        }
    }
}

#[derive(Serialize)]
struct ApnsPayloadAps {
    #[serde(rename = "content-available")]
    content_available: u8,
}

#[derive(Serialize)]
struct TrixInboxPushPayload {
    event: &'static str,
    version: u8,
}

#[derive(Deserialize)]
struct ApnsErrorResponse {
    reason: String,
}

fn apns_host_for_environment(environment: ApplePushEnvironment) -> &'static str {
    match environment {
        ApplePushEnvironment::Sandbox => "api.sandbox.push.apple.com",
        ApplePushEnvironment::Production => "api.push.apple.com",
    }
}

fn should_disable_registration(status: StatusCode, reason: &str) -> bool {
    matches!(status, StatusCode::BAD_REQUEST | StatusCode::GONE)
        && matches!(
            reason,
            "BadDeviceToken" | "DeviceTokenNotForTopic" | "Unregistered"
        )
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
