#!/usr/bin/env bash
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${APPLE_DIR}/.." && pwd)"
DERIVED_DATA="${APPLE_DIR}/build/DerivedDataLiveCallEcho"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/Trix.app"
EVIDENCE_ROOT="${APPLE_DIR}/build/LiveCallEchoEvidence"

usage() {
  cat <<'EOF'
Usage: apple/scripts/run-live-call-echo-assistant-macos.sh [build|evidence]

build     Generate and build the macOS app.
evidence  Run call-echo-assistant and capture an audited evidence bundle.

The evidence command requires disposable live smoke credentials in:
TRIX_XMPP_LIVE_SMOKE_USER_ID, TRIX_XMPP_LIVE_SMOKE_PASSWORD,
TRIX_XMPP_LIVE_SMOKE_PEER_ID, TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD,
TRIX_XMPP_LIVE_SMOKE_ECHO_ID, and TRIX_XMPP_LIVE_SMOKE_ECHO_PASSWORD.

Optional:
TRIX_XMPP_LIVE_SMOKE_ECHO_DELAY_SECONDS, TRIX_XMPP_LIVE_SMOKE_CALL_LAB_HOLD_SECONDS,
TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX, TRIX_CALL_CONTROL_BASE_URL, TRIX_XMPP_URL,
TRIX_LIVE_CALL_ECHO_EVIDENCE_DIR, TRIX_LIVE_CALL_ECHO_SMOKE_ATTEMPTS, and
TRIX_CALL_LIVEKIT_DEBUG_LOGS=1 to include LiveKit SDK RTC debug lines in the
audited evidence bundle.
EOF
}

build_app() {
  (cd "${APPLE_DIR}" && xcodegen generate)
  xcodebuild \
    -project "${APPLE_DIR}/TrixMatrix.xcodeproj" \
    -scheme TrixMatrixMac \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    build
}

require_evidence_environment() {
  local missing=()
  local name
  for name in \
    TRIX_XMPP_LIVE_SMOKE_USER_ID \
    TRIX_XMPP_LIVE_SMOKE_PASSWORD \
    TRIX_XMPP_LIVE_SMOKE_PEER_ID \
    TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD \
    TRIX_XMPP_LIVE_SMOKE_ECHO_ID \
    TRIX_XMPP_LIVE_SMOKE_ECHO_PASSWORD; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("${name}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'missing required live call echo environment: %s\n' "${missing[*]}" >&2
    return 2
  fi
}

account_localpart() {
  local account="$1"
  account="${account%@*}"
  account="${account#@}"
  account="${account%%:*}"
  printf '%s' "${account}"
}

write_evidence_metadata() {
  local bundle_dir="$1"
  cat >"${bundle_dir}/README.md" <<EOF
# Trix Live Call Echo Assistant Evidence

- mode: call-echo-assistant
- call-control: ${TRIX_CALL_CONTROL_BASE_URL:-https://trix.selfhost.ru}
- xmpp-server: ${TRIX_XMPP_LIVE_SMOKE_SERVER_URL:-${TRIX_XMPP_URL:-xmpp://trix.selfhost.ru}}
- echo-account-localpart: $(account_localpart "${TRIX_XMPP_LIVE_SMOKE_ECHO_ID}")
- relay-only: true
- owner-audio-probe: false
- echo-audio-probe: true
- configured-delay-seconds: ${TRIX_XMPP_LIVE_SMOKE_ECHO_DELAY_SECONDS:-2}
- profile-prefix: ${TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX:-call-echo}
- delayed-audio-echo: false
- delayed-video-echo: false
- diagnostic-only: true
- livekit-sdk-debug-logs: $(truthy "${TRIX_CALL_LIVEKIT_DEBUG_LOGS:-0}" && printf 'true' || printf 'false')

This bundle intentionally records only scrubbed smoke status lines and sanitized
Apple logs. It must not contain XMPP passwords, LiveKit tokens, TURN
credentials, OMEMO secrets, media keys, APNs tokens, raw audio/video, or
decrypted content. Echo-assistant evidence does not close the signed-device
encrypted-calls launch gate.
EOF
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

oslog_level() {
  if truthy "${TRIX_CALL_LIVEKIT_DEBUG_LOGS:-0}"; then
    printf 'debug'
  else
    printf 'info'
  fi
}

oslog_predicate() {
  if truthy "${TRIX_CALL_LIVEKIT_DEBUG_LOGS:-0}"; then
    printf '(subsystem == "com.softgrid.trixapp" OR subsystem == "io.livekit.sdk") AND process == "Trix"'
  else
    printf 'subsystem == "com.softgrid.trixapp" AND (category == "call-media" OR category == "call-control" OR category == "xmpp")'
  fi
}

run_evidence_smoke() {
  require_evidence_environment

  if [[ ! -x "${APP_PATH}/Contents/MacOS/Trix" ]]; then
    build_app
  fi

  local bundle_dir="${TRIX_LIVE_CALL_ECHO_EVIDENCE_DIR:-${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "${bundle_dir}"
  write_evidence_metadata "${bundle_dir}"

  local oslog_pid=""
  log stream --style compact --level "$(oslog_level)" \
    --predicate "$(oslog_predicate)" \
    >"${bundle_dir}/apple-oslog.log" 2>&1 &
  oslog_pid="$!"

  local smoke_status=0
  local max_attempts="${TRIX_LIVE_CALL_ECHO_SMOKE_ATTEMPTS:-2}"
  if ! [[ "${max_attempts}" =~ ^[0-9]+$ ]] || [[ "${max_attempts}" -lt 1 ]]; then
    max_attempts=1
  fi

  : >"${bundle_dir}/apple-smoke.log"
  local attempt
  for ((attempt = 1; attempt <= max_attempts; attempt += 1)); do
    local attempt_log="${bundle_dir}/apple-smoke-attempt-${attempt}.log"
    smoke_status=0
    TRIX_CALL_FORCE_RELAY_ONLY=1 \
      TRIX_CALL_AUDIO_PROBE=1 \
      TRIX_XMPP_LIVE_SMOKE_MODE=call-echo-assistant \
      TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1 \
      TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1 \
      TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX="${TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX:-call-echo}" \
      "${APP_PATH}/Contents/MacOS/Trix" >"${attempt_log}" 2>&1 || smoke_status="$?"
    cat "${attempt_log}" >>"${bundle_dir}/apple-smoke.log"
    if [[ "${smoke_status}" -eq 0 ]]; then
      break
    fi
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      sleep 8
    fi
  done

  sleep 2
  if [[ -n "${oslog_pid}" ]]; then
    kill "${oslog_pid}" >/dev/null 2>&1 || true
    wait "${oslog_pid}" >/dev/null 2>&1 || true
  fi

  grep '^TRIX_XMPP_LIVE_SMOKE ' "${bundle_dir}/apple-smoke.log" || true

  local audit_output
  audit_output="$(mktemp)"
  local audit_status=0
  "${REPO_DIR}/server/xmpp/scripts/call-log-audit.sh" "${bundle_dir}" >"${audit_output}" 2>&1 || audit_status="$?"
  mv "${audit_output}" "${bundle_dir}/call-log-audit.txt"
  cat "${bundle_dir}/call-log-audit.txt"

  echo "evidence bundle: ${bundle_dir}"
  if [[ "${smoke_status}" -ne 0 ]]; then
    echo "call-echo-assistant smoke failed with status ${smoke_status}" >&2
    return "${smoke_status}"
  fi
  if [[ "${audit_status}" -ne 0 ]]; then
    echo "call log audit failed with status ${audit_status}" >&2
    return "${audit_status}"
  fi
}

command="${1:-evidence}"
case "${command}" in
  build)
    build_app
    ;;
  evidence)
    run_evidence_smoke
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
