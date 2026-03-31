use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use ed25519_dalek::{SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret as X25519StaticSecret};

use crate::{DeviceKeyMaterial, LocalProjectedMessage, decode_b64_field, encode_b64};

const HISTORY_SYNC_CHUNK_VERSION: u32 = 1;
const HISTORY_SYNC_CHUNK_DOMAIN: &[u8] = b"trix.history_sync_chunk.v1";
const HISTORY_SYNC_CURSOR_METADATA_KEY: &str = "history_sync_export";
const HISTORY_SYNC_CHAT_METADATA_KEY: &str = "history_sync_chat";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecryptedHistorySyncChunk {
    pub job_id: String,
    pub chat_id: String,
    pub projected_messages: Vec<LocalProjectedMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistorySyncExportMetadata {
    pub version: u32,
    pub format: String,
    pub exported_through_server_seq: u64,
    pub projected_message_count: usize,
    pub chunk_message_limit: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistorySyncChatMetadata {
    pub chat_type: trix_types::ChatType,
    pub title: Option<String>,
    pub participant_profiles: Vec<trix_types::ChatParticipantProfileSummary>,
    pub epoch: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HistorySyncChunkEnvelope {
    version: u32,
    sender_transport_pubkey_b64: String,
    nonce_b64: String,
    ciphertext_b64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HistorySyncChunkPlaintext {
    version: u32,
    job_id: String,
    chat_id: String,
    projected_messages: Vec<SerializableProjectedMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct SerializableProjectedMessage {
    server_seq: u64,
    message_id: String,
    sender_account_id: String,
    sender_device_id: String,
    epoch: u64,
    message_kind: trix_types::MessageKind,
    content_type: trix_types::ContentType,
    projection_kind: crate::LocalProjectionKind,
    payload_b64: Option<String>,
    merged_epoch: Option<u64>,
    created_at_unix: u64,
}

pub(crate) fn parse_export_metadata(cursor_json: &Value) -> Option<HistorySyncExportMetadata> {
    cursor_json
        .get(HISTORY_SYNC_CURSOR_METADATA_KEY)
        .cloned()
        .and_then(|value| serde_json::from_value(value).ok())
}

pub(crate) fn parse_chat_metadata(cursor_json: &Value) -> Option<HistorySyncChatMetadata> {
    cursor_json
        .get(HISTORY_SYNC_CHAT_METADATA_KEY)
        .cloned()
        .and_then(|value| serde_json::from_value(value).ok())
}

pub(crate) fn with_export_metadata(
    cursor_json: &Value,
    metadata: &HistorySyncExportMetadata,
) -> Value {
    let mut object = match cursor_json {
        Value::Object(existing) => existing.clone(),
        _ => Map::new(),
    };
    object.insert(
        HISTORY_SYNC_CURSOR_METADATA_KEY.to_owned(),
        serde_json::to_value(metadata).unwrap_or_else(|_| {
            json!({
                "version": metadata.version,
                "format": metadata.format,
                "exported_through_server_seq": metadata.exported_through_server_seq,
                "projected_message_count": metadata.projected_message_count,
                "chunk_message_limit": metadata.chunk_message_limit,
            })
        }),
    );
    Value::Object(object)
}

pub(crate) fn with_chat_metadata(cursor_json: &Value, metadata: &HistorySyncChatMetadata) -> Value {
    let mut object = match cursor_json {
        Value::Object(existing) => existing.clone(),
        _ => Map::new(),
    };
    object.insert(
        HISTORY_SYNC_CHAT_METADATA_KEY.to_owned(),
        serde_json::to_value(metadata).unwrap_or_else(|_| {
            json!({
                "chat_type": metadata.chat_type,
                "title": metadata.title,
                "participant_profiles": metadata.participant_profiles,
                "epoch": metadata.epoch,
            })
        }),
    );
    Value::Object(object)
}

pub(crate) fn encrypt_projected_message_chunk(
    job_id: &str,
    chat_id: &str,
    projected_messages: &[LocalProjectedMessage],
    sender_device_keys: &DeviceKeyMaterial,
    recipient_transport_pubkey: &[u8],
) -> Result<Vec<u8>> {
    let sender_transport_pubkey = sender_device_keys.public_key_bytes();
    let key = derive_sender_chunk_key(
        sender_device_keys,
        &sender_transport_pubkey,
        recipient_transport_pubkey,
    )?;
    let nonce: [u8; 24] = rand::random();
    let plaintext = serde_json::to_vec(&HistorySyncChunkPlaintext {
        version: HISTORY_SYNC_CHUNK_VERSION,
        job_id: job_id.to_owned(),
        chat_id: chat_id.to_owned(),
        projected_messages: projected_messages
            .iter()
            .cloned()
            .map(SerializableProjectedMessage::from)
            .collect(),
    })
    .context("failed to serialize history sync plaintext")?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| anyhow!("failed to initialize history sync cipher"))?;
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext.as_ref())
        .map_err(|_| anyhow!("failed to encrypt history sync chunk"))?;
    serde_json::to_vec(&HistorySyncChunkEnvelope {
        version: HISTORY_SYNC_CHUNK_VERSION,
        sender_transport_pubkey_b64: encode_b64(&sender_transport_pubkey),
        nonce_b64: general_purpose::STANDARD.encode(nonce),
        ciphertext_b64: general_purpose::STANDARD.encode(ciphertext),
    })
    .context("failed to serialize history sync chunk envelope")
}

pub(crate) fn decrypt_projected_message_chunk(
    payload: &[u8],
    recipient_device_keys: &DeviceKeyMaterial,
) -> Result<DecryptedHistorySyncChunk> {
    let envelope: HistorySyncChunkEnvelope =
        serde_json::from_slice(payload).context("failed to parse history sync chunk envelope")?;
    if envelope.version != HISTORY_SYNC_CHUNK_VERSION {
        return Err(anyhow!(
            "unsupported history sync chunk version: {}",
            envelope.version
        ));
    }
    let sender_transport_pubkey = decode_b64_field(
        "sender_transport_pubkey_b64",
        &envelope.sender_transport_pubkey_b64,
    )?;
    let recipient_transport_pubkey = recipient_device_keys.public_key_bytes();
    let key = derive_recipient_chunk_key(
        recipient_device_keys,
        &sender_transport_pubkey,
        &recipient_transport_pubkey,
    )?;
    let nonce = decode_array_24(&envelope.nonce_b64, "nonce_b64")?;
    let ciphertext = decode_b64_field("ciphertext_b64", &envelope.ciphertext_b64)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| anyhow!("failed to initialize history sync cipher"))?;
    let plaintext = cipher
        .decrypt(XNonce::from_slice(&nonce), ciphertext.as_ref())
        .map_err(|_| anyhow!("failed to decrypt history sync chunk"))?;
    let decrypted: HistorySyncChunkPlaintext =
        serde_json::from_slice(&plaintext).context("failed to parse history sync plaintext")?;
    if decrypted.version != HISTORY_SYNC_CHUNK_VERSION {
        return Err(anyhow!(
            "unsupported history sync plaintext version: {}",
            decrypted.version
        ));
    }
    Ok(DecryptedHistorySyncChunk {
        job_id: decrypted.job_id,
        chat_id: decrypted.chat_id,
        projected_messages: decrypted
            .projected_messages
            .into_iter()
            .map(LocalProjectedMessage::try_from)
            .collect::<Result<Vec<_>>>()?,
    })
}

impl From<LocalProjectedMessage> for SerializableProjectedMessage {
    fn from(value: LocalProjectedMessage) -> Self {
        Self {
            server_seq: value.server_seq,
            message_id: value.message_id.0.to_string(),
            sender_account_id: value.sender_account_id.0.to_string(),
            sender_device_id: value.sender_device_id.0.to_string(),
            epoch: value.epoch,
            message_kind: value.message_kind,
            content_type: value.content_type,
            projection_kind: value.projection_kind,
            payload_b64: value.payload.map(|payload| encode_b64(&payload)),
            merged_epoch: value.merged_epoch,
            created_at_unix: value.created_at_unix,
        }
    }
}

impl TryFrom<SerializableProjectedMessage> for LocalProjectedMessage {
    type Error = anyhow::Error;

    fn try_from(value: SerializableProjectedMessage) -> Result<Self> {
        Ok(Self {
            server_seq: value.server_seq,
            message_id: trix_types::MessageId(
                uuid::Uuid::parse_str(&value.message_id).context("invalid projected message_id")?,
            ),
            sender_account_id: trix_types::AccountId(
                uuid::Uuid::parse_str(&value.sender_account_id)
                    .context("invalid projected sender_account_id")?,
            ),
            sender_device_id: trix_types::DeviceId(
                uuid::Uuid::parse_str(&value.sender_device_id)
                    .context("invalid projected sender_device_id")?,
            ),
            epoch: value.epoch,
            message_kind: value.message_kind,
            content_type: value.content_type,
            projection_kind: value.projection_kind,
            payload: value
                .payload_b64
                .as_deref()
                .map(|payload| decode_b64_field("payload_b64", payload))
                .transpose()?,
            merged_epoch: value.merged_epoch,
            created_at_unix: value.created_at_unix,
        })
    }
}

fn derive_sender_chunk_key(
    sender_device_keys: &DeviceKeyMaterial,
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    derive_chunk_key(
        sender_device_keys,
        recipient_transport_pubkey,
        sender_transport_pubkey,
        recipient_transport_pubkey,
    )
}

fn derive_recipient_chunk_key(
    recipient_device_keys: &DeviceKeyMaterial,
    sender_transport_pubkey: &[u8],
    recipient_transport_pubkey: &[u8],
) -> Result<[u8; 32]> {
    derive_chunk_key(
        recipient_device_keys,
        sender_transport_pubkey,
        sender_transport_pubkey,
        recipient_transport_pubkey,
    )
}

fn derive_chunk_key(
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
    digest.update(HISTORY_SYNC_CHUNK_DOMAIN);
    digest.update(shared_secret);
    digest.update(sender_transport_pubkey);
    digest.update(recipient_transport_pubkey);

    let mut key = [0u8; 32];
    key.copy_from_slice(&digest.finalize());
    Ok(key)
}

fn decode_array_24(value: &str, field: &'static str) -> Result<[u8; 24]> {
    let bytes = decode_b64_field(field, value)?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("{field} must be 24 bytes"))
}

fn to_32_bytes(bytes: &[u8], label: &str) -> Result<[u8; 32]> {
    bytes
        .try_into()
        .map_err(|_| anyhow!("{label} must be 32 bytes"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::LocalProjectionKind;
    use trix_types::{AccountId, ChatId, ContentType, DeviceId, MessageId, MessageKind};
    use uuid::Uuid;

    fn sample_projected_message(server_seq: u64, payload: Option<&[u8]>) -> LocalProjectedMessage {
        LocalProjectedMessage {
            server_seq,
            message_id: MessageId(Uuid::new_v4()),
            sender_account_id: AccountId(Uuid::new_v4()),
            sender_device_id: DeviceId(Uuid::new_v4()),
            epoch: 7,
            message_kind: if payload.is_some() {
                MessageKind::Application
            } else {
                MessageKind::Commit
            },
            content_type: if payload.is_some() {
                ContentType::Text
            } else {
                ContentType::ChatEvent
            },
            projection_kind: if payload.is_some() {
                LocalProjectionKind::ApplicationMessage
            } else {
                LocalProjectionKind::CommitMerged
            },
            payload: payload.map(|value| value.to_vec()),
            merged_epoch: payload.is_none().then_some(7),
            created_at_unix: 1_700_000_000 + server_seq,
        }
    }

    #[test]
    fn projected_message_chunk_round_trips() {
        let sender = DeviceKeyMaterial::generate();
        let recipient = DeviceKeyMaterial::generate();
        let chat_id = ChatId(Uuid::new_v4()).0.to_string();
        let job_id = Uuid::new_v4().to_string();
        let projected_messages = vec![
            sample_projected_message(1, Some(b"hello")),
            sample_projected_message(2, None),
        ];

        let encrypted = encrypt_projected_message_chunk(
            &job_id,
            &chat_id,
            &projected_messages,
            &sender,
            &recipient.public_key_bytes(),
        )
        .unwrap();
        let decrypted = decrypt_projected_message_chunk(&encrypted, &recipient).unwrap();

        assert_eq!(decrypted.job_id, job_id);
        assert_eq!(decrypted.chat_id, chat_id);
        assert_eq!(decrypted.projected_messages, projected_messages);
    }

    #[test]
    fn projected_message_chunk_rejects_wrong_recipient() {
        let sender = DeviceKeyMaterial::generate();
        let recipient = DeviceKeyMaterial::generate();
        let wrong = DeviceKeyMaterial::generate();
        let encrypted = encrypt_projected_message_chunk(
            &Uuid::new_v4().to_string(),
            &ChatId(Uuid::new_v4()).0.to_string(),
            &[sample_projected_message(1, Some(b"secret"))],
            &sender,
            &recipient.public_key_bytes(),
        )
        .unwrap();

        let error = decrypt_projected_message_chunk(&encrypted, &wrong).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("failed to decrypt history sync chunk"),
            "{error:?}"
        );
    }

    #[test]
    fn export_metadata_merges_into_existing_cursor_json() {
        let existing = json!({
            "kind": "chat_backfill",
            "chat_id": Uuid::new_v4().to_string(),
        });
        let metadata = HistorySyncExportMetadata {
            version: HISTORY_SYNC_CHUNK_VERSION,
            format: "projected_messages".to_owned(),
            exported_through_server_seq: 42,
            projected_message_count: 8,
            chunk_message_limit: 64,
        };

        let merged = with_export_metadata(&existing, &metadata);

        assert_eq!(
            merged.get("kind").and_then(Value::as_str),
            Some("chat_backfill")
        );
        assert_eq!(parse_export_metadata(&merged), Some(metadata));
    }
}
