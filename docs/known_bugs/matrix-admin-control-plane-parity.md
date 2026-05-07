# Matrix: Admin Control Plane Parity

Status: Open.

## Summary

Legacy Trix includes a macOS admin app and server admin routes for registration
settings, user provisioning, user disable/reactivate, sessions, feature flags,
and debug metrics. The Matrix MVP currently relies on Conduit admin/bootstrap
behavior and has no Trix Matrix admin app.

## Legacy behavior to match

- Admin user provisioning with one-time tokens.
- Registration and server runtime settings.
- User list, disable, reactivate, and patch operations.
- Debug metrics and session inspection.

Relevant legacy entry points:

- `apps/macos-admin/README.md`
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Shell/RootView.swift`
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/UserListView.swift`
- `crates/trix-server/src/routes/admin.rs`

## Current Matrix state

- Conduit is the homeserver.
- Federation is disabled for the MVP.
- Docs rely on first-user admin and manual account/bootstrap operations.
- No Matrix admin app or Trix admin wrapper is documented.

## Required implementation

- Decide whether Matrix MVP needs an admin UI, admin script, or docs-only
  operator path.
- If docs-only, write exact Conduit admin commands and remove ambiguity from the
  MVP checklist.
- If an admin app is required, scope it to Matrix/Conduit-supported admin APIs
  and do not resurrect `trixd`.
- Include user provisioning, registration disabling, backup/restore, and account
  disable/reactivate if supported.

## Boundaries

- Do not implement a parallel custom Matrix control plane without explicit user
  approval.
- Do not commit admin tokens or credentials.
- Do not weaken private deployment security for convenience.

## Acceptance criteria

- There is a clear operator path for creating and disabling users.
- There is a clear path for disabling registration after bootstrap.
- Backup/restore/admin limitations are documented.
- If an app/script is added, it uses supported Conduit/Matrix APIs and has safe
  secret handling.

## Verification plan

- Validate docs against a disposable Conduit instance if possible.
- Confirm no secrets are committed.
- Run affected docs/code checks and `git diff --check`.
