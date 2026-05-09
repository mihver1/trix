#!/usr/bin/env bash
set -euo pipefail

API_URL="${TRIX_XMPP_API_URL:-http://127.0.0.1:5280/api}"
HOST="${TRIX_XMPP_OPERATOR_HOST:-trix.selfhost.ru}"
USER_NAME="${TRIX_XMPP_OPERATOR_USER:-operator_$$_$(date +%s)}"
PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
REQUEST_FILE="$(mktemp "${TMPDIR:-/tmp}/trix-xmpp-api.XXXXXX")"

if [ -z "$PASSWORD" ]; then
  echo "failed to generate disposable operator password" >&2
  exit 2
fi

cleanup() {
  status=$?
  rm -f "$REQUEST_FILE"
  exit "$status"
}

trap cleanup EXIT

command -v curl >/dev/null 2>&1 || {
  echo "curl is required for operator API smoke" >&2
  exit 2
}

umask 077
cat > "$REQUEST_FILE" <<JSON
{"user":"$USER_NAME","host":"$HOST","password":"$PASSWORD"}
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

curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$REQUEST_FILE" \
  "$API_URL/register" >/dev/null

curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"user\":\"$USER_NAME\",\"host\":\"$HOST\"}" \
  "$API_URL/unregister" >/dev/null

echo "operator API smoke passed over localhost for disposable account ${USER_NAME}@${HOST}"
