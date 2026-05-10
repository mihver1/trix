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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$PASSWORD" ] || [ -z "$RESET_PASSWORD" ]; then
  echo "failed to generate disposable operator passwords" >&2
  exit 2
fi

cleanup() {
  status=$?
  rm -f "$REQUEST_FILE" "$PASSWORD_FILE" "$RESET_PASSWORD_FILE"
  exit "$status"
}

trap cleanup EXIT

command -v curl >/dev/null 2>&1 || {
  echo "curl is required for operator API smoke" >&2
  exit 2
}

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
