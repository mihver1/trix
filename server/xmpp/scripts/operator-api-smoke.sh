#!/usr/bin/env bash
set -euo pipefail

API_URL="${TRIX_XMPP_API_URL:-http://127.0.0.1:5280/api}"
HOST="${TRIX_XMPP_OPERATOR_HOST:-trix.selfhost.ru}"
USER_NAME="${TRIX_XMPP_OPERATOR_USER:-operator_$$_$(date +%s)}"
PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
RESET_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
REQUEST_FILE="$(mktemp "${TMPDIR:-/tmp}/trix-xmpp-api.XXXXXX")"
PASSWORD_FILE="$(mktemp "${TMPDIR:-/tmp}/trix-xmpp-api-password.XXXXXX")"
RESET_PASSWORD_FILE="$(mktemp "${TMPDIR:-/tmp}/trix-xmpp-api-reset.XXXXXX")"
RATE_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-xmpp-api-rate.XXXXXX")"
ANTI_LOOP_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-xmpp-api-anti-loop.XXXXXX")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$PASSWORD" ] || [ -z "$RESET_PASSWORD" ]; then
  echo "failed to generate disposable operator passwords" >&2
  exit 2
fi

cleanup() {
  status=$?
  rm -f "$REQUEST_FILE" "$PASSWORD_FILE" "$RESET_PASSWORD_FILE"
  rm -rf "$RATE_STATE_DIR" "$ANTI_LOOP_STATE_DIR"
  exit "$status"
}

trap cleanup EXIT

command -v curl >/dev/null 2>&1 || {
  echo "curl is required for operator API smoke" >&2
  exit 2
}

export TRIX_XMPP_OPERATOR_RATE_STATE_DIR="${TRIX_XMPP_OPERATOR_RATE_STATE_DIR:-$RATE_STATE_DIR}"

TRIX_XMPP_OPERATOR_RATE_STATE_DIR="$ANTI_LOOP_STATE_DIR" \
TRIX_XMPP_OPERATOR_RATE_WINDOW_SECONDS=60 \
TRIX_XMPP_OPERATOR_RATE_LIMIT_HEALTH=1 \
TRIX_XMPP_API_URL="http://127.0.0.1:9/api" \
"$SCRIPT_DIR/operator-control.sh" health >/dev/null 2>/dev/null || true

set +e
ANTI_LOOP_OUTPUT="$(TRIX_XMPP_OPERATOR_RATE_STATE_DIR="$ANTI_LOOP_STATE_DIR" \
  TRIX_XMPP_OPERATOR_RATE_WINDOW_SECONDS=60 \
  TRIX_XMPP_OPERATOR_RATE_LIMIT_HEALTH=1 \
  TRIX_XMPP_API_URL="http://127.0.0.1:9/api" \
  "$SCRIPT_DIR/operator-control.sh" health 2>&1 >/dev/null)"
ANTI_LOOP_STATUS=$?
set -e

if [ "$ANTI_LOOP_STATUS" -eq 0 ]; then
  echo "expected operator anti-loop limiter to reject repeated health command" >&2
  exit 1
fi

case "$ANTI_LOOP_OUTPUT" in
  *"operator rate limit exceeded"*) ;;
  *)
    echo "expected operator anti-loop limiter output, got: ${ANTI_LOOP_OUTPUT}" >&2
    exit 1
    ;;
esac

umask 077
printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
printf '%s\n' "$RESET_PASSWORD" > "$RESET_PASSWORD_FILE"
cat > "$REQUEST_FILE" <<JSON
{"user":"$USER_NAME","host":"$HOST"}
JSON

status_response="$(curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -d '{}' \
  "$API_URL/status")"

case "$status_response" in
  *"ejabberd"*"running"*|*"ejabberd"*"started"*) ;;
  *)
    echo "operator API status response did not report a running ejabberd node" >&2
    exit 1
    ;;
esac

"$SCRIPT_DIR/operator-control.sh" provision-user "$USER_NAME" "$PASSWORD_FILE" >/dev/null
"$SCRIPT_DIR/operator-control.sh" reset-password "$USER_NAME" "$RESET_PASSWORD_FILE" >/dev/null
"$SCRIPT_DIR/operator-control.sh" search-directory "$USER_NAME" >/dev/null
"$SCRIPT_DIR/operator-control.sh" archive-upload-push-health >/dev/null
"$SCRIPT_DIR/operator-control.sh" disable-user "$USER_NAME" "operator API smoke" >/dev/null
"$SCRIPT_DIR/operator-control.sh" enable-user "$USER_NAME" >/dev/null

curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$REQUEST_FILE" \
  "$API_URL/unregister" >/dev/null

echo "operator API smoke passed over localhost for disposable account ${USER_NAME}@${HOST}"
