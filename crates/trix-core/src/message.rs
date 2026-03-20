use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use trix_types::{ContentType, MessageId};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReactionAction {
    Add,
    Remove,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReceiptType {
    Delivered,
    Read,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextMessageBody {
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReactionMessageBody {
    pub target_message_id: MessageId,
    pub emoji: String,
    pub action: ReactionAction,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReceiptMessageBody {
    pub target_message_id: MessageId,
    pub receipt_type: ReceiptType,
    pub at_unix: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentMessageBody {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub file_name: Option<String>,
    pub width_px: Option<u32>,
    pub height_px: Option<u32>,
    pub file_key: Vec<u8>,
    pub nonce: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatEventMessageBody {
    pub event_type: String,
    pub payload_json: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MessageBody {
    Text(TextMessageBody),
    Reaction(ReactionMessageBody),
    Receipt(ReceiptMessageBody),
    Attachment(AttachmentMessageBody),
    ChatEvent(ChatEventMessageBody),
}

impl MessageBody {
    pub fn content_type(&self) -> ContentType {
        match self {
            Self::Text(_) => ContentType::Text,
            Self::Reaction(_) => ContentType::Reaction,
            Self::Receipt(_) => ContentType::Receipt,
            Self::Attachment(_) => ContentType::Attachment,
            Self::ChatEvent(_) => ContentType::ChatEvent,
        }
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).context("failed to serialize message body")
    }

    pub fn from_bytes(content_type: ContentType, bytes: &[u8]) -> Result<Self> {
        if matches!(content_type, ContentType::Text) {
            if let Ok(text) = std::str::from_utf8(bytes) {
                if !looks_like_json(text) {
                    return Ok(Self::Text(TextMessageBody {
                        text: text.to_owned(),
                    }));
                }
            }
        }

        let parsed: MessageBody =
            serde_json::from_slice(bytes).context("failed to parse message body json")?;
        if parsed.content_type() != content_type {
            return Err(anyhow!(
                "message body kind {:?} does not match content_type {:?}",
                parsed.content_type(),
                content_type
            ));
        }
        Ok(parsed)
    }
}

fn looks_like_json(value: &str) -> bool {
    let trimmed = value.trim_start();
    matches!(
        trimmed.as_bytes().first(),
        Some(b'{') | Some(b'[') | Some(b'"')
    )
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn text_body_round_trip_supports_plaintext_fallback() {
        let parsed = MessageBody::from_bytes(ContentType::Text, b"hello").unwrap();
        assert_eq!(
            parsed,
            MessageBody::Text(TextMessageBody {
                text: "hello".to_owned()
            })
        );
    }

    #[test]
    fn structured_bodies_round_trip() {
        let body = MessageBody::Attachment(AttachmentMessageBody {
            blob_id: "blob-1".to_owned(),
            mime_type: "image/jpeg".to_owned(),
            size_bytes: 1024,
            sha256: vec![1, 2, 3],
            file_name: Some("pic.jpg".to_owned()),
            width_px: Some(320),
            height_px: Some(240),
            file_key: vec![4, 5, 6],
            nonce: vec![7, 8, 9],
        });
        let encoded = body.to_bytes().unwrap();
        let decoded = MessageBody::from_bytes(ContentType::Attachment, &encoded).unwrap();
        assert_eq!(decoded, body);

        let event = MessageBody::ChatEvent(ChatEventMessageBody {
            event_type: "member_added".to_owned(),
            payload_json: json!({"account_id":"abc"}),
        });
        let encoded = event.to_bytes().unwrap();
        let decoded = MessageBody::from_bytes(ContentType::ChatEvent, &encoded).unwrap();
        assert_eq!(decoded, event);
    }
}
