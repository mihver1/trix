# TRI-30 Signed-Device APNs And Persistent-Sync Smoke Lane

Date: 2026-05-20

This runbook gives the Founding Engineer one path for the two remaining live
smokes without putting APNs tokens, XMPP passwords, gateway bearer tokens,
private keys, or decrypted message content in issue comments or logs.

## Current Aliases

- `macos-signed-debug-2026-05-20`: signed macOS app built at
  `/tmp/trix-tri30-mac-signed/Build/Products/Debug/Trix.app`.
- `macos-signed-exec-2026-05-20`: executable path
  `/tmp/trix-tri30-mac-signed/Build/Products/Debug/Trix.app/Contents/MacOS/Trix`.
- `ios-device-1`: connected physical iPhone visible to Xcode. It is not usable
  for install/launch until Developer Mode is enabled on the device.
- `trix-live-smoke-env`: repo-external secret file path expected at
  `/Users/mihver/.trix/smoke/tri-30-live-smoke.env`.

## Secret Handoff Contract

The secret file is outside the repository and must be mode `0600`. It should
export only deployment-local smoke values:

```bash
export TRIX_XMPP_LIVE_SMOKE_USER_ID='...'
export TRIX_XMPP_LIVE_SMOKE_PASSWORD='...'
export TRIX_XMPP_LIVE_SMOKE_PEER_ID='...'
export TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD='...'
export TRIX_XMPP_LIVE_SMOKE_THIRD_ID='...'
export TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD='...'
export TRIX_XMPP_LIVE_SMOKE_SERVER_URL='https://trix.selfhost.ru'

export TRIX_PUSH_GATEWAY_BASE_URL='http://127.0.0.1:8090'
export TRIX_PUSH_GATEWAY_TOKEN='...'
export TRIX_PUSH_STORE_PATH='/var/lib/trix-push-gateway/registrations.json'
export TRIX_APNS_TEAM_ID='...'
export TRIX_APNS_KEY_ID='...'
export TRIX_APNS_TOPIC='com.softgrid.trixapp'
export TRIX_APNS_VOIP_TOPIC='com.softgrid.trixapp.voip'
export TRIX_APNS_PRIVATE_KEY_PATH='/opt/trix-xmpp/certs/apns/AuthKey_XXXX.p8'
```

Do not paste the values into Paperclip. If the path changes, hand off only the
new path.

## Signed macOS Persistent-Sync Gate

Build and verify the signed app:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/trix-tri30-mac-signed \
  build

codesign --verify --deep --strict \
  /tmp/trix-tri30-mac-signed/Build/Products/Debug/Trix.app
```

Run the persistent encrypted sync and process relaunch gate:

```bash
set +x
source /Users/mihver/.trix/smoke/tri-30-live-smoke.env

cd apple
./scripts/run-persistent-sync-gate.sh \
  --skip-build \
  --app-executable /tmp/trix-tri30-mac-signed/Build/Products/Debug/Trix.app/Contents/MacOS/Trix
```

Expected final line:

```text
TRIX_XMPP_PERSISTENT_GATE ok dm_persistence=true group_persistence=true process_relaunch=true ...
```

The wrapper must print only `TRIX_XMPP_PERSISTENT_GATE` and
`TRIX_XMPP_LIVE_SMOKE` status lines. It must not print passwords, APNs tokens,
OMEMO material, decrypted message text, filenames, or media keys.

## Signed-Device APNs Smoke

Prefer the real XMPP path:

1. Start or confirm ejabberd with federation still disabled.
2. Start or confirm `trix-push-gateway` on loopback/private network with the
   deployment-local APNs env from `trix-live-smoke-env`.
3. Launch the signed app and sign in with the disposable smoke account.
4. In the app diagnostics, confirm Push status is ready and note only:
   environment, provider, and gateway JID. Do not record the APNs token or full
   registration store contents.
5. Trigger a message or XEP-0357 publish that routes through ejabberd
   `mod_push` to `push.trix.selfhost.ru`.
6. Confirm the received notification is generic: title `Trix`, body
   `New encrypted message` or unread-count wording, `trix.type=sync`, and no
   plaintext body, decrypted content, filename, attachment name, media key, or
   attachment URL.

Diagnostic fallback, only from the host that has the private registration store:

```bash
set +x
source /Users/mihver/.trix/smoke/tri-30-live-smoke.env

node='trix-push/...'
token_hex="$(jq -r --arg node "$node" '.registrations[$node].token_hex' "$TRIX_PUSH_STORE_PATH")"
environment="$(jq -r --arg node "$node" '.registrations[$node].environment' "$TRIX_PUSH_STORE_PATH" | tr '[:upper:]' '[:lower:]')"

jq -n \
  --arg token_hex "$token_hex" \
  --arg environment "$environment" \
  --arg account "$TRIX_XMPP_LIVE_SMOKE_USER_ID" \
  '{token_hex: $token_hex, environment: $environment, account: $account, badge: 1}' |
curl -sS \
  -H "Authorization: Bearer $TRIX_PUSH_GATEWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d @- \
  "$TRIX_PUSH_GATEWAY_BASE_URL/v0/apns/wake"

unset token_hex
```

Do not paste the `node`, token, or curl response body into issue comments.
Report only sanitized field-presence evidence.

## Rollback And Cleanup

- If APNs delivery fails, stop at the first failing hop: app Push status,
  component registration, ejabberd `mod_push`, gateway health, then APNs
  response. Keep all tokens redacted.
- If the persistent-sync gate fails after `timeline-relaunch-seed`, rerun with
  `TRIX_XMPP_LIVE_SMOKE_RELAUNCH_CLEANUP=1` or remove the marker path printed
  by the smoke status line.
- If the gateway is restarted, rollback is the previous container/binary plus
  the unchanged `TRIX_PUSH_STORE_PATH`. Do not delete `registrations.json`;
  losing it forces client re-registration.

## Heartbeat Evidence

- Signed macOS build passed with `TrixMatrixMac` and DerivedData
  `/tmp/trix-tri30-mac-signed`.
- `codesign --verify --deep --strict` passed for
  `/tmp/trix-tri30-mac-signed/Build/Products/Debug/Trix.app`.
- Persistent gate wrapper self-skipped safely when live credentials were absent.
- Physical iOS destination is still blocked by Developer Mode disabled for
  `ios-device-1`.
- `trix-live-smoke-env` was not present in this heartbeat, so credentialed APNs
  delivery and persistent-sync proof were not run.

## Resume Evidence

On the resumed 2026-05-20 heartbeat:

- `trix-live-smoke-env` existed with mode `0600`.
- Required live smoke exports were present.
- APNs private key parsing passed with `openssl pkey -noout`.
- The signed macOS app still passed `codesign --verify --deep --strict`.
- `apple/scripts/run-persistent-sync-gate.sh` passed:
  - DM persistence overlap was nonzero after restart.
  - Group encrypted MUC persistence overlap was nonzero after restart.
  - Process relaunch used distinct seed and verify PIDs.
- `trix-push-gateway` started on `127.0.0.1:8090` and health returned `ok`.
- APNs delivery was not attempted because `TRIX_PUSH_STORE_PATH` pointed to a
  missing local `registrations.json`, and no APNs device-token env alias was
  present in the handoff file.

Remaining APNs unblock action: populate a signed macOS APNs registration in the
gateway store, or provide a repo-external token handoff path, then rerun the
generic sync wake without printing token values.

## APNs Provider Evidence

After the token handoff was populated on 2026-05-20:

- Repo-external token handoff file existed with mode `0600`.
- Repo-external token file existed with mode `0600`.
- `trix-push-gateway` started on `127.0.0.1:8090`.
- Generic sync APNs wake used the signed macOS token handoff and sandbox
  environment.
- Gateway/APNs response was `delivered=true`, `disable_registration=false`,
  `reason=none`, `http_status=200`.

This proves APNs provider acceptance for the signed macOS token path. A human or
QA-visible notification check should still confirm the macOS notification UI
shows only the generic Trix alert and no plaintext message, filename,
attachment, media-key, or decrypted-content fields.

## QA Visible Evidence

QA completed the visible macOS Notification Center check on 2026-05-20:

- Visible title: `Trix`.
- Visible body: `New encrypted message`.
- Visible extra text: timestamp only.
- No plaintext message body, filename, attachment name, media key, attachment
  URL, OMEMO material, APNs token, gateway bearer token, private key contents,
  or XMPP credential was visible in the notification card.
