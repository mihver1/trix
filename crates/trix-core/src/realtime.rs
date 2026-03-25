use std::time::Duration;

use anyhow::Result;
use trix_types::{InboxItem, WebSocketServerFrame};

use crate::{InboxApplyOutcome, LocalHistoryStore, LocalStoreApplyReport, SyncCoordinator};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RealtimeMode {
    Websocket,
    Polling,
    Disconnected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RealtimeEventKind {
    Hello,
    InboxItems,
    Acked,
    Pong,
    SessionReplaced,
    Error,
    Disconnected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeConfig {
    pub inbox_limit: usize,
    pub inbox_lease_ttl_seconds: u64,
    pub poll_interval: Duration,
    pub websocket_retry_delay: Duration,
}

impl Default for RealtimeConfig {
    fn default() -> Self {
        Self {
            inbox_limit: 100,
            inbox_lease_ttl_seconds: 30,
            poll_interval: Duration::from_millis(750),
            websocket_retry_delay: Duration::from_secs(3),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeEvent {
    pub mode: RealtimeMode,
    pub kind: RealtimeEventKind,
    pub report: Option<LocalStoreApplyReport>,
    pub outbound_ack_inbox_ids: Vec<u64>,
    pub server_acked_inbox_ids: Vec<u64>,
    pub lease_owner: Option<String>,
    pub lease_expires_at_unix: Option<u64>,
    pub pong_nonce: Option<String>,
    pub pong_server_unix: Option<u64>,
    pub session_replaced_reason: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RealtimeDriver {
    config: RealtimeConfig,
}

impl Default for RealtimeDriver {
    fn default() -> Self {
        Self::new()
    }
}

impl RealtimeDriver {
    pub fn new() -> Self {
        Self {
            config: RealtimeConfig::default(),
        }
    }

    pub fn with_config(config: RealtimeConfig) -> Self {
        Self { config }
    }

    pub fn config(&self) -> &RealtimeConfig {
        &self.config
    }

    pub async fn poll_once(
        &self,
        client: &crate::ServerApiClient,
        sync: &mut SyncCoordinator,
        store: &mut LocalHistoryStore,
    ) -> Result<InboxApplyOutcome> {
        sync.lease_inbox_into_store(
            client,
            store,
            Some(self.config.inbox_limit),
            Some(self.config.inbox_lease_ttl_seconds),
        )
        .await
    }

    pub async fn next_websocket_event(
        &self,
        websocket: &mut crate::ServerWebSocketClient,
        sync: &mut SyncCoordinator,
        store: &mut LocalHistoryStore,
        auto_ack: bool,
    ) -> Result<Option<RealtimeEvent>> {
        let Some(frame) = websocket.next_frame().await? else {
            return Ok(Some(RealtimeEvent {
                mode: RealtimeMode::Disconnected,
                kind: RealtimeEventKind::Disconnected,
                report: None,
                outbound_ack_inbox_ids: Vec::new(),
                server_acked_inbox_ids: Vec::new(),
                lease_owner: None,
                lease_expires_at_unix: None,
                pong_nonce: None,
                pong_server_unix: None,
                session_replaced_reason: None,
                error_code: None,
                error_message: None,
            }));
        };

        let event = self.process_websocket_frame(sync, store, frame)?;
        if auto_ack && !event.outbound_ack_inbox_ids.is_empty() {
            websocket
                .send_ack(event.outbound_ack_inbox_ids.clone())
                .await?;
        }
        Ok(Some(event))
    }

    pub fn process_websocket_frame(
        &self,
        sync: &mut SyncCoordinator,
        store: &mut LocalHistoryStore,
        frame: WebSocketServerFrame,
    ) -> Result<RealtimeEvent> {
        match frame {
            WebSocketServerFrame::Hello { .. } => Ok(RealtimeEvent {
                mode: RealtimeMode::Websocket,
                kind: RealtimeEventKind::Hello,
                report: None,
                outbound_ack_inbox_ids: Vec::new(),
                server_acked_inbox_ids: Vec::new(),
                lease_owner: None,
                lease_expires_at_unix: None,
                pong_nonce: None,
                pong_server_unix: None,
                session_replaced_reason: None,
                error_code: None,
                error_message: None,
            }),
            WebSocketServerFrame::InboxItems {
                lease_owner,
                lease_expires_at_unix,
                items,
            } => self.process_inbox_items(sync, store, lease_owner, lease_expires_at_unix, &items),
            WebSocketServerFrame::Acked { acked_inbox_ids } => {
                sync.record_acked_inbox_ids(&acked_inbox_ids)?;
                Ok(RealtimeEvent {
                    mode: RealtimeMode::Websocket,
                    kind: RealtimeEventKind::Acked,
                    report: None,
                    outbound_ack_inbox_ids: Vec::new(),
                    server_acked_inbox_ids: acked_inbox_ids,
                    lease_owner: None,
                    lease_expires_at_unix: None,
                    pong_nonce: None,
                    pong_server_unix: None,
                    session_replaced_reason: None,
                    error_code: None,
                    error_message: None,
                })
            }
            WebSocketServerFrame::Pong { nonce, server_unix } => Ok(RealtimeEvent {
                mode: RealtimeMode::Websocket,
                kind: RealtimeEventKind::Pong,
                report: None,
                outbound_ack_inbox_ids: Vec::new(),
                server_acked_inbox_ids: Vec::new(),
                lease_owner: None,
                lease_expires_at_unix: None,
                pong_nonce: nonce,
                pong_server_unix: Some(server_unix),
                session_replaced_reason: None,
                error_code: None,
                error_message: None,
            }),
            WebSocketServerFrame::SessionReplaced { reason } => Ok(RealtimeEvent {
                mode: RealtimeMode::Websocket,
                kind: RealtimeEventKind::SessionReplaced,
                report: None,
                outbound_ack_inbox_ids: Vec::new(),
                server_acked_inbox_ids: Vec::new(),
                lease_owner: None,
                lease_expires_at_unix: None,
                pong_nonce: None,
                pong_server_unix: None,
                session_replaced_reason: Some(reason),
                error_code: None,
                error_message: None,
            }),
            WebSocketServerFrame::Error { code, message } => Ok(RealtimeEvent {
                mode: RealtimeMode::Websocket,
                kind: RealtimeEventKind::Error,
                report: None,
                outbound_ack_inbox_ids: Vec::new(),
                server_acked_inbox_ids: Vec::new(),
                lease_owner: None,
                lease_expires_at_unix: None,
                pong_nonce: None,
                pong_server_unix: None,
                session_replaced_reason: None,
                error_code: Some(code),
                error_message: Some(message),
            }),
        }
    }

    fn process_inbox_items(
        &self,
        sync: &mut SyncCoordinator,
        store: &mut LocalHistoryStore,
        lease_owner: String,
        lease_expires_at_unix: u64,
        items: &[InboxItem],
    ) -> Result<RealtimeEvent> {
        let report = sync.apply_inbox_items_into_store(store, items)?;
        Ok(RealtimeEvent {
            mode: RealtimeMode::Websocket,
            kind: RealtimeEventKind::InboxItems,
            report: Some(report),
            outbound_ack_inbox_ids: items.iter().map(|item| item.inbox_id).collect(),
            server_acked_inbox_ids: Vec::new(),
            lease_owner: Some(lease_owner),
            lease_expires_at_unix: Some(lease_expires_at_unix),
            pong_nonce: None,
            pong_server_unix: None,
            session_replaced_reason: None,
            error_code: None,
            error_message: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use trix_types::{
        AccountId, ChatId, ContentType, DeviceId, InboxItem, MessageEnvelope, MessageId,
        MessageKind,
    };
    use uuid::Uuid;

    use super::*;

    #[test]
    fn realtime_driver_processes_inbox_and_ack_frames() {
        let driver = RealtimeDriver::new();
        let mut sync = SyncCoordinator::new();
        let mut store = LocalHistoryStore::new();
        let chat_id = ChatId(Uuid::new_v4());
        let account_id = AccountId(Uuid::new_v4());
        let device_id = DeviceId(Uuid::new_v4());

        let event = driver
            .process_websocket_frame(
                &mut sync,
                &mut store,
                WebSocketServerFrame::InboxItems {
                    lease_owner: "lease-1".to_owned(),
                    lease_expires_at_unix: 123,
                    items: vec![InboxItem {
                        inbox_id: 7,
                        message: MessageEnvelope {
                            message_id: MessageId(Uuid::new_v4()),
                            chat_id,
                            server_seq: 1,
                            sender_account_id: account_id,
                            sender_device_id: device_id,
                            epoch: 1,
                            message_kind: MessageKind::Application,
                            content_type: ContentType::Text,
                            ciphertext_b64: crate::encode_b64(b"ciphertext"),
                            aad_json: json!({}),
                            created_at_unix: 1,
                        },
                    }],
                },
            )
            .unwrap();

        assert_eq!(event.kind, RealtimeEventKind::InboxItems);
        assert_eq!(event.outbound_ack_inbox_ids, vec![7]);
        assert_eq!(
            store
                .get_chat_history(chat_id, None, Some(10))
                .messages
                .len(),
            1
        );
        assert_eq!(sync.chat_cursor(chat_id), None);

        let acked = driver
            .process_websocket_frame(
                &mut sync,
                &mut store,
                WebSocketServerFrame::Acked {
                    acked_inbox_ids: vec![7],
                },
            )
            .unwrap();
        assert_eq!(acked.kind, RealtimeEventKind::Acked);
        assert_eq!(sync.last_acked_inbox_id(), Some(7));
    }
}
