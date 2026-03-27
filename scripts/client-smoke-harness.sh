#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
DEFAULT_DATABASE_URL="postgres://trix:trix@localhost:5432/trix"
DEFAULT_IOS_SERVER_SMOKE_BASE_URL="http://localhost:8080"
DEFAULT_IOS_UI_TEST_BASE_URL="http://localhost:8080"

declare -a SELECTED_SUITES=()
declare -a DEFAULT_SUITES=(
  "client-scenarios"
  "safe-ffi"
  "bot-runtime"
  "macos"
  "android-unit"
)

START_POSTGRES=1
KEEP_POSTGRES=1
COMPOSE_TOOL=""
PODMAN_BIN=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/client-smoke-harness.sh [options]

Default suites:
  client-scenarios  FFI client lifecycle, chat, messaging, read-state, realtime, outbox
  safe-ffi          High-level safe messenger flows, attachments, device linking, reopen
  bot-runtime       Headless bot runtime smoke flows, websocket/polling fallback, files
  macos             Swift host tests for the macOS client package
  android-unit      JVM unit tests for the Android client

Optional suites:
  ios-unit         xcodebuild test for apps/ios on an available iPhone simulator
  ios-server       xcodebuild server-backed smoke for apps/ios against a running backend
  ios-ui           xcodebuild XCUITest smoke for apps/ios against a running backend
  macos             swift test for apps/macos
  android-unit      ./gradlew testDebugUnitTest
  android-ui        ./gradlew connectedDebugAndroidTest

Options:
  --suite NAME      Add a suite to the run. Repeat to run multiple suites.
  --list-suites     Print available suites and exit.
  --no-postgres     Do not start postgres via compose; assume it is already running.
  --keep-postgres   Leave postgres running after the harness completes. This is the default.
  --stop-postgres   Stop postgres after the harness completes if the harness started it.
  --help            Show this help.

Environment:
  TRIX_TEST_DATABASE_URL  Override the database URL used by the Rust e2e suites.
  TRIX_IOS_SERVER_SMOKE_BASE_URL  Override the base URL used by the ios-server suite.
  TRIX_IOS_UI_TEST_BASE_URL  Override the base URL used by the ios-ui suite.
EOF
}

list_suites() {
  cat <<'EOF'
client-scenarios
safe-ffi
bot-runtime
ios-unit
ios-server
ios-ui
macos
android-unit
android-ui
EOF
}

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

has_suite() {
  local needle="$1"
  local suite
  if [[ "${SELECTED_SUITES[*]-}" == "" ]]; then
    return 1
  fi
  for suite in "${SELECTED_SUITES[@]}"; do
    if [[ "$suite" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

add_suite() {
  local suite="$1"
  case "$suite" in
    client-scenarios|safe-ffi|bot-runtime|ios-unit|ios-server|ios-ui|macos|android-unit|android-ui) ;;
    *) die "unknown suite '$suite'; use --list-suites to inspect supported values" ;;
  esac

  if ! has_suite "$suite"; then
    SELECTED_SUITES+=("$suite")
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --suite)
        shift
        (($# > 0)) || die "--suite expects a value"
        add_suite "$1"
        ;;
      --list-suites)
        list_suites
        exit 0
        ;;
      --no-postgres)
        START_POSTGRES=0
        ;;
      --keep-postgres)
        KEEP_POSTGRES=1
        ;;
      --stop-postgres)
        KEEP_POSTGRES=0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument '$1'; use --help for usage"
        ;;
    esac
    shift
  done

  if ((${#SELECTED_SUITES[@]} == 0)); then
    SELECTED_SUITES=("${DEFAULT_SUITES[@]}")
  fi
}

detect_compose_tool() {
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    PODMAN_BIN="$(command -v podman)"
    COMPOSE_TOOL="podman compose"
    return 0
  fi

  if [[ -x /opt/podman/bin/podman ]] && /opt/podman/bin/podman compose version >/dev/null 2>&1; then
    PODMAN_BIN="/opt/podman/bin/podman"
    COMPOSE_TOOL="podman compose"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_TOOL="docker compose"
    return 0
  fi

  if command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_TOOL="podman-compose"
    return 0
  fi

  return 1
}

compose_cmd() {
  if [[ "$COMPOSE_TOOL" == "podman-compose" ]]; then
    podman-compose -f "$COMPOSE_FILE" "$@"
    return
  fi

  if [[ "$COMPOSE_TOOL" == "podman compose" ]]; then
    "${PODMAN_BIN:-podman}" compose -f "$COMPOSE_FILE" "$@"
    return
  fi

  if [[ "$COMPOSE_TOOL" == "docker compose" ]]; then
    docker compose -f "$COMPOSE_FILE" "$@"
    return
  fi

  die "compose tool is not configured"
}

wait_for_postgres() {
  local deadline=$((SECONDS + 90))

  log "Waiting for postgres on 127.0.0.1:5432"
  while ((SECONDS < deadline)); do
    if command -v pg_isready >/dev/null 2>&1; then
      if pg_isready -h 127.0.0.1 -p 5432 -U trix -d trix >/dev/null 2>&1; then
        return 0
      fi
    elif (echo > /dev/tcp/127.0.0.1/5432) >/dev/null 2>&1; then
      sleep 2
      return 0
    fi
    sleep 1
  done

  die "postgres on 127.0.0.1:5432 did not become ready in time"
}

wait_for_http_health() {
  local base_url="$1"
  local deadline=$((SECONDS + 120))
  local health_url="${base_url%/}/v0/system/health"

  log "Waiting for server health on $health_url"
  while ((SECONDS < deadline)); do
    if curl -fsS "$health_url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "server health on $health_url did not become ready in time"
}

start_postgres() {
  detect_compose_tool || die "podman compose or docker compose is required to auto-start postgres"
  log "Starting postgres with $COMPOSE_TOOL"
  compose_cmd up -d postgres
  wait_for_postgres
}

start_local_server() {
  local base_url="${TRIX_IOS_SERVER_SMOKE_BASE_URL:-$DEFAULT_IOS_SERVER_SMOKE_BASE_URL}"
  detect_compose_tool || die "podman compose or docker compose is required to auto-start the local server"
  log "Starting postgres + app with $COMPOSE_TOOL"
  compose_cmd up -d postgres app
  wait_for_postgres
  wait_for_http_health "$base_url"
}

stop_postgres() {
  if [[ -n "$COMPOSE_TOOL" ]]; then
    log "Stopping postgres"
    compose_cmd stop postgres >/dev/null || true
  fi
}

stop_local_server() {
  if [[ -n "$COMPOSE_TOOL" ]]; then
    log "Stopping app + postgres"
    compose_cmd stop app postgres >/dev/null || true
  fi
}

run_root_command() {
  (
    cd "$ROOT_DIR"
    "$@"
  )
}

run_android_command() {
  (
    cd "$ROOT_DIR/apps/android"
    "$@"
  )
}

resolve_ios_destination() {
  command -v xcrun >/dev/null 2>&1 || die "xcrun is required for the ios-unit suite"

  local preferred_name
  for preferred_name in "iPhone 17" "iPhone 17 Pro" "iPhone 16e"; do
    if xcrun simctl list devices available | grep -Fq "    ${preferred_name} ("; then
      printf 'platform=iOS Simulator,name=%s' "$preferred_name"
      return 0
    fi
  done

  local detected_name
  detected_name="$(
    xcrun simctl list devices available \
      | awk -F ' \\(' '/iPhone/ { gsub(/^ +/, "", $1); print $1; exit }'
  )"
  [[ -n "$detected_name" ]] || die "no available iOS Simulator devices were found"
  printf 'platform=iOS Simulator,name=%s' "$detected_name"
}

run_suite() {
  local suite="$1"
  case "$suite" in
    client-scenarios)
      log "Running client-scenarios"
      run_root_command cargo test -p trix-core --test client_scenario_e2e -- --ignored --test-threads=1
      ;;
    safe-ffi)
      log "Running safe-ffi"
      run_root_command cargo test -p trix-core --test safe_ffi_e2e -- --ignored --test-threads=1
      ;;
    bot-runtime)
      log "Running bot-runtime"
      run_root_command cargo test -p trix-bot --test runtime_e2e -- --ignored --test-threads=1
      ;;
    ios-unit)
      local destination
      destination="$(resolve_ios_destination)"
      log "Running ios-unit on $destination"
      run_root_command xcodebuild \
        -project apps/ios/TrixiOS.xcodeproj \
        -scheme TrixiOS \
        -destination "$destination" \
        -derivedDataPath apps/ios/build/ios-tests-deriveddata \
        CODE_SIGNING_ALLOWED=NO \
        -only-testing:TrixiOSTests \
        -skip-testing:TrixiOSTests/ServerBackedSmokeTests \
        -skip-testing:TrixiOSTests/UITestConversationSeedStateTests \
        test
      ;;
    ios-server)
      local destination
      local base_url
      destination="$(resolve_ios_destination)"
      base_url="${TRIX_IOS_SERVER_SMOKE_BASE_URL:-$DEFAULT_IOS_SERVER_SMOKE_BASE_URL}"
      log "Running ios-server on $destination against $base_url"
      run_root_command env \
        TRIX_IOS_SERVER_SMOKE_BASE_URL="$base_url" \
        xcodebuild \
        -project apps/ios/TrixiOS.xcodeproj \
        -scheme TrixiOS \
        -destination "$destination" \
        -derivedDataPath apps/ios/build/ios-tests-deriveddata \
        CODE_SIGNING_ALLOWED=NO \
        -only-testing:TrixiOSTests/ServerBackedSmokeTests \
        -only-testing:TrixiOSTests/UITestConversationSeedStateTests \
        test
      ;;
    ios-ui)
      local destination
      local base_url
      destination="$(resolve_ios_destination)"
      base_url="${TRIX_IOS_UI_TEST_BASE_URL:-$DEFAULT_IOS_UI_TEST_BASE_URL}"
      log "Running ios-ui on $destination against $base_url"
      run_root_command env \
        TRIX_IOS_UI_TEST_BASE_URL="$base_url" \
        xcodebuild \
        -project apps/ios/TrixiOS.xcodeproj \
        -scheme TrixiOS \
        -destination "$destination" \
        -derivedDataPath apps/ios/build/ios-tests-deriveddata \
        CODE_SIGNING_ALLOWED=NO \
        -only-testing:TrixiOSUITests/TrixiOSSmokeUITests \
        test
      ;;
    macos)
      log "Running macos"
      run_root_command swift test --package-path "$ROOT_DIR/apps/macos"
      ;;
    android-unit)
      log "Running android-unit"
      run_android_command ./gradlew -PtrixSkipAndroidNdkBuild=true testDebugUnitTest
      ;;
    android-ui)
      log "Running android-ui"
      run_android_command ./gradlew connectedDebugAndroidTest
      ;;
    *)
      die "unsupported suite '$suite'"
      ;;
  esac
}

main() {
  parse_args "$@"

  export TRIX_TEST_DATABASE_URL="${TRIX_TEST_DATABASE_URL:-$DEFAULT_DATABASE_URL}"

  log "Selected suites: ${SELECTED_SUITES[*]}"
  log "TRIX_TEST_DATABASE_URL=$TRIX_TEST_DATABASE_URL"

  if ((START_POSTGRES)); then
    if has_suite "ios-server" || has_suite "ios-ui"; then
      start_local_server
    else
      start_postgres
    fi
  else
    log "Skipping backend startup"
  fi

  local suite
  for suite in "${SELECTED_SUITES[@]}"; do
    run_suite "$suite"
  done

  if ((START_POSTGRES)) && ((KEEP_POSTGRES == 0)); then
    if has_suite "ios-server" || has_suite "ios-ui"; then
      stop_local_server
    else
      stop_postgres
    fi
  fi

  log "Harness completed successfully"
}

main "$@"
