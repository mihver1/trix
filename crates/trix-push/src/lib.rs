use std::{
    fmt,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use http::StatusCode;
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::Mutex;
use trix_types::ApplePushEnvironment;

const APNS_AUTH_TOKEN_TTL_SECONDS: u64 = 50 * 60;
const APNS_PUSH_TYPE_BACKGROUND: &str = "background";
const APNS_PRIORITY_BACKGROUND: &str = "5";
const APNS_PUSH_TYPE_ALERT: &str = "alert";
const APNS_PRIORITY_ALERT: &str = "10";
const APNS_COLLAPSE_ID: &str = "trix-inbox";
const APNS_ALERT_TITLE: &str = "Trix";
const APNS_ALERT_BODY_SINGLE: &str = "New encrypted message";

#[derive(Clone)]
pub struct ApnsPushConfig {
    pub team_id: String,
    pub key_id: String,
    pub topic: String,
    pub private_key_pem: String,
}

impl fmt::Debug for ApnsPushConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApnsPushConfig")
            .field("team_id", &self.team_id)
            .field("key_id", &self.key_id)
            .field("topic", &self.topic)
            .field("private_key_pem", &"[REDACTED]")
            .finish()
    }
}

impl ApnsPushConfig {
    pub fn new(
        team_id: impl Into<String>,
        key_id: impl Into<String>,
        topic: impl Into<String>,
        private_key_pem: impl Into<String>,
    ) -> Self {
        Self {
            team_id: team_id.into(),
            key_id: key_id.into(),
            topic: topic.into(),
            private_key_pem: private_key_pem.into(),
        }
    }

    pub fn validate(&self) -> Result<()> {
        if self.team_id.trim().is_empty() {
            anyhow::bail!("TRIX_APNS_TEAM_ID must not be empty");
        }
        if self.key_id.trim().is_empty() {
            anyhow::bail!("TRIX_APNS_KEY_ID must not be empty");
        }
        if self.topic.trim().is_empty() {
            anyhow::bail!("TRIX_APNS_TOPIC must not be empty");
        }
        if self.private_key_pem.trim().is_empty() {
            anyhow::bail!("TRIX_APNS private key must not be empty");
        }
        Ok(())
    }
}

pub struct ApnsPushClient {
    client: Client,
    team_id: String,
    key_id: String,
    topic: String,
    encoding_key: EncodingKey,
    cached_auth_token: Mutex<Option<CachedApnsAuthToken>>,
}

impl ApnsPushClient {
    pub fn new(config: ApnsPushConfig) -> Result<Self> {
        config.validate()?;
        let encoding_key = EncodingKey::from_ec_pem(config.private_key_pem.as_bytes())
            .context("failed to parse APNs EC private key")?;

        Ok(Self {
            client: Client::builder()
                .build()
                .context("failed to build APNs HTTP client")?,
            team_id: config.team_id,
            key_id: config.key_id,
            topic: config.topic,
            encoding_key,
            cached_auth_token: Mutex::new(None),
        })
    }

    pub async fn deliver_notification(
        &self,
        target: ApnsPushTarget,
        notification: TrixApnsNotificationPayload,
    ) -> Result<ApnsDeliveryOutcome> {
        self.deliver_payload(
            target,
            APNS_PUSH_TYPE_ALERT,
            APNS_PRIORITY_ALERT,
            notification,
        )
        .await
    }

    pub async fn deliver_wake(
        &self,
        target: ApnsPushTarget,
        wake: TrixApnsWakePayload,
    ) -> Result<ApnsDeliveryOutcome> {
        self.deliver_payload(
            target,
            APNS_PUSH_TYPE_BACKGROUND,
            APNS_PRIORITY_BACKGROUND,
            wake,
        )
        .await
    }

    async fn deliver_payload<T: Serialize>(
        &self,
        target: ApnsPushTarget,
        push_type: &'static str,
        priority: &'static str,
        payload: T,
    ) -> Result<ApnsDeliveryOutcome> {
        let authorization = self.authorization_header().await?;
        let url = format!(
            "https://{}/3/device/{}",
            apns_host_for_environment(target.environment),
            target.token_hex
        );
        let response = self
            .client
            .post(url)
            .header("authorization", authorization)
            .header("apns-topic", &self.topic)
            .header("apns-push-type", push_type)
            .header("apns-priority", priority)
            .header("apns-collapse-id", APNS_COLLAPSE_ID)
            .json(&payload)
            .send()
            .await
            .map_err(|_| anyhow::anyhow!("failed to send APNs request"))?;

        let status = response.status();
        if status == StatusCode::OK {
            return Ok(ApnsDeliveryOutcome::Delivered);
        }

        let response_body = response.text().await.unwrap_or_default();
        let reason = serde_json::from_str::<ApnsErrorResponse>(&response_body)
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
        let disable_registration = should_disable_registration(status, &reason);

        Ok(ApnsDeliveryOutcome::Rejected {
            reason,
            disable_registration,
        })
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

#[derive(Clone)]
pub struct ApnsPushTarget {
    pub token_hex: String,
    pub environment: ApplePushEnvironment,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApnsDeliveryOutcome {
    Delivered,
    Rejected {
        reason: String,
        disable_registration: bool,
    },
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct TrixApnsNotificationPayload {
    aps: ApnsNotificationAps,
    trix: TrixSyncMetadata,
}

impl TrixApnsNotificationPayload {
    pub fn new(account: Option<String>, room: Option<String>, badge: Option<u32>) -> Self {
        Self {
            aps: ApnsNotificationAps {
                alert: ApnsPayloadAlert {
                    title: APNS_ALERT_TITLE,
                    body: notification_body(badge),
                },
                content_available: 1,
                sound: "default",
                badge,
            },
            trix: TrixSyncMetadata {
                payload_type: "sync",
                version: 1,
                account,
                room,
                badge,
            },
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct ApnsNotificationAps {
    alert: ApnsPayloadAlert,
    #[serde(rename = "content-available")]
    content_available: u8,
    sound: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    badge: Option<u32>,
}

impl Default for ApnsNotificationAps {
    fn default() -> Self {
        Self {
            alert: ApnsPayloadAlert {
                title: APNS_ALERT_TITLE,
                body: APNS_ALERT_BODY_SINGLE.to_owned(),
            },
            content_available: 1,
            sound: "default",
            badge: None,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct TrixApnsWakePayload {
    aps: ApnsWakeAps,
    trix: TrixSyncMetadata,
}

impl TrixApnsWakePayload {
    pub fn new(account: Option<String>, room: Option<String>, badge: Option<u32>) -> Self {
        Self {
            aps: ApnsWakeAps {
                content_available: 1,
                badge,
            },
            trix: TrixSyncMetadata {
                payload_type: "sync",
                version: 1,
                account,
                room,
                badge,
            },
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct ApnsWakeAps {
    #[serde(rename = "content-available")]
    content_available: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    badge: Option<u32>,
}

impl Default for ApnsWakeAps {
    fn default() -> Self {
        Self {
            content_available: 1,
            badge: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct ApnsPayloadAlert {
    title: &'static str,
    body: String,
}

#[derive(Debug, Clone, Serialize)]
struct TrixSyncMetadata {
    #[serde(rename = "type")]
    payload_type: &'static str,
    version: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    account: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    room: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    badge: Option<u32>,
}

impl Default for TrixSyncMetadata {
    fn default() -> Self {
        Self {
            payload_type: "sync",
            version: 1,
            account: None,
            room: None,
            badge: None,
        }
    }
}

#[derive(Serialize)]
struct ApnsTokenClaims {
    iss: String,
    iat: u64,
}

struct CachedApnsAuthToken {
    value: String,
    expires_at_unix: u64,
}

#[derive(Deserialize)]
struct ApnsErrorResponse {
    reason: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ApnsTokenError {
    #[error("token_hex must not be empty")]
    Empty,
    #[error("token_hex must contain an even number of hex characters")]
    OddLength,
    #[error("token_hex must be a hex-encoded APNs token")]
    InvalidHex,
}

pub fn normalize_apns_token_hex(raw_value: &str) -> std::result::Result<String, ApnsTokenError> {
    let normalized: String = raw_value
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .map(|character| character.to_ascii_lowercase())
        .collect();

    if normalized.is_empty() {
        return Err(ApnsTokenError::Empty);
    }
    if normalized.len() % 2 != 0 {
        return Err(ApnsTokenError::OddLength);
    }
    if !normalized
        .chars()
        .all(|character| character.is_ascii_hexdigit())
    {
        return Err(ApnsTokenError::InvalidHex);
    }

    Ok(normalized)
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

fn notification_body(badge: Option<u32>) -> String {
    match badge {
        Some(1) | None => APNS_ALERT_BODY_SINGLE.to_owned(),
        Some(count) => format!("{count} unread encrypted messages"),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn notification_payload_is_generic_sync_only() {
        let payload = TrixApnsNotificationPayload::new(
            Some("alice@trix.selfhost.ru".to_owned()),
            Some("room@example".to_owned()),
            Some(3),
        );

        let value = serde_json::to_value(payload).expect("payload serializes");
        assert_eq!(value["aps"]["alert"]["title"], json!("Trix"));
        assert_eq!(
            value["aps"]["alert"]["body"],
            json!("3 unread encrypted messages")
        );
        assert_eq!(value["aps"]["sound"], json!("default"));
        assert_eq!(value["aps"]["content-available"], json!(1));
        assert_eq!(value["aps"]["badge"], json!(3));
        assert_eq!(value["trix"]["type"], json!("sync"));
        assert_eq!(value["trix"]["version"], json!(1));
        assert_eq!(value["trix"]["account"], json!("alice@trix.selfhost.ru"));
        assert_eq!(value["trix"]["room"], json!("room@example"));
        assert!(value.get("body").is_none());
        assert!(value.get("plaintext").is_none());
    }

    #[test]
    fn wake_payload_remains_background_sync_only() {
        let payload = TrixApnsWakePayload::new(
            Some("alice@trix.selfhost.ru".to_owned()),
            Some("room@example".to_owned()),
            Some(3),
        );

        let value = serde_json::to_value(payload).expect("payload serializes");
        assert_eq!(value["aps"]["content-available"], json!(1));
        assert_eq!(value["aps"]["badge"], json!(3));
        assert_eq!(value["trix"]["type"], json!("sync"));
        assert_eq!(value["trix"]["version"], json!(1));
        assert_eq!(value["trix"]["account"], json!("alice@trix.selfhost.ru"));
        assert_eq!(value["trix"]["room"], json!("room@example"));
        assert!(value["aps"].get("alert").is_none());
        assert!(value["aps"].get("sound").is_none());
    }

    #[test]
    fn normalizes_apns_token_without_logging_value() {
        assert_eq!(
            normalize_apns_token_hex(" AA bb\nCC ").expect("valid token"),
            "aabbcc"
        );
        assert_eq!(
            normalize_apns_token_hex("").unwrap_err(),
            ApnsTokenError::Empty
        );
        assert_eq!(
            normalize_apns_token_hex("abc").unwrap_err(),
            ApnsTokenError::OddLength
        );
        assert_eq!(
            normalize_apns_token_hex("zz").unwrap_err(),
            ApnsTokenError::InvalidHex
        );
    }
}
