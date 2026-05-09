use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use trix_types::ApplePushEnvironment;

use trix_push::normalize_apns_token_hex;

pub struct PushRegistrationStore {
    path: PathBuf,
    state: Mutex<StoreState>,
}

impl PushRegistrationStore {
    pub async fn open(path: PathBuf) -> Result<Self> {
        let state = match tokio::fs::read_to_string(&path).await {
            Ok(contents) => serde_json::from_str(&contents).with_context(|| {
                format!(
                    "failed to parse push registration store: {}",
                    path.display()
                )
            })?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => StoreState::default(),
            Err(err) => {
                return Err(err).with_context(|| {
                    format!("failed to read push registration store: {}", path.display())
                });
            }
        };

        Ok(Self {
            path,
            state: Mutex::new(state),
        })
    }

    pub async fn register(
        &self,
        owner_jid: &str,
        provider: &str,
        token_hex: &str,
    ) -> Result<StoredRegistration> {
        let environment = provider_environment(provider)?;
        let normalized_token =
            normalize_apns_token_hex(token_hex).map_err(|err| anyhow::anyhow!(err.to_string()))?;
        let owner_jid = bare_jid(owner_jid);
        let node = registration_node(owner_jid, provider, &normalized_token);

        let registration = StoredRegistration {
            node: node.clone(),
            owner_jid: owner_jid.to_owned(),
            provider: provider.to_owned(),
            token_hex: normalized_token,
            environment,
            updated_at_unix: unix_now(),
            disabled_at_unix: None,
            last_success_at_unix: None,
            last_failure_at_unix: None,
            failure_reason: None,
        };

        let mut state = self.state.lock().await;
        state.registrations.insert(node, registration.clone());
        self.persist_locked(&state).await?;
        Ok(registration)
    }

    pub async fn unregister(&self, owner_jid: &str, provider: &str, token_hex: &str) -> Result<()> {
        let normalized_token =
            normalize_apns_token_hex(token_hex).map_err(|err| anyhow::anyhow!(err.to_string()))?;
        let owner_jid = bare_jid(owner_jid);
        let node = registration_node(owner_jid, provider, &normalized_token);

        let mut state = self.state.lock().await;
        state.registrations.remove(&node);
        self.persist_locked(&state).await
    }

    pub async fn registration_for_node(&self, node: &str) -> Option<StoredRegistration> {
        let state = self.state.lock().await;
        state
            .registrations
            .get(node)
            .filter(|registration| registration.disabled_at_unix.is_none())
            .cloned()
    }

    pub async fn mark_success(&self, node: &str) -> Result<()> {
        let mut state = self.state.lock().await;
        if let Some(registration) = state.registrations.get_mut(node) {
            registration.updated_at_unix = unix_now();
            registration.last_success_at_unix = Some(unix_now());
            registration.last_failure_at_unix = None;
            registration.failure_reason = None;
        }
        self.persist_locked(&state).await
    }

    pub async fn mark_failure(
        &self,
        node: &str,
        reason: &str,
        disable_registration: bool,
    ) -> Result<()> {
        let mut state = self.state.lock().await;
        if let Some(registration) = state.registrations.get_mut(node) {
            registration.updated_at_unix = unix_now();
            registration.last_failure_at_unix = Some(unix_now());
            registration.failure_reason = Some(reason.to_owned());
            if disable_registration {
                registration.disabled_at_unix = Some(unix_now());
            }
        }
        self.persist_locked(&state).await
    }

    async fn persist_locked(&self, state: &StoreState) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await.with_context(|| {
                format!(
                    "failed to create push registration store directory: {}",
                    parent.display()
                )
            })?;
            set_dir_permissions(parent).await?;
        }

        let contents = serde_json::to_vec_pretty(state)
            .context("failed to serialize push registration store")?;
        let tmp_path = self.path.with_extension("json.tmp");
        tokio::fs::write(&tmp_path, contents)
            .await
            .with_context(|| {
                format!(
                    "failed to write push registration store: {}",
                    tmp_path.display()
                )
            })?;
        set_file_permissions(&tmp_path).await?;
        tokio::fs::rename(&tmp_path, &self.path)
            .await
            .with_context(|| {
                format!(
                    "failed to replace push registration store: {}",
                    self.path.display()
                )
            })?;
        Ok(())
    }
}

#[derive(Default, Serialize, Deserialize)]
struct StoreState {
    registrations: BTreeMap<String, StoredRegistration>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct StoredRegistration {
    pub node: String,
    pub owner_jid: String,
    pub provider: String,
    pub token_hex: String,
    pub environment: ApplePushEnvironment,
    updated_at_unix: u64,
    disabled_at_unix: Option<u64>,
    last_success_at_unix: Option<u64>,
    last_failure_at_unix: Option<u64>,
    failure_reason: Option<String>,
}

fn provider_environment(provider: &str) -> Result<ApplePushEnvironment> {
    match provider {
        "apns-sandbox" => Ok(ApplePushEnvironment::Sandbox),
        "apns-production" => Ok(ApplePushEnvironment::Production),
        _ => anyhow::bail!("unsupported push provider"),
    }
}

fn registration_node(owner_jid: &str, provider: &str, token_hex: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(owner_jid.as_bytes());
    hasher.update([0]);
    hasher.update(provider.as_bytes());
    hasher.update([0]);
    hasher.update(token_hex.as_bytes());
    let digest = hasher.finalize();
    format!("trix-push/{}", hex_lower(&digest[..16]))
}

fn bare_jid(jid: &str) -> &str {
    jid.split_once('/').map(|(bare, _)| bare).unwrap_or(jid)
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(unix)]
async fn set_dir_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let permissions = std::fs::Permissions::from_mode(0o700);
    tokio::fs::set_permissions(path, permissions)
        .await
        .with_context(|| {
            format!(
                "failed to set store directory permissions: {}",
                path.display()
            )
        })
}

#[cfg(not(unix))]
async fn set_dir_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
async fn set_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let permissions = std::fs::Permissions::from_mode(0o600);
    tokio::fs::set_permissions(path, permissions)
        .await
        .with_context(|| format!("failed to set store file permissions: {}", path.display()))
}

#[cfg(not(unix))]
async fn set_file_permissions(_path: &Path) -> Result<()> {
    Ok(())
}
