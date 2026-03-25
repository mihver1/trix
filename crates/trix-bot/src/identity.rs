use std::{
    fs::{self, File},
    path::Path,
};

use anyhow::{Context, Result, anyhow};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{
    ChaCha20Poly1305, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use serde::{Deserialize, Serialize};
use trix_core::{AccountRootMaterial, DeviceKeyMaterial};
use trix_types::{AccountId, ChatId, DeviceId};

use crate::state::BotStateLayout;

pub const DEFAULT_MASTER_SECRET_ENV: &str = "TRIX_BOT_MASTER_SECRET";

#[derive(Debug, Clone)]
pub struct IdentityStoreConfig {
    pub plaintext_dev_store: bool,
    pub master_secret_env: Option<String>,
}

#[derive(Debug, Clone)]
pub struct BotIdentity {
    pub server_url: String,
    pub profile_name: String,
    pub handle: Option<String>,
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub account_sync_chat_id: ChatId,
    pub credential_identity: Vec<u8>,
    pub account_root: AccountRootMaterial,
    pub device_keys: DeviceKeyMaterial,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredBotIdentity {
    version: u32,
    server_url: String,
    profile_name: String,
    handle: Option<String>,
    account_id: AccountId,
    device_id: DeviceId,
    account_sync_chat_id: ChatId,
    credential_identity_b64: String,
    account_root_private_key_b64: String,
    device_private_key_b64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncryptedIdentityFile {
    version: u32,
    kdf: String,
    salt_b64: String,
    nonce_b64: String,
    ciphertext_b64: String,
}

impl IdentityStoreConfig {
    pub fn resolve_master_secret(&self) -> Result<Option<String>> {
        if self.plaintext_dev_store {
            return Ok(None);
        }

        let env_name = self
            .master_secret_env
            .as_deref()
            .unwrap_or(DEFAULT_MASTER_SECRET_ENV);
        let value = std::env::var(env_name).with_context(|| {
            format!("missing bot master secret env var `{env_name}` for encrypted identity store")
        })?;
        if value.is_empty() {
            return Err(anyhow!(
                "bot master secret env var `{env_name}` must not be empty"
            ));
        }
        Ok(Some(value))
    }

    pub fn exists(&self, layout: &BotStateLayout) -> bool {
        if self.plaintext_dev_store {
            layout.identity_path.exists()
        } else {
            layout.encrypted_identity_path.exists()
        }
    }

    pub fn save(&self, layout: &BotStateLayout, identity: &BotIdentity) -> Result<()> {
        let stored = StoredBotIdentity::from(identity);
        if self.plaintext_dev_store {
            save_json(&layout.identity_path, &stored)?;
            return Ok(());
        }

        let secret = self
            .resolve_master_secret()?
            .ok_or_else(|| anyhow!("encrypted identity store requires a master secret"))?;
        let plaintext =
            serde_json::to_vec_pretty(&stored).context("failed to encode bot identity json")?;
        let salt: [u8; 16] = rand::random();
        let nonce: [u8; 12] = rand::random();
        let ciphertext = encrypt_identity(&secret, &salt, &nonce, &plaintext)?;
        save_json(
            &layout.encrypted_identity_path,
            &EncryptedIdentityFile {
                version: 1,
                kdf: "argon2id".to_owned(),
                salt_b64: general_purpose::STANDARD.encode(salt),
                nonce_b64: general_purpose::STANDARD.encode(nonce),
                ciphertext_b64: general_purpose::STANDARD.encode(ciphertext),
            },
        )?;
        Ok(())
    }

    pub fn load(&self, layout: &BotStateLayout) -> Result<BotIdentity> {
        if self.plaintext_dev_store {
            let stored: StoredBotIdentity = load_json(&layout.identity_path)?;
            return BotIdentity::try_from(stored);
        }

        let secret = self
            .resolve_master_secret()?
            .ok_or_else(|| anyhow!("encrypted identity store requires a master secret"))?;
        let encrypted: EncryptedIdentityFile = load_json(&layout.encrypted_identity_path)?;
        let salt = decode_fixed::<16>("salt_b64", &encrypted.salt_b64)?;
        let nonce = decode_fixed::<12>("nonce_b64", &encrypted.nonce_b64)?;
        let ciphertext = decode_bytes("ciphertext_b64", &encrypted.ciphertext_b64)?;
        let plaintext = decrypt_identity(&secret, &salt, &nonce, &ciphertext)?;
        let stored: StoredBotIdentity =
            serde_json::from_slice(&plaintext).context("failed to decode decrypted identity")?;
        BotIdentity::try_from(stored)
    }
}

impl From<&BotIdentity> for StoredBotIdentity {
    fn from(value: &BotIdentity) -> Self {
        Self {
            version: 1,
            server_url: value.server_url.clone(),
            profile_name: value.profile_name.clone(),
            handle: value.handle.clone(),
            account_id: value.account_id,
            device_id: value.device_id,
            account_sync_chat_id: value.account_sync_chat_id,
            credential_identity_b64: general_purpose::STANDARD.encode(&value.credential_identity),
            account_root_private_key_b64: general_purpose::STANDARD
                .encode(value.account_root.private_key_bytes()),
            device_private_key_b64: general_purpose::STANDARD
                .encode(value.device_keys.private_key_bytes()),
        }
    }
}

impl TryFrom<StoredBotIdentity> for BotIdentity {
    type Error = anyhow::Error;

    fn try_from(value: StoredBotIdentity) -> Result<Self> {
        Ok(Self {
            server_url: value.server_url,
            profile_name: value.profile_name,
            handle: value.handle,
            account_id: value.account_id,
            device_id: value.device_id,
            account_sync_chat_id: value.account_sync_chat_id,
            credential_identity: decode_bytes(
                "credential_identity_b64",
                &value.credential_identity_b64,
            )?,
            account_root: AccountRootMaterial::from_bytes(decode_fixed::<32>(
                "account_root_private_key_b64",
                &value.account_root_private_key_b64,
            )?),
            device_keys: DeviceKeyMaterial::from_bytes(decode_fixed::<32>(
                "device_private_key_b64",
                &value.device_private_key_b64,
            )?),
        })
    }
}

fn save_json(path: &Path, value: &impl Serialize) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create parent directory {}", parent.display()))?;
    }
    let file =
        File::create(path).with_context(|| format!("failed to create {}", path.display()))?;
    serde_json::to_writer_pretty(file, value)
        .with_context(|| format!("failed to write {}", path.display()))
}

fn load_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T> {
    let file = File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    serde_json::from_reader(file).with_context(|| format!("failed to decode {}", path.display()))
}

fn encrypt_identity(
    secret: &str,
    salt: &[u8; 16],
    nonce: &[u8; 12],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    let key = derive_key(secret, salt)?;
    let cipher = ChaCha20Poly1305::new((&key).into());
    cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad: b"trix-bot-identity:v1",
            },
        )
        .map_err(|err| anyhow!("failed to encrypt identity payload: {err}"))
}

fn decrypt_identity(
    secret: &str,
    salt: &[u8; 16],
    nonce: &[u8; 12],
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    let key = derive_key(secret, salt)?;
    let cipher = ChaCha20Poly1305::new((&key).into());
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: ciphertext,
                aad: b"trix-bot-identity:v1",
            },
        )
        .map_err(|err| anyhow!("failed to decrypt identity payload: {err}"))
}

fn derive_key(secret: &str, salt: &[u8; 16]) -> Result<[u8; 32]> {
    let params = Params::new(64 * 1024, 3, 1, Some(32))
        .map_err(|err| anyhow!("failed to build argon2 params for bot identity: {err}"))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = [0u8; 32];
    argon2
        .hash_password_into(secret.as_bytes(), salt, &mut key)
        .map_err(|err| anyhow!("failed to derive bot identity encryption key: {err}"))?;
    Ok(key)
}

fn decode_bytes(field: &'static str, value: &str) -> Result<Vec<u8>> {
    general_purpose::STANDARD
        .decode(value)
        .map_err(|err| anyhow!("invalid base64 in `{field}`: {err}"))
}

fn decode_fixed<const N: usize>(field: &'static str, value: &str) -> Result<[u8; N]> {
    let bytes = decode_bytes(field, value)?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("decoded `{field}` must be {N} bytes"))
}

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use trix_core::{AccountRootMaterial, DeviceKeyMaterial};
    use trix_types::{AccountId, ChatId, DeviceId};
    use uuid::Uuid;

    use super::{BotIdentity, IdentityStoreConfig};
    use crate::state::BotStateLayout;

    #[test]
    fn encrypted_identity_store_round_trips() -> Result<()> {
        let state_dir = std::env::temp_dir().join(format!("trix-bot-identity-{}", Uuid::new_v4()));
        let layout = BotStateLayout::new(&state_dir);
        let env_name = format!("TRIX_BOT_TEST_SECRET_{}", Uuid::new_v4().simple());
        unsafe {
            std::env::set_var(&env_name, "test-secret");
        }

        let config = IdentityStoreConfig {
            plaintext_dev_store: false,
            master_secret_env: Some(env_name.clone()),
        };
        let identity = BotIdentity {
            server_url: "http://localhost:8080".to_owned(),
            profile_name: "Echo Bot".to_owned(),
            handle: Some("echo-bot".to_owned()),
            account_id: AccountId(Uuid::new_v4()),
            device_id: DeviceId(Uuid::new_v4()),
            account_sync_chat_id: ChatId(Uuid::new_v4()),
            credential_identity: b"bot-credential".to_vec(),
            account_root: AccountRootMaterial::generate(),
            device_keys: DeviceKeyMaterial::generate(),
        };

        config.save(&layout, &identity)?;
        let restored = config.load(&layout)?;

        assert_eq!(restored.server_url, identity.server_url);
        assert_eq!(restored.profile_name, identity.profile_name);
        assert_eq!(restored.handle, identity.handle);
        assert_eq!(restored.account_id, identity.account_id);
        assert_eq!(restored.device_id, identity.device_id);
        assert_eq!(restored.account_sync_chat_id, identity.account_sync_chat_id);
        assert_eq!(restored.credential_identity, identity.credential_identity);
        assert_eq!(
            restored.account_root.private_key_bytes(),
            identity.account_root.private_key_bytes()
        );
        assert_eq!(
            restored.device_keys.private_key_bytes(),
            identity.device_keys.private_key_bytes()
        );

        std::fs::remove_dir_all(&state_dir).ok();
        unsafe {
            std::env::remove_var(env_name);
        }
        Ok(())
    }
}
