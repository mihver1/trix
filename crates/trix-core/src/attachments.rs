use anyhow::{Result, anyhow};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use sha2::{Digest, Sha256};

use crate::AttachmentMessageBody;

pub const ATTACHMENT_FILE_KEY_BYTES: usize = 32;
pub const ATTACHMENT_NONCE_BYTES: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedAttachmentUpload {
    pub mime_type: String,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
    pub plaintext_size_bytes: u64,
    pub encrypted_size_bytes: u64,
    pub encrypted_payload: Vec<u8>,
    pub encrypted_sha256: Vec<u8>,
    pub file_key: Vec<u8>,
    pub nonce: Vec<u8>,
}

impl PreparedAttachmentUpload {
    pub fn into_message_body(self, blob_id: String) -> AttachmentMessageBody {
        AttachmentMessageBody {
            blob_id,
            mime_type: self.mime_type,
            size_bytes: self.plaintext_size_bytes,
            sha256: self.encrypted_sha256,
            file_name: self.file_name,
            width_px: self.width_px,
            height_px: self.height_px,
            file_key: self.file_key,
            nonce: self.nonce,
        }
    }
}

pub fn prepare_attachment_upload(
    payload: &[u8],
    mime_type: impl Into<String>,
    file_name: Option<String>,
    width_px: Option<u32>,
    height_px: Option<u32>,
) -> Result<PreparedAttachmentUpload> {
    let mime_type = mime_type.into().trim().to_owned();
    if mime_type.is_empty() {
        return Err(anyhow!("attachment mime_type must not be empty"));
    }

    let file_key = rand::random::<[u8; ATTACHMENT_FILE_KEY_BYTES]>();
    let nonce = rand::random::<[u8; ATTACHMENT_NONCE_BYTES]>();
    let cipher = XChaCha20Poly1305::new_from_slice(&file_key)
        .map_err(|_| anyhow!("failed to initialize attachment cipher"))?;
    let encrypted_payload = cipher
        .encrypt(XNonce::from_slice(&nonce), payload)
        .map_err(|_| anyhow!("failed to encrypt attachment payload"))?;
    let encrypted_sha256 = Sha256::digest(&encrypted_payload).to_vec();

    Ok(PreparedAttachmentUpload {
        mime_type,
        file_name,
        width_px,
        height_px,
        plaintext_size_bytes: payload.len() as u64,
        encrypted_size_bytes: encrypted_payload.len() as u64,
        encrypted_payload,
        encrypted_sha256,
        file_key: file_key.to_vec(),
        nonce: nonce.to_vec(),
    })
}

pub fn decrypt_attachment_payload(
    body: &AttachmentMessageBody,
    encrypted_payload: &[u8],
) -> Result<Vec<u8>> {
    let expected_sha256 = Sha256::digest(encrypted_payload);
    if expected_sha256.as_slice() != body.sha256.as_slice() {
        return Err(anyhow!("attachment blob sha256 did not match descriptor"));
    }

    let file_key: [u8; ATTACHMENT_FILE_KEY_BYTES] = body
        .file_key
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("attachment file_key must be exactly 32 bytes"))?;
    let nonce: [u8; ATTACHMENT_NONCE_BYTES] = body
        .nonce
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("attachment nonce must be exactly 24 bytes"))?;

    let cipher = XChaCha20Poly1305::new_from_slice(&file_key)
        .map_err(|_| anyhow!("failed to initialize attachment cipher"))?;
    cipher
        .decrypt(XNonce::from_slice(&nonce), encrypted_payload)
        .map_err(|_| anyhow!("failed to decrypt attachment payload"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attachment_prepare_and_decrypt_round_trip() {
        let payload = b"hello attachment".to_vec();
        let prepared = prepare_attachment_upload(
            &payload,
            "image/jpeg",
            Some("photo.jpg".to_owned()),
            Some(320),
            Some(240),
        )
        .unwrap();

        assert_eq!(prepared.mime_type, "image/jpeg");
        assert_eq!(prepared.file_name.as_deref(), Some("photo.jpg"));
        assert_eq!(prepared.plaintext_size_bytes, payload.len() as u64);
        assert!(prepared.encrypted_size_bytes >= prepared.plaintext_size_bytes);
        assert_ne!(prepared.encrypted_payload, payload);

        let body = prepared.clone().into_message_body("blob-1".to_owned());
        assert_eq!(body.size_bytes, payload.len() as u64);
        assert_eq!(body.mime_type, "image/jpeg");

        let decrypted = decrypt_attachment_payload(&body, &prepared.encrypted_payload).unwrap();
        assert_eq!(decrypted, payload);
    }
}
