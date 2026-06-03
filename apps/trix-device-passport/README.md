# trix-device-passport

`trix-device-passport` is the app-facing Device Passport state service for the
private XMPP deployment. It is separate from `trix-admin-api` and from the
Python invite wrapper.

The service stores long-lived approval state, reset notices, directory claims,
notice dismissals, and scrubbed audit records in SQLite. It stores OMEMO device
ids, friendly device labels, platform values, trust generations, and fingerprint
hashes. It must not store OMEMO private material, raw fingerprints, passwords,
APNs tokens, credentials, media keys, decrypted message bodies, or raw secrets.

Server state is not a cryptographic trust oracle. Directory claims are emitted
with `proof_required=true`; Apple clients must auto-apply trust only after an
OMEMO-backed claim can be tied to a previously trusted device and the refreshed
MartinOMEMO identity state matches `device_id` plus `fingerprint_hash`.

## Run Locally

```bash
TRIX_DEVICE_PASSPORT_DRY_RUN_AUTH=1 \
TRIX_DEVICE_PASSPORT_DB_PATH=/tmp/trix-device-passport.sqlite \
cargo run -p trix-device-passport
```

For a Compose deployment:

```bash
cd server/xmpp
TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN="$(openssl rand -hex 32)" \
docker compose --profile device-passport up -d device-passport
```

The default service bind is `127.0.0.1:8094`. In Compose the container listens on
`0.0.0.0:8094`, while the host publish remains loopback-bound by default.

For a self-contained deploy smoke without real ejabberd credentials:

```bash
server/xmpp/scripts/device-passport-smoke.sh
```

The smoke builds the binary, starts it on a random loopback port with a
temporary SQLite database and dry-run auth, then exercises health,
current-device registration, operator reset, approval request creation,
directory-claim pagination, notice dismissal, and state sync.

## Configuration

- `TRIX_DEVICE_PASSPORT_BIND_ADDR`: service bind address. Default:
  `127.0.0.1:8094`.
- `TRIX_DEVICE_PASSPORT_ALLOW_NON_LOOPBACK`: explicit container/private-network
  override for non-loopback binds. The Compose profile sets this while keeping
  the host publish loopback-bound.
- `TRIX_DEVICE_PASSPORT_DB_PATH`: SQLite database path. Default:
  `/var/lib/trix-device-passport/device-passport.sqlite`.
- `TRIX_DEVICE_PASSPORT_LOG`: tracing filter. Default:
  `info,trix_device_passport=debug`.
- `TRIX_DEVICE_PASSPORT_APPROVAL_TTL_SECONDS`: approval request lifetime.
  Default: `600`.
- `TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN`: bearer token for operator reset. Empty
  disables reset. Placeholder or weak values are rejected.
- `TRIX_DEVICE_PASSPORT_DRY_RUN_AUTH`: local-only switch that accepts Basic auth
  without calling ejabberd.
- `TRIX_XMPP_API_URL`: ejabberd `mod_http_api` endpoint for `check_password`.
- `TRIX_XMPP_HOST`: local XMPP domain, default `trix.selfhost.ru`.

## API

App-facing routes use the signed-in XMPP account via Basic auth.

- `GET /v1/system/health`
- `POST /v1/device-passport/current-device`
- `GET /v1/device-passport/state` with `X-Trix-Device-ID`
- `POST /v1/device-passport/approval-requests`
- `POST /v1/device-passport/approval-requests/{request_id}/approve`
- `POST /v1/device-passport/approval-requests/{request_id}/decline`
- `GET /v1/device-passport/directory-claims?since=cursor`
- `POST /v1/device-passport/notices/{user_id}/dismiss`

Operator reset uses `Authorization: Bearer <TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN>`:

- `POST /v1/operator/device-passport/{user_id}/reset`

Reset increments the user's trust generation, revokes prior devices, expires
pending approvals, emits a high-severity directory claim, and writes a scrubbed
high-severity audit event.
