#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-device-passport-smoke.XXXXXX")"
SERVER_PID=""

cleanup() {
  status=$?
  set +e
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}

trap cleanup EXIT

command -v curl >/dev/null 2>&1 || {
  echo "curl is required for Device Passport smoke" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required for Device Passport smoke assertions" >&2
  exit 2
}

if [ "${TRIX_DEVICE_PASSPORT_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
  command -v cargo >/dev/null 2>&1 || {
    echo "cargo is required to build trix-device-passport" >&2
    exit 2
  }
  (
    cd "$REPO_ROOT"
    cargo build -p trix-device-passport >/dev/null
  )
fi

BIN="${TRIX_DEVICE_PASSPORT_SMOKE_BIN:-$REPO_ROOT/target/debug/trix-device-passport}"
if [ ! -x "$BIN" ]; then
  echo "trix-device-passport binary is missing or not executable: $BIN" >&2
  exit 2
fi

PORT="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"
API_URL="http://127.0.0.1:$PORT"
DB_PATH="$WORK_DIR/device-passport.sqlite"
ALICE="alice@trix.selfhost.ru"
BOB="bob@trix.selfhost.ru"

auth_header() {
  python3 - "$1" "$PASSWORD" <<'PY'
import base64
import sys
print("Authorization: Basic " + base64.b64encode(f"{sys.argv[1]}:{sys.argv[2]}".encode()).decode())
PY
}

ALICE_AUTH="$(auth_header "$ALICE")"
BOB_AUTH="$(auth_header "$BOB")"
OPERATOR_AUTH="Authorization: Bearer $TOKEN"

json_post() {
  local auth_header="$1"
  local path="$2"
  local body="$3"
  curl -fsS \
    -H "$auth_header" \
    -H 'Content-Type: application/json' \
    --data-binary "$body" \
    "$API_URL$path"
}

json_get() {
  local auth_header="$1"
  local path="$2"
  shift 2
  curl -fsS \
    -H "$auth_header" \
    "$@" \
    "$API_URL$path"
}

(
  cd "$REPO_ROOT"
  TRIX_DEVICE_PASSPORT_BIND_ADDR="127.0.0.1:$PORT" \
    TRIX_DEVICE_PASSPORT_DB_PATH="$DB_PATH" \
    TRIX_DEVICE_PASSPORT_OPERATOR_TOKEN="$TOKEN" \
    TRIX_DEVICE_PASSPORT_DRY_RUN_AUTH=1 \
    TRIX_DEVICE_PASSPORT_LOG="${TRIX_DEVICE_PASSPORT_LOG:-warn}" \
    "$BIN" > "$WORK_DIR/device-passport.stdout" 2> "$WORK_DIR/device-passport.stderr"
) &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS "$API_URL/v1/system/health" > "$WORK_DIR/health.json" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "trix-device-passport exited before health was reachable" >&2
    tail -40 "$WORK_DIR/device-passport.stderr" >&2 || true
    exit 1
  fi
  sleep 0.1
done

python3 - "$WORK_DIR/health.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("service") != "trix-device-passport" or payload.get("status") != "ok":
    raise SystemExit(f"unexpected health response: {payload}")
PY

ROOT_DEVICE='{"user_id":"alice@trix.selfhost.ru","omemo_device_id":"1000","device_label":"Trusted Mac","platform":"macos","fingerprint_hash":"00112233445566778899aabbccddeeff","app_version":"0.2.11"}'
json_post "$ALICE_AUTH" "/v1/device-passport/current-device" "$ROOT_DEVICE" >/dev/null

RESET_BODY='{"root_device":{"omemo_device_id":"1000","device_label":"Trusted Mac","platform":"macos","fingerprint_hash":"00112233445566778899aabbccddeeff","app_version":"0.2.11"}}'
RESET_RESPONSE="$(json_post "$OPERATOR_AUTH" "/v1/operator/device-passport/$ALICE/reset" "$RESET_BODY")"
python3 -c '
import json
import sys
payload = json.load(sys.stdin)
if payload.get("generation") != 2:
    raise SystemExit(f"unexpected reset generation: {payload}")
if payload.get("claim", {}).get("severity") != "high":
    raise SystemExit(f"operator reset did not emit high severity claim: {payload}")
' <<<"$RESET_RESPONSE"

NEW_DEVICE='{"user_id":"alice@trix.selfhost.ru","omemo_device_id":"2002","device_label":"New iPhone","platform":"ios","fingerprint_hash":"ffeeddccbbaa99887766554433221100","app_version":"0.2.11"}'
json_post "$ALICE_AUTH" "/v1/device-passport/current-device" "$NEW_DEVICE" >/dev/null

APPROVAL_RESPONSE="$(json_post "$ALICE_AUTH" "/v1/device-passport/approval-requests" '{"device_id":"2002"}')"
APPROVAL_ID="$(python3 -c '
import json
import sys
payload = json.load(sys.stdin)
approval = payload.get("approval", {})
if approval.get("status") != "pending" or not approval.get("challenge"):
    raise SystemExit(f"unexpected approval response: {payload}")
print(approval["id"])
' <<<"$APPROVAL_RESPONSE"
)"

APPROVE_RESPONSE="$(json_post "$ALICE_AUTH" "/v1/device-passport/approval-requests/$APPROVAL_ID/approve" '{"approver_device_id":"1000"}')"
python3 -c '
import json
import sys
payload = json.load(sys.stdin)
if payload.get("device", {}).get("state") != "approved":
    raise SystemExit(f"device was not approved: {payload}")
claim = payload.get("claim", {})
if claim.get("proof_required") is not True or claim.get("approved_by_device_id") != "1000":
    raise SystemExit(f"claim did not require external proof: {payload}")
' <<<"$APPROVE_RESPONSE"

CLAIMS_RESPONSE="$(json_get "$BOB_AUTH" "/v1/device-passport/directory-claims?since=0&limit=20")"
NEXT_CURSOR="$(python3 -c '
import json
import sys
payload = json.load(sys.stdin)
claims = payload.get("claims", [])
if payload.get("recipient_user_id") != "bob@trix.selfhost.ru":
    raise SystemExit(f"unexpected recipient: {payload}")
if not any(claim.get("user_id") == "alice@trix.selfhost.ru" and claim.get("kind") == "approved" and claim.get("proof_required") is True for claim in claims):
    raise SystemExit(f"approved claim missing: {payload}")
print(payload.get("next_cursor", 0))
' <<<"$CLAIMS_RESPONSE"
)"

json_post "$BOB_AUTH" "/v1/device-passport/notices/$ALICE/dismiss" '{"severity":"normal"}' >/dev/null
FILTERED_RESPONSE="$(json_get "$BOB_AUTH" "/v1/device-passport/directory-claims?since=0&limit=20")"
EXPECTED_CURSOR="$NEXT_CURSOR" python3 -c '
import json
import os
import sys
expected_cursor = int(os.environ["EXPECTED_CURSOR"])
payload = json.load(sys.stdin)
claims = payload.get("claims", [])
if any(claim.get("user_id") == "alice@trix.selfhost.ru" and claim.get("severity") == "normal" for claim in claims):
    raise SystemExit(f"dismissed normal notice was returned again: {payload}")
if payload.get("next_cursor", 0) < expected_cursor:
    raise SystemExit(f"cursor regressed after dismissal: {payload}")
' <<<"$FILTERED_RESPONSE"

STATE_RESPONSE="$(json_get "$ALICE_AUTH" "/v1/device-passport/state" -H 'X-Trix-Device-ID: 2002')"
python3 -c '
import json
import sys
payload = json.load(sys.stdin)
if payload.get("server_state_is_trust_authority") is not False:
    raise SystemExit(f"server trust oracle flag must stay false: {payload}")
if payload.get("current_device", {}).get("state") != "approved":
    raise SystemExit(f"unexpected approved-device state: {payload}")
' <<<"$STATE_RESPONSE"

echo "device-passport smoke ok"
