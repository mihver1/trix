#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DERIVED_DATA_PATH="${TRIX_XMPP_PERSISTENT_GATE_DERIVED_DATA_PATH:-$APPLE_DIR/build/DerivedDataPersistentSyncGate}"
APP_EXECUTABLE="${TRIX_XMPP_PERSISTENT_GATE_APP_EXECUTABLE:-$DERIVED_DATA_PATH/Build/Products/Debug/Trix.app/Contents/MacOS/Trix}"
SKIP_XCODEGEN=0
SKIP_BUILD=0
REQUIRE_SIGNED=1
INCLUDE_KEYCHAIN_RELAUNCH=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-persistent-sync-gate.sh [options]

Runs one repeatable encrypted sync gate without Keychain-backed smoke storage by default:
1) DM timeline persistence (`timeline-restart`)
2) Group timeline persistence (`group-timeline-restart`)
3) Same-account new-device DM backfill repair (`dm-backfill-repair`)

Options:
  --app-executable <path>  Override app executable path.
  --derived-data <path>    Override DerivedData path for build output.
  --skip-build             Do not build the app before running smokes.
  --skip-xcodegen          Skip xcodegen generate before build.
  --include-keychain-relaunch
                          Also run the signed process quit/relaunch Keychain proof.
  --allow-unsigned         Allow unsigned app executable for the relaunch proof.
  --help                   Show this help.

Required environment variables:
  TRIX_XMPP_LIVE_SMOKE_USER_ID
  TRIX_XMPP_LIVE_SMOKE_PASSWORD
  TRIX_XMPP_LIVE_SMOKE_PEER_ID
  TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD
  TRIX_XMPP_LIVE_SMOKE_THIRD_ID
  TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD

Optional environment variables:
  TRIX_XMPP_LIVE_SMOKE_SERVER_URL
  TRIX_XMPP_LIVE_SMOKE_RELAUNCH_MARKER_PATH
  TRIX_XMPP_LIVE_SMOKE_RELAUNCH_SESSION_SERVICE
  TRIX_XMPP_LIVE_SMOKE_RELAUNCH_SESSION_ACCOUNT
  TRIX_XMPP_LIVE_SMOKE_RELAUNCH_CLEANUP (default 1)

Keychain-specific relaunch smokes are skipped unless --include-keychain-relaunch
is provided. That option sets TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN=1 for the
relaunch seed/verify processes only.
EOF
}

status() {
  printf 'TRIX_XMPP_PERSISTENT_GATE %s\n' "$*"
}

die() {
  status "failed reason=$*"
  exit 1
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --app-executable)
        shift
        (($# > 0)) || die "missing_value_app_executable"
        APP_EXECUTABLE="$1"
        ;;
      --derived-data)
        shift
        (($# > 0)) || die "missing_value_derived_data"
        DERIVED_DATA_PATH="$1"
        ;;
      --skip-build)
        SKIP_BUILD=1
        ;;
      --skip-xcodegen)
        SKIP_XCODEGEN=1
        ;;
      --include-keychain-relaunch)
        INCLUDE_KEYCHAIN_RELAUNCH=1
        ;;
      --allow-unsigned)
        REQUIRE_SIGNED=0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown_argument_${1}"
        ;;
    esac
    shift
  done
}

check_required_env() {
  local missing=()
  local key
  for key in \
    TRIX_XMPP_LIVE_SMOKE_USER_ID \
    TRIX_XMPP_LIVE_SMOKE_PASSWORD \
    TRIX_XMPP_LIVE_SMOKE_PEER_ID \
    TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD \
    TRIX_XMPP_LIVE_SMOKE_THIRD_ID \
    TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done

  if ((${#missing[@]} > 0)); then
    status "skip reason=missing_credentials missing=$(IFS=,; echo "${missing[*]}")"
    exit 0
  fi
}

build_app_if_needed() {
  if [[ $SKIP_BUILD -eq 1 ]]; then
    return
  fi

  if [[ $SKIP_XCODEGEN -eq 0 ]]; then
    status "xcodegen start"
    (cd "$APPLE_DIR" && xcodegen generate)
  fi

  status "build start derived_data=$DERIVED_DATA_PATH"
  xcodebuild \
    -project "$APPLE_DIR/TrixMatrix.xcodeproj" \
    -scheme TrixMatrixMac \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

require_app_executable() {
  [[ -x "$APP_EXECUTABLE" ]] || die "app_executable_missing path=$APP_EXECUTABLE"
}

require_signed_app_if_needed() {
  if [[ $INCLUDE_KEYCHAIN_RELAUNCH -eq 0 ]]; then
    return
  fi

  if [[ $REQUIRE_SIGNED -eq 0 ]]; then
    return
  fi

  if ! codesign --verify --deep --strict "$APP_EXECUTABLE" >/dev/null 2>&1; then
    status "skip reason=unsigned_app path=$APP_EXECUTABLE"
    exit 0
  fi
}

run_smoke_mode() {
  local mode="$1"
  local output_file="$2"
  local use_keychain="${3:-0}"
  status "mode_start mode=$mode"
  TRIX_XMPP_LIVE_SMOKE_MODE="$mode" \
  TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1 \
  TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1 \
  TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN="$use_keychain" \
  "$APP_EXECUTABLE" | tee "$output_file"
  status "mode_done mode=$mode"
}

extract_pid() {
  local output_file="$1"
  local value
  value="$(rg -o 'pid=[0-9]+' "$output_file" | tail -n 1 | cut -d= -f2 || true)"
  printf '%s' "$value"
}

parse_args "$@"
check_required_env
build_app_if_needed
require_app_executable
require_signed_app_if_needed

seed_output="$(mktemp "${TMPDIR:-/tmp}/trix-persistent-seed.XXXXXX.log")"
verify_output="$(mktemp "${TMPDIR:-/tmp}/trix-persistent-verify.XXXXXX.log")"
dm_output="$(mktemp "${TMPDIR:-/tmp}/trix-persistent-dm.XXXXXX.log")"
group_output="$(mktemp "${TMPDIR:-/tmp}/trix-persistent-group.XXXXXX.log")"
backfill_output="$(mktemp "${TMPDIR:-/tmp}/trix-persistent-backfill.XXXXXX.log")"
trap 'rm -f "$seed_output" "$verify_output" "$dm_output" "$group_output" "$backfill_output"' EXIT

run_smoke_mode timeline-restart "$dm_output"
run_smoke_mode group-timeline-restart "$group_output"
run_smoke_mode dm-backfill-repair "$backfill_output"

if [[ $INCLUDE_KEYCHAIN_RELAUNCH -eq 0 ]]; then
  status "skip keychain_relaunch=default_disabled"
  exit 0
fi

run_smoke_mode timeline-relaunch-seed "$seed_output" 1
run_smoke_mode timeline-relaunch-verify "$verify_output" 1

seed_pid="$(extract_pid "$seed_output")"
verify_pid="$(extract_pid "$verify_output")"

if [[ -z "$seed_pid" || -z "$verify_pid" ]]; then
  die "missing_pid_proof seed_pid=$seed_pid verify_pid=$verify_pid"
fi

if [[ "$seed_pid" == "$verify_pid" ]]; then
  die "pid_not_relaunched pid=$seed_pid"
fi

status "ok dm_persistence=true group_persistence=true dm_backfill_repair=true process_relaunch=true seed_pid=$seed_pid verify_pid=$verify_pid"
