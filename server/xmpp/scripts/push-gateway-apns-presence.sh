#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  push-gateway-apns-presence.sh <env-file>
  push-gateway-apns-presence.sh --pid <trixd-pid>

Reports APNs configuration presence without printing values or key paths.
Use this before mirroring legacy trixd APNs settings into trix-push-gateway.
EOF
}

die() {
  echo "$*" >&2
  exit 2
}

if [ "${1:-}" = "--help" ] || [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

source_kind="file"
source_path="$1"

if [ "${1:-}" = "--pid" ]; then
  [ "$#" -eq 2 ] || die "--pid requires a process id"
  case "$2" in
    ''|*[!0-9]*) die "process id must be numeric" ;;
  esac
  source_kind="proc"
  source_path="/proc/$2/environ"
fi

[ -r "$source_path" ] || die "source is not readable"

python3 - "$source_kind" "$source_path" <<'PY'
import pathlib
import sys

source_kind = sys.argv[1]
source_path = pathlib.Path(sys.argv[2])
raw = source_path.read_bytes()

if source_kind == "proc":
    records = raw.split(b"\0")
else:
    records = raw.splitlines()

values = {}
for record in records:
    if not record or record.lstrip().startswith(b"#") or b"=" not in record:
        continue
    key, value = record.split(b"=", 1)
    key_text = key.decode("utf-8", "ignore").strip()
    if key_text.startswith("export "):
        key_text = key_text[len("export "):].strip()
    if key_text in {
        "TRIX_APNS_KEY_DIR",
        "TRIX_APNS_TEAM_ID",
        "TRIX_APNS_KEY_ID",
        "TRIX_APNS_TOPIC",
        "TRIX_APNS_PRIVATE_KEY_PEM",
        "TRIX_APNS_PRIVATE_KEY_PATH",
    }:
        values[key_text] = value.strip().strip(b"'\"")

def present(key: str) -> bool:
    return bool(values.get(key))

def emit(key: str, state: str) -> None:
    print(f"{key}={state}")

emit("apns_team_id", "present" if present("TRIX_APNS_TEAM_ID") else "missing")
emit("apns_key_id", "present" if present("TRIX_APNS_KEY_ID") else "missing")
emit("apns_topic", "present" if present("TRIX_APNS_TOPIC") else "missing")

has_pem = present("TRIX_APNS_PRIVATE_KEY_PEM")
has_path = present("TRIX_APNS_PRIVATE_KEY_PATH")
if has_pem:
    emit("apns_private_key", "pem-present")
elif has_path:
    emit("apns_private_key", "path-present")
else:
    emit("apns_private_key", "missing")

if has_path:
    path = pathlib.Path(values["TRIX_APNS_PRIVATE_KEY_PATH"].decode("utf-8", "ignore"))
    if not path.is_file() and values.get("TRIX_APNS_KEY_DIR"):
        host_dir = pathlib.Path(values["TRIX_APNS_KEY_DIR"].decode("utf-8", "ignore"))
        path = host_dir / path.name
    if not path.is_file():
        emit("apns_private_key_path_file", "missing")
    else:
        try:
            with path.open("rb") as handle:
                handle.read(1)
        except OSError:
            emit("apns_private_key_path_file", "unreadable")
        else:
            emit("apns_private_key_path_file", "readable")
else:
    emit("apns_private_key_path_file", "not-set")

complete = (
    present("TRIX_APNS_TEAM_ID")
    and present("TRIX_APNS_KEY_ID")
    and present("TRIX_APNS_TOPIC")
    and (has_pem or has_path)
)
emit("apns_config", "complete" if complete else "incomplete")
PY
