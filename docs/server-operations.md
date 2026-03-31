# Server Setup, APNs, and Device Lifecycle

This document is the operator-facing guide for:

- starting `trixd`
- configuring APNs wake-up pushes
- understanding how the first device, linked devices, and revoked devices move through the backend

It complements:

- [README.md](../README.md) for the top-level project overview
- [openapi/v0.yaml](../openapi/v0.yaml) for the wire contract
- [apps/ios/README.md](../apps/ios/README.md) and [apps/macos/README.md](../apps/macos/README.md) for client-specific notes

## Server Startup

`trixd` reads process environment directly. It does not auto-load `.env`.

Minimal local startup:

```bash
cp .env.example .env
set -a
source .env
set +a

docker compose up -d postgres
cargo run -p trixd
```

Health checks:

```bash
curl http://127.0.0.1:8080/v0/system/health
curl http://127.0.0.1:8080/v0/system/version
```

Important runtime details:

- `TRIX_DATABASE_URL` must point at a reachable `PostgreSQL` instance.
- `trixd` runs `sqlx` migrations automatically on startup before serving traffic.
- `TRIX_BLOB_ROOT` must be writable by the process. Blob payloads are stored there.
- `TRIX_ADMIN_USERNAME`, `TRIX_ADMIN_PASSWORD`, and `TRIX_ADMIN_JWT_SIGNING_KEY` are required even for local development.
- `TRIX_PUBLIC_BASE_URL` is not cosmetic. It is embedded into device-link QR payloads and must be reachable by the device that is scanning the QR code.

### Localhost vs LAN

For simulator-only work on the same Mac, `127.0.0.1:8080` is fine.

For a physical iPhone or another machine on the LAN, use a reachable bind/public URL pair, for example:

```bash
export TRIX_BIND_ADDR=0.0.0.0:8080
export TRIX_PUBLIC_BASE_URL=http://192.168.1.50:8080
```

If `TRIX_PUBLIC_BASE_URL` still points at `localhost`, linked-device onboarding will generate an unusable QR payload for physical devices.

### Docker Compose

The checked-in `docker-compose.yml` is enough to bootstrap local `PostgreSQL`.

If you also run the `app` service from that file, make sure it receives the same required env set as `.env.example`, especially:

- `TRIX_ADMIN_USERNAME`
- `TRIX_ADMIN_PASSWORD`
- `TRIX_ADMIN_JWT_SIGNING_KEY`

## APNs Configuration

`trixd` uses the APNs token-based auth flow with an Apple `.p8` auth key. This is an auth key, not a legacy `.cer` or `.p12` push certificate.

The server enables APNs delivery only when all four values are present:

- `TRIX_APNS_TEAM_ID`
- `TRIX_APNS_KEY_ID`
- `TRIX_APNS_TOPIC`
- one of:
  - `TRIX_APNS_PRIVATE_KEY_PATH`
  - `TRIX_APNS_PRIVATE_KEY_PEM`

If only some of them are set, startup fails validation.

### Where To Put The APNs Key

There is no hard-coded certificate directory. The server reads the key from whatever path you point `TRIX_APNS_PRIVATE_KEY_PATH` at.

Recommended pattern:

- keep the `.p8` file outside the repo
- reference it via an absolute path

Example:

```bash
export TRIX_APNS_TEAM_ID=ABCDE12345
export TRIX_APNS_KEY_ID=ABC123XYZ
export TRIX_APNS_TOPIC=com.softgrid.trixapp
export TRIX_APNS_PRIVATE_KEY_PATH=$HOME/.config/trix/apns/AuthKey_ABC123XYZ.p8
```

Containerized example:

- mount the file read-only into the container, for example `/run/secrets/apns/AuthKey_ABC123XYZ.p8`
- set `TRIX_APNS_PRIVATE_KEY_PATH=/run/secrets/apns/AuthKey_ABC123XYZ.p8`

`TRIX_APNS_PRIVATE_KEY_PEM` takes precedence over `TRIX_APNS_PRIVATE_KEY_PATH` when both are set.

### Topic And Entitlements

The current app bundle identifier for the shipping iOS/macOS app targets is `com.softgrid.trixapp`, so the matching APNs topic is also `com.softgrid.trixapp`.

Client entitlements must match the APNs environment:

- iOS: [apps/ios/TrixiOS/TrixiOS.entitlements](../apps/ios/TrixiOS/TrixiOS.entitlements)
- macOS: [apps/macos/TrixMac.entitlements](../apps/macos/TrixMac.entitlements)

The client chooses `sandbox` or `production` when it registers its APNs token. `trixd` then routes the wake-up push to:

- `api.sandbox.push.apple.com` for `sandbox`
- `api.push.apple.com` for `production`

### What The Server Sends

The APNs payload is intentionally a background wake-up only:

- `aps.content-available = 1`
- `trix.event = "inbox_update"`
- `trix.version = 1`

It does not contain message text. Devices wake up, sync inbox/history, and derive notification content locally from encrypted state.

### When Registrations Are Disabled

APNs registrations are stored in `device_push_registrations`.

The server automatically disables a stored registration after APNs rejects it with one of these terminal cases:

- `BadDeviceToken`
- `DeviceTokenNotForTopic`
- `Unregistered`

Operationally, that usually means one of:

- the token was produced for a different bundle/topic
- the app switched sandbox vs production
- the device token is stale and must be re-registered by the client

## Device Lifecycle

### First Device Bootstrap

The first device for an account is created with `POST /v0/accounts`.

The request includes:

- profile data
- `device_display_name`
- `platform`
- `credential_identity_b64`
- `account_root_pubkey_b64`
- `account_root_signature_b64`
- `transport_pubkey_b64`

The backend verifies the canonical account-bootstrap payload before creating the account and its first device.

Result:

- a new account is created
- the first device is created as active
- the response includes `account_id`, `device_id`, and `account_sync_chat_id`

If public registration is disabled in admin runtime settings, the same call also requires `provision_token`. Those one-time onboarding tokens are created through `POST /v0/admin/users`.

### Existing Device Authentication

Once a device is active, it authenticates with:

- `POST /v0/auth/challenge`
- `POST /v0/auth/session`

The session flow is device-key based. The client signs the challenge with the device key, not with the account-root key.

### Linking An Additional Device

The linked-device flow is a four-step handshake.

#### 1. Active device opens a link intent

Endpoint:

- `POST /v0/devices/link-intents`

Only an authenticated active device can do this.

The response includes:

- `link_intent_id`
- `qr_payload`
- `expires_at_unix`

The QR payload embeds:

- `version`
- `base_url` from `TRIX_PUBLIC_BASE_URL`
- `account_id`
- `link_intent_id`
- `link_token`

#### 2. New device completes the link intent

Endpoint:

- `POST /v0/devices/link-intents/{link_intent_id}/complete`

The new device submits:

- `link_token`
- `device_display_name`
- `platform`
- `credential_identity_b64`
- `transport_pubkey_b64`
- optional MLS `key_packages`

Result:

- a new device row is created
- it starts in `pending` status
- the link intent moves to `pending_approval`
- the response returns `pending_device_id` plus `bootstrap_payload_b64`

At this point the device exists, but it is not yet active.

#### 3. Existing trusted device reviews and approves

Inspection endpoint:

- `GET /v0/devices/{device_id}/approve-payload`

Approval endpoint:

- `POST /v0/devices/{device_id}/approve`

The approving device must belong to the same account and already be active.

The approving device signs the canonical bootstrap payload with the account-root key and sends:

- `account_root_signature_b64`
- optional `transfer_bundle_b64`

Result:

- the pending device becomes `active`
- the link intent becomes `completed`
- sync/bootstrap jobs are scheduled for the new device

#### 4. Newly approved device authenticates and optionally fetches transfer state

After approval, the new device can use the normal auth challenge/session flow.

If the approving device uploaded a transfer bundle, the target device can fetch it once through:

- `GET /v0/devices/{device_id}/transfer-bundle`

That route is only available to the target device itself after it can authenticate.

### Push Registration For iOS And macOS

After a device is active and authenticated, iOS/macOS register APNs tokens with:

- `PUT /v0/devices/push-token`

Request body:

- `token_hex`
- `environment` = `sandbox` or `production`

Response:

- `device_id`
- `environment`
- `push_delivery_enabled`

`push_delivery_enabled=true` means the server itself is APNs-capable right now. `false` means the token was stored, but `trixd` does not have a complete APNs config yet.

To unregister the device token:

- `DELETE /v0/devices/push-token`

The backend only targets APNs registrations for devices that are:

- `device_status = active`
- `platform in ('ios', 'macos')`
- not disabled in `device_push_registrations`

### Device Revoke

Endpoint:

- `POST /v0/devices/{device_id}/revoke`

The caller must be an authenticated active device on the same account.

The request includes:

- `reason`
- `account_root_signature_b64`

The signature is verified against the canonical revoke payload for `(device_id, reason)`.

Result:

- the target device moves to `revoked`
- websocket sessions for that device are eventually replaced/closed by the normal auth/runtime flow
- sync jobs are scheduled so the remaining devices converge on the new membership state

## Operator Checklist

- If `trixd` fails during startup with APNs validation, check that all four `TRIX_APNS_*` values are present together.
- If pushes never wake devices, inspect whether `push_delivery_enabled` is `false` in `PUT /v0/devices/push-token` responses.
- If APNs returns `DeviceTokenNotForTopic`, verify `TRIX_APNS_TOPIC` matches the real app bundle identifier.
- If linked-device QR payloads are unusable on phones, verify `TRIX_PUBLIC_BASE_URL` is reachable from the phone, not `localhost`.
- If `complete_link_intent` returns `active link intent not found`, the intent likely expired, the token is wrong, or the account was disabled/deleted.
