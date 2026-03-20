use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use ed25519_dalek::{SigningKey, VerifyingKey};
use serde::{Deserialize as SerdeDeserialize, Serialize as SerdeSerialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret as X25519StaticSecret};

use crate::{AccountRootMaterial, DeviceKeyMaterial};

const TRANSFER_BUNDLE_VERSION: u32 = 1;
const TRANSFER_BUNDLE_DOMAIN: &[u8] = b"trix.device_transfer.v1";

#[derive(Debug, Clone)]
pub struct CreateDeviceTransferBundleInput {
    pub account_id: String,
    pub source_device_id: String,
    pub target_device_id: String,
    pub account_sync_chat_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedDeviceTransferBundle {
    pub account_id: String,
    pub source_device_id: String,
    pub target_device_id: String,
    pub account_sync_chat_id: Option<String>,
    pub account_root_private_key: Vec<u8>,
    pub account_root_public_key: Vec<u8>,
}

#[derive(Debug, Clone, SerdeSerialize, SerdeDeserialize)]
struct TransferBundleEnvelope {
    version: u32,
    sender_transport_pubkey_b64: String,
    nonce_b64: String,
    ciphertext_b64: String,
}

#[derive(Debug, Clone, SerdeSerialize, SerdeDeserialize)]
struct TransferBundlePlaintext {
    version: u32,
    account_id: String,
    source_device_id: String,
    target_device_id: String,
    account_sync_chat_id: Option<String>,
    account_root_private_seed_b64: String,
}

pub fn create_device_transfer_bundle(
    input: CreateDeviceTransferBundleInput,
    account_root: &AccountRootMaterial,
    sender_device_keys: &DeviceKeyMaterial,
    recipient_transport_pubkey: &[u8],
) -> Result<Vec<u8>> {
    let sender_transport_pubkey = sender_device_keys.public_key_bytes();
    let key = derive_sender_bundle_key(
        sender_device_keys,
        &sender_transport_pubkey,
        recipient_transport_pubkey,
    )?;
    let nonce: [u8; 24] = rand::random();
    let plaintext = serde_json::to_vec(&TransferBundlePlaintext {
        version: TRANSFER_BUNDLE_VERSION,
        account_id: input.account_id,
        source_device_id: input.source_device_id,
        target_device_id: input.target_device_id,
        account_sync_chat_id: input.account_sync_chat_id,
        account_root_private_seed_b64: general_purpose::STANDARD
            .encode(account_root.private_key_bytes()),
    })
    .context("failed to serialize transfer bundle plaintext")?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| anyhow!("failed to initialize transfer bundle cipher"))?;
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext.as_ref())
        .map_err(|_| anyhow!("failed to encrypt transfer bundle"))?;

    serde_json::to_vec(&TransferBundleEnvelope {
        version: TRANSFER_BUNDLE_VERSION,
        sender_transport_pubkey_b64: general_purpose::STANDARD.encode(&sender_transport_pubkey),
        nonce_b64: general_purpose::STANDARD.encode(nonce),
        ciphertext_b64: general_purpose::STANDARD.encode(ciphertext),
    })
    .context("failed to serialize transfer bundle envelope")
}

pub fn decrypt_device_transfer_bundle(
    bundle: &[u8],
    recipient_device_keys: &DeviceKeyMaterial,
) -> Result<ImportedDeviceTransferBundle> {
    let envelope: TransferBundleEnvelope =
        serde_json::from_slice(bundle).context("failed to parse transfer bundle envelope")?;
    if envelope.version != TRANSFER_BUNDLE_VERSION {
        return Err(anyhow!(
            "unsupported transfer bundle version: {}",
            envelope.version
        ));
    }

    let sender_transport_pubkey =
        decode_b64(&envelope.sender_transport_pubkey_b64, "sender_transport_pubkey_b64")?;
    let recipient_transport_pubkey = recipient_device_keys.public_key_bytes();
    let key = derive_recipient_bundle_key(
        recipient_device_keys,
        &sender_transport_pubkey,
        &recipient_transport_pubkey,
    )?;
    let nonce = decode_array_24(&envelope.nonce_b64, "nonce_b64")?;
    let ciphertext = decode_b64(&envelope.ciphertext_b64, "ciphertext_b64")?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| anyhow!("failed to initialize transfer bundle cipher"))?;
    let plaintext_bytes = cipher
        .decrypt(XNonce::from_slice(&nonce), ciphertext.as_ref())
        .map_err(|_| anyhow!("failed to decrypt transfer bundle"))?;
    let plaintext: TransferBundlePlaintext = serde_json::from_slice(&plaintext_bytes)
        .context("failed to parse transfer bundle plaintext")?;
    if plaintext.version != TRANSFER_BUNDLE_VERSION {
        return Err(anyhow!(
            "unsupported transfer bundle plaintext version: {}",
            plaintext.version
        ));
    }

    let account_root_private_key =
        decode_array_32(&plaintext.account_root_private_seed_b64, "account_root_private_seed_b64")?;
    let account_root = AccountRootMaterial::from_bytes(account_root_private_key);

    Ok(ImportedDeviceTransferBundle {
        account_id: plaintext.account_id,
        source_device_id: plaintext.source_device_id,
        target_device_id: plaintext.target_device_id,
        account_sync_chat_id: plaintext.account_sync_chat_id,
        account_root_private_key: account_root.private_key_bytes().to_vec(),
        account_root_public_key: account_root.public_key_bytes(),
    })
}

fn derive_sender_bundle_key(
    sender_device_keys: &DeviceKeyMaterial,
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    derive_bundle_key(
        sender_device_keys,
        recipient_transport_pubkey,
        sender_transport_pubkey,
        recipient_transport_pubkey,
    )
}

fn derive_recipient_bundle_key(
    recipient_device_keys: &DeviceKeyMaterial,
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    derive_bundle_key(
        recipient_device_keys,
        sender_transport_pubkey,
        sender_transport_pubkey,
        recipient_transport_pubkey,
    )
}

fn derive_bundle_key(
    own_device_keys: &DeviceKeyMaterial,
    peer_transport_pubkey: &[u8],
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    let own_signing_key = SigningKey::from_bytes(&own_device_keys.private_key_bytes());
    let own_secret = X25519StaticSecret::from(own_signing_key.to_scalar_bytes());
    let peer_verifying_key = VerifyingKey::from_bytes(&to_32_bytes(
        peer_transport_pubkey,
        "peer transport public key",
    )?)
    .context("invalid peer transport public key")?;
    let peer_public = X25519PublicKey::from(peer_verifying_key.to_montgomery().to_bytes());
    let shared_secret = own_secret.diffie_hellman(&peer_public).to_bytes();

    let mut digest = Sha256::new();
    digest.update(TRANSFER_BUNDLE_DOMAIN);
    digest.update(shared_secret);
    digest.update(sender_transport_pubkey);
    digest.update(recipient_transport_pubkey);

    let mut key = [0u8; 32];
    key.copy_from_slice(&digest.finalize());
    Ok(key)
}

fn decode_b64(value: &str, field: &str) -> Result<Vec<u8>> {
    for engine in [
        &general_purpose::STANDARD,
        &general_purpose::STANDARD_NO_PAD,
        &general_purpose::URL_SAFE,
        &general_purpose::URL_SAFE_NO_PAD,
    ] {
        if let Ok(bytes) = engine.decode(value) {
            return Ok(bytes);
        }
    }

    Err(anyhow!("invalid base64 payload for {field}"))
}

fn decode_array_24(value: &str, field: &str) -> Result<[u8; 24]> {
    let bytes = decode_b64(value, field)?;
    bytes.try_into().map_err(|_| anyhow!("{field} must be 24 bytes"))
}

fn decode_array_32(value: &str, field: &str) -> Result<[u8; 32]> {
    let bytes = decode_b64(value, field)?;
    bytes.try_into().map_err(|_| anyhow!("{field} must be 32 bytes"))
}

fn to_32_bytes(bytes: &[u8], label: &str) -> Result<[u8; 32]> {
    bytes.try_into()
        .map_err(|_| anyhow!("{label} must be 32 bytes"))
}

#[cfg(test)]
mod tests {
    use super::{
        CreateDeviceTransferBundleInput, create_device_transfer_bundle,
        decrypt_device_transfer_bundle,
    };
    use crate::{AccountRootMaterial, DeviceKeyMaterial};

    #[test]
    fn transfer_bundle_round_trip_recovers_account_root() {
        let account_root = AccountRootMaterial::generate();
        let approving_device = DeviceKeyMaterial::generate();
        let pending_device = DeviceKeyMaterial::generate();

        let encrypted = create_device_transfer_bundle(
            CreateDeviceTransferBundleInput {
                account_id: "account-1".to_owned(),
                source_device_id: "device-a".to_owned(),
                target_device_id: "device-b".to_owned(),
                account_sync_chat_id: Some("chat-sync-1".to_owned()),
            },
            &account_root,
            &approving_device,
            &pending_device.public_key_bytes(),
        )
        .unwrap();

        let imported = decrypt_device_transfer_bundle(&encrypted, &pending_device).unwrap();

        assert_eq!(imported.account_id, "account-1");
        assert_eq!(imported.source_device_id, "device-a");
        assert_eq!(imported.target_device_id, "device-b");
        assert_eq!(imported.account_sync_chat_id.as_deref(), Some("chat-sync-1"));
        assert_eq!(
            imported.account_root_private_key,
            account_root.private_key_bytes().to_vec()
        );
        assert_eq!(imported.account_root_public_key, account_root.public_key_bytes());
    }

    #[test]
    fn transfer_bundle_rejects_wrong_recipient_key() {
        let account_root = AccountRootMaterial::generate();
        let approving_device = DeviceKeyMaterial::generate();
        let pending_device = DeviceKeyMaterial::generate();
        let wrong_device = DeviceKeyMaterial::generate();

        let encrypted = create_device_transfer_bundle(
            CreateDeviceTransferBundleInput {
                account_id: "account-1".to_owned(),
                source_device_id: "device-a".to_owned(),
                target_device_id: "device-b".to_owned(),
                account_sync_chat_id: None,
            },
            &account_root,
            &approving_device,
            &pending_device.public_key_bytes(),
        )
        .unwrap();

        let error = decrypt_device_transfer_bundle(&encrypted, &wrong_device).unwrap_err();
        assert!(
            error.to_string().contains("failed to decrypt transfer bundle"),
            "{error:?}"
        );
    }
}
