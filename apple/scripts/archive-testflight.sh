#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PLATFORM="${TRIX_APPLE_PLATFORM:-}"
CONFIGURATION="${TRIX_APPLE_CONFIGURATION:-Release}"
BUILD_ROOT="${TRIX_APPLE_BUILD_ROOT:-$APPLE_DIR/build/testflight}"
DERIVED_DATA_PATH="${TRIX_APPLE_DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
ALLOW_PROVISIONING_UPDATES="${TRIX_APPLE_ALLOW_PROVISIONING_UPDATES:-1}"
DESTINATION="${TRIX_ASC_DESTINATION:-export}"
SKIP_XCODEGEN=0
SKIP_EXPORT=0
UNSIGNED_ARCHIVE=0
INTERNAL_ONLY="${TRIX_TESTFLIGHT_INTERNAL_ONLY:-0}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/archive-testflight.sh --platform ios|macos [options]

Archives the current XMPP Apple app targets.

Options:
  --platform ios|macos  Required unless TRIX_APPLE_PLATFORM is set.
  --skip-xcodegen       Do not run xcodegen generate before archive.
  --skip-export         Create the archive only.
  --unsigned-archive    Create a local unsigned archive for pipeline validation.
                        This implies --skip-export and cannot upload to
                        TestFlight.
  --help                Show this help.

Environment:
  TRIX_APPLE_BUILD_NUMBER          Override CURRENT_PROJECT_VERSION.
  TRIX_APPLE_MARKETING_VERSION     Override MARKETING_VERSION.
  TRIX_APPLE_DEVELOPMENT_TEAM      Override DEVELOPMENT_TEAM.
  TRIX_APPLE_BUILD_ROOT            Override artifact root.
  TRIX_ASC_DESTINATION             export or upload. Defaults to export.
  TRIX_ASC_AUTH_KEY_PATH           Optional App Store Connect key path.
  TRIX_ASC_AUTH_KEY_ID             Required with TRIX_ASC_AUTH_KEY_PATH.
  TRIX_ASC_AUTH_ISSUER_ID          Required with TRIX_ASC_AUTH_KEY_PATH.
  TRIX_TESTFLIGHT_INTERNAL_ONLY    Set to 1/true for internal-only upload.

Examples:
  ./scripts/archive-testflight.sh --platform ios --unsigned-archive
  TRIX_APPLE_BUILD_NUMBER=42 ./scripts/archive-testflight.sh --platform ios
  TRIX_APPLE_BUILD_NUMBER=42 TRIX_ASC_DESTINATION=upload \
    TRIX_ASC_AUTH_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123.p8" \
    TRIX_ASC_AUTH_KEY_ID=ABC123 TRIX_ASC_AUTH_ISSUER_ID=issuer-id \
    ./scripts/archive-testflight.sh --platform macos
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

is_truthy() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --platform)
        shift
        (($# > 0)) || die "--platform expects ios or macos"
        PLATFORM="$1"
        ;;
      --skip-xcodegen)
        SKIP_XCODEGEN=1
        ;;
      --skip-export)
        SKIP_EXPORT=1
        ;;
      --unsigned-archive)
        UNSIGNED_ARCHIVE=1
        SKIP_EXPORT=1
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
}

make_export_options() {
  local plist_path="$1"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :method string app-store-connect" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :destination string $DESTINATION" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :manageAppVersionAndBuildNumber bool false" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :stripSwiftSymbols bool true" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :uploadSymbols bool true" "$plist_path"

  if is_truthy "$INTERNAL_ONLY"; then
    /usr/libexec/PlistBuddy -c "Add :testFlightInternalTestingOnly bool true" "$plist_path"
  fi
}

parse_args "$@"

case "$PLATFORM" in
  ios)
    SCHEME="${TRIX_APPLE_SCHEME:-TrixMatrixiOS}"
    DESTINATION_SPEC="generic/platform=iOS"
    ARCHIVE_NAME="TrixMatrixiOS"
    ;;
  macos)
    SCHEME="${TRIX_APPLE_SCHEME:-TrixMatrixMac}"
    DESTINATION_SPEC="generic/platform=macOS"
    ARCHIVE_NAME="TrixMatrixMac"
    ;;
  *)
    usage >&2
    die "set --platform to ios or macos"
    ;;
esac

case "$DESTINATION" in
  export|upload) ;;
  *) die "TRIX_ASC_DESTINATION must be export or upload" ;;
esac

if [[ $UNSIGNED_ARCHIVE -eq 1 && "$DESTINATION" == "upload" ]]; then
  die "--unsigned-archive cannot upload to TestFlight"
fi

BUILD_NUMBER="${TRIX_APPLE_BUILD_NUMBER:-$(date '+%Y%m%d%H%M')}"
ARCHIVE_PATH="${TRIX_APPLE_ARCHIVE_PATH:-$BUILD_ROOT/$ARCHIVE_NAME.xcarchive}"
RESULT_BUNDLE_PATH="${TRIX_APPLE_RESULT_BUNDLE_PATH:-$BUILD_ROOT/$ARCHIVE_NAME-archive.xcresult}"
EXPORT_PATH="${TRIX_APPLE_EXPORT_PATH:-$BUILD_ROOT/$ARCHIVE_NAME-export}"
EXPORT_OPTIONS_PLIST="$(mktemp "${TMPDIR:-/tmp}/trix-apple-export-options.XXXXXX.plist")"
trap 'rm -f "$EXPORT_OPTIONS_PLIST"' EXIT

declare -a AUTH_ARGS=()
if [[ -n "${TRIX_ASC_AUTH_KEY_PATH:-}" ]]; then
  : "${TRIX_ASC_AUTH_KEY_ID:?Set TRIX_ASC_AUTH_KEY_ID when using TRIX_ASC_AUTH_KEY_PATH}"
  : "${TRIX_ASC_AUTH_ISSUER_ID:?Set TRIX_ASC_AUTH_ISSUER_ID when using TRIX_ASC_AUTH_KEY_PATH}"
  AUTH_ARGS+=(
    -authenticationKeyPath "$TRIX_ASC_AUTH_KEY_PATH"
    -authenticationKeyID "$TRIX_ASC_AUTH_KEY_ID"
    -authenticationKeyIssuerID "$TRIX_ASC_AUTH_ISSUER_ID"
  )
fi

mkdir -p "$BUILD_ROOT"
rm -rf "$ARCHIVE_PATH" "$RESULT_BUNDLE_PATH" "$EXPORT_PATH"

if [[ $SKIP_XCODEGEN -eq 0 ]]; then
  echo "==> Generating Xcode project"
  (cd "$APPLE_DIR" && xcodegen generate)
fi

declare -a ARCHIVE_CMD=(
  xcodebuild
  -project "$APPLE_DIR/TrixMatrix.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION_SPEC"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -archivePath "$ARCHIVE_PATH"
  -resultBundlePath "$RESULT_BUNDLE_PATH"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  archive
)

if [[ -n "${TRIX_APPLE_MARKETING_VERSION:-}" ]]; then
  ARCHIVE_CMD+=(MARKETING_VERSION="$TRIX_APPLE_MARKETING_VERSION")
fi

if [[ -n "${TRIX_APPLE_DEVELOPMENT_TEAM:-}" ]]; then
  ARCHIVE_CMD+=(DEVELOPMENT_TEAM="$TRIX_APPLE_DEVELOPMENT_TEAM")
fi

if [[ $UNSIGNED_ARCHIVE -eq 1 ]]; then
  ARCHIVE_CMD+=(CODE_SIGNING_ALLOWED=NO)
elif is_truthy "$ALLOW_PROVISIONING_UPDATES"; then
  ARCHIVE_CMD+=(-allowProvisioningUpdates)
fi

if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
  ARCHIVE_CMD+=("${AUTH_ARGS[@]}")
fi

echo "==> Archiving $SCHEME ($CONFIGURATION) for $PLATFORM"
"${ARCHIVE_CMD[@]}" 2>&1 | tee "$BUILD_ROOT/$ARCHIVE_NAME-archive.log"

if [[ $SKIP_EXPORT -eq 1 ]]; then
  echo
  echo "Archive ready:"
  echo "  $ARCHIVE_PATH"
  exit 0
fi

make_export_options "$EXPORT_OPTIONS_PLIST"
mkdir -p "$EXPORT_PATH"

declare -a EXPORT_CMD=(
  xcodebuild
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)

if is_truthy "$ALLOW_PROVISIONING_UPDATES"; then
  EXPORT_CMD+=(-allowProvisioningUpdates)
fi

if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
  EXPORT_CMD+=("${AUTH_ARGS[@]}")
fi

echo "==> Exporting $SCHEME archive ($DESTINATION)"
"${EXPORT_CMD[@]}" 2>&1 | tee "$BUILD_ROOT/$ARCHIVE_NAME-export.log"

echo
echo "Archive:"
echo "  $ARCHIVE_PATH"
echo "Export destination:"
echo "  $DESTINATION"
echo "Export path:"
echo "  $EXPORT_PATH"
