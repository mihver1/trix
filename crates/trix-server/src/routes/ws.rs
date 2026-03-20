use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::{
    Router,
    extract::{
        State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::HeaderMap,
    response::Response,
    routing::get,
};
use futures_util::{SinkExt, StreamExt};
use tokio::{
    select,
    sync::mpsc,
    time::{MissedTickBehavior, interval},
};
use trix_types::{InboxItem, WebSocketClientFrame, WebSocketServerFrame};

use crate::{auth::SessionPrincipal, error::AppError, state::AppState};

use super::chats::message_to_api;

const WS_INBOX_LEASE_TTL_SECONDS: u64 = 30;
const WS_POLL_INTERVAL: Duration = Duration::from_millis(750);

pub fn router() -> Router<AppState> {
    Router::new().route("/ws", get(connect_ws))
}

async fn connect_ws(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    Ok(ws.on_upgrade(move |socket| websocket_session(state, principal, socket)))
}

async fn websocket_session(state: AppState, principal: SessionPrincipal, mut socket: WebSocket) {
    let (server_tx, mut server_rx) = mpsc::unbounded_channel::<WebSocketServerFrame>();
    let session_id = state
        .ws_registry
        .register(principal.device_id, server_tx.clone())
        .await;
    let lease_owner = format!("ws:{}:{}", principal.device_id, session_id.simple());

    let hello = WebSocketServerFrame::Hello {
        session_id: session_id.to_string(),
        account_id: trix_types::AccountId(principal.account_id),
        device_id: trix_types::DeviceId(principal.device_id),
        lease_owner: lease_owner.clone(),
        lease_ttl_seconds: WS_INBOX_LEASE_TTL_SECONDS,
    };

    if send_server_frame(&mut socket, &hello).await.is_err() {
        state
            .ws_registry
            .unregister(principal.device_id, session_id)
            .await;
        return;
    }

    if deliver_inbox_batch(&state, principal, &lease_owner, &mut socket)
        .await
        .is_err()
    {
        state
            .ws_registry
            .unregister(principal.device_id, session_id)
            .await;
        let _ = socket.close().await;
        return;
    }

    let mut poll_interval = interval(WS_POLL_INTERVAL);
    poll_interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        select! {
            maybe_frame = server_rx.recv() => {
                let Some(frame) = maybe_frame else {
                    break;
                };

                let should_close = matches!(frame, WebSocketServerFrame::SessionReplaced { .. });
                if send_server_frame(&mut socket, &frame).await.is_err() {
                    break;
                }
                if should_close {
                    break;
                }
            }
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(message)) => {
                        match handle_client_message(&state, principal, &mut socket, message).await {
                            Ok(ClientMessageDisposition::Continue) => {}
                            Ok(ClientMessageDisposition::Close) => break,
                            Err(_) => break,
                        }
                    }
                    Some(Err(_)) | None => break,
                }
            }
            _ = poll_interval.tick() => {
                if deliver_inbox_batch(&state, principal, &lease_owner, &mut socket).await.is_err() {
                    break;
                }
            }
        }
    }

    state
        .ws_registry
        .unregister(principal.device_id, session_id)
        .await;
    let _ = socket.close().await;
}

enum ClientMessageDisposition {
    Continue,
    Close,
}

async fn handle_client_message(
    state: &AppState,
    principal: SessionPrincipal,
    socket: &mut WebSocket,
    message: Message,
) -> Result<ClientMessageDisposition, AppError> {
    match message {
        Message::Text(text) => {
            let frame: WebSocketClientFrame =
                serde_json::from_str(text.as_ref()).map_err(|err| {
                    AppError::bad_request(format!("invalid websocket frame payload: {err}"))
                })?;

            ensure_session_active(state, principal).await?;

            match frame {
                WebSocketClientFrame::Ack { inbox_ids } => {
                    let acked_inbox_ids = state
                        .db
                        .ack_inbox_items(
                            principal.device_id,
                            inbox_ids
                                .into_iter()
                                .map(|inbox_id| {
                                    i64::try_from(inbox_id).map_err(|_| {
                                        AppError::bad_request(
                                            "inbox id exceeds supported range for websocket ack",
                                        )
                                    })
                                })
                                .collect::<Result<Vec<_>, _>>()?,
                        )
                        .await?;

                    send_server_frame(socket, &WebSocketServerFrame::Acked { acked_inbox_ids })
                        .await?;
                }
                WebSocketClientFrame::PresencePing { nonce } => {
                    send_server_frame(
                        socket,
                        &WebSocketServerFrame::Pong {
                            nonce,
                            server_unix: unix_now(),
                        },
                    )
                    .await?;
                }
                WebSocketClientFrame::TypingUpdate { .. }
                | WebSocketClientFrame::HistorySyncProgress { .. } => {}
            }

            Ok(ClientMessageDisposition::Continue)
        }
        Message::Close(_) => Ok(ClientMessageDisposition::Close),
        Message::Ping(payload) => {
            socket.send(Message::Pong(payload)).await.map_err(|err| {
                AppError::internal(format!("failed to send websocket pong: {err}"))
            })?;
            Ok(ClientMessageDisposition::Continue)
        }
        Message::Pong(_) => Ok(ClientMessageDisposition::Continue),
        Message::Binary(_) => {
            send_server_frame(
                socket,
                &WebSocketServerFrame::Error {
                    code: "bad_request".to_owned(),
                    message: "binary websocket frames are not supported".to_owned(),
                },
            )
            .await?;
            Ok(ClientMessageDisposition::Continue)
        }
    }
}

async fn deliver_inbox_batch(
    state: &AppState,
    principal: SessionPrincipal,
    lease_owner: &str,
    socket: &mut WebSocket,
) -> Result<(), AppError> {
    ensure_session_active(state, principal).await?;

    let items = state
        .db
        .lease_inbox_for_device(
            principal.device_id,
            lease_owner,
            None,
            None,
            Some(WS_INBOX_LEASE_TTL_SECONDS),
        )
        .await?;

    if items.is_empty() {
        return Ok(());
    }

    let frame = WebSocketServerFrame::InboxItems {
        lease_owner: lease_owner.to_owned(),
        lease_expires_at_unix: unix_now().saturating_add(WS_INBOX_LEASE_TTL_SECONDS),
        items: items.into_iter().map(inbox_item_to_api).collect(),
    };
    send_server_frame(socket, &frame).await
}

async fn ensure_session_active(
    state: &AppState,
    principal: SessionPrincipal,
) -> Result<(), AppError> {
    state
        .db
        .ensure_active_device_session(principal.account_id, principal.device_id)
        .await
}

async fn send_server_frame(
    socket: &mut WebSocket,
    frame: &WebSocketServerFrame,
) -> Result<(), AppError> {
    let payload = serde_json::to_string(frame)
        .map_err(|err| AppError::internal(format!("failed to encode websocket frame: {err}")))?;
    socket
        .send(Message::Text(payload.into()))
        .await
        .map_err(|err| AppError::internal(format!("failed to send websocket frame: {err}")))
}

fn inbox_item_to_api(item: crate::db::InboxItemRow) -> InboxItem {
    InboxItem {
        inbox_id: item.inbox_id,
        message: message_to_api(item.message),
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
