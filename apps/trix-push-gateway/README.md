# Trix Push Gateway

`trix-push-gateway` is a small APNs sender and XEP-0114 XMPP push component. It
is intentionally not a chat server and does not handle OMEMO payloads.

Current scope:

- load APNs token-auth credentials from deployment environment or a mounted
  `.p8` file;
- accept an internal bearer-authenticated notification request;
- optionally connect to ejabberd as an XEP-0114 component and answer Martin's
  `register-device` ad-hoc command;
- store Martin/XEP-0357 push nodes locally and map them to APNs device tokens;
- store separate VoIP PushKit tokens through the `apns-voip-sandbox` and
  `apns-voip-production` providers without enabling those tokens for XEP-0357
  sync notifications;
- send XEP-0357 component publishes as silent APNs background wakes:
  `aps.content-available=1` and `trix.type=sync`;
- keep the internal HTTP notification endpoint limited to the Trix generic APNs
  alert payload: `aps.alert.title=Trix`, `aps.alert.body=New encrypted message`
  or unread-count wording, `aps.content-available=1`, and `trix.type=sync`;
- send only the Trix VoIP call payload through the separate APNs VoIP topic:
  `trix.call_id=<opaque-call-id>` and optional `trix.account`; no room, caller,
  LiveKit token, TURN credential, media key, or decrypted text is included;
- return APNs success/rejection state without logging APNs tokens, APNs auth
  tokens, private keys, XMPP passwords, OMEMO secrets, or decrypted message
  bodies.

This binary is the APNs transport layer for the XMPP pivot. In component mode it
advertises a `pubsub/push` identity, accepts Martin/Tigase `apns-sandbox` and
`apns-production` device registration commands, returns a stable XEP-0357 node,
and sends silent APNs background wakes when ejabberd publishes to that node. The
same private component accepts `apns-voip-sandbox` and `apns-voip-production`
registration commands for PushKit tokens, but those nodes use the `trix-voip/`
namespace and are only used by the internal call-push endpoint.

## Local Run

Use deployment-local credentials only. Do not put real values in this repository.

```bash
TRIX_PUSH_GATEWAY_TOKEN='...' \
TRIX_APNS_TEAM_ID='...' \
TRIX_APNS_KEY_ID='...' \
TRIX_APNS_TOPIC='com.softgrid.trixapp' \
TRIX_APNS_VOIP_TOPIC='com.softgrid.trixapp.voip' \
TRIX_APNS_PRIVATE_KEY_PATH='/absolute/path/to/AuthKey_ABC123XYZ.p8' \
cargo run -p trix-push-gateway
```

XMPP component mode connects to ejabberd's private `ejabberd_service` listener:

```bash
TRIX_PUSH_GATEWAY_TOKEN='...' \
TRIX_APNS_TEAM_ID='...' \
TRIX_APNS_KEY_ID='...' \
TRIX_APNS_TOPIC='com.softgrid.trixapp' \
TRIX_APNS_VOIP_TOPIC='com.softgrid.trixapp.voip' \
TRIX_APNS_PRIVATE_KEY_PATH='/absolute/path/to/AuthKey_ABC123XYZ.p8' \
TRIX_PUSH_STORE_PATH='/var/lib/trix-push-gateway/registrations.json' \
TRIX_XMPP_COMPONENT_ENABLED=1 \
TRIX_XMPP_COMPONENT_HOST='127.0.0.1' \
TRIX_XMPP_COMPONENT_PORT=5347 \
TRIX_XMPP_COMPONENT_JID='push.trix.selfhost.ru' \
TRIX_XMPP_COMPONENT_SECRET='...' \
cargo run -p trix-push-gateway
```

The component secret must match ejabberd's `ejabberd_service` password for
`push.trix.selfhost.ru`. Keep that listener private to the host or Docker
network. The gateway refuses empty, placeholder, and checked-in
`dev-local-*-change-me` gateway/component secrets; production must provide
deployment-local values through the environment or host secret files.

Health:

```bash
curl http://127.0.0.1:8090/v0/system/health
```

Notification request shape:

```json
{
  "token_hex": "hex-encoded-apns-token",
  "environment": "sandbox",
  "account": "optional-account-id",
  "room": "optional-room-id",
  "badge": 1
}
```

Callers must send `Authorization: Bearer <TRIX_PUSH_GATEWAY_TOKEN>`.

VoIP call request shape:

```json
{
  "account": "callee@trix.selfhost.ru",
  "call_id": "opaque-call-id"
}
```

Callers must send `Authorization: Bearer <TRIX_PUSH_GATEWAY_TOKEN>` to
`POST /v0/apns/voip/call`. The endpoint sends to registered VoIP tokens for the
account through `TRIX_APNS_VOIP_TOPIC`; it never sends the regular APNs token or
topic for CallKit/PushKit delivery.

## Private Deployment Prerequisites

Before production startup, confirm all of the following:

- APNs token-auth material is deployment-local only:
  `TRIX_APNS_TEAM_ID`, `TRIX_APNS_KEY_ID`, `TRIX_APNS_TOPIC`,
  `TRIX_APNS_VOIP_TOPIC`, and `TRIX_APNS_PRIVATE_KEY_PATH` (or inline
  `TRIX_APNS_PRIVATE_KEY_PEM`).
- Gateway bearer token and XEP-0114 component secret are non-default deployment
  secrets: `TRIX_PUSH_GATEWAY_TOKEN` and `TRIX_XMPP_COMPONENT_SECRET`.
- Gateway registration store path is persistent and host-private:
  `TRIX_PUSH_STORE_PATH` (default `/var/lib/trix-push-gateway/registrations.json`).
- XMPP component sync pushes are rate-limited per registration node by
  `TRIX_PUSH_XMPP_SYNC_MIN_INTERVAL_SECONDS` (default `60`) because XEP-0357
  publishes are generic sync wakes; repeated wakes inside this interval carry no
  additional plaintext-free information and can otherwise churn Apple devices.
- ejabberd is configured with private `ejabberd_service` listener and
  `mod_push` route to component JID `push.trix.selfhost.ru`.
- Component network path is private (loopback or internal Docker network only):
  `TRIX_XMPP_COMPONENT_HOST`, `TRIX_XMPP_COMPONENT_PORT`, and
  `TRIX_XMPP_COMPONENT_JID`.

## Suggested Bring-Up Sequence

1. Start ejabberd first and verify it is healthy with federation still disabled.
2. Start `trix-push-gateway` with component mode enabled and confirm
   `/v0/system/health` on loopback.
3. Confirm component handshake success in logs (without printing secrets).
4. Register one APNs token via Martin/Tigase `register-device` and verify the
   store contains the derived node mapping.
5. Trigger a controlled push through ejabberd `mod_push` (preferred) or the
   loopback gateway endpoint and confirm generic/sanitized payload behavior.

## Open MVP Risks

- Signed-device APNs delivery proof passed on 2026-05-20 with a signed macOS
  token handoff, generic APNs provider acceptance, and QA-visible generic
  notification text. Keep this as a regression smoke before launch changes.
- APNs key rotation and component-secret rotation need a short maintenance
  procedure so ejabberd/gateway restarts happen in the right order.
- Registration-store durability depends on host volume backup/restore; losing
  `registrations.json` will require fresh client registration.
- There is no external/public listener by design; operator diagnostics must
  continue through private shell/control-plane paths only.

## Deployment Status

The 2026-05-10 XMPP deploy runs this gateway on the VPS. The container loads
deployment-local APNs token-auth settings from `/opt/trix-xmpp/.env`, mounts the
APNs `.p8` key read-only from `/opt/trix-xmpp/certs/apns`, keeps the HTTP health
endpoint on `127.0.0.1:8090`, and connects to ejabberd as
`push.trix.selfhost.ru`. Signed macOS APNs smoke passed on 2026-05-20 with a
visible generic push and no plaintext message, filename, or attachment metadata
fields. XEP-0357 component publishes now use silent background wakes; visible
generic alerts remain limited to the internal HTTP notification path and any
client-created local fallback after sync.
