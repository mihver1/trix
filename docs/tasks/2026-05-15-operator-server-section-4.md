# Operator Plane And Server Section 4

This file validates the fourth auditor batch and points the next agents at
bounded prompts under `docs/tasks/`.

## Validation

These items are worth keeping, with one important boundary: ejabberd
`mod_http_api` remains a loopback backend only. Anything user-facing or
operator-facing must sit behind a small Trix wrapper, local UI, or SSH-tunneled
private surface.

- Operator audit log viewer is valid and should come first. Today invite
  creation/redeem state lives in `invite-registration-server.py`, while
  provision/reset/disable/enable actions live in `operator-control.sh`. There is
  no single redacted timeline of operator actions.
- A tiny operator panel is valid, but should be local-first: TUI or bearer-only
  HTML bound to `127.0.0.1`, preferably reached through SSH. It must call the
  Trix wrapper/script, not expose raw `mod_http_api`.
- Apple operator diagnostics are valid if scoped carefully. Normal Settings can
  show redacted local diagnostics; operator-only server health needs a wrapper
  endpoint or token stored in Keychain, never a committed/admin secret.
- Automated backup-restore CI is high value. `restore-verify.sh` already exists
  and should run on a schedule and in manual CI, because backup reliability
  decays when it is only checked by hand.
- Rate limiting and anti-flood on the loopback control plane is valid. Even on
  localhost, a client bug or wrapper loop can hammer registration, password,
  invite, sticker, or operator commands.

## Suggested Order

1. `2026-05-15-operator-audit-log-viewer.md`
2. `2026-05-15-loopback-api-rate-limit-anti-flood.md`
3. `2026-05-15-automated-backup-restore-ci.md`
4. `2026-05-15-local-operator-panel.md`
5. `2026-05-15-apple-operator-health-dashboard.md`

Audit logging and rate limits should land before adding friendlier operator
surfaces. Backup-restore CI is independent and can run in parallel. The local
operator panel can reuse the audit and health endpoints. Apple operator
diagnostics should come after there is a safe server-side diagnostics contract.

## Global Constraints For All Prompts

- Start by reading `AGENTS.md`, `docs/security.md`, `docs/mvp-checklist.md`,
  `server/xmpp/README.md`, and the task-specific files listed in each prompt.
- Run `git status --short` before editing and do not revert unrelated changes.
- Keep `mod_http_api` loopback-only. Do not expose port `5280` publicly.
- Do not log passwords, Basic auth headers, bearer tokens, invite codes, APNs
  tokens, APNs private keys, OMEMO secrets, private keys, media keys, sticker
  file tokens, Telegram bot tokens, local decrypted paths, or decrypted message
  bodies.
- Store operator audit and state files with restrictive permissions and
  deployment-local paths.
- Operator tooling may print scrubbed status lines, action ids, timestamps,
  actor ids, target JIDs, result codes, and generic error codes.
- Treat health, quota, and media-size diagnostics as operational metadata; keep
  them authenticated and private.
- Preserve existing server scripts and live-smoke behavior unless a task
  explicitly replaces them.

## Current Entry Points

- `server/xmpp/scripts/operator-control.sh`
- `server/xmpp/scripts/operator-api-smoke.sh`
- `server/xmpp/scripts/invite-registration-server.py`
- `server/xmpp/scripts/invite-registration-smoke.sh`
- `server/xmpp/scripts/backup.sh`
- `server/xmpp/scripts/restore-verify.sh`
- `server/xmpp/docker-compose.yml`
- `server/xmpp/ejabberd.yml`
- iOS Settings diagnostics:
  `apple/Sources/Shared/Views/TrixRoomListView.swift`
- macOS Settings diagnostics:
  `apple/Sources/macOS/TrixMacRootView.swift`
