use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use trix_push::{ApplePushEnvironment, normalize_apns_token_hex};

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
        let owner_jid = bare_jid(owner_jid).to_ascii_lowercase();
        let node = registration_node(&owner_jid, provider, &normalized_token);

        let registration = StoredRegistration {
            node: node.clone(),
            owner_jid,
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
        let owner_jid = bare_jid(owner_jid).to_ascii_lowercase();
        let node = registration_node(&owner_jid, provider, &normalized_token);

        let mut state = self.state.lock().await;
        state.registrations.remove(&node);
        self.persist_locked(&state).await
    }

    pub async fn registration_for_node(&self, node: &str) -> Option<StoredRegistration> {
        let state = self.state.lock().await;
        state
            .registrations
            .get(node)
            .filter(|registration| registration.is_sync_registration())
            .filter(|registration| registration.disabled_at_unix.is_none())
            .cloned()
    }

    pub async fn sync_push_succeeded_recently(&self, node: &str, min_interval: Duration) -> bool {
        let min_interval_secs = min_interval.as_secs();
        if min_interval_secs == 0 {
            return false;
        }

        let state = self.state.lock().await;
        let Some(registration) = state
            .registrations
            .get(node)
            .filter(|registration| registration.is_sync_registration())
            .filter(|registration| registration.disabled_at_unix.is_none())
        else {
            return false;
        };

        let Some(last_success_at_unix) = registration.last_success_at_unix else {
            return false;
        };

        unix_now().saturating_sub(last_success_at_unix) < min_interval_secs
    }

    pub async fn voip_registrations_for_owner(&self, owner_jid: &str) -> Vec<StoredRegistration> {
        let owner_jid = bare_jid(owner_jid).to_ascii_lowercase();
        let state = self.state.lock().await;
        state
            .registrations
            .values()
            .filter(|registration| registration.owner_jid == owner_jid)
            .filter(|registration| registration.is_voip_registration())
            .filter(|registration| registration.disabled_at_unix.is_none())
            .cloned()
            .collect()
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

impl StoredRegistration {
    fn is_sync_registration(&self) -> bool {
        provider_kind(&self.provider) == Some(PushProviderKind::Sync)
    }

    fn is_voip_registration(&self) -> bool {
        provider_kind(&self.provider) == Some(PushProviderKind::Voip)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PushProviderKind {
    Sync,
    Voip,
}

fn provider_environment(provider: &str) -> Result<ApplePushEnvironment> {
    match provider {
        "apns-sandbox" | "apns-voip-sandbox" => Ok(ApplePushEnvironment::Sandbox),
        "apns-production" | "apns-voip-production" => Ok(ApplePushEnvironment::Production),
        _ => anyhow::bail!("unsupported push provider"),
    }
}

fn provider_kind(provider: &str) -> Option<PushProviderKind> {
    match provider {
        "apns-sandbox" | "apns-production" => Some(PushProviderKind::Sync),
        "apns-voip-sandbox" | "apns-voip-production" => Some(PushProviderKind::Voip),
        _ => None,
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
    let prefix = match provider_kind(provider) {
        Some(PushProviderKind::Voip) => "trix-voip",
        _ => "trix-push",
    };
    format!("{prefix}/{}", hex_lower(&digest[..16]))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voip_providers_use_distinct_registration_namespace() {
        let sync_node = registration_node("alice@trix.selfhost.ru", "apns-sandbox", "001122");
        let voip_node = registration_node("alice@trix.selfhost.ru", "apns-voip-sandbox", "001122");

        assert!(sync_node.starts_with("trix-push/"));
        assert!(voip_node.starts_with("trix-voip/"));
        assert_ne!(sync_node, voip_node);
        assert_eq!(
            provider_environment("apns-voip-production").expect("voip provider"),
            ApplePushEnvironment::Production
        );
    }

    #[tokio::test]
    async fn recent_sync_success_suppresses_duplicate_pushes() {
        let directory = std::env::temp_dir().join(format!(
            "trix-push-store-{}-{}",
            std::process::id(),
            unix_now()
        ));
        std::fs::create_dir_all(&directory).expect("temp store directory");
        let path = directory.join("registrations.json");
        let store = PushRegistrationStore::open(path.clone())
            .await
            .expect("store opens");
        let registration = store
            .register("alice@trix.selfhost.ru/ios", "apns-sandbox", "001122aabbcc")
            .await
            .expect("registration succeeds");

        assert!(
            !store
                .sync_push_succeeded_recently(&registration.node, Duration::from_secs(60))
                .await
        );

        store
            .mark_success(&registration.node)
            .await
            .expect("success persisted");

        assert!(
            store
                .sync_push_succeeded_recently(&registration.node, Duration::from_secs(60))
                .await
        );
        assert!(
            !store
                .sync_push_succeeded_recently(&registration.node, Duration::from_secs(0))
                .await
        );

        let _ = std::fs::remove_dir_all(directory);
    }
}
