use trix_types::api::{WebSocketClientFrame, WebSocketServerFrame};
use trix_types::ws_protocol::{WsState, WsTransition};
use trix_types::{AccountId, ChatId, DeviceId};

// --- Scenario tests ---

#[test]
fn hello_transitions_from_connected_to_active() {
    let hello = WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    };
    assert_eq!(
        WsState::Connected.on_server_frame(&hello),
        WsTransition::Valid(WsState::Active)
    );
}

#[test]
fn duplicate_hello_is_invalid() {
    let hello = WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    };
    assert!(matches!(
        WsState::Active.on_server_frame(&hello),
        WsTransition::Invalid(_)
    ));
}

#[test]
fn client_frame_before_hello_is_invalid() {
    let ack = WebSocketClientFrame::Ack {
        inbox_ids: vec![1],
    };
    assert!(matches!(
        WsState::Connected.on_client_frame(&ack),
        WsTransition::Invalid(_)
    ));
}

#[test]
fn session_replaced_transitions_to_replaced() {
    let replaced = WebSocketServerFrame::SessionReplaced {
        reason: "new device".into(),
    };
    assert_eq!(
        WsState::Active.on_server_frame(&replaced),
        WsTransition::Valid(WsState::Replaced)
    );
}

#[test]
fn frames_after_session_replaced_are_invalid() {
    let pong = WebSocketServerFrame::Pong {
        nonce: None,
        server_unix: 123,
    };
    assert!(matches!(
        WsState::Replaced.on_server_frame(&pong),
        WsTransition::Invalid(_)
    ));

    let ack = WebSocketClientFrame::Ack {
        inbox_ids: vec![1],
    };
    assert!(matches!(
        WsState::Replaced.on_client_frame(&ack),
        WsTransition::Invalid(_)
    ));
}

#[test]
fn normal_flow_hello_inbox_ack() {
    let mut state = WsState::Connected;

    // Server sends Hello
    let hello = WebSocketServerFrame::Hello {
        session_id: "s1".into(),
        account_id: AccountId::new(),
        device_id: DeviceId::new(),
        lease_owner: "owner".into(),
        lease_ttl_seconds: 60,
    };
    if let WsTransition::Valid(next) = state.on_server_frame(&hello) {
        state = next;
    } else {
        panic!("Hello should be valid");
    }
    assert_eq!(state, WsState::Active);

    // Server sends InboxItems
    let inbox = WebSocketServerFrame::InboxItems {
        lease_owner: "owner".into(),
        lease_expires_at_unix: 999,
        items: vec![],
    };
    if let WsTransition::Valid(next) = state.on_server_frame(&inbox) {
        state = next;
    } else {
        panic!("InboxItems should be valid");
    }
    assert_eq!(state, WsState::Active);

    // Client sends Ack
    let ack = WebSocketClientFrame::Ack {
        inbox_ids: vec![1, 2],
    };
    if let WsTransition::Valid(next) = state.on_client_frame(&ack) {
        state = next;
    } else {
        panic!("Ack should be valid");
    }
    assert_eq!(state, WsState::Active);

    // Client sends PresencePing
    let ping = WebSocketClientFrame::PresencePing {
        nonce: Some("abc".into()),
    };
    assert!(matches!(
        state.on_client_frame(&ping),
        WsTransition::Valid(WsState::Active)
    ));

    // Client sends TypingUpdate
    let typing = WebSocketClientFrame::TypingUpdate {
        chat_id: ChatId::new(),
        is_typing: true,
    };
    assert!(matches!(
        state.on_client_frame(&typing),
        WsTransition::Valid(WsState::Active)
    ));
}

#[test]
fn replaced_state_should_disconnect() {
    assert!(!WsState::Connected.should_disconnect());
    assert!(!WsState::Active.should_disconnect());
    assert!(WsState::Replaced.should_disconnect());
}

// --- Property-based tests ---

mod proptest_tests {
    use super::*;
    use proptest::prelude::*;

    fn arb_server_frame() -> impl Strategy<Value = WebSocketServerFrame> {
        prop_oneof![
            Just(WebSocketServerFrame::Hello {
                session_id: "s".into(),
                account_id: AccountId::new(),
                device_id: DeviceId::new(),
                lease_owner: "o".into(),
                lease_ttl_seconds: 60,
            }),
            Just(WebSocketServerFrame::InboxItems {
                lease_owner: "o".into(),
                lease_expires_at_unix: 999,
                items: vec![],
            }),
            Just(WebSocketServerFrame::Acked {
                acked_inbox_ids: vec![1],
            }),
            Just(WebSocketServerFrame::Pong {
                nonce: None,
                server_unix: 0,
            }),
            Just(WebSocketServerFrame::SessionReplaced {
                reason: "r".into(),
            }),
            Just(WebSocketServerFrame::Error {
                code: "e".into(),
                message: "m".into(),
            }),
        ]
    }

    fn arb_client_frame() -> impl Strategy<Value = WebSocketClientFrame> {
        prop_oneof![
            Just(WebSocketClientFrame::Ack {
                inbox_ids: vec![1],
            }),
            Just(WebSocketClientFrame::PresencePing { nonce: None }),
            Just(WebSocketClientFrame::TypingUpdate {
                chat_id: ChatId::new(),
                is_typing: true,
            }),
            Just(WebSocketClientFrame::HistorySyncProgress {
                job_id: "j".into(),
                cursor_json: None,
                completed_chunks: None,
            }),
        ]
    }

    proptest! {
        #[test]
        fn state_machine_never_panics_server_frames(
            frames in prop::collection::vec(arb_server_frame(), 0..50)
        ) {
            let mut state = WsState::Connected;
            for frame in &frames {
                match state.on_server_frame(frame) {
                    WsTransition::Valid(next) => state = next,
                    WsTransition::Invalid(_) => {} // invalid is fine, just don't transition
                }
            }
        }

        #[test]
        fn state_machine_never_panics_mixed_frames(
            server_frames in prop::collection::vec(arb_server_frame(), 0..25),
            client_frames in prop::collection::vec(arb_client_frame(), 0..25),
        ) {
            let mut state = WsState::Connected;
            let mut si = 0;
            let mut ci = 0;
            // Interleave server and client frames
            while si < server_frames.len() || ci < client_frames.len() {
                if si < server_frames.len() {
                    match state.on_server_frame(&server_frames[si]) {
                        WsTransition::Valid(next) => state = next,
                        WsTransition::Invalid(_) => {}
                    }
                    si += 1;
                }
                if ci < client_frames.len() {
                    match state.on_client_frame(&client_frames[ci]) {
                        WsTransition::Valid(next) => state = next,
                        WsTransition::Invalid(_) => {}
                    }
                    ci += 1;
                }
            }
        }
    }
}
