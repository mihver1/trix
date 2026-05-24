#!/usr/bin/env bash
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${APPLE_DIR}/.." && pwd)"
DERIVED_DATA="${APPLE_DIR}/build/DerivedDataLocalCallLab"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/Trix.app"
PROFILE_APPS_DIR="${APPLE_DIR}/build/LocalCallLabApps"
EVIDENCE_ROOT="${APPLE_DIR}/build/LocalCallLabEvidence"

usage() {
  cat <<'EOF'
Usage: apple/scripts/run-local-call-lab-macos.sh [build|launch|evidence|logs|kill]

build     Generate and build the macOS app.
launch    Build if needed, then launch two isolated local profiles: alice and bob.
evidence  Run the deterministic group-call media smoke and capture an audited log bundle.
logs      Stream sanitized call/media logs from local Trix processes.
kill      Stop local Trix processes launched from the local-call-lab DerivedData app.

The evidence command requires disposable XMPP smoke credentials in:
TRIX_XMPP_LIVE_SMOKE_USER_ID, TRIX_XMPP_LIVE_SMOKE_PASSWORD,
TRIX_XMPP_LIVE_SMOKE_PEER_ID, TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD,
TRIX_XMPP_LIVE_SMOKE_THIRD_ID, and TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD.
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

launch_profile() {
  local profile="$1"
  local profile_app="${PROFILE_APPS_DIR}/Trix-${profile}.app"
  prepare_profile_app "${profile}" "${profile_app}"
  open -n "${profile_app}"
  sleep 1
  local pid
  pid="$(pgrep -f "${profile_app}/Contents/MacOS/Trix" | tail -n 1 || true)"
  if [[ -n "${pid}" ]]; then
    echo "launched profile ${profile} pid=${pid}"
  else
    echo "launched profile ${profile}; process not visible yet"
  fi
}

launch_app() {
  if [[ ! -x "${APP_PATH}/Contents/MacOS/Trix" ]]; then
    build_app
  fi

  launch_profile alice
  launch_profile bob
  echo "call-control: ${TRIX_CALL_CONTROL_BASE_URL:-http://127.0.0.1:8092}"
  echo "profiles: alice, bob"
}

prepare_profile_app() {
  local profile="$1"
  local profile_app="$2"
  local bundle_id="com.softgrid.trixapp.local.${profile}"
  local entitlements="${PROFILE_APPS_DIR}/Trix-${profile}.entitlements.plist"
  local identity="${TRIX_LOCAL_CALL_LAB_CODESIGN_IDENTITY:--}"
  local force_relay="false"
  case "${TRIX_CALL_FORCE_RELAY_ONLY:-false}" in
    1|true|TRUE|yes|YES|on|ON)
      force_relay="true"
      ;;
  esac

  mkdir -p "${PROFILE_APPS_DIR}"
  rm -rf "${profile_app}"
  ditto "${APP_PATH}" "${profile_app}"

  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_id}" "${profile_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Trix ${profile}" "${profile_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Trix ${profile}" "${profile_app}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Trix ${profile}" "${profile_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TrixLocalProfile string ${profile}" "${profile_app}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :TrixLocalProfile ${profile}" "${profile_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TrixCallControlBaseURL string ${TRIX_CALL_CONTROL_BASE_URL:-http://127.0.0.1:8092}" "${profile_app}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :TrixCallControlBaseURL ${TRIX_CALL_CONTROL_BASE_URL:-http://127.0.0.1:8092}" "${profile_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TrixCallAudioProbe bool true" "${profile_app}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :TrixCallAudioProbe true" "${profile_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TrixCallForceRelayOnly bool ${force_relay}" "${profile_app}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :TrixCallForceRelayOnly ${force_relay}" "${profile_app}/Contents/Info.plist"

  codesign -d --entitlements :- "${APP_PATH}" >"${entitlements}" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "${entitlements}" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.aps-environment" "${entitlements}" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "${entitlements}" 2>/dev/null || true

  if [[ -s "${entitlements}" ]]; then
    codesign --force --deep --sign "${identity}" --entitlements "${entitlements}" "${profile_app}" >/dev/null
  else
    codesign --force --deep --sign "${identity}" "${profile_app}" >/dev/null
  fi
}

logs() {
  log stream --style compact --level info \
    --predicate 'subsystem == "com.softgrid.trixapp" AND (category == "call-media" OR category == "call-control" OR category == "xmpp")'
}

require_evidence_environment() {
  local missing=()
  local name
  for name in \
    TRIX_XMPP_LIVE_SMOKE_USER_ID \
    TRIX_XMPP_LIVE_SMOKE_PASSWORD \
    TRIX_XMPP_LIVE_SMOKE_PEER_ID \
    TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD \
    TRIX_XMPP_LIVE_SMOKE_THIRD_ID \
    TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("${name}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'missing required evidence environment: %s\n' "${missing[*]}" >&2
    return 2
  fi
}

write_evidence_metadata() {
  local bundle_dir="$1"
  cat >"${bundle_dir}/README.md" <<EOF
# Trix Local Call Lab Evidence

- mode: group-call-lab-media
- call-control: ${TRIX_CALL_CONTROL_BASE_URL:-http://127.0.0.1:8092}
- xmpp-server: ${TRIX_XMPP_LIVE_SMOKE_SERVER_URL:-${TRIX_XMPP_URL:-xmpp://trix.selfhost.ru}}
- relay-only: true
- audio-probe: true
- profile-prefix: ${TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX:-call-lab}

This bundle intentionally records only scrubbed smoke status lines and sanitized
service logs. It must not contain XMPP passwords, LiveKit tokens, TURN
credentials, OMEMO secrets, media keys, APNs tokens, or decrypted content.
EOF
}

run_evidence_smoke() {
  require_evidence_environment
  "${REPO_DIR}/server/xmpp/scripts/local-call-lab.sh" start

  if [[ ! -x "${APP_PATH}/Contents/MacOS/Trix" ]]; then
    build_app
  fi

  local bundle_dir="${TRIX_CALL_LAB_EVIDENCE_DIR:-${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "${bundle_dir}"
  write_evidence_metadata "${bundle_dir}"

  local oslog_pid=""
  log stream --style compact --level info \
    --predicate 'subsystem == "com.softgrid.trixapp" AND (category == "call-media" OR category == "call-control" OR category == "xmpp")' \
    >"${bundle_dir}/apple-oslog.log" 2>&1 &
  oslog_pid="$!"

  local smoke_status=0
  TRIX_CALL_FORCE_RELAY_ONLY=1 \
    TRIX_CALL_AUDIO_PROBE=1 \
    TRIX_CALL_CONTROL_BASE_URL="${TRIX_CALL_CONTROL_BASE_URL:-http://127.0.0.1:8092}" \
    TRIX_XMPP_LIVE_SMOKE_MODE=group-call-lab-media \
    TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1 \
    TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1 \
    TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX="${TRIX_XMPP_LIVE_SMOKE_CALL_LAB_PROFILE_PREFIX:-call-lab}" \
    "${APP_PATH}/Contents/MacOS/Trix" >"${bundle_dir}/apple-smoke.log" 2>&1 || smoke_status="$?"

  sleep 2
  if [[ -n "${oslog_pid}" ]]; then
    kill "${oslog_pid}" >/dev/null 2>&1 || true
    wait "${oslog_pid}" >/dev/null 2>&1 || true
  fi

  "${REPO_DIR}/server/xmpp/scripts/local-call-lab.sh" log-snapshot "${bundle_dir}"

  local audit_output
  audit_output="$(mktemp)"
  local audit_status=0
  "${REPO_DIR}/server/xmpp/scripts/call-log-audit.sh" "${bundle_dir}" >"${audit_output}" 2>&1 || audit_status="$?"
  mv "${audit_output}" "${bundle_dir}/call-log-audit.txt"
  cat "${bundle_dir}/call-log-audit.txt"

  echo "evidence bundle: ${bundle_dir}"
  if [[ "${smoke_status}" -ne 0 ]]; then
    echo "group-call-lab-media smoke failed with status ${smoke_status}" >&2
    return "${smoke_status}"
  fi
  if [[ "${audit_status}" -ne 0 ]]; then
    echo "call log audit failed with status ${audit_status}" >&2
    return "${audit_status}"
  fi
}

kill_app() {
  pkill -f "${PROFILE_APPS_DIR}.*/Contents/MacOS/Trix" || true
}

command="${1:-launch}"
case "${command}" in
  build)
    build_app
    ;;
  launch)
    launch_app
    ;;
  evidence)
    run_evidence_smoke
    ;;
  logs)
    logs
    ;;
  kill)
    kill_app
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
