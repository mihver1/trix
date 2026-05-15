# Task: Loopback Control-Plane Rate Limit And Anti-Flood

You are the next coding agent working in the Trix repo. Add conservative
rate-limit and anti-flood protection around the XMPP control-plane wrappers,
including paths that ultimately call ejabberd `mod_http_api`.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `server/xmpp/README.md`
- `server/xmpp/ejabberd.yml`
- `server/xmpp/scripts/operator-control.sh`
- `server/xmpp/scripts/operator-api-smoke.sh`
- `server/xmpp/scripts/invite-registration-server.py`
- `server/xmpp/scripts/invite-registration-smoke.sh`

`invite-registration-server.py` limits request body size and uses auth for
operator/account endpoints, but it has no request rate limiter. `operator-control.sh`
refuses non-loopback API URLs by default, but a local loop or buggy wrapper could
still hammer `register`, `change_password`, `ban_account`, `unban_account`,
`check_password`, sticker import, or health endpoints.

## Goal

Local and app-facing wrappers fail closed under accidental loops or repeated bad
requests, returning clear generic errors without leaking secrets.

## Non-Goals

- Do not expose `mod_http_api` publicly.
- Do not weaken authentication or allow unauthenticated mutation.
- Do not rely on rate limits as the only security boundary.
- Do not log request bodies, passwords, Basic headers, bearer tokens, invite
  codes, or sticker file tokens.

## Implementation Plan

1. Define scopes and defaults:
   - per source IP for public/private wrapper HTTP routes;
   - per account JID for signed-in invite/password/sticker routes;
   - per command for operator endpoints;
   - per process or file-backed state for `operator-control.sh`.
2. Add a small token-bucket or fixed-window limiter to
   `invite-registration-server.py`:
   - configurable env vars for window and limits;
   - sane defaults for invite creation, redemption, password change, sticker
     pack resolve, sticker file download, and operator routes;
   - HTTP `429` with generic JSON error.
3. Add anti-loop protection to `operator-control.sh`:
   - local lock with `flock` or a portable fallback;
   - file-backed recent-call counters under a restrictive state dir;
   - per-command minimum interval or fixed-window limit;
   - env override only for explicit maintenance, and document it.
4. Add optional gateway/proxy hardening docs:
   - nginx/Caddy `limit_req` examples for app-facing routes;
   - keep `/v1/operator/*` operator-only;
   - never proxy raw `/api` outside loopback.
5. Add tests/smokes:
   - repeated bad auth reaches `429`;
   - repeated redeem attempts reach `429` without consuming valid invite state;
   - operator dry-run or fake backend reaches local limiter;
   - successful low-rate operations still pass.
6. Update docs:
   - `docs/security.md` registration/control-plane risk;
   - `server/xmpp/README.md` env vars and expected limits.

## Acceptance Criteria

- App-facing wrapper routes have rate limits with configurable defaults.
- Operator script has local anti-loop protection before calling loopback
  `mod_http_api`.
- `429` responses are generic and secret-free.
- Existing invite and operator smokes still pass at normal rates.
- Docs state that rate limiting is defense-in-depth and does not make
  `mod_http_api` public-safe.

## Verification Commands

```bash
bash -n server/xmpp/scripts/*.sh
server/xmpp/scripts/invite-registration-smoke.sh
server/xmpp/scripts/operator-api-smoke.sh
git diff --check
```

Run `operator-api-smoke.sh` only when local ejabberd is available; otherwise
report it as skipped with the exact reason.
