# Matrix: History Sync, Repair, And Offline Recovery Parity

Status: Open.

## Summary

Legacy Trix has explicit history sync jobs, backfill, repair witnesses, local
history stores, and outbox recovery. Matrix Apple should rely on Matrix SDK sync
and storage, but it still needs product-level offline/restart robustness and
diagnostics for missing history.

## Legacy behavior to match

- Local history is available after restart.
- Inbox/history repair fills missing timeline data.
- Linked devices can recover history through repair/backfill paths.
- Users and developers can distinguish "still syncing" from "history missing".

Relevant legacy entry points:

- `crates/trix-server/src/routes/history_sync.rs`
- `crates/trix-server/src/routes/message_repairs.rs`
- `crates/trix-core/src/sync.rs`
- `crates/trix-core/src/messenger.rs`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`

## Current Matrix state

- Matrix SDK persistent storage is configured through the adapter.
- Timeline load and pagination are exposed.
- Restart refresh is still a separate TODO.
- No app-visible history repair/backfill controls or diagnostics exist.

## Required implementation

- First finish timeline restart refresh.
- Validate Matrix SDK persistent timeline behavior for encrypted DM and group
  rooms after app relaunch.
- Add user-readable loading, pagination, and error states for missing history.
- If SDK exposes back-pagination or timeline reset repair APIs, keep them behind
  the service/view-model boundary.
- Document which legacy repair controls are intentionally replaced by Matrix SDK
  sync.

## Boundaries

- Do not port legacy MLS history repair logic.
- Do not manually decrypt Matrix event history.
- Do not log decrypted event bodies or access tokens.

## Acceptance criteria

- Previously loaded messages remain visible after app restart.
- New messages sent while the app was closed appear after refresh.
- Older messages can be paginated/backfilled where Matrix SDK supports it.
- Missing-history failures are actionable and do not appear as blank timelines.
- Docs explain the Matrix-native replacement for legacy repair controls.

## Verification plan

- Build iOS and macOS Matrix targets.
- Live-test encrypted DM and group after app restart.
- Send messages while one client is offline, then relaunch and verify sync.
- Test older-message pagination if supported.
- `git diff --check`
