#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE_FILE="$(mktemp "${TMPDIR:-/tmp}/trix-invites.XXXXXX")"
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/trix-invite-server.XXXXXX")"
TOKEN="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
PORT="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
SERVER_PID=""

cleanup() {
  status=$?
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$STORE_FILE" "$LOG_FILE"
  exit "$status"
}

trap cleanup EXIT

if [ -z "$TOKEN" ] || [ -z "$PASSWORD" ]; then
  echo "failed to generate disposable invite smoke secrets" >&2
  exit 2
fi

TRIX_INVITE_BIND=127.0.0.1 \
TRIX_INVITE_PORT="$PORT" \
TRIX_INVITE_STORE_PATH="$STORE_FILE" \
TRIX_INVITE_OPERATOR_TOKEN="$TOKEN" \
TRIX_INVITE_DRY_RUN=1 \
python3 "$SCRIPT_DIR/invite-registration-server.py" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${PORT}/v1/system/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

curl -fsS "http://127.0.0.1:${PORT}/v1/system/health" >/dev/null

CREATE_BODY='{"localpart":"smokeuser","display_name":"Smoke User","ttl_seconds":300}'
CREATE_RESPONSE="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary "$CREATE_BODY" \
  "http://127.0.0.1:${PORT}/v1/operator/invites")"

INVITE_CODE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["invite_code"])' <<<"$CREATE_RESPONSE")"

REDEEM_RESPONSE="$(python3 - "$INVITE_CODE" "$PASSWORD" <<'PY' | curl -fsS \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/registration/redeem"
import json
import sys

print(json.dumps({
    "invite_code": sys.argv[1],
    "password": sys.argv[2],
    "display_name": "Smoke User",
}, separators=(",", ":")))
PY
)"

python3 -c 'import json,sys
response = json.load(sys.stdin)
if response.get("user_id") != "smokeuser@trix.selfhost.ru":
    raise SystemExit("unexpected redeemed user id")
' <<<"$REDEEM_RESPONSE"

SECOND_STATUS="$(python3 - "$INVITE_CODE" "$PASSWORD" <<'PY' | curl -sS \
  -o /dev/null \
  -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/registration/redeem"
import json
import sys

print(json.dumps({
    "invite_code": sys.argv[1],
    "password": sys.argv[2],
}, separators=(",", ":")))
PY
)"

if [ "$SECOND_STATUS" != "409" ]; then
  echo "expected second invite redemption to fail with HTTP 409, got ${SECOND_STATUS}" >&2
  exit 1
fi

AUTH_HEADER="$(python3 - "$PASSWORD" <<'PY'
import base64
import sys

raw = f"issuer@trix.selfhost.ru:{sys.argv[1]}".encode("utf-8")
print("Basic " + base64.b64encode(raw).decode("ascii"))
PY
)"
APP_CREATE_BODY='{"localpart":"appsmoke","display_name":"App Smoke","ttl_seconds":300}'
APP_CREATE_RESPONSE="$(curl -fsS \
  -H "Authorization: ${AUTH_HEADER}" \
  -H 'Content-Type: application/json' \
  --data-binary "$APP_CREATE_BODY" \
  "http://127.0.0.1:${PORT}/v1/invites")"

APP_INVITE_CODE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["invite_code"])' <<<"$APP_CREATE_RESPONSE")"

APP_REDEEM_RESPONSE="$(python3 - "$APP_INVITE_CODE" "$PASSWORD" <<'PY' | curl -fsS \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/registration/redeem"
import json
import sys

print(json.dumps({
    "invite_code": sys.argv[1],
    "password": sys.argv[2],
}, separators=(",", ":")))
PY
)"

python3 -c 'import json,sys
response = json.load(sys.stdin)
if response.get("user_id") != "appsmoke@trix.selfhost.ru":
    raise SystemExit("unexpected app-issued redeemed user id")
' <<<"$APP_REDEEM_RESPONSE"

NEW_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
if [ -z "$NEW_PASSWORD" ]; then
  echo "failed to generate disposable changed password" >&2
  exit 2
fi

CHANGE_RESPONSE="$(python3 - "$NEW_PASSWORD" <<'PY' | curl -fsS \
  -H "Authorization: ${AUTH_HEADER}" \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/account/password"
import json
import sys

print(json.dumps({
    "new_password": sys.argv[1],
}, separators=(",", ":")))
PY
)"

python3 -c 'import json,sys
response = json.load(sys.stdin)
if response.get("user_id") != "issuer@trix.selfhost.ru":
    raise SystemExit("unexpected password-change user id")
' <<<"$CHANGE_RESPONSE"

WEAK_CHANGE_STATUS="$(python3 <<'PY' | curl -sS \
  -o /dev/null \
  -w '%{http_code}' \
  -H "Authorization: ${AUTH_HEADER}" \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/account/password"
import json

print(json.dumps({
    "new_password": "short",
}, separators=(",", ":")))
PY
)"

if [ "$WEAK_CHANGE_STATUS" != "400" ]; then
  echo "expected weak password change to fail with HTTP 400, got ${WEAK_CHANGE_STATUS}" >&2
  exit 1
fi

echo "invite registration and password smoke passed in dry-run mode"
