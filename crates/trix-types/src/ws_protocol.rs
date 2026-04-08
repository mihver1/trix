//! WebSocket protocol state machine.
//!
//! Defines valid state transitions for the trix WebSocket protocol.
//! Used in tests and debug builds to catch protocol violations.

use crate::api::{WebSocketClientFrame, WebSocketServerFrame};

/// WebSocket connection state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsState {
    /// TCP connected, awaiting Hello from server.
    Connected,
    /// Received Hello, normal bidirectional operation.
    Active,
    /// SessionReplaced received, must disconnect.
    Replaced,
}

/// Result of attempting a state transition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WsTransition {
    /// Valid transition to new state.
    Valid(WsState),
    /// Invalid frame for current state; contains reason.
    Invalid(&'static str),
}

impl WsState {
    /// Check if a server-sent frame is valid in the current state.
    pub fn on_server_frame(&self, frame: &WebSocketServerFrame) -> WsTransition {
        match (self, frame) {
            // Connected: only Hello is valid
            (WsState::Connected, WebSocketServerFrame::Hello { .. }) => {
                WsTransition::Valid(WsState::Active)
            }
            (WsState::Connected, _) => {
                WsTransition::Invalid("server must send Hello before any other frame")
            }

            // Active: anything except a duplicate Hello
            (WsState::Active, WebSocketServerFrame::Hello { .. }) => {
                WsTransition::Invalid("duplicate Hello in active session")
            }
            (WsState::Active, WebSocketServerFrame::SessionReplaced { .. }) => {
                WsTransition::Valid(WsState::Replaced)
            }
            (WsState::Active, _) => WsTransition::Valid(WsState::Active),

            // Replaced: no frames are valid, must disconnect
            (WsState::Replaced, _) => WsTransition::Invalid("session is replaced, must disconnect"),
        }
    }

    /// Check if a client-sent frame is valid in the current state.
    pub fn on_client_frame(&self, _frame: &WebSocketClientFrame) -> WsTransition {
        match self {
            WsState::Connected => {
                WsTransition::Invalid("client must wait for Hello before sending frames")
            }
            WsState::Active => WsTransition::Valid(WsState::Active),
            WsState::Replaced => WsTransition::Invalid("session is replaced, must disconnect"),
        }
    }

    /// Whether the connection should be closed.
    pub fn should_disconnect(&self) -> bool {
        matches!(self, WsState::Replaced)
    }
}
