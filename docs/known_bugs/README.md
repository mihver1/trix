# Known Bugs And Feature Parity Gaps

This folder tracks user-visible Matrix Apple MVP bugs and legacy parity gaps
that must be fixed before the app is treated as production-ready.

Each item has its own file with the expected behavior, legacy reference points,
current Matrix state, implementation boundaries, acceptance criteria, and
verification plan. Future agents must keep Matrix SDK calls behind the
service/view-model boundary and must not add custom crypto, custom protocol
handling, trust-all shortcuts, local verified overrides, or secret logging.

Legacy Trix may be used as a UX and behavior reference by running the app,
reviewing screenshots/docs, and reading legacy code to understand existing
behavior. Do not copy legacy implementation code into the new Matrix client, and
do not modify legacy TestFlight scripts while fixing these bugs unless the user
explicitly reopens that scope.

## Messenger Parity

- [Timeline refresh after app restart](matrix-timeline-restart-refresh.md)
- [Message reactions](matrix-reactions-parity.md)
- [Unread, read, and delivery decorations](matrix-read-delivery-receipts-parity.md)
- [Typing indicators](matrix-typing-indicators-parity.md)
- [APNs-backed Matrix push notifications](matrix-push-notifications-parity.md)
- [Rich attachment and media parity](matrix-attachments-rich-media-parity.md)

## Rooms And Participants

- [Group membership management parity](matrix-group-membership-parity.md)
- [Chat lifecycle parity](matrix-chat-lifecycle-parity.md)
- [Device management parity](matrix-device-management-parity.md)

## Directory And Account Surfaces

- [User directory and profile parity](matrix-user-directory-profile-parity.md)
- [Account bootstrap and provisioning parity](matrix-account-bootstrap-provisioning-parity.md)

## Operational And Advanced Surfaces

- [History sync, repair, and offline recovery parity](matrix-history-sync-repair-parity.md)
- [Diagnostics and system status parity](matrix-diagnostics-system-status-parity.md)
- [Admin control plane parity](matrix-admin-control-plane-parity.md)
- [Bot runtime parity](matrix-bot-runtime-parity.md)
- [Matrix TestFlight release parity](matrix-testflight-release-parity.md)

## Platform Regression Items

- [iOS opens the first dialog automatically](ios-auto-opens-first-dialog.md)
- [iOS attachment rows skip the explicit download/open flow](ios-attachment-download-flow.md)
- [iOS Matrix UI lacks legacy product parity](ios-legacy-parity-ui.md)
- [iOS DM rooms are missing from the room list](ios-dm-rooms-missing.md)
- [macOS attachment transfer needs manual picker/open release revalidation](macos-attachment-transfer-failed.md)
- [macOS Matrix UI lacks legacy product parity](macos-legacy-parity-ui.md)
- [macOS navigation and settings structure is wrong](macos-three-column-settings.md)
