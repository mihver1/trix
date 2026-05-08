# Archived Matrix Parity Backlog

This folder contains user-visible bugs and parity notes from the short-lived
Matrix Apple experiment.

The active product direction is now XMPP + OMEMO. Do not use the Matrix backlog
as the active implementation plan. The current XMPP migration plan, parity
checklist, protocol feature map, spike checklist, and risk register live in:

- [../xmpp-migration/README.md](../xmpp-migration/README.md)
- [../xmpp-migration/parity-checklist.md](../xmpp-migration/parity-checklist.md)
- [../xmpp-migration/protocol-feature-map.md](../xmpp-migration/protocol-feature-map.md)
- [../xmpp-migration/spike-checklist.md](../xmpp-migration/spike-checklist.md)
- [../xmpp-migration/risk-register.md](../xmpp-migration/risk-register.md)

These archived files are still useful as legacy parity evidence because they
describe product behavior that XMPP must cover: reactions, receipts, typing,
push, directory/profile, group membership, lifecycle, history repair,
diagnostics, admin tooling, bot runtime, and release surfaces.

## Archived Messenger Parity

- [Timeline refresh after app restart](matrix-timeline-restart-refresh.md)
- [Message reactions](matrix-reactions-parity.md)
- [Unread, read, and delivery decorations](matrix-read-delivery-receipts-parity.md)
- [Typing indicators](matrix-typing-indicators-parity.md)
- [APNs-backed Matrix push notifications](matrix-push-notifications-parity.md)
- [Rich attachment and media parity](matrix-attachments-rich-media-parity.md)

## Archived Rooms And Participants

- [Group membership management parity](matrix-group-membership-parity.md)
- [Chat lifecycle parity](matrix-chat-lifecycle-parity.md)
- [Device management parity](matrix-device-management-parity.md)

## Archived Directory And Account Surfaces

- [User directory and profile parity](matrix-user-directory-profile-parity.md)
- [Account bootstrap and provisioning parity](matrix-account-bootstrap-provisioning-parity.md)

## Archived Operational And Advanced Surfaces

- [History sync, repair, and offline recovery parity](matrix-history-sync-repair-parity.md)
- [Diagnostics and system status parity](matrix-diagnostics-system-status-parity.md)
- [Admin control plane parity](matrix-admin-control-plane-parity.md)
- Matrix bot runtime parity was tracked in the Matrix backlog, but the standalone
  file is not present in this checkout. Use the XMPP parity checklist instead.
- [Matrix TestFlight release parity](matrix-testflight-release-parity.md)

## Archived Platform Regression Items

- [iOS opens the first dialog automatically](ios-auto-opens-first-dialog.md)
- [iOS attachment rows skip the explicit download/open flow](ios-attachment-download-flow.md)
- [iOS Matrix UI lacks legacy product parity](ios-legacy-parity-ui.md)
- [iOS DM rooms are missing from the room list](ios-dm-rooms-missing.md)
- [macOS attachment transfer needs manual picker/open release revalidation](macos-attachment-transfer-failed.md)
- [macOS Matrix UI lacks legacy product parity](macos-legacy-parity-ui.md)
- [macOS navigation and settings structure is wrong](macos-three-column-settings.md)

## Rules For Future Work

- Do not add new active Matrix bug docs.
- Do not implement Matrix parity items directly unless the user explicitly
  reopens the Matrix experiment.
- When a Matrix archived note describes a product behavior that still matters,
  implement it through XMPP + OMEMO and update `docs/xmpp-migration/` instead.
