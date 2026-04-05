# Server Configuration

Operational notes for `trixd`, the admin control plane, and the staged public test rollout.

## Local Development

`trixd` reads process environment directly. The repo-root `.env.example` is a convenient template, but the binary does not auto-load it.

Typical local startup:

```bash
cp .env.example .env
set -a
source .env
set +a

docker compose up -d postgres
cargo run -p trixd
```

## Runtime Environment

### Core server

- `TRIX_BIND_ADDR`: listener address. Default `127.0.0.1:8080`.
- `TRIX_PUBLIC_BASE_URL`: externally reachable base URL advertised by the service. Keep this on local `http://localhost:8080` for laptop dev; move it to the final `https://...` host only after ingress/TLS is live.
- `TRIX_DATABASE_URL`: PostgreSQL DSN.
- `TRIX_BLOB_ROOT`: local blob storage root.
- `TRIX_BLOB_MAX_UPLOAD_BYTES`: max encrypted upload size in bytes.
- `TRIX_LOG`: tracing filter, default `info,trix_server=debug`.
- `TRIX_JWT_SIGNING_KEY`: required consumer auth signing key. Must not be empty and must not be `replace-me`.
- `TRIX_CORS_ALLOWED_ORIGINS`: comma-separated allowed browser origins.

### Admin control plane

- `TRIX_ADMIN_USERNAME`: required cluster-local admin login name.
- `TRIX_ADMIN_PASSWORD`: required cluster-local admin login password.
- `TRIX_ADMIN_JWT_SIGNING_KEY`: required admin JWT signing key. Separate from consumer auth and must not be `replace-me`.
- `TRIX_ADMIN_SESSION_TTL_SECONDS`: admin JWT lifetime in seconds. Default `900`.

The current admin API is stateless except for the issued JWT. Routes live under `/v0/admin/*` and are separate from consumer account/device/chat auth.

### Rate limits

- `TRIX_RATE_LIMIT_WINDOW_SECONDS`
- `TRIX_RATE_LIMIT_AUTH_CHALLENGE_LIMIT`
- `TRIX_RATE_LIMIT_AUTH_SESSION_LIMIT`
- `TRIX_RATE_LIMIT_LINK_INTENTS_LIMIT`
- `TRIX_RATE_LIMIT_DIRECTORY_LIMIT`
- `TRIX_RATE_LIMIT_BLOB_UPLOAD_LIMIT`

`docker-compose.yml` intentionally overrides some auth/session limits upward for local smoke runs so repeated simulator/device reseeding does not trip the default dev throttles.

### Cleanup and retention

- `TRIX_CLEANUP_INTERVAL_SECONDS`
- `TRIX_AUTH_CHALLENGE_RETENTION_SECONDS`
- `TRIX_LINK_INTENT_RETENTION_SECONDS`
- `TRIX_TRANSFER_BUNDLE_RETENTION_SECONDS`
- `TRIX_HISTORY_SYNC_RETENTION_SECONDS`
- `TRIX_PENDING_BLOB_RETENTION_SECONDS`
- `TRIX_SHUTDOWN_GRACE_PERIOD_SECONDS`

These control server-side garbage collection for auth challenges, device-link artifacts, single-consume transfer bundles, history-sync ciphertext, staged blob uploads, and shutdown drain behavior.

## History Sync Orchestration

- `TRIX_HISTORY_SYNC_RETENTION_SECONDS` applies to all history-sync job families: `initial_sync`, explicit `chat_backfill`, `device_rekey`, and targeted `timeline_repair`.
- `POST /v0/history-sync/jobs/request` lets an authenticated target device ask one sibling active device for a fresh `chat_backfill` job for a specific chat.
- repeated `POST /v0/history-sync/jobs/request` calls for the same `(account_id, target_device_id, chat_id)` reuse the existing active `chat_backfill` job instead of inserting duplicates.
- `POST /v0/history-sync/jobs:request-repair` lets an authenticated target device ask all sibling active devices for a bounded replay window when local history projection detects a gap, an unmaterialized application message, or a projection failure.
- overlapping pending `timeline_repair` requests are coalesced server-side by widening the stored `repair_from_server_seq` / `repair_through_server_seq` window instead of creating duplicate pending jobs.
- if an account has no other active source device, `/v0/history-sync/jobs/request` returns `404` and `/v0/history-sync/jobs:request-repair` returns an empty `jobs` array.

## Message Repair Witness

- `POST /v0/message-repairs:request` is a second-line, per-message recovery path used only after ordinary `timeline_repair` did not restore a specific canonical message.
- the request is bound to canonical server metadata: `chat_id`, `message_id`, `server_seq`, `epoch`, sender identifiers, message shape, and the stored ciphertext hash.
- the server chooses an eligible witness only from active devices of the sender account, preferring the original `sender_device_id`.
- if no eligible sender-side witness exists, the route returns a clean `unavailable` outcome; it does not fall back to arbitrary plaintext holders.
- the server stores only short-lived request state and an opaque relay payload; it never stores durable plaintext-derived backups and cannot decrypt the witness payload.
- witness payloads are encrypted directly to the target device transport key and are single-use once the target calls `POST /v0/message-repairs/{request_id}/complete`.

## Admin API Summary

Current operator routes:

- `POST /v0/admin/session`
- `DELETE /v0/admin/session`
- `GET /v0/admin/overview`
- `GET/PATCH /v0/admin/settings/registration`
- `GET/PATCH /v0/admin/settings/server`
- `GET /v0/admin/users`
- `GET/PATCH /v0/admin/users/{account_id}`
- `POST /v0/admin/users`
- `POST /v0/admin/users/{account_id}/disable`
- `POST /v0/admin/users/{account_id}/reactivate`

Important behavior:

- `POST /v0/admin/users` returns a provisioning artifact and one-time `provision_token`; it does not create a fully bootstrapped cryptographic account.
- disabling a user closes active consumer websocket sessions with `session_replaced`.
- registration/server settings are DB-backed runtime settings; deploy-time env such as bind address, database URL, or signing keys are intentionally not mutable through the admin API.

See [`openapi/v0.yaml`](../openapi/v0.yaml) for the full request/response contract.

## Public Test Rollout

The staged ingress/TLS overlay for `https://trix.artelproject.tech` lives under [`deploy/public-test/`](../deploy/public-test/README.md).

Use the base compose file plus the overlay:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/public-test/docker-compose.public-test.yml \
  up -d app nginx
```

Issue certificates with the `certbot` profile only after DNS resolves. Keep `TRIX_PUBLIC_BASE_URL` on the final `https://` domain only once HTTPS is actually reachable.
