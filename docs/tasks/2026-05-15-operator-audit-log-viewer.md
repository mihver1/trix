# Task: Operator Audit Log And Viewer

You are the next coding agent working in the Trix repo. Add a redacted
append-only operator audit log and a small viewer for account/invite/control
actions.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `server/xmpp/README.md`
- `server/xmpp/scripts/operator-control.sh`
- `server/xmpp/scripts/operator-api-smoke.sh`
- `server/xmpp/scripts/invite-registration-server.py`
- `server/xmpp/scripts/invite-registration-smoke.sh`

Current split:

- `invite-registration-server.py` stores invite metadata in JSON with
  `created_at`, `issued_by`, `expires_at`, `redeemed_at`, and `redeemed_user`.
- `operator-control.sh` can provision users, reset passwords, disable/enable
  accounts, search directory, and report health through loopback `mod_http_api`.
- There is no unified audit timeline for invite creation, redemption,
  password-reset, disable, enable, or wrapper failures.

## Goal

Operators can answer who did what and when for sensitive account lifecycle
events without reading scattered state files or service logs.

## Non-Goals

- Do not log invite codes or code hashes.
- Do not log passwords, password-file paths, Basic auth headers, bearer tokens,
  APNs material, sticker file tokens, Telegram bot tokens, OMEMO secrets, or
  decrypted content.
- Do not expose the audit log publicly.
- Do not replace systemd/journal logs; this is a product-specific redacted event
  ledger.

## Implementation Plan

1. Define a small append-only JSONL schema, for example:
   - `version`;
   - `event_id`;
   - `timestamp_utc`;
   - `actor`;
   - `actor_kind` (`operator`, `account`, `system`, `unknown`);
   - `action`;
   - `target_jid` or `target_localpart`;
   - `result` (`ok`, `denied`, `failed`);
   - `error_code`;
   - `request_id` or invite id where safe;
   - `source` (`operator-control`, `invite-wrapper`, `restore-ci`);
   - optional `metadata` with only non-secret values.
2. Add a shared lightweight writer:
   - either a Python module/script under `server/xmpp/scripts/`;
   - or duplicated minimal JSONL append helpers if shell/Python sharing gets
     awkward.
3. Add env-configurable paths:
   - `TRIX_OPERATOR_AUDIT_LOG_PATH`;
   - default under `server/xmpp/.state/operator-audit.jsonl` for local dev;
   - production example under `/var/lib/trix-xmpp/operator-audit.jsonl`.
4. Enforce file permissions:
   - create parent directory with `0700`;
   - create log file with `0600`;
   - append atomically enough for local single-host usage;
   - avoid truncation on parse/viewer errors.
5. Instrument `invite-registration-server.py`:
   - operator invite created;
   - app invite created with signed-in issuer JID;
   - invite redemption success/failure;
   - account password changed by signed-in user;
   - sticker import failures only if useful and redacted.
6. Instrument `operator-control.sh`:
   - provision-user;
   - reset-password;
   - disable-user;
   - enable-user;
   - health checks if wanted, but keep noisy events opt-in.
7. Add `operator-audit-viewer`:
   - filter by time, actor, target, action, result;
   - default table output;
   - `--json` output for future panels;
   - never print raw secrets.
8. Add smoke coverage:
   - dry-run invite smoke writes and reads audit events;
   - operator API smoke writes account lifecycle events;
   - viewer rejects malformed filters cleanly.
9. Update `docs/security.md` and `server/xmpp/README.md` with audit-log
   location, retention expectations, and redaction guarantees.

## Acceptance Criteria

- Invite creation/redeem, disable, enable, provision, and reset-password create
  redacted audit events.
- The viewer can filter and print a useful timeline without secrets.
- Audit log files are created with restrictive permissions.
- Existing invite and operator smokes pass.
- Failure paths record generic error codes without request bodies or credentials.

## Verification Commands

```bash
bash -n server/xmpp/scripts/*.sh
TRIX_INVITE_DRY_RUN=1 server/xmpp/scripts/invite-registration-smoke.sh
server/xmpp/scripts/operator-api-smoke.sh
git diff --check
```

Run `operator-api-smoke.sh` only when a local ejabberd with loopback API is
already running. If unavailable, report it as skipped with the exact reason.
