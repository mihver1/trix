# Task: Local Operator Panel Over The Loopback Control Plane

You are the next coding agent working in the Trix repo. Add a tiny local
operator panel that wraps the existing control-plane scripts without exposing
ejabberd `mod_http_api` directly.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `server/xmpp/README.md`
- `server/xmpp/scripts/operator-control.sh`
- `server/xmpp/scripts/operator-api-smoke.sh`
- `server/xmpp/scripts/invite-registration-server.py`
- `docs/tasks/2026-05-15-operator-audit-log-viewer.md`

`operator-control.sh` already refuses non-loopback `TRIX_XMPP_API_URL` unless an
explicit override is set. The finished operator plane still needs a small
authenticated/audited wrapper before any non-local operator surface exists.

## Goal

An operator can use a small local UI for common tasks:

- health and archive/upload/push status;
- create invite;
- provision user;
- reset password;
- disable/enable user;
- search directory;
- view audit log.

## Non-Goals

- Do not expose `mod_http_api` or port `5280` publicly.
- Do not build a public admin console.
- Do not store operator bearer tokens, passwords, or reset passwords in repo
  files.
- Do not add multi-operator RBAC in the first slice.
- Do not make Apple clients depend on this local panel.

## Implementation Plan

1. Choose the smallest surface:
   - preferred first slice: local TUI/CLI menu that shells out to
     `operator-control.sh` and `operator-audit-viewer`;
   - acceptable alternative: bearer-only HTML server bound to `127.0.0.1`, with
     explicit SSH tunnel documentation.
2. Keep all actions behind the existing script boundary:
   - call `operator-control.sh`;
   - call invite wrapper only through its documented private endpoints;
   - never call raw `mod_http_api` from browser/frontend code.
3. If using HTML:
   - bind to `127.0.0.1` by default;
   - require `Authorization: Bearer ...`;
   - reject missing token at startup unless `--dev-no-auth` is set for local
     smoke only;
   - send `Cache-Control: no-store`;
   - disable CORS;
   - add CSRF protection for browser form POSTs;
   - avoid logging request bodies.
4. If using TUI:
   - read passwords from files or prompt without echo;
   - never pass secrets through command output;
   - display only scrubbed script output.
5. Add panel actions:
   - health status;
   - archive/upload/push health;
   - create invite;
   - provision/reset/disable/enable;
   - directory search;
   - audit log filter.
6. Add rate-limit hooks or depend on the rate-limit task before broad use.
7. Add tests/smoke:
   - dry-run mode using fake `operator-control.sh` outputs;
   - auth rejection for HTML mode;
   - no body/token values in logs.
8. Update `server/xmpp/README.md` with run instructions and private-access
   warning.

## Acceptance Criteria

- Operator can perform the listed tasks from a local UI.
- The panel binds to loopback and never requires public exposure.
- The panel uses the audited script/wrapper path, not raw `mod_http_api`.
- Secrets are accepted through files, no-echo prompts, or private POST bodies and
  are never logged.
- Audit events are written for mutating actions.

## Verification Commands

```bash
bash -n server/xmpp/scripts/*.sh
server/xmpp/scripts/invite-registration-smoke.sh
git diff --check
```

Also run the new panel smoke in dry-run/fake-backend mode. Run local
`operator-api-smoke.sh` only if an ejabberd loopback API is available.
