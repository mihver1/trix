# Trix Push Gateway

`trix-push-gateway` is a small APNs sender extracted from the legacy `trixd`
push path. It is intentionally not a chat server and does not handle OMEMO
payloads.

Current scope:

- load APNs token-auth credentials from deployment environment or a mounted
  `.p8` file;
- accept an internal bearer-authenticated wake request;
- optionally connect to ejabberd as an XEP-0114 component and answer Martin's
  `register-device` ad-hoc command;
- store Martin/XEP-0357 push nodes locally and map them to APNs device tokens;
- send only the Trix wake-only APNs payload:
  `aps.content-available=1` and `trix.type=sync`;
- return APNs success/rejection state without logging APNs tokens, APNs auth
  tokens, private keys, XMPP passwords, OMEMO secrets, or decrypted message
  bodies.

This binary is the APNs transport layer for the XMPP pivot. In component mode it
advertises a `pubsub/push` identity, accepts Martin/Tigase `apns-sandbox` and
`apns-production` device registration commands, returns a stable XEP-0357 node,
and sends wake-only APNs notifications when ejabberd publishes to that node.

## Local Run

Use deployment-local credentials only. Do not put real values in this repository.

```bash
TRIX_PUSH_GATEWAY_TOKEN='...' \
TRIX_APNS_TEAM_ID='...' \
TRIX_APNS_KEY_ID='...' \
TRIX_APNS_TOPIC='com.softgrid.trixapp' \
TRIX_APNS_PRIVATE_KEY_PATH='/absolute/path/to/AuthKey_ABC123XYZ.p8' \
cargo run -p trix-push-gateway
```

XMPP component mode connects to ejabberd's private `ejabberd_service` listener:

```bash
TRIX_PUSH_GATEWAY_TOKEN='...' \
TRIX_APNS_TEAM_ID='...' \
TRIX_APNS_KEY_ID='...' \
TRIX_APNS_TOPIC='com.softgrid.trixapp' \
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
network.

Health:

```bash
curl http://127.0.0.1:8090/v0/system/health
```

Wake request shape:

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
