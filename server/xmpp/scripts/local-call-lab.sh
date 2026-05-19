#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
LAB_DIR="${ROOT_DIR}/.local-call-lab"
ENV_FILE="${LAB_DIR}/local-call-lab.env"
OVERRIDE_FILE="${LAB_DIR}/docker-compose.local-call-lab.yml"
LIVEKIT_FILE="${LAB_DIR}/livekit.yaml"
TURN_FILE="${LAB_DIR}/turnserver.conf"
HOST_CALL_CONTROL_PID_FILE="${LAB_DIR}/call-control.pid"
HOST_CALL_CONTROL_LOG="${LAB_DIR}/call-control.log"

usage() {
  cat <<'EOF'
Usage: server/xmpp/scripts/local-call-lab.sh [start|status|smoke|logs|down]

Starts a loopback-only LiveKit + coturn + trix-call-control stack for local
Apple call testing. Generated secrets stay under server/xmpp/.local-call-lab
and are not printed.

By default call-control runs on the host from target/debug to avoid local
container clock drift breaking Debian apt during image builds. Set
TRIX_LOCAL_CALL_CONTROL_MODE=container to use the compose call-control service.
EOF
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    uuidgen | tr -d '-'
  fi
}

compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    podman compose "$@"
  else
    echo "docker compose or podman compose is required" >&2
    return 1
  fi
}

ensure_files() {
  mkdir -p "${LAB_DIR}"
  chmod 700 "${LAB_DIR}"

  if [[ ! -f "${ENV_FILE}" ]]; then
    local livekit_key="local_livekit_$(random_secret)"
    local livekit_secret
    local turn_secret
    livekit_secret="$(random_secret)"
    turn_secret="$(random_secret)"
    umask 077
    cat >"${ENV_FILE}" <<EOF
TRIX_LIVEKIT_API_KEY=${livekit_key}
TRIX_LIVEKIT_API_SECRET=${livekit_secret}
TRIX_TURN_SHARED_SECRET=${turn_secret}
TRIX_LIVEKIT_URL=ws://127.0.0.1:7880
TRIX_TURN_URIS=turn:127.0.0.1:3478?transport=udp,turn:127.0.0.1:3478?transport=tcp
TRIX_CALL_DRY_RUN_AUTH=1
TRIX_CALL_SKIP_MUC_MEMBERSHIP_CHECK=1
TRIX_CALL_BIND=127.0.0.1
TRIX_LIVEKIT_HTTP_BIND=127.0.0.1
TRIX_LIVEKIT_RTC_TCP_BIND=127.0.0.1
TRIX_LIVEKIT_RTC_UDP_BIND=127.0.0.1
TRIX_TURN_BIND=127.0.0.1
TRIX_TURNS_BIND=127.0.0.1
TRIX_TURN_RELAY_BIND=127.0.0.1
EOF
  fi

  # shellcheck disable=SC1090
  set -a
  . "${ENV_FILE}"
  set +a

  umask 077
  cat >"${LIVEKIT_FILE}" <<EOF
port: 7880
bind_addresses:
  - 0.0.0.0

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50100
  use_external_ip: false

turn:
  enabled: false

keys:
  ${TRIX_LIVEKIT_API_KEY}: ${TRIX_LIVEKIT_API_SECRET}
EOF

  cat >"${TURN_FILE}" <<EOF
realm=trix.selfhost.ru
server-name=trix.selfhost.ru
listening-port=3478
min-port=49160
max-port=49200
fingerprint
use-auth-secret
static-auth-secret=${TRIX_TURN_SHARED_SECRET}
no-tls
no-dtls
no-multicast-peers
pidfile=/var/tmp/turnserver.pid
log-file=stdout
EOF

  cat >"${OVERRIDE_FILE}" <<'EOF'
services:
  livekit:
    ports: !override
      - "${TRIX_LIVEKIT_HTTP_BIND:-127.0.0.1}:${TRIX_LIVEKIT_HTTP_PORT:-7880}:7880"
      - "${TRIX_LIVEKIT_RTC_TCP_BIND:-127.0.0.1}:${TRIX_LIVEKIT_RTC_TCP_PORT:-7881}:7881"
    volumes:
      - ./.local-call-lab/livekit.yaml:/etc/livekit.yaml:ro
  coturn:
    ports: !override
      - "${TRIX_TURN_BIND:-127.0.0.1}:${TRIX_TURN_PORT:-3478}:3478/tcp"
      - "${TRIX_TURN_BIND:-127.0.0.1}:${TRIX_TURN_PORT:-3478}:3478/udp"
    volumes:
      - ./.local-call-lab/turnserver.conf:/etc/coturn/turnserver.conf:ro
EOF
}

compose_lab() {
  compose \
    -f docker-compose.yml \
    -f "${OVERRIDE_FILE}" \
    --env-file "${ENV_FILE}" \
    --profile media \
    "$@"
}

wait_for_call_control() {
  local url="http://127.0.0.1:8092/v1/system/health"
  for _ in $(seq 1 60); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "call-control health: ok (${url})"
      return 0
    fi
    sleep 1
  done
  echo "call-control health did not become ready on ${url}" >&2
  return 1
}

host_call_control_running() {
  [[ -f "${HOST_CALL_CONTROL_PID_FILE}" ]] \
    && kill -0 "$(cat "${HOST_CALL_CONTROL_PID_FILE}")" >/dev/null 2>&1
}

start_host_call_control() {
  if host_call_control_running; then
    echo "host call-control: already running pid=$(cat "${HOST_CALL_CONTROL_PID_FILE}")"
    return 0
  fi

  : >"${HOST_CALL_CONTROL_LOG}"
  (cd "${REPO_DIR}" && cargo build -p trix-call-control >/dev/null)

  TRIX_CALL_BIND_ADDR=127.0.0.1:8092 \
    TRIX_CALL_LOG="${TRIX_CALL_LOG:-info,trix_call_control=debug}" \
    TRIX_CALL_DRY_RUN_AUTH=1 \
    TRIX_CALL_SKIP_MUC_MEMBERSHIP_CHECK=1 \
    TRIX_XMPP_HOST="${TRIX_XMPP_HOST:-trix.selfhost.ru}" \
    TRIX_XMPP_CONFERENCE_HOST="${TRIX_XMPP_CONFERENCE_HOST:-conference.trix.selfhost.ru}" \
    TRIX_LIVEKIT_URL="${TRIX_LIVEKIT_URL}" \
    TRIX_LIVEKIT_API_KEY="${TRIX_LIVEKIT_API_KEY}" \
    TRIX_LIVEKIT_API_SECRET="${TRIX_LIVEKIT_API_SECRET}" \
    TRIX_TURN_SHARED_SECRET="${TRIX_TURN_SHARED_SECRET}" \
    TRIX_TURN_URIS="${TRIX_TURN_URIS}" \
    TRIX_CALL_PUSH_GATEWAY_TOKEN= \
    python3 - "${REPO_DIR}" "${HOST_CALL_CONTROL_LOG}" "${HOST_CALL_CONTROL_PID_FILE}" <<'PY'
import os
import subprocess
import sys

repo_dir, log_path, pid_path = sys.argv[1:4]
with open(log_path, "ab", buffering=0) as log:
    process = subprocess.Popen(
        [os.path.join(repo_dir, "target/debug/trix-call-control")],
        cwd=repo_dir,
        env=os.environ.copy(),
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
with open(pid_path, "w", encoding="utf-8") as handle:
    handle.write(str(process.pid))
PY
  echo "host call-control: started pid=$(cat "${HOST_CALL_CONTROL_PID_FILE}")"
}

stop_host_call_control() {
  if host_call_control_running; then
    kill "$(cat "${HOST_CALL_CONTROL_PID_FILE}")" >/dev/null 2>&1 || true
  fi
  rm -f "${HOST_CALL_CONTROL_PID_FILE}"
}

start_stack() {
  ensure_files
  if [[ "${TRIX_LOCAL_CALL_CONTROL_MODE:-host}" == "container" ]]; then
    (cd "${ROOT_DIR}" && compose_lab up -d livekit coturn call-control)
  else
    (cd "${ROOT_DIR}" && compose_lab up -d livekit coturn)
    start_host_call_control
  fi
  wait_for_call_control
}

status_stack() {
  ensure_files
  (cd "${ROOT_DIR}" && compose_lab ps)
  if host_call_control_running; then
    echo "host call-control: running pid=$(cat "${HOST_CALL_CONTROL_PID_FILE}")"
  else
    echo "host call-control: not running"
  fi
}

down_stack() {
  ensure_files
  stop_host_call_control
  (cd "${ROOT_DIR}" && compose_lab down)
}

logs_stack() {
  ensure_files
  if [[ -f "${HOST_CALL_CONTROL_LOG}" ]]; then
    echo "== host call-control log =="
    tail -n 120 "${HOST_CALL_CONTROL_LOG}" || true
  fi
  (cd "${ROOT_DIR}" && compose_lab logs --tail=120 -f livekit coturn)
}

shape_summary() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

turn = payload.get("turn") or {}
print(
    "shape:",
    "call_id=", bool(payload.get("call_id")),
    "kind=", payload.get("kind"),
    "livekit_url=", payload.get("livekit_url"),
    "livekit_room=", bool(payload.get("livekit_room")),
    "livekit_token=", bool(payload.get("livekit_token")),
    "e2ee_required=", payload.get("e2ee_required"),
    "publish_audio=", payload.get("publish_audio"),
    "publish_video=", payload.get("publish_video"),
    "subscribe_audio=", payload.get("subscribe_audio"),
    "subscribe_video=", payload.get("subscribe_video"),
    "turn_uris=", len(turn.get("uris") or []),
    "turn_username=", bool(turn.get("username")),
    "turn_credential=", bool(turn.get("credential")),
)
PY
}

smoke_stack() {
  ensure_files
  wait_for_call_control

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN

  local auth
  auth="$(printf '%s' 'local-a@trix.selfhost.ru:local-password' | base64)"
  local status
  status="$(curl -sS -o "${tmp}" -w '%{http_code}' \
    -H "Authorization: Basic ${auth}" \
    -H 'Content-Type: application/json' \
    -d '{"room_id":"local-room@conference.trix.selfhost.ru","device_id":"local-a"}' \
    http://127.0.0.1:8092/v1/calls/group-voice/join)"
  if [[ "${status}" != "200" ]]; then
    echo "group voice join smoke failed with HTTP ${status}" >&2
    return 1
  fi
  shape_summary "${tmp}"
}

command="${1:-start}"
case "${command}" in
  start)
    start_stack
    ;;
  status)
    status_stack
    ;;
  smoke)
    smoke_stack
    ;;
  logs)
    logs_stack
    ;;
  down)
    down_stack
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
