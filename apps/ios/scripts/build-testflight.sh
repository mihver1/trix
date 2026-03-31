#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"

PROJECT_PATH="${TRIX_IOS_PROJECT_PATH:-$IOS_DIR/TrixiOS.xcodeproj}"
SCHEME="${TRIX_IOS_SCHEME:-TrixiOS}"
CONFIGURATION="${TRIX_IOS_CONFIGURATION:-Release}"
ARCHIVE_DESTINATION="${TRIX_IOS_ARCHIVE_DESTINATION:-generic/platform=iOS}"

BUILD_ROOT="${TRIX_IOS_BUILD_ROOT:-$IOS_DIR/build/testflight}"
DERIVED_DATA_PATH="${TRIX_IOS_DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
ARCHIVE_PATH="${TRIX_IOS_ARCHIVE_PATH:-$BUILD_ROOT/TrixiOS.xcarchive}"
RESULT_BUNDLE_PATH="${TRIX_IOS_RESULT_BUNDLE_PATH:-$BUILD_ROOT/TrixiOS-archive.xcresult}"
EXPORT_PATH="${TRIX_IOS_EXPORT_PATH:-$BUILD_ROOT/export}"
EXPORT_OPTIONS_PLIST="${TRIX_IOS_EXPORT_OPTIONS_PLIST:-$SCRIPT_DIR/testflight-export-options.plist}"

ARCHIVE_LOG_PATH="${TRIX_IOS_ARCHIVE_LOG_PATH:-$BUILD_ROOT/archive.log}"
EXPORT_LOG_PATH="${TRIX_IOS_EXPORT_LOG_PATH:-$BUILD_ROOT/export.log}"
VALIDATE_LOG_PATH="${TRIX_IOS_VALIDATE_LOG_PATH:-$BUILD_ROOT/validate.log}"
UPLOAD_LOG_PATH="${TRIX_IOS_UPLOAD_LOG_PATH:-$BUILD_ROOT/upload.log}"

RUN_PRECHECKS=1
RUN_VALIDATE=0
RUN_UPLOAD=0
SKIP_BRIDGE=0
SKIP_XCODEGEN=0
IPA_PATH="${TRIX_IOS_IPA_PATH:-}"
ALLOW_PROVISIONING_UPDATES="${TRIX_IOS_ALLOW_PROVISIONING_UPDATES:-1}"
TESTFLIGHT_INTERNAL_ONLY="${TRIX_TESTFLIGHT_INTERNAL_ONLY:-0}"
ALTOOL_AUTH_MODE=""
XCODEBUILD_AUTH_MODE=""
USE_XCODEBUILD_UPLOAD=0
declare -a ALTOOL_AUTH_ARGS=()
declare -a XCODEBUILD_AUTH_ARGS=()
declare -a TEMP_FILES=()

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build-testflight.sh [options]

Builds a signed iOS archive, exports an .ipa, and can optionally validate or
upload it to App Store Connect/TestFlight.

Options:
  --validate           Validate the exported IPA with altool.
  --upload             Upload to App Store Connect/TestFlight.
                       Fresh archives use xcodebuild with the current Xcode
                       account by default, or App Store Connect key auth if set.
  --ipa PATH           Skip archive/export and validate/upload an existing IPA.
  --skip-prechecks     Skip ios-unit simulator prechecks.
  --skip-bridge        Skip ./scripts/generate-trix-core-bridge.sh.
  --skip-xcodegen      Skip xcodegen generate.
  --help               Show this help.

Archive/export environment:
  TRIX_IOS_MARKETING_VERSION       Override MARKETING_VERSION for the archive.
  TRIX_IOS_BUILD_NUMBER            Override CURRENT_PROJECT_VERSION for the archive.
                                   Use a monotonically increasing value for uploads.
  TRIX_IOS_DEVELOPMENT_TEAM        Override DEVELOPMENT_TEAM for the archive.
  TRIX_IOS_BUILD_ROOT              Override artifact root (default: apps/ios/build/testflight).
  TRIX_IOS_EXPORT_OPTIONS_PLIST    Override export options plist path.
  TRIX_IOS_ALLOW_PROVISIONING_UPDATES
                                   Set to 0 to disable -allowProvisioningUpdates.
  TRIX_TESTFLIGHT_INTERNAL_ONLY    Set to 1/true to mark upload for internal
                                   TestFlight testing only.

Upload auth environment:
  No upload env is required for a fresh archive if Xcode is already signed in
  on this Mac. The credentials stay local and are not stored in git.

  Preferred App Store Connect key auth for xcodebuild upload:
    TRIX_ASC_AUTH_KEY_PATH
    TRIX_ASC_AUTH_KEY_ID
    TRIX_ASC_AUTH_ISSUER_ID

  Username/password:
    TRIX_APPLE_ID
    TRIX_APP_SPECIFIC_PASSWORD

  Keychain password item:
    TRIX_APPLE_ID                  Optional when the keychain item stores the account.
    TRIX_ALTOOL_KEYCHAIN_ITEM
    TRIX_ALTOOL_KEYCHAIN_PATH      Optional custom keychain path.

  App Store Connect API key:
    TRIX_ASC_API_KEY               Alias for TRIX_ASC_AUTH_KEY_ID.
    TRIX_ASC_API_ISSUER            Alias for TRIX_ASC_AUTH_ISSUER_ID.
    TRIX_ASC_API_P8_FILE_PATH      Explicit AuthKey_<key>.p8 or ApiKey_<key>.p8 path.
    TRIX_ASC_API_AUTH_STRING       Inline p8 key contents.
    TRIX_ASC_API_KEY_SUBJECT       Optional, for example 'user' for individual keys.
    TRIX_ASC_API_PRIVATE_KEYS_DIR  Directory containing AuthKey_<key>.p8 or ApiKey_<key>.p8.

Examples:
  ./scripts/build-testflight.sh
  TRIX_IOS_BUILD_NUMBER=42 ./scripts/build-testflight.sh --validate
  TRIX_IOS_BUILD_NUMBER=42 ./scripts/build-testflight.sh --upload
  TRIX_IOS_BUILD_NUMBER=42 TRIX_ASC_AUTH_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123.p8" \
    TRIX_ASC_AUTH_KEY_ID=ABC123 TRIX_ASC_AUTH_ISSUER_ID=issuer-id \
    ./scripts/build-testflight.sh --upload
  TRIX_APPLE_ID=me@example.com TRIX_APP_SPECIFIC_PASSWORD=xxxx \
    ./scripts/build-testflight.sh --ipa apps/ios/build/testflight/export/Trix.ipa --upload
EOF
}

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
}

abs_path() {
  local input_path="$1"
  local dir_name
  local base_name

  dir_name="$(cd "$(dirname "$input_path")" && pwd)"
  base_name="$(basename "$input_path")"
  printf '%s/%s\n' "$dir_name" "$base_name"
}

is_truthy() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

normalized_asc_key_id() {
  printf '%s' "${TRIX_ASC_AUTH_KEY_ID:-${TRIX_ASC_API_KEY:-}}"
}

normalized_asc_issuer_id() {
  printf '%s' "${TRIX_ASC_AUTH_ISSUER_ID:-${TRIX_ASC_API_ISSUER:-}}"
}

normalized_asc_key_path() {
  printf '%s' "${TRIX_ASC_AUTH_KEY_PATH:-${TRIX_ASC_API_P8_FILE_PATH:-}}"
}

has_altool_upload_auth_config() {
  local asc_key_id
  local asc_issuer_id
  local asc_key_path

  asc_key_id="$(normalized_asc_key_id)"
  asc_issuer_id="$(normalized_asc_issuer_id)"
  asc_key_path="$(normalized_asc_key_path)"

  if [[ -n "${TRIX_ALTOOL_KEYCHAIN_ITEM:-}" \
    || -n "${TRIX_APPLE_ID:-}" \
    || -n "${TRIX_APP_SPECIFIC_PASSWORD:-}" \
    || -n "${TRIX_ASC_API_AUTH_STRING:-}" \
    || -n "${TRIX_ASC_API_PRIVATE_KEYS_DIR:-}" \
    || -n "${TRIX_ASC_API_KEY_SUBJECT:-}" ]]; then
    return 0
  fi

  if [[ -n "$asc_key_id" || -n "$asc_issuer_id" ]]; then
    [[ -z "$asc_key_path" ]] && return 0
  fi

  return 1
}

api_key_file_exists() {
  local dir_path="$1"
  local key_id="$2"
  [[ -n "$dir_path" && -n "$key_id" ]] || return 1
  [[ -f "$dir_path/AuthKey_${key_id}.p8" || -f "$dir_path/ApiKey_${key_id}.p8" ]]
}

cleanup() {
  local status=$?
  local temp_file

  for temp_file in "${TEMP_FILES[@]:-}"; do
    rm -f "$temp_file"
  done

  if ((status != 0)); then
    printf '\nerror: build-testflight.sh failed. Inspect artifacts under %s\n' "$BUILD_ROOT" >&2
  fi

  exit "$status"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --validate)
        RUN_VALIDATE=1
        ;;
      --upload)
        RUN_UPLOAD=1
        ;;
      --ipa)
        shift
        (($# > 0)) || die "--ipa expects a path"
        IPA_PATH="$1"
        ;;
      --skip-prechecks)
        RUN_PRECHECKS=0
        ;;
      --skip-bridge)
        SKIP_BRIDGE=1
        ;;
      --skip-xcodegen)
        SKIP_XCODEGEN=1
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

  if [[ -n "$IPA_PATH" && $RUN_VALIDATE -eq 0 && $RUN_UPLOAD -eq 0 ]]; then
    die "--ipa requires --validate or --upload"
  fi
}

print_runtime_summary() {
  log "Project: $PROJECT_PATH"
  log "Scheme: $SCHEME ($CONFIGURATION)"

  if [[ -n "$IPA_PATH" ]]; then
    log "Using existing IPA: $IPA_PATH"
    return
  fi

  log "Artifacts root: $BUILD_ROOT"
  log "Archive: $ARCHIVE_PATH"
  log "Export dir: $EXPORT_PATH"

  if [[ -n "${TRIX_IOS_MARKETING_VERSION:-}" ]]; then
    log "Overriding MARKETING_VERSION=$TRIX_IOS_MARKETING_VERSION"
  fi

  if [[ -n "${TRIX_IOS_BUILD_NUMBER:-}" ]]; then
    log "Overriding CURRENT_PROJECT_VERSION=$TRIX_IOS_BUILD_NUMBER"
  fi

  if [[ -n "${TRIX_IOS_DEVELOPMENT_TEAM:-}" ]]; then
    log "Overriding DEVELOPMENT_TEAM=$TRIX_IOS_DEVELOPMENT_TEAM"
  fi
}

prepare_artifact_root() {
  mkdir -p "$BUILD_ROOT"
  rm -rf "$ARCHIVE_PATH" "$RESULT_BUNDLE_PATH" "$EXPORT_PATH"
  rm -f "$ARCHIVE_LOG_PATH" "$EXPORT_LOG_PATH" "$VALIDATE_LOG_PATH" "$UPLOAD_LOG_PATH"
}

prepare_project() {
  if ((SKIP_BRIDGE == 0)); then
    log "Regenerating iOS UniFFI bridge and xcframework"
    bash "$SCRIPT_DIR/generate-trix-core-bridge.sh"
  fi

  if ((SKIP_XCODEGEN == 0)); then
    log "Regenerating Xcode project with XcodeGen"
    (
      cd "$IOS_DIR"
      xcodegen generate
    )
  fi
}

run_prechecks() {
  if ((RUN_PRECHECKS == 0)); then
    return
  fi

  log "Running ios-unit prechecks"
  bash "$REPO_ROOT/scripts/client-smoke-harness.sh" --no-postgres --suite ios-unit
}

archive_app() {
  local build_number="${TRIX_IOS_BUILD_NUMBER:-$(date '+%Y%m%d%H%M')}"
  local -a archive_args=(
    clean
    archive
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "$ARCHIVE_DESTINATION"
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -resultBundlePath "$RESULT_BUNDLE_PATH"
  )

  if [[ "$ALLOW_PROVISIONING_UPDATES" != "0" ]]; then
    archive_args+=(-allowProvisioningUpdates)
  fi

  if [[ -n "${TRIX_IOS_MARKETING_VERSION:-}" ]]; then
    archive_args+=(MARKETING_VERSION="$TRIX_IOS_MARKETING_VERSION")
  fi

  archive_args+=(CURRENT_PROJECT_VERSION="$build_number")

  if [[ -n "${TRIX_IOS_DEVELOPMENT_TEAM:-}" ]]; then
    archive_args+=(DEVELOPMENT_TEAM="$TRIX_IOS_DEVELOPMENT_TEAM")
  fi

  if ((${#XCODEBUILD_AUTH_ARGS[@]} > 0)); then
    archive_args+=("${XCODEBUILD_AUTH_ARGS[@]}")
  fi

  log "Archiving signed iOS app"
  (
    cd "$IOS_DIR"
    xcodebuild "${archive_args[@]}" | tee "$ARCHIVE_LOG_PATH"
  )
}

create_export_options_plist() {
  local destination="$1"
  local plist_path

  plist_path="$(mktemp "${TMPDIR:-/tmp}/trix-ios-export-options.XXXXXX")"
  TEMP_FILES+=("$plist_path")
  cp "$EXPORT_OPTIONS_PLIST" "$plist_path"

  if ! /usr/libexec/PlistBuddy -c "Set :destination $destination" "$plist_path" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :destination string $destination" "$plist_path" >/dev/null
  fi

  if is_truthy "$TESTFLIGHT_INTERNAL_ONLY"; then
    if ! /usr/libexec/PlistBuddy -c "Set :testFlightInternalTestingOnly true" "$plist_path" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Add :testFlightInternalTestingOnly bool true" "$plist_path" >/dev/null
    fi
  fi

  printf '%s\n' "$plist_path"
}

export_archive() {
  local destination="${1:-export}"
  local log_path="${2:-$EXPORT_LOG_PATH}"
  local action_label="${3:-Exporting IPA}"
  local export_options_plist
  local -a export_args=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_PATH"
  )

  export_options_plist="$(create_export_options_plist "$destination")"
  export_args+=(-exportOptionsPlist "$export_options_plist")

  if [[ "$ALLOW_PROVISIONING_UPDATES" != "0" ]]; then
    export_args+=(-allowProvisioningUpdates)
  fi

  if ((${#XCODEBUILD_AUTH_ARGS[@]} > 0)); then
    export_args+=("${XCODEBUILD_AUTH_ARGS[@]}")
  fi

  log "$action_label"
  (
    cd "$IOS_DIR"
    xcodebuild "${export_args[@]}" | tee "$log_path"
  )
}

resolve_exported_ipa() {
  local -a ipas=()

  shopt -s nullglob
  ipas=("$EXPORT_PATH"/*.ipa)
  shopt -u nullglob

  if ((${#ipas[@]} == 1)); then
    IPA_PATH="${ipas[0]}"
    return 0
  fi

  if ((${#ipas[@]} == 0)); then
    die "no IPA found under $EXPORT_PATH after export"
  fi

  die "multiple IPA files found under $EXPORT_PATH; set TRIX_IOS_IPA_PATH explicitly"
}

build_altool_auth_args() {
  ALTOOL_AUTH_ARGS=()
  ALTOOL_AUTH_MODE=""
  local asc_key_id
  local asc_issuer_id
  local asc_key_path

  asc_key_id="$(normalized_asc_key_id)"
  asc_issuer_id="$(normalized_asc_issuer_id)"
  asc_key_path="$(normalized_asc_key_path)"

  if [[ -n "${TRIX_ASC_API_PRIVATE_KEYS_DIR:-}" ]]; then
    export API_PRIVATE_KEYS_DIR="$TRIX_ASC_API_PRIVATE_KEYS_DIR"
  fi

  if [[ -n "$asc_key_id" || -n "$asc_issuer_id" || -n "$asc_key_path" || -n "${TRIX_ASC_API_AUTH_STRING:-}" || -n "${TRIX_ASC_API_PRIVATE_KEYS_DIR:-}" ]]; then
    [[ -n "$asc_key_id" && -n "$asc_issuer_id" ]] || die "set both TRIX_ASC_AUTH_KEY_ID/TRIX_ASC_API_KEY and TRIX_ASC_AUTH_ISSUER_ID/TRIX_ASC_API_ISSUER"
    [[ -z "$asc_key_path" || -z "${TRIX_ASC_API_AUTH_STRING:-}" ]] || die "set only one of TRIX_ASC_AUTH_KEY_PATH/TRIX_ASC_API_P8_FILE_PATH or TRIX_ASC_API_AUTH_STRING"

    ALTOOL_AUTH_MODE="api-key"
    ALTOOL_AUTH_ARGS+=(--api-key "$asc_key_id" --api-issuer "$asc_issuer_id")

    if [[ -n "$asc_key_path" ]]; then
      [[ -f "$asc_key_path" ]] || die "API key file not found: $asc_key_path"
      ALTOOL_AUTH_ARGS+=(--p8-file-path "$asc_key_path")
    fi

    if [[ -n "${TRIX_ASC_API_AUTH_STRING:-}" ]]; then
      ALTOOL_AUTH_ARGS+=(--auth-string "$TRIX_ASC_API_AUTH_STRING")
    fi

    if [[ -z "$asc_key_path" && -z "${TRIX_ASC_API_AUTH_STRING:-}" ]]; then
      if ! api_key_file_exists "${TRIX_ASC_API_PRIVATE_KEYS_DIR:-}" \
        "$asc_key_id" \
        && ! api_key_file_exists "${API_PRIVATE_KEYS_DIR:-}" "$asc_key_id" \
        && ! api_key_file_exists "$IOS_DIR/private_keys" "$asc_key_id" \
        && ! api_key_file_exists "$HOME/private_keys" "$asc_key_id" \
        && ! api_key_file_exists "$HOME/.private_keys" "$asc_key_id" \
        && ! api_key_file_exists "$HOME/.appstoreconnect/private_keys" "$asc_key_id"; then
        die "API key auth requires TRIX_ASC_AUTH_KEY_PATH/TRIX_ASC_API_P8_FILE_PATH, TRIX_ASC_API_AUTH_STRING, or a private key directory containing AuthKey_${asc_key_id}.p8 or ApiKey_${asc_key_id}.p8"
      fi
    fi

    if [[ -n "${TRIX_ASC_API_KEY_SUBJECT:-}" ]]; then
      ALTOOL_AUTH_ARGS+=(--api-key-subject "$TRIX_ASC_API_KEY_SUBJECT")
    fi

    return
  fi

  if [[ -n "${TRIX_ALTOOL_KEYCHAIN_ITEM:-}" ]]; then
    ALTOOL_AUTH_MODE="keychain"

    if [[ -n "${TRIX_APPLE_ID:-}" ]]; then
      ALTOOL_AUTH_ARGS+=(--username "$TRIX_APPLE_ID")
    fi

    ALTOOL_AUTH_ARGS+=(--password "@keychain:${TRIX_ALTOOL_KEYCHAIN_ITEM}")

    if [[ -n "${TRIX_ALTOOL_KEYCHAIN_PATH:-}" ]]; then
      ALTOOL_AUTH_ARGS+=(--keychain "$TRIX_ALTOOL_KEYCHAIN_PATH")
    fi

    return
  fi

  if [[ -n "${TRIX_APPLE_ID:-}" || -n "${TRIX_APP_SPECIFIC_PASSWORD:-}" ]]; then
    [[ -n "${TRIX_APPLE_ID:-}" && -n "${TRIX_APP_SPECIFIC_PASSWORD:-}" ]] || die "set both TRIX_APPLE_ID and TRIX_APP_SPECIFIC_PASSWORD"

    ALTOOL_AUTH_MODE="apple-id"
    ALTOOL_AUTH_ARGS+=(--username "$TRIX_APPLE_ID" --password "@env:TRIX_APP_SPECIFIC_PASSWORD")
    return
  fi

  die "set upload credentials via TRIX_APPLE_ID/TRIX_APP_SPECIFIC_PASSWORD, TRIX_ALTOOL_KEYCHAIN_ITEM, or App Store Connect key settings such as TRIX_ASC_AUTH_KEY_ID/TRIX_ASC_AUTH_ISSUER_ID"
}

build_xcodebuild_auth_args() {
  XCODEBUILD_AUTH_ARGS=()
  XCODEBUILD_AUTH_MODE="xcode-account"

  local asc_key_id
  local asc_issuer_id
  local asc_key_path

  asc_key_id="$(normalized_asc_key_id)"
  asc_issuer_id="$(normalized_asc_issuer_id)"
  asc_key_path="$(normalized_asc_key_path)"

  if [[ -z "$asc_key_path" ]]; then
    return
  fi

  [[ -n "$asc_key_id" && -n "$asc_issuer_id" ]] || die "set TRIX_ASC_AUTH_KEY_PATH/TRIX_ASC_API_P8_FILE_PATH, TRIX_ASC_AUTH_KEY_ID/TRIX_ASC_API_KEY, and TRIX_ASC_AUTH_ISSUER_ID/TRIX_ASC_API_ISSUER for xcodebuild upload"
  [[ -f "$asc_key_path" ]] || die "API key file not found: $asc_key_path"

  XCODEBUILD_AUTH_MODE="asc-api-key"
  XCODEBUILD_AUTH_ARGS+=(
    -authenticationKeyPath "$asc_key_path"
    -authenticationKeyID "$asc_key_id"
    -authenticationKeyIssuerID "$asc_issuer_id"
  )
}

validate_ipa() {
  log "Validating IPA with altool ($ALTOOL_AUTH_MODE)"
  (
    cd "$IOS_DIR"
    xcrun altool \
      --validate-app \
      -f "$IPA_PATH" \
      "${ALTOOL_AUTH_ARGS[@]}" \
      --output-format json \
      --show-progress \
      | tee "$VALIDATE_LOG_PATH"
  )
}

upload_ipa() {
  log "Uploading IPA with altool ($ALTOOL_AUTH_MODE)"
  (
    cd "$IOS_DIR"
    xcrun altool \
      --upload-app \
      -f "$IPA_PATH" \
      "${ALTOOL_AUTH_ARGS[@]}" \
      --output-format json \
      --show-progress \
      | tee "$UPLOAD_LOG_PATH"
  )
}

upload_archive() {
  export_archive upload "$UPLOAD_LOG_PATH" "Uploading archive to App Store Connect via xcodebuild ($XCODEBUILD_AUTH_MODE)"
}

validate_existing_ipa_path() {
  IPA_PATH="$(abs_path "$IPA_PATH")"
  [[ -f "$IPA_PATH" ]] || die "IPA not found: $IPA_PATH"
}

print_success_summary() {
  if [[ -f "$ARCHIVE_LOG_PATH" ]]; then
    log "Archive log: $ARCHIVE_LOG_PATH"
  fi

  if [[ -f "$EXPORT_LOG_PATH" ]]; then
    log "Export log: $EXPORT_LOG_PATH"
  fi

  if [[ -f "$RESULT_BUNDLE_PATH/Info.plist" ]]; then
    log "Archive result bundle: $RESULT_BUNDLE_PATH"
  fi

  if [[ -n "$IPA_PATH" ]]; then
    log "IPA: $IPA_PATH"
  fi

  if ((RUN_VALIDATE)); then
    log "Validate log: $VALIDATE_LOG_PATH"
  fi

  if ((RUN_UPLOAD)); then
    log "Upload log: $UPLOAD_LOG_PATH"
  fi
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  mkdir -p "$BUILD_ROOT"

  require_command xcodebuild
  require_command xcrun
  if ((RUN_UPLOAD)); then
    build_xcodebuild_auth_args
  fi

  if ((RUN_UPLOAD)) && [[ -z "$IPA_PATH" ]]; then
    if ((${#XCODEBUILD_AUTH_ARGS[@]} > 0)) || ! has_altool_upload_auth_config; then
      USE_XCODEBUILD_UPLOAD=1
    fi
  fi

  if ((RUN_VALIDATE)); then
    build_altool_auth_args
  elif ((RUN_UPLOAD)) && ((USE_XCODEBUILD_UPLOAD == 0)); then
    build_altool_auth_args
  fi

  if [[ -n "$IPA_PATH" ]]; then
    validate_existing_ipa_path
  else
    require_command cargo
    require_command rustup
    require_command xcodegen

    [[ -f "$EXPORT_OPTIONS_PLIST" ]] || die "export options plist not found: $EXPORT_OPTIONS_PLIST"

    prepare_artifact_root
    print_runtime_summary
    prepare_project
    run_prechecks
    archive_app

    if ((RUN_VALIDATE)) || ((USE_XCODEBUILD_UPLOAD == 0)); then
      export_archive export "$EXPORT_LOG_PATH" "Exporting IPA"
      resolve_exported_ipa
    fi
  fi

  if [[ -n "$IPA_PATH" ]]; then
    log "IPA ready: $IPA_PATH"
  fi

  if ((RUN_VALIDATE)); then
    build_altool_auth_args
    validate_ipa
  fi

  if ((RUN_UPLOAD)); then
    if ((USE_XCODEBUILD_UPLOAD)); then
      upload_archive
    else
      upload_ipa
    fi
  fi

  print_success_summary
}

main "$@"
