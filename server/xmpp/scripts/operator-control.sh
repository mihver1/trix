#!/usr/bin/env bash
set -euo pipefail

API_URL="${TRIX_XMPP_API_URL:-http://127.0.0.1:5280/api}"
HOST="${TRIX_XMPP_OPERATOR_HOST:-trix.selfhost.ru}"
BACKUP_DIR="${TRIX_XMPP_BACKUP_DIR:-/var/backups/trix-xmpp}"
PUSH_HEALTH_URL="${TRIX_PUSH_HEALTH_URL:-http://127.0.0.1:8090/v0/system/health}"
UPLOAD_HEALTH_URL="${TRIX_XMPP_UPLOAD_HEALTH_URL:-http://127.0.0.1:5280/upload}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-xmpp-operator.XXXXXX")"

cleanup() {
  status=$?
  rm -rf "$TMP_DIR"
  exit "$status"
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  operator-control.sh health
  operator-control.sh archive-upload-push-health
  operator-control.sh provision-user <localpart> <password-file>
  operator-control.sh reset-password <localpart> <password-file>
  operator-control.sh disable-user <localpart> [reason]
  operator-control.sh search-directory <query>

Environment:
  TRIX_XMPP_API_URL                 default: http://127.0.0.1:5280/api
  TRIX_XMPP_OPERATOR_HOST           default: trix.selfhost.ru
  TRIX_XMPP_BACKUP_DIR              default: /var/backups/trix-xmpp
  TRIX_XMPP_UPLOAD_HEALTH_URL       default: http://127.0.0.1:5280/upload
  TRIX_PUSH_HEALTH_URL              default: http://127.0.0.1:8090/v0/system/health
  TRIX_XMPP_OPERATOR_ALLOW_NON_LOOPBACK=1 permits a non-loopback API URL.

Passwords are read from files and are never printed.
EOF
}

die() {
  echo "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

ensure_loopback_api() {
  case "$API_URL" in
    http://127.0.0.1:*|http://localhost:*|http://[::1]:*) ;;
    *)
      if [ "${TRIX_XMPP_OPERATOR_ALLOW_NON_LOOPBACK:-0}" != "1" ]; then
        die "refusing non-loopback TRIX_XMPP_API_URL; keep ejabberd mod_http_api private"
      fi
      ;;
  esac
}

json_file() {
  local output="$1"
  shift
  python3 - "$output" "$@" <<'PY'
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
mode = sys.argv[2]

if mode == "user-host-password":
    _, _, _, user, host, password_path = sys.argv
    password = pathlib.Path(password_path).read_text(encoding="utf-8").rstrip("\r\n")
    if not password:
        raise SystemExit("password file is empty")
    payload = {"user": user, "host": host, "password": password}
elif mode == "user-host-newpass":
    _, _, _, user, host, password_path = sys.argv
    password = pathlib.Path(password_path).read_text(encoding="utf-8").rstrip("\r\n")
    if not password:
        raise SystemExit("password file is empty")
    payload = {"user": user, "host": host, "newpass": password}
elif mode == "user-host-reason":
    _, _, _, user, host, reason = sys.argv
    payload = {"user": user, "host": host, "reason": reason}
elif mode == "user-host":
    _, _, _, user, host = sys.argv
    payload = {"user": user, "host": host}
elif mode == "host":
    _, _, _, host = sys.argv
    payload = {"host": host}
elif mode == "vcard":
    _, _, _, user, host, name = sys.argv
    payload = {"user": user, "host": host, "name": name}
elif mode == "empty":
    payload = {}
else:
    raise SystemExit(f"unknown json mode: {mode}")

output.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
PY
}

api_post_file() {
  local command_name="$1"
  local file="$2"
  curl -fsS \
    -H 'Content-Type: application/json' \
    --data-binary "@$file" \
    "$API_URL/$command_name"
}

api_post_json() {
  local command_name="$1"
  local mode="$2"
  shift 2
  local payload_file="$TMP_DIR/${command_name}.json"
  json_file "$payload_file" "$mode" "$@"
  api_post_file "$command_name" "$payload_file"
}

decode_json_string_or_raw() {
  python3 - <<'PY'
import json
import sys

data = sys.stdin.read()
try:
    value = json.loads(data)
except json.JSONDecodeError:
    print(data.strip())
else:
    if isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
PY
}

health() {
  api_post_json status empty >/dev/null
  echo "ejabberd_api=ok"
}

archive_upload_push_health() {
  health

  if [ -d "$BACKUP_DIR" ]; then
    latest_backup="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'trix-xmpp-*.tgz' -print 2>/dev/null | sort | tail -n 1)"
    if [ -n "$latest_backup" ]; then
      echo "archive_backup=present"
    else
      echo "archive_backup=missing"
    fi
  else
    echo "archive_backup=unavailable"
  fi

  upload_status="$(curl -sS -o /dev/null -w '%{http_code}' -I "$UPLOAD_HEALTH_URL" 2>/dev/null || true)"
  if [ "$upload_status" != "000" ] && [ -n "$upload_status" ]; then
    echo "http_upload=reachable"
  else
    echo "http_upload=unreachable"
  fi

  if curl -fsS "$PUSH_HEALTH_URL" >/dev/null 2>&1; then
    echo "push_gateway=reachable"
  else
    echo "push_gateway=unreachable"
  fi
}

provision_user() {
  local user="$1"
  local password_file="$2"
  [ -f "$password_file" ] || die "password file does not exist"
  api_post_json register user-host-password "$user" "$HOST" "$password_file" >/dev/null
  echo "provision_user=ok jid=${user}@${HOST}"
}

reset_password() {
  local user="$1"
  local password_file="$2"
  [ -f "$password_file" ] || die "password file does not exist"
  api_post_json change_password user-host-newpass "$user" "$HOST" "$password_file" >/dev/null
  echo "reset_password=ok jid=${user}@${HOST}"
}

disable_user() {
  local user="$1"
  local reason="${2:-disabled by Trix operator}"
  api_post_json ban_account user-host-reason "$user" "$HOST" "$reason" >/dev/null
  api_post_json get_ban_details user-host "$user" "$HOST" >/dev/null || true
  echo "disable_user=ok jid=${user}@${HOST}"
}

search_directory() {
  local query="$1"
  local users_payload="$TMP_DIR/registered-users.json"
  local users_file="$TMP_DIR/registered-users.txt"
  local records_file="$TMP_DIR/directory-records.jsonl"

  api_post_json registered_users host "$HOST" > "$users_payload"
  python3 - "$users_payload" "$users_file" <<'PY'
import json
import pathlib
import sys

users = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
pathlib.Path(sys.argv[2]).write_text("\n".join(users) + ("\n" if users else ""), encoding="utf-8")
PY

  : > "$records_file"
  while IFS= read -r user; do
    [ -n "$user" ] || continue
    fn_payload="$TMP_DIR/vcard-fn.json"
    nick_payload="$TMP_DIR/vcard-nick.json"
    json_file "$fn_payload" vcard "$user" "$HOST" FN
    json_file "$nick_payload" vcard "$user" "$HOST" NICKNAME
    fn="$(api_post_file get_vcard "$fn_payload" 2>/dev/null | decode_json_string_or_raw || true)"
    nick="$(api_post_file get_vcard "$nick_payload" 2>/dev/null | decode_json_string_or_raw || true)"
    python3 - "$records_file" "$user" "$HOST" "$fn" "$nick" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
record = {"user": sys.argv[2], "host": sys.argv[3], "name": sys.argv[4], "nickname": sys.argv[5]}
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
  done < "$users_file"

  python3 - "$records_file" "$query" <<'PY'
import json
import pathlib
import sys

records = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
query = sys.argv[2].casefold()
matches = []
for record in records:
    haystack = " ".join(
        value for value in [
            record["user"],
            f"{record['user']}@{record['host']}",
            record.get("name", ""),
            record.get("nickname", ""),
        ] if value
    ).casefold()
    if query in haystack:
        matches.append(record)

for record in matches:
    display = record.get("name") or record.get("nickname") or record["user"]
    print(f"{record['user']}@{record['host']}\t{display}")
PY
}

main() {
  require_command curl
  require_command python3
  ensure_loopback_api

  case "${1:-}" in
    health)
      health
      ;;
    archive-upload-push-health)
      archive_upload_push_health
      ;;
    provision-user)
      [ "$#" -eq 3 ] || { usage >&2; exit 2; }
      provision_user "$2" "$3"
      ;;
    reset-password)
      [ "$#" -eq 3 ] || { usage >&2; exit 2; }
      reset_password "$2" "$3"
      ;;
    disable-user)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
      disable_user "$2" "${3:-disabled by Trix operator}"
      ;;
    search-directory)
      [ "$#" -eq 2 ] || { usage >&2; exit 2; }
      search_directory "$2"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
