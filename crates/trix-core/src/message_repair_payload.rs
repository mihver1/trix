use anyhow::{Context, Result, anyhow};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use ed25519_dalek::{SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret as X25519StaticSecret};

use crate::{DeviceKeyMaterial, decode_b64_field, encode_b64};

const MESSAGE_REPAIR_PAYLOAD_VERSION: u32 = 1;
const MESSAGE_REPAIR_PAYLOAD_DOMAIN: &[u8] = b"trix.message_repair_witness.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecryptedMessageRepairPayload {
    pub request_id: String,
    pub binding: trix_types::MessageRepairBinding,
    pub witness_account_id: trix_types::AccountId,
    pub witness_device_id: trix_types::DeviceId,
    pub repaired_body: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MessageRepairPayloadEnvelope {
    version: u32,
    sender_transport_pubkey_b64: String,
    nonce_b64: String,
    ciphertext_b64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MessageRepairPayloadPlaintext {
    version: u32,
    request_id: String,
    binding: trix_types::MessageRepairBinding,
    witness_account_id: trix_types::AccountId,
    witness_device_id: trix_types::DeviceId,
    repaired_body_b64: String,
}

pub(crate) fn encrypt_message_repair_payload(
    request_id: &str,
    binding: trix_types::MessageRepairBinding,
    witness_account_id: trix_types::AccountId,
    witness_device_id: trix_types::DeviceId,
    repaired_body: &[u8],
    sender_device_keys: &DeviceKeyMaterial,
    recipient_transport_pubkey: &[u8],
) -> Result<Vec<u8>> {
    let sender_transport_pubkey = sender_device_keys.public_key_bytes();
    let key = derive_sender_payload_key(
        sender_device_keys,
        &sender_transport_pubkey,
        recipient_transport_pubkey,
    )?;
    let nonce: [u8; 24] = rand::random();
    let plaintext = serde_json::to_vec(&MessageRepairPayloadPlaintext {
        version: MESSAGE_REPAIR_PAYLOAD_VERSION,
        request_id: request_id.to_owned(),
        binding,
        witness_account_id,
        witness_device_id,
        repaired_body_b64: encode_b64(repaired_body),
    })
    .context("failed to serialize message repair payload")?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| anyhow!("failed to initialize message repair cipher"))?;
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext.as_ref())
        .map_err(|_| anyhow!("failed to encrypt message repair payload"))?;

    serde_json::to_vec(&MessageRepairPayloadEnvelope {
        version: MESSAGE_REPAIR_PAYLOAD_VERSION,
        sender_transport_pubkey_b64: encode_b64(&sender_transport_pubkey),
        nonce_b64: encode_b64(&nonce),
        ciphertext_b64: encode_b64(&ciphertext),
    })
    .context("failed to serialize message repair envelope")
}

pub(crate) fn decrypt_message_repair_payload(
    payload: &[u8],
    recipient_device_keys: &DeviceKeyMaterial,
) -> Result<DecryptedMessageRepairPayload> {
    let envelope: MessageRepairPayloadEnvelope =
        serde_json::from_slice(payload).context("failed to parse message repair envelope")?;
    if envelope.version != MESSAGE_REPAIR_PAYLOAD_VERSION {
        return Err(anyhow!(
            "unsupported message repair envelope version: {}",
            envelope.version
        ));
    }

    let sender_transport_pubkey = decode_b64_field(
        "sender_transport_pubkey_b64",
        &envelope.sender_transport_pubkey_b64,
    )?;
    let recipient_transport_pubkey = recipient_device_keys.public_key_bytes();
    let key = derive_recipient_payload_key(
        recipient_device_keys,
        &sender_transport_pubkey,
        &recipient_transport_pubkey,
    )?;
    let nonce = decode_array_24(&envelope.nonce_b64)?;
    let ciphertext = decode_b64_field("ciphertext_b64", &envelope.ciphertext_b64)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| anyhow!("failed to initialize message repair cipher"))?;
    let plaintext = cipher
        .decrypt(XNonce::from_slice(&nonce), ciphertext.as_ref())
        .map_err(|_| anyhow!("failed to decrypt message repair payload"))?;
    let decrypted: MessageRepairPayloadPlaintext =
        serde_json::from_slice(&plaintext).context("failed to parse message repair payload")?;
    if decrypted.version != MESSAGE_REPAIR_PAYLOAD_VERSION {
        return Err(anyhow!(
            "unsupported message repair payload version: {}",
            decrypted.version
        ));
    }

    Ok(DecryptedMessageRepairPayload {
        request_id: decrypted.request_id,
        binding: decrypted.binding,
        witness_account_id: decrypted.witness_account_id,
        witness_device_id: decrypted.witness_device_id,
        repaired_body: decode_b64_field("repaired_body_b64", &decrypted.repaired_body_b64)?,
    })
}

fn derive_sender_payload_key(
    sender_device_keys: &DeviceKeyMaterial,
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    derive_payload_key(
        sender_device_keys,
        recipient_transport_pubkey,
        sender_transport_pubkey,
        recipient_transport_pubkey,
    )
}

fn derive_recipient_payload_key(
    recipient_device_keys: &DeviceKeyMaterial,
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    derive_payload_key(
        recipient_device_keys,
        sender_transport_pubkey,
        sender_transport_pubkey,
        recipient_transport_pubkey,
    )
}

fn derive_payload_key(
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
    digest.update(MESSAGE_REPAIR_PAYLOAD_DOMAIN);
    digest.update(shared_secret);
    digest.update(sender_transport_pubkey);
    digest.update(recipient_transport_pubkey);

    let mut key = [0u8; 32];
    key.copy_from_slice(&digest.finalize());
    Ok(key)
}

fn decode_array_24(value: &str) -> Result<[u8; 24]> {
    let bytes = decode_b64_field("nonce_b64", value)?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("nonce_b64 must be 24 bytes"))
}

fn to_32_bytes(bytes: &[u8], label: &str) -> Result<[u8; 32]> {
    bytes
        .try_into()
        .map_err(|_| anyhow!("{label} must be 32 bytes"))
}

#[cfg(test)]
mod tests {
    use super::{decrypt_message_repair_payload, encrypt_message_repair_payload};
    use crate::{DeviceKeyMaterial, encode_b64};
    use trix_types::{AccountId, ChatId, ContentType, DeviceId, MessageId, MessageKind};
    use uuid::Uuid;

    #[test]
    fn message_repair_payload_round_trip_recovers_binding_and_body() {
        let witness_keys = DeviceKeyMaterial::generate();
        let target_keys = DeviceKeyMaterial::generate();
        let binding = trix_types::MessageRepairBinding {
            chat_id: ChatId(Uuid::new_v4()),
            message_id: MessageId(Uuid::new_v4()),
            server_seq: 7,
            epoch: 3,
            sender_account_id: AccountId(Uuid::new_v4()),
            sender_device_id: DeviceId(Uuid::new_v4()),
            message_kind: MessageKind::Application,
            content_type: ContentType::Text,
            ciphertext_sha256_b64: encode_b64(&[5u8; 32]),
        };
        let payload = encrypt_message_repair_payload(
            "request-1",
            binding.clone(),
            AccountId(Uuid::new_v4()),
            DeviceId(Uuid::new_v4()),
            b"restored-body",
            &witness_keys,
            &target_keys.public_key_bytes(),
        )
        .unwrap();

        let decrypted = decrypt_message_repair_payload(&payload, &target_keys).unwrap();
        assert_eq!(decrypted.request_id, "request-1");
        assert_eq!(decrypted.binding, binding);
        assert_eq!(decrypted.repaired_body, b"restored-body".to_vec());
    }
}
