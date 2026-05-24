# TRI-110 Call Ops Readiness

Date: 2026-05-21

This runbook is the SRE gate for VoIP APNs, call-control, LiveKit/coturn, and
sanitized call diagnostics. It is written for the private Trix deployment and
must not be used to expose admin surfaces or print secrets.

## Safety Boundary

Allowed evidence:

- HTTP status codes from auth-gated call-control routes.
- Health JSON from loopback-only private endpoints.
- APNs delivery counts and APNs provider reason strings.
- LiveKit room and participant counts after tokens are redacted.
- coturn relay proof as counts, selected relay transport, or redacted log lines.
- `call-log-audit.sh` class counts and pass/fail result.

Never record:

- APNs device tokens, APNs auth tokens, `.p8` material, gateway bearer tokens, or
  XEP component secrets.
- LiveKit JWTs, LiveKit API secrets, TURN REST usernames or credentials, TURN
  shared secret, media keys, XMPP passwords, OMEMO material, decrypted message
  text, screenshots containing identifiers, or raw device identifiers.

## Current External Exposure Evidence

Run from an external network, not from the VPS:

```bash
nc -vz -G 5 trix.selfhost.ru 5222
nc -vz -G 5 trix.selfhost.ru 5269
nc -vz -G 5 trix.selfhost.ru 8092
nc -vz -G 5 trix.selfhost.ru 8090
nc -vz -G 5 trix.selfhost.ru 5280
nc -vz -G 5 trix.selfhost.ru 7880
```

Result on 2026-05-21:

```text
5222: reachable
5269: timed out
8092: timed out
8090: timed out
5280: timed out
7880: timed out
```

Interpretation: client-to-server XMPP is reachable. XMPP federation, raw
call-control, raw push-gateway, raw ejabberd HTTP, and raw LiveKit HTTP are not
externally reachable.

Check the app-facing call-control proxy routes without credentials:

```bash
curl -sS --max-time 10 \
  -o /tmp/trix-tri110-dm-video.json \
  -w 'status=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"peer_user_id":"callee@trix.selfhost.ru","device_id":"tri110"}' \
  https://trix.selfhost.ru/v1/calls/dm-video

curl -sS --max-time 10 \
  -o /tmp/trix-tri110-dm-video-join.json \
  -w 'status=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"call_id":"tri110-opaque-call-id","device_id":"tri110"}' \
  https://trix.selfhost.ru/v1/calls/dm-video/join

curl -sS --max-time 10 \
  -o /tmp/trix-tri110-group-voice.json \
  -w 'status=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"room_id":"room@conference.trix.selfhost.ru","device_id":"tri110"}' \
  https://trix.selfhost.ru/v1/calls/group-voice/join

curl -sS --max-time 10 \
  -o /tmp/trix-tri110-turn.json \
  -w 'status=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{}' \
  https://trix.selfhost.ru/v1/turn/credentials

curl -sS --max-time 10 \
  -o /tmp/trix-tri110-health.json \
  -w 'status=%{http_code}\n' \
  https://trix.selfhost.ru/v1/system/health
```

Result on 2026-05-21:

```text
/v1/calls/dm-video: 401 unauthorized
/v1/calls/dm-video/join: 401 unauthorized
/v1/calls/group-voice/join: 401 unauthorized
/v1/turn/credentials: 401 unauthorized
/v1/system/health: 404 from nginx
```

Interpretation: the app routes are externally reachable only behind account
auth, while the health/admin surface is not published.

## Live Host Readiness Checks

Run on the VPS with deployment-local environment only. Keep shell tracing off.
Do not paste raw command output until it has been checked for secrets.

```bash
set +x
cd /opt/trix-xmpp

podman compose ps ejabberd push-gateway livekit coturn call-control

curl -fsS http://127.0.0.1:8090/v0/system/health |
  jq -c '{service,status,version}'

curl -fsS http://127.0.0.1:8092/v1/system/health |
  jq -c '{service,status,version}'

nc -vz -G 5 127.0.0.1 7880
nc -vz -G 5 127.0.0.1 3478
```

Expected result:

- Compose shows the private XMPP, push, media, TURN, and call-control services
  running.
- Gateway health reports `service=trix-push-gateway` and `status=ok`.
- Call-control health reports `service=trix-call-control` and `status=ok`.
- Loopback LiveKit HTTP and local TURN ports are reachable from the host.

## VoIP APNs Delivery Check

Prerequisites:

- A signed iOS build has registered a PushKit token for the callee account using
  `apns-voip-sandbox` or `apns-voip-production`.
- `TRIX_PUSH_GATEWAY_TOKEN` is present only in the shell environment or secret
  file.
- The account value is a disposable smoke account or a sanitized local alias.

Send one opaque call push through the loopback gateway:

```bash
set +x
cd /opt/trix-xmpp

export TRIX_VOIP_ACCOUNT='callee@trix.selfhost.ru'
export TRIX_CALL_ID="tri110-$(date +%s)"

curl -fsS \
  -H "Authorization: Bearer ${TRIX_PUSH_GATEWAY_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"account\":\"${TRIX_VOIP_ACCOUNT}\",\"call_id\":\"${TRIX_CALL_ID}\"}" \
  http://127.0.0.1:8090/v0/apns/voip/call |
  jq -c '{attempted,delivered,failed,disabled}'
```

Success evidence is only the aggregate JSON, for example:

```text
{"attempted":1,"delivered":1,"failed":0,"disabled":0}
```

If APNs rejects the request, collect the provider reason from the private
registration store without printing `token_hex`:

```bash
jq -c --arg account "${TRIX_VOIP_ACCOUNT}" '
  .registrations
  | to_entries[]
  | select(.value.owner_jid == $account)
  | select(.value.provider | startswith("apns-voip-"))
  | {
      node: .key,
      provider: .value.provider,
      environment: .value.environment,
      disabled: (.value.disabled_at_unix != null),
      last_success_at_unix: .value.last_success_at_unix,
      last_failure_at_unix: .value.last_failure_at_unix,
      failure_reason: .value.failure_reason
    }
' /var/lib/trix-push-gateway/registrations.json
```

This prints node ids and APNs reason strings only. It must not print APNs token
hex or auth material.

## Forced Relay Proof

For signed-device smoke, launch at least one caller with relay-only ICE:

```bash
TRIX_CALL_FORCE_RELAY_ONLY=1 open -a TrixMatrix
```

Acceptable relay proof:

- app diagnostics state that ICE policy is relay-only and the selected candidate
  pair is relay/TURN-backed, with TURN username and credential redacted;
- coturn logs show an allocation and relay traffic for the smoke window, with
  TURN usernames redacted;
- LiveKit diagnostics show participants joined and media moved during the
  relay-only window, with JWTs absent.

For local debugging only, use the loopback lab:

```bash
server/xmpp/scripts/local-call-lab.sh start
server/xmpp/scripts/local-call-lab.sh smoke
apple/scripts/run-local-call-lab-macos.sh evidence
```

The local lab is useful for MTTR but does not replace signed-device PushKit,
CallKit, APNs, and real media evidence.

## Log Capture And Audit

Create one temporary bundle outside the repo, then copy only sanitized audit
results into issue comments:

```bash
set +x
bundle="$(mktemp -d /tmp/trix-call-smoke-logs.XXXXXX)"

podman compose logs --no-color call-control >"${bundle}/call-control.log"
podman compose logs --no-color push-gateway >"${bundle}/push-gateway.log"
podman compose logs --no-color livekit coturn >"${bundle}/livekit-coturn.log"

# Add sanitized Apple app logs and reverse-proxy logs for the same smoke window.

./scripts/call-log-audit.sh "${bundle}"
```

The audit must report `call-log-audit ok`. If it reports findings, fix the
logging source before rerunning the smoke. The audit output prints forbidden
classes, file paths, and line counts only; it does not print matched values.

## Rollback

Small rollback steps, ordered from least disruptive to most disruptive:

1. Disable new call attempts at the proxy by removing or commenting the
   app-facing `/v1/calls/*` and `/v1/turn/credentials` routes, then reload nginx.
   Existing XMPP messaging remains up.
2. Stop call-control only:
   `podman compose --profile media stop call-control`.
3. Stop the media profile if LiveKit/coturn are unhealthy:
   `podman compose --profile media stop livekit coturn`.
4. If push delivery is causing noise, stop the gateway after confirming generic
   XMPP sync pushes may be temporarily unavailable:
   `podman compose --profile push-gateway stop push-gateway`.
5. Restore the previous `.env`, `livekit.yaml`, `turnserver.conf`, and nginx
   config from the deployment backup, then restart only the affected service.

Do not open port `5269`, raw `8092`, raw `8090`, raw `5280`, or LiveKit admin
surfaces as a rollback shortcut.

## Reporting Template

Use this shape for the SRE issue comment after the live smoke:

```md
## SRE Update

VoIP APNs and media ops readiness evidence updated.

- Changed: <runbook/doc/script/config change or none>
- Verified: external C2S reachable; federation/raw private ports closed; call
  routes auth-gated; call-control and push loopback health; VoIP APNs delivery
  counts; forced relay proof; call-log-audit result
- APNs: attempted=<n> delivered=<n> failed=<n> disabled=<n> reason=<safe APNs
  reason or none>
- Media: LiveKit participants=<n> relay_only=<pass/fail> coturn_proof=<summary>
- Rollback: <ready/not-ready and exact rollback route>
- Remaining: <only real blockers, with owner and next action>
```

## Current Remaining Risk

This heartbeat did not use deployment-local secrets, signed iOS hardware, or
live APNs PushKit tokens. The open operational proof is the live host readiness
check, VoIP APNs delivery count, forced relay proof, and post-smoke log audit.
