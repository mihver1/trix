# Trix Admin App

The admin app is a local native macOS operator surface for the private Trix XMPP
deployment. It talks to `trix-admin-api`, which wraps loopback-only ejabberd,
push gateway, media-storage, logs, metrics, and feature-flag operations.

Do not point the app at raw ejabberd `5280`, the invite wrapper's private
operator routes, or any public unaudited endpoint.

## Current Slice

- macOS target: `TrixAdminMac` in `apple/project.yml`.
- Server binary: `apps/trix-admin-api`.
- Default server bind: `127.0.0.1:8093`.
- Auth: `Authorization: Bearer <TRIX_ADMIN_API_TOKEN>`.
- Token policy: deployment-local, non-default, and at least 32 bytes.
- Feature flags: JSON file at `TRIX_FEATURE_FLAGS_PATH`, defaulting to
  `/var/lib/trix-admin-api/feature-flags.json` in the container.

The app currently exposes:

- user search, create, password reset, disable, and enable;
- wake and VoIP test-push requests through `trix-push-gateway`;
- media storage status for the ejabberd HTTP-upload volume;
- status, metrics summary, and recent scrubbed logs;
- secret-safe audit events for admin mutations;
- feature-flag list, create, update, and delete.

## Local Bring-Up

```bash
cd server/xmpp
TRIX_ADMIN_API_TOKEN="$(openssl rand -hex 32)" \
podman compose --profile admin up -d admin-api
```

For a self-contained local verification after admin API changes:

```bash
server/xmpp/scripts/admin-api-smoke.sh
```

The smoke builds `trix-admin-api`, starts a disposable loopback server, verifies
admin auth, user-management routes through a temporary fake ejabberd API,
client-visible flag filtering, feature-flag create/update/delete, audit events,
media storage, metrics, scrubbed logs, and the disabled test-push dependency
path. It uses temporary files and does not require real APNs, ejabberd, or
push-gateway secrets.

Then build/run `TrixAdminMac` from the generated Xcode project:

```bash
cd apple
xcodegen generate
xcodebuild -project TrixMatrix.xcodeproj -scheme TrixAdminMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

In the app, use:

```text
Server URL: http://127.0.0.1:8093
Admin token: the deployment-local TRIX_ADMIN_API_TOKEN
```

## VPS Access

Keep `trix-admin-api` bound to loopback on the VPS. From the Mac, open a tunnel:

```bash
ssh -N -L 8093:127.0.0.1:8093 trix.selfhost.ru
```

Then point the app to `http://127.0.0.1:8093`. The standalone admin API refuses
non-loopback binds and non-private upstream URLs unless a deployment override is
explicitly set. Do not add a public nginx route for `/v1/admin/*` unless a
separate review accepts the exposure, rate limits, audit logs, and operator-auth
policy.

## Server API

Unauthenticated:

- `GET /v1/system/health`
- `GET /v1/feature-flags/snapshot`

Bearer-authenticated:

- `GET /v1/admin/session`
- `GET /v1/admin/users?query=<text>&limit=<n>`
- `POST /v1/admin/users`
- `POST /v1/admin/users/{localpart}/reset-password`
- `POST /v1/admin/users/{localpart}/disable`
- `POST /v1/admin/users/{localpart}/enable`
- `POST /v1/admin/push/test/wake`
- `POST /v1/admin/push/test/voip`
- `GET /v1/admin/media/storage`
- `GET /v1/admin/ops/status`
- `GET /v1/admin/metrics/summary`
- `GET /v1/admin/logs/recent?service=<name>&limit=<n>`
- `GET /v1/admin/audit/recent?limit=<n>`
- `GET /v1/admin/feature-flags`
- `POST /v1/admin/feature-flags`
- `PUT /v1/admin/feature-flags/{key}`
- `DELETE /v1/admin/feature-flags/{key}`

Admin responses must not include passwords, APNs keys, APNs tokens, bearer
tokens, OMEMO state, media keys, decrypted message bodies, or decrypted
filenames.

Admin mutations append JSONL audit events to `TRIX_ADMIN_AUDIT_LOG_PATH`.
Events contain only timestamp, actor, action, target, outcome, and optional
redacted detail. They must not contain request bodies, passwords, APNs tokens,
call ids, invite codes, OMEMO material, media keys, or decrypted content.

## Agent Rules

- Keep the admin API loopback-first.
- Keep raw ejabberd `5280`, push `8090`, invite `8091`, and call-control `8092`
  non-public unless a task explicitly changes the deployment boundary.
- Use existing server-supported APIs and wrappers; do not add a second chat
  protocol.
- Add or update smoke coverage when a route mutates user, push, media, log, or
  feature-flag behavior.
- Add audit events for new mutating admin routes and keep event fields
  secret-safe.
- Update this document and `docs/feature-flags.md` when the operator workflow
  changes.
