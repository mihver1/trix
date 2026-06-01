#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-admin-api-smoke.XXXXXX")"
SERVER_PID=""
FAKE_EJABBERD_PID=""
OPERATOR="${TRIX_ADMIN_SMOKE_OPERATOR:-smoke@trix.selfhost.ru}"
FLAG_KEY="${TRIX_ADMIN_SMOKE_FLAG_KEY:-server.admin_api_smoke}"
USER_NAME="${TRIX_ADMIN_SMOKE_USER:-admin_smoke_user}"

cleanup() {
  status=$?
  set +e
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$FAKE_EJABBERD_PID" ]; then
    kill "$FAKE_EJABBERD_PID" >/dev/null 2>&1 || true
    wait "$FAKE_EJABBERD_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}

trap cleanup EXIT

command -v curl >/dev/null 2>&1 || {
  echo "curl is required for admin API smoke" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required for admin API smoke assertions" >&2
  exit 2
}

if [ "${TRIX_ADMIN_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
  command -v cargo >/dev/null 2>&1 || {
    echo "cargo is required to build trix-admin-api" >&2
    exit 2
  }
  (
    cd "$REPO_ROOT"
    cargo build -p trix-admin-api >/dev/null
  )
fi

BIN="${TRIX_ADMIN_SMOKE_BIN:-$REPO_ROOT/target/debug/trix-admin-api}"
if [ ! -x "$BIN" ]; then
  echo "trix-admin-api binary is missing or not executable: $BIN" >&2
  echo "run cargo build -p trix-admin-api, or set TRIX_ADMIN_SMOKE_BIN" >&2
  exit 2
fi

TOKEN="${TRIX_ADMIN_SMOKE_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
fi

USER_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"
RESET_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"

PORT="${TRIX_ADMIN_SMOKE_PORT:-}"
if [ -z "$PORT" ]; then
  PORT="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
fi

FAKE_EJABBERD_PORT="${TRIX_ADMIN_SMOKE_FAKE_EJABBERD_PORT:-}"
if [ -z "$FAKE_EJABBERD_PORT" ]; then
  FAKE_EJABBERD_PORT="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
fi

API_URL="http://127.0.0.1:$PORT"
FAKE_EJABBERD_API_URL="http://127.0.0.1:$FAKE_EJABBERD_PORT/api"
AUTH_CONFIG="$WORK_DIR/curl-auth.conf"
UPLOAD_DIR="$WORK_DIR/upload"
LOG_DIR="$WORK_DIR/logs"
FLAGS_PATH="$WORK_DIR/feature-flags.json"
AUDIT_PATH="$WORK_DIR/audit.jsonl"

mkdir -p "$UPLOAD_DIR/nested" "$LOG_DIR"
printf 'admin api media smoke\n' > "$UPLOAD_DIR/nested/sample.txt"
printf 'admin api status ok\nAuthorization: Bearer should-redact\n' > "$LOG_DIR/trix-admin-api.log"
umask 077
printf 'header = "Authorization: Bearer %s"\nheader = "X-Trix-Operator: %s"\n' \
  "$TOKEN" "$OPERATOR" > "$AUTH_CONFIG"

python3 - "$FAKE_EJABBERD_PORT" > "$WORK_DIR/fake-ejabberd.stdout" 2> "$WORK_DIR/fake-ejabberd.stderr" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host = "trix.selfhost.ru"
users = {}

def write_json(handler, status, payload):
    data = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)

def write_empty(handler, status=200):
    handler.send_response(status)
    handler.send_header("Content-Length", "0")
    handler.end_headers()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            write_json(self, 400, {"error": "invalid_json"})
            return

        command = self.path.rstrip("/").split("/")[-1]
        if command == "status":
            write_json(self, 200, {"status": "ejabberd running"})
        elif command == "registered_users":
            write_json(self, 200, sorted(users))
        elif command == "register":
            user = payload.get("user")
            if not user or payload.get("host") != host:
                write_json(self, 400, {"error": "invalid_register"})
                return
            users[user] = {"disabled": False}
            write_empty(self)
        elif command == "change_password":
            user = payload.get("user")
            if user not in users:
                write_json(self, 404, {"error": "unknown_user"})
                return
            write_empty(self)
        elif command == "ban_account":
            user = payload.get("user")
            if user not in users:
                write_json(self, 404, {"error": "unknown_user"})
                return
            users[user]["disabled"] = True
            write_empty(self)
        elif command == "unban_account":
            user = payload.get("user")
            if user not in users:
                write_json(self, 404, {"error": "unknown_user"})
                return
            users[user]["disabled"] = False
            write_empty(self)
        else:
            write_json(self, 404, {"error": "unknown_command"})

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
FAKE_EJABBERD_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
    "$FAKE_EJABBERD_API_URL/status" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$FAKE_EJABBERD_PID" >/dev/null 2>&1; then
    echo "fake ejabberd API exited before status was reachable" >&2
    tail -40 "$WORK_DIR/fake-ejabberd.stderr" >&2 || true
    exit 1
  fi
  sleep 0.25
done

(
  cd "$REPO_ROOT"
  TRIX_ADMIN_BIND_ADDR="127.0.0.1:$PORT" \
    TRIX_ADMIN_API_TOKEN="$TOKEN" \
    TRIX_XMPP_API_URL="$FAKE_EJABBERD_API_URL" \
    TRIX_FEATURE_FLAGS_PATH="$FLAGS_PATH" \
    TRIX_ADMIN_AUDIT_LOG_PATH="$AUDIT_PATH" \
    TRIX_ADMIN_UPLOAD_DIR="$UPLOAD_DIR" \
    TRIX_ADMIN_LOG_DIR="$LOG_DIR" \
    "$BIN" > "$WORK_DIR/admin-api.stdout" 2> "$WORK_DIR/admin-api.stderr"
) &
SERVER_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl -fsS "$API_URL/v1/system/health" > "$WORK_DIR/health.json" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "trix-admin-api exited before health was reachable" >&2
    tail -40 "$WORK_DIR/admin-api.stderr" >&2 || true
    exit 1
  fi
  sleep 0.25
done

curl -fsS "$API_URL/v1/system/health" > "$WORK_DIR/health.json"
unauth_code="$(curl -sS -o "$WORK_DIR/unauth.json" -w '%{http_code}' "$API_URL/v1/admin/session")"
if [ "$unauth_code" != "401" ]; then
  echo "expected unauthorized admin session request to return 401, got $unauth_code" >&2
  exit 1
fi

auth_curl() {
  curl -fsS --config "$AUTH_CONFIG" "$@"
}

auth_curl "$API_URL/v1/admin/session" > "$WORK_DIR/session.json"
curl -fsS "$API_URL/v1/feature-flags/snapshot" > "$WORK_DIR/client-flags.json"

python3 - "$WORK_DIR/user-create.json" "$USER_NAME" "$USER_PASSWORD" <<'PY'
import json
import sys

path, user, password = sys.argv[1:4]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"localpart": user, "password": password}, handle)
PY

python3 - "$WORK_DIR/user-reset.json" "$RESET_PASSWORD" <<'PY'
import json
import sys

path, password = sys.argv[1:3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"password": password}, handle)
PY

python3 - "$WORK_DIR/user-disable.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"reason": "admin API smoke"}, handle)
PY

auth_curl \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$WORK_DIR/user-create.json" \
  "$API_URL/v1/admin/users" > "$WORK_DIR/user-created.json"

auth_curl \
  "$API_URL/v1/admin/users?query=$USER_NAME&limit=5" > "$WORK_DIR/users.json"

auth_curl \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$WORK_DIR/user-reset.json" \
  "$API_URL/v1/admin/users/$USER_NAME/reset-password" > "$WORK_DIR/user-reset-response.json"

auth_curl \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$WORK_DIR/user-disable.json" \
  "$API_URL/v1/admin/users/$USER_NAME/disable" > "$WORK_DIR/user-disabled.json"

auth_curl \
  -X POST \
  "$API_URL/v1/admin/users/$USER_NAME/enable" > "$WORK_DIR/user-enabled.json"

python3 - "$WORK_DIR/flag-create.json" "$FLAG_KEY" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "key": key,
            "enabled": True,
            "rollout_percentage": 25,
            "client_visible": False,
            "description": "admin API smoke flag; contains no secrets",
        },
        handle,
    )
PY

python3 - "$WORK_DIR/flag-update.json" "$FLAG_KEY" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "key": key,
            "enabled": False,
            "rollout_percentage": 0,
            "client_visible": False,
            "description": "admin API smoke flag updated",
        },
        handle,
    )
PY

auth_curl \
  -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$WORK_DIR/flag-create.json" \
  "$API_URL/v1/admin/feature-flags" > "$WORK_DIR/flag-created.json"

auth_curl \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data-binary "@$WORK_DIR/flag-update.json" \
  "$API_URL/v1/admin/feature-flags/$FLAG_KEY" > "$WORK_DIR/flag-updated.json"

auth_curl -X DELETE "$API_URL/v1/admin/feature-flags/$FLAG_KEY" > "$WORK_DIR/flag-deleted.json"
auth_curl "$API_URL/v1/admin/audit/recent?limit=20" > "$WORK_DIR/audit.json"
auth_curl "$API_URL/v1/admin/media/storage" > "$WORK_DIR/media.json"
auth_curl "$API_URL/v1/admin/metrics/summary" > "$WORK_DIR/metrics.json"
auth_curl "$API_URL/v1/admin/ops/status" > "$WORK_DIR/ops-status.json"
auth_curl "$API_URL/v1/admin/logs/recent?service=trix-admin-api&limit=20" > "$WORK_DIR/logs.json"

python3 - "$WORK_DIR/push-wake.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "token_hex": "00",
            "environment": "sandbox",
            "account": "smoke@trix.selfhost.ru",
            "badge": 1,
        },
        handle,
    )
PY

push_code="$(
  curl -sS \
    --config "$AUTH_CONFIG" \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-binary "@$WORK_DIR/push-wake.json" \
    -o "$WORK_DIR/push-disabled.json" \
    -w '%{http_code}' \
    "$API_URL/v1/admin/push/test/wake"
)"
if [ "$push_code" != "412" ]; then
  echo "expected test push without gateway token to return 412, got $push_code" >&2
  exit 1
fi

python3 - "$WORK_DIR" "$FLAG_KEY" "$OPERATOR" "$USER_NAME" <<'PY'
import json
import pathlib
import sys

work_dir = pathlib.Path(sys.argv[1])
flag_key = sys.argv[2]
operator = sys.argv[3]
user_name = sys.argv[4]
user_jid = f"{user_name}@trix.selfhost.ru"

def load(name):
    with open(work_dir / name, encoding="utf-8") as handle:
        return json.load(handle)

health = load("health.json")
assert health["service"] == "trix-admin-api"
assert health["status"] == "ok"

session = load("session.json")
capabilities = set(session["capabilities"])
for capability in ["users", "test_pushes", "media_storage", "metrics", "logs", "audit", "feature_flags"]:
    assert capability in capabilities, capability

client_flags = load("client-flags.json")
client_keys = {flag["key"] for flag in client_flags["flags"]}
assert "client.calls.encrypted_media" in client_keys
assert "admin.users" not in client_keys

user_created = load("user-created.json")
assert user_created["jid"] == user_jid
assert user_created["changed"] is True

users = load("users.json")
assert any(user["jid"] == user_jid for user in users["users"])

for name in ["user-reset-response.json", "user-disabled.json", "user-enabled.json"]:
    response = load(name)
    assert response["jid"] == user_jid
    assert response["changed"] is True

created = load("flag-created.json")
created_flag = next(flag for flag in created["flags"] if flag["key"] == flag_key)
assert created_flag["enabled"] is True
assert created_flag["rollout_percentage"] == 25
assert created_flag["client_visible"] is False

updated = load("flag-updated.json")
updated_flag = next(flag for flag in updated["flags"] if flag["key"] == flag_key)
assert updated_flag["enabled"] is False
assert updated_flag["rollout_percentage"] == 0

deleted = load("flag-deleted.json")
assert flag_key not in {flag["key"] for flag in deleted["flags"]}

audit = load("audit.json")
assert audit["status"] == "ok"
events = audit["events"]
actions = {(event["action"], event["target"], event["actor"]) for event in events}
for action in ["user.provision", "user.reset_password", "user.disable", "user.enable"]:
    assert (action, user_jid, operator) in actions, action
for action in ["feature_flag.create", "feature_flag.update", "feature_flag.delete"]:
    assert (action, flag_key, operator) in actions, action

for event in events:
    for field in ["actor", "target", "outcome", "detail"]:
        value = str(event.get(field) or "").lower()
        for needle in ["token", "secret", "private_key", "authorization", "sasl", "omemo", "apns", "credential"]:
            assert needle not in value, (field, needle)
        if field != "detail":
            assert "password" not in value, field

media = load("media.json")
assert media["status"] == "ok"
assert media["file_count"] >= 1
assert media["total_bytes"] > 0

metrics = load("metrics.json")
assert metrics["media_file_count"] >= 1
assert metrics["total_feature_flags"] >= 2
assert isinstance(metrics["ejabberd_api_reachable"], bool)
assert isinstance(metrics["push_gateway_reachable"], bool)

ops = load("ops-status.json")
assert ops["media_storage"] == "ok"
assert ops["ejabberd_api"] in {"ok", "unavailable"}
assert ops["push_gateway"] in {"ok", "unavailable"}

logs = load("logs.json")
assert logs["service"] == "trix-admin-api"
assert logs["status"] == "ok"
joined_lines = "\n".join(logs["lines"])
assert "admin api status ok" in joined_lines
assert "[redacted sensitive log line]" in joined_lines
assert "should-redact" not in joined_lines
assert "Bearer should-redact" not in joined_lines

push = load("push-disabled.json")
assert push["code"] == "dependency_disabled"
PY

echo "admin API smoke passed over loopback"
echo "admin_api_health=ok"
echo "admin_api_auth=ok"
echo "users=ok"
echo "feature_flags=ok"
echo "audit=ok"
echo "media_storage=ok"
echo "metrics=ok"
echo "logs=ok"
echo "test_push_dependency_gate=ok"
