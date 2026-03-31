use std::{env, net::SocketAddr, path::PathBuf, str::FromStr};

use anyhow::{Context, Result};

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub bind_addr: SocketAddr,
    pub public_base_url: String,
    pub database_url: String,
    pub blob_root: PathBuf,
    pub blob_max_upload_bytes: u64,
    pub log_filter: String,
    pub jwt_signing_key: String,
    pub admin_username: String,
    pub admin_password: String,
    pub admin_jwt_signing_key: String,
    pub admin_session_ttl_seconds: u64,
    pub cors_allowed_origins: Vec<String>,
    pub rate_limit_window_seconds: u64,
    pub rate_limit_auth_challenge_limit: usize,
    pub rate_limit_auth_session_limit: usize,
    pub rate_limit_link_intents_limit: usize,
    pub rate_limit_directory_limit: usize,
    pub rate_limit_blob_upload_limit: usize,
    pub cleanup_interval_seconds: u64,
    pub auth_challenge_retention_seconds: u64,
    pub link_intent_retention_seconds: u64,
    pub transfer_bundle_retention_seconds: u64,
    pub history_sync_retention_seconds: u64,
    pub pending_blob_retention_seconds: u64,
    pub shutdown_grace_period_seconds: u64,
    pub apns_team_id: Option<String>,
    pub apns_key_id: Option<String>,
    pub apns_topic: Option<String>,
    pub apns_private_key_pem: Option<String>,
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let bind_addr = env_or("TRIX_BIND_ADDR", "127.0.0.1:8080")?;
        let apns_private_key_path = env::var("TRIX_APNS_PRIVATE_KEY_PATH").ok();
        let apns_private_key_pem =
            match (
                env::var("TRIX_APNS_PRIVATE_KEY_PEM").ok(),
                apns_private_key_path.as_deref(),
            ) {
                (Some(value), _) => Some(value),
                (None, Some(path)) => Some(std::fs::read_to_string(path).with_context(|| {
                    format!("failed to read TRIX_APNS_PRIVATE_KEY_PATH: {path}")
                })?),
                (None, None) => None,
            };
        let bind_addr = SocketAddr::from_str(&bind_addr)
            .with_context(|| format!("invalid TRIX_BIND_ADDR: {bind_addr}"))?;
        let config = Self {
            bind_addr,
            public_base_url: env_or("TRIX_PUBLIC_BASE_URL", "http://localhost:8080")?,
            database_url: env_or(
                "TRIX_DATABASE_URL",
                "postgres://trix:trix@localhost:5432/trix",
            )?,
            blob_root: PathBuf::from(env_or("TRIX_BLOB_ROOT", "./blobs")?),
            blob_max_upload_bytes: env_or("TRIX_BLOB_MAX_UPLOAD_BYTES", "26214400")?
                .parse()
                .with_context(|| "invalid TRIX_BLOB_MAX_UPLOAD_BYTES")?,
            log_filter: env_or("TRIX_LOG", "info,trix_server=debug")?,
            jwt_signing_key: env_required("TRIX_JWT_SIGNING_KEY")?,
            admin_username: normalize_admin_env_value(env_required("TRIX_ADMIN_USERNAME")?),
            admin_password: normalize_admin_env_value(env_required("TRIX_ADMIN_PASSWORD")?),
            admin_jwt_signing_key: normalize_admin_env_value(env_required(
                "TRIX_ADMIN_JWT_SIGNING_KEY",
            )?),
            admin_session_ttl_seconds: env_or("TRIX_ADMIN_SESSION_TTL_SECONDS", "900")?
                .parse()
                .with_context(|| "invalid TRIX_ADMIN_SESSION_TTL_SECONDS")?,
            cors_allowed_origins: env_csv("TRIX_CORS_ALLOWED_ORIGINS"),
            rate_limit_window_seconds: env_or("TRIX_RATE_LIMIT_WINDOW_SECONDS", "60")?
                .parse()
                .with_context(|| "invalid TRIX_RATE_LIMIT_WINDOW_SECONDS")?,
            rate_limit_auth_challenge_limit: env_or("TRIX_RATE_LIMIT_AUTH_CHALLENGE_LIMIT", "20")?
                .parse()
                .with_context(|| "invalid TRIX_RATE_LIMIT_AUTH_CHALLENGE_LIMIT")?,
            rate_limit_auth_session_limit: env_or("TRIX_RATE_LIMIT_AUTH_SESSION_LIMIT", "20")?
                .parse()
                .with_context(|| "invalid TRIX_RATE_LIMIT_AUTH_SESSION_LIMIT")?,
            rate_limit_link_intents_limit: env_or("TRIX_RATE_LIMIT_LINK_INTENTS_LIMIT", "30")?
                .parse()
                .with_context(|| "invalid TRIX_RATE_LIMIT_LINK_INTENTS_LIMIT")?,
            rate_limit_directory_limit: env_or("TRIX_RATE_LIMIT_DIRECTORY_LIMIT", "120")?
                .parse()
                .with_context(
                || "invalid TRIX_RATE_LIMIT_DIRECTORY_LIMIT",
            )?,
            rate_limit_blob_upload_limit: env_or("TRIX_RATE_LIMIT_BLOB_UPLOAD_LIMIT", "30")?
                .parse()
                .with_context(|| "invalid TRIX_RATE_LIMIT_BLOB_UPLOAD_LIMIT")?,
            cleanup_interval_seconds: env_or("TRIX_CLEANUP_INTERVAL_SECONDS", "300")?
                .parse()
                .with_context(|| "invalid TRIX_CLEANUP_INTERVAL_SECONDS")?,
            auth_challenge_retention_seconds: env_or(
                "TRIX_AUTH_CHALLENGE_RETENTION_SECONDS",
                "3600",
            )?
            .parse()
            .with_context(|| "invalid TRIX_AUTH_CHALLENGE_RETENTION_SECONDS")?,
            link_intent_retention_seconds: env_or("TRIX_LINK_INTENT_RETENTION_SECONDS", "86400")?
                .parse()
                .with_context(|| "invalid TRIX_LINK_INTENT_RETENTION_SECONDS")?,
            transfer_bundle_retention_seconds: env_or(
                "TRIX_TRANSFER_BUNDLE_RETENTION_SECONDS",
                "86400",
            )?
            .parse()
            .with_context(|| "invalid TRIX_TRANSFER_BUNDLE_RETENTION_SECONDS")?,
            history_sync_retention_seconds: env_or(
                "TRIX_HISTORY_SYNC_RETENTION_SECONDS",
                "604800",
            )?
            .parse()
            .with_context(|| "invalid TRIX_HISTORY_SYNC_RETENTION_SECONDS")?,
            pending_blob_retention_seconds: env_or("TRIX_PENDING_BLOB_RETENTION_SECONDS", "86400")?
                .parse()
                .with_context(|| "invalid TRIX_PENDING_BLOB_RETENTION_SECONDS")?,
            shutdown_grace_period_seconds: env_or("TRIX_SHUTDOWN_GRACE_PERIOD_SECONDS", "15")?
                .parse()
                .with_context(|| "invalid TRIX_SHUTDOWN_GRACE_PERIOD_SECONDS")?,
            apns_team_id: env::var("TRIX_APNS_TEAM_ID")
                .ok()
                .map(normalize_optional_env_value),
            apns_key_id: env::var("TRIX_APNS_KEY_ID")
                .ok()
                .map(normalize_optional_env_value),
            apns_topic: env::var("TRIX_APNS_TOPIC")
                .ok()
                .map(normalize_optional_env_value),
            apns_private_key_pem: apns_private_key_pem.map(normalize_optional_env_value),
        };

        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        let jwt = self.jwt_signing_key.trim();
        if jwt.is_empty() {
            anyhow::bail!("TRIX_JWT_SIGNING_KEY must not be empty");
        }
        if jwt == "replace-me" {
            anyhow::bail!("TRIX_JWT_SIGNING_KEY must not use the insecure default value");
        }

        if self.admin_username.trim().is_empty() {
            anyhow::bail!("TRIX_ADMIN_USERNAME must not be empty");
        }
        if self.admin_password.trim().is_empty() {
            anyhow::bail!("TRIX_ADMIN_PASSWORD must not be empty");
        }
        let admin_jwt = self.admin_jwt_signing_key.trim();
        if admin_jwt.is_empty() {
            anyhow::bail!("TRIX_ADMIN_JWT_SIGNING_KEY must not be empty");
        }
        if admin_jwt == "replace-me" {
            anyhow::bail!("TRIX_ADMIN_JWT_SIGNING_KEY must not use the insecure default value");
        }
        if self.admin_session_ttl_seconds == 0 {
            anyhow::bail!("TRIX_ADMIN_SESSION_TTL_SECONDS must be greater than zero");
        }

        if self.rate_limit_window_seconds == 0 {
            anyhow::bail!("TRIX_RATE_LIMIT_WINDOW_SECONDS must be greater than zero");
        }
        if self.cleanup_interval_seconds == 0 {
            anyhow::bail!("TRIX_CLEANUP_INTERVAL_SECONDS must be greater than zero");
        }
        if self.shutdown_grace_period_seconds == 0 {
            anyhow::bail!("TRIX_SHUTDOWN_GRACE_PERIOD_SECONDS must be greater than zero");
        }

        let apns_field_count = [
            self.apns_team_id.is_some(),
            self.apns_key_id.is_some(),
            self.apns_topic.is_some(),
            self.apns_private_key_pem.is_some(),
        ]
        .into_iter()
        .filter(|is_present| *is_present)
        .count();
        if apns_field_count > 0 && apns_field_count < 4 {
            anyhow::bail!(
                "TRIX_APNS_TEAM_ID, TRIX_APNS_KEY_ID, TRIX_APNS_TOPIC, and TRIX_APNS_PRIVATE_KEY_PEM/TRIX_APNS_PRIVATE_KEY_PATH must be configured together"
            );
        }
        if let Some(team_id) = &self.apns_team_id {
            if team_id.is_empty() {
                anyhow::bail!("TRIX_APNS_TEAM_ID must not be empty");
            }
        }
        if let Some(key_id) = &self.apns_key_id {
            if key_id.is_empty() {
                anyhow::bail!("TRIX_APNS_KEY_ID must not be empty");
            }
        }
        if let Some(topic) = &self.apns_topic {
            if topic.is_empty() {
                anyhow::bail!("TRIX_APNS_TOPIC must not be empty");
            }
        }
        if let Some(private_key_pem) = &self.apns_private_key_pem {
            if private_key_pem.is_empty() {
                anyhow::bail!("TRIX_APNS private key must not be empty");
            }
        }

        Ok(())
    }
}

fn env_or(key: &str, default: &str) -> Result<String> {
    Ok(env::var(key).unwrap_or_else(|_| default.to_owned()))
}

fn env_required(key: &str) -> Result<String> {
    env::var(key).with_context(|| format!("{key} is required"))
}

fn normalize_admin_env_value(value: String) -> String {
    value.trim().to_owned()
}

fn normalize_optional_env_value(value: String) -> String {
    let trimmed = value.trim().to_owned();
    if trimmed.is_empty() {
        String::new()
    } else {
        trimmed
    }
}

fn env_csv(key: &str) -> Vec<String> {
    env::var(key)
        .ok()
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, path::PathBuf, str::FromStr};

    use super::{AppConfig, normalize_admin_env_value};

    fn valid_config() -> AppConfig {
        AppConfig {
            bind_addr: SocketAddr::from_str("127.0.0.1:8080").unwrap(),
            public_base_url: "http://localhost:8080".to_owned(),
            database_url: "postgres://trix:trix@localhost:5432/trix".to_owned(),
            blob_root: PathBuf::from("./blobs"),
            blob_max_upload_bytes: 1024,
            log_filter: "info".to_owned(),
            jwt_signing_key: "test-secret".to_owned(),
            admin_username: "admin".to_owned(),
            admin_password: "admin-pass".to_owned(),
            admin_jwt_signing_key: "admin-test-secret".to_owned(),
            admin_session_ttl_seconds: 900,
            cors_allowed_origins: Vec::new(),
            rate_limit_window_seconds: 60,
            rate_limit_auth_challenge_limit: 10,
            rate_limit_auth_session_limit: 10,
            rate_limit_link_intents_limit: 10,
            rate_limit_directory_limit: 10,
            rate_limit_blob_upload_limit: 10,
            cleanup_interval_seconds: 60,
            auth_challenge_retention_seconds: 60,
            link_intent_retention_seconds: 60,
            transfer_bundle_retention_seconds: 60,
            history_sync_retention_seconds: 60,
            pending_blob_retention_seconds: 60,
            shutdown_grace_period_seconds: 10,
            apns_team_id: None,
            apns_key_id: None,
            apns_topic: None,
            apns_private_key_pem: None,
        }
    }

    #[test]
    fn validate_rejects_default_jwt_secret() {
        let mut config = valid_config();
        config.jwt_signing_key = "replace-me".to_owned();
        assert!(config.validate().is_err());
    }

    #[test]
    fn validate_rejects_empty_jwt_secret() {
        let mut config = valid_config();
        config.jwt_signing_key = " ".to_owned();
        assert!(config.validate().is_err());
    }

    #[test]
    fn validate_requires_admin_credentials() {
        let mut config = valid_config();
        config.admin_username = "".to_owned();
        config.admin_password = "".to_owned();
        config.admin_jwt_signing_key = "admin-test-secret".to_owned();

        assert!(config.validate().is_err());
    }

    #[test]
    fn normalize_admin_env_value_trims_whitespace() {
        assert_eq!(normalize_admin_env_value("  ops  \n".to_owned()), "ops");
        assert_eq!(normalize_admin_env_value("secret".to_owned()), "secret");
    }

    #[test]
    fn validate_rejects_partial_apns_configuration() {
        let mut config = valid_config();
        config.apns_team_id = Some("team".to_owned());
        config.apns_key_id = Some("key".to_owned());

        assert!(config.validate().is_err());
    }
}
