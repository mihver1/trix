#!/usr/bin/env bash
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${APPLE_DIR}/.." && pwd)"
DERIVED_DATA="${APPLE_DIR}/build/DerivedDataLocalCallLab"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/Trix.app"
PROFILE_APPS_DIR="${APPLE_DIR}/build/LocalCallLabApps"

usage() {
  cat <<'EOF'
Usage: apple/scripts/run-local-call-lab-macos.sh [build|launch|logs|kill]

build   Generate and build the macOS app.
launch  Build if needed, then launch two isolated local profiles: alice and bob.
logs    Stream sanitized call/media logs from local Trix processes.
kill    Stop local Trix processes launched from the local-call-lab DerivedData app.
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
