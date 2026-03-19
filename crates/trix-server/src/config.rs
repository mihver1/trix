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
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let bind_addr = env_or("TRIX_BIND_ADDR", "127.0.0.1:8080")?;
        let bind_addr = SocketAddr::from_str(&bind_addr)
            .with_context(|| format!("invalid TRIX_BIND_ADDR: {bind_addr}"))?;

        Ok(Self {
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
            jwt_signing_key: env_or("TRIX_JWT_SIGNING_KEY", "replace-me")?,
        })
    }
}

fn env_or(key: &str, default: &str) -> Result<String> {
    Ok(env::var(key).unwrap_or_else(|_| default.to_owned()))
}
