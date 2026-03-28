#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEME="${TRIX_SCHEME:-TrixMac}"
CONFIGURATION="${TRIX_CONFIGURATION:-Release}"
DIST_ROOT="${TRIX_DIST_ROOT:-$APP_ROOT/dist/testflight}"
ARCHIVE_PATH="${TRIX_ARCHIVE_PATH:-$DIST_ROOT/$SCHEME.xcarchive}"
EXPORT_PATH="${TRIX_EXPORT_PATH:-$DIST_ROOT/export}"
EXPORT_OPTIONS_PLIST="${TRIX_EXPORT_OPTIONS_PLIST:-$APP_ROOT/AppStoreConnectExportOptions.plist}"
DESTINATION="${TRIX_ASC_DESTINATION:-export}"
SKIP_EXPORT="${TRIX_SKIP_EXPORT:-0}"
INTERNAL_ONLY="${TRIX_TESTFLIGHT_INTERNAL_ONLY:-0}"

case "$DESTINATION" in
  export|upload) ;;
  *)
    echo "Unsupported TRIX_ASC_DESTINATION: $DESTINATION" >&2
    echo "Expected 'export' or 'upload'." >&2
    exit 1
    ;;
esac

declare -a XCODEBUILD_AUTH_ARGS=()
if [[ -n "${TRIX_ASC_AUTH_KEY_PATH:-}" ]]; then
  : "${TRIX_ASC_AUTH_KEY_ID:?Set TRIX_ASC_AUTH_KEY_ID when using TRIX_ASC_AUTH_KEY_PATH}"
  : "${TRIX_ASC_AUTH_ISSUER_ID:?Set TRIX_ASC_AUTH_ISSUER_ID when using TRIX_ASC_AUTH_KEY_PATH}"
  XCODEBUILD_AUTH_ARGS+=(
    -authenticationKeyPath "$TRIX_ASC_AUTH_KEY_PATH"
    -authenticationKeyID "$TRIX_ASC_AUTH_KEY_ID"
    -authenticationKeyIssuerID "$TRIX_ASC_AUTH_ISSUER_ID"
  )
fi

mkdir -p "$DIST_ROOT"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

TMP_EXPORT_OPTIONS_PLIST="$(mktemp "${TMPDIR:-/tmp}/trix-app-store-connect-export-options.XXXXXX.plist")"
trap 'rm -f "$TMP_EXPORT_OPTIONS_PLIST"' EXIT

cp "$EXPORT_OPTIONS_PLIST" "$TMP_EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Set :destination $DESTINATION" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null

if [[ "$INTERNAL_ONLY" == "1" || "$INTERNAL_ONLY" == "true" ]]; then
  if ! /usr/libexec/PlistBuddy -c "Set :testFlightInternalTestingOnly true" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :testFlightInternalTestingOnly bool true" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null
  fi
fi

echo "==> Archiving macOS app for App Store Connect"
archive_cmd=(
  xcodebuild
  -project "$APP_ROOT/TrixMac.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -allowProvisioningUpdates
  archive
)
if [[ ${#XCODEBUILD_AUTH_ARGS[@]} -gt 0 ]]; then
  archive_cmd+=("${XCODEBUILD_AUTH_ARGS[@]}")
fi
"${archive_cmd[@]}"

if [[ "$SKIP_EXPORT" == "1" || "$SKIP_EXPORT" == "true" ]]; then
  echo
  echo "Archive ready:"
  echo "  $ARCHIVE_PATH"
  exit 0
fi

mkdir -p "$EXPORT_PATH"

echo "==> Exporting archive for App Store Connect ($DESTINATION)"
export_cmd=(
  xcodebuild
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$TMP_EXPORT_OPTIONS_PLIST"
  -allowProvisioningUpdates
)
if [[ ${#XCODEBUILD_AUTH_ARGS[@]} -gt 0 ]]; then
  export_cmd+=("${XCODEBUILD_AUTH_ARGS[@]}")
fi
"${export_cmd[@]}"

echo
echo "Archive:"
echo "  $ARCHIVE_PATH"
echo "Export destination:"
echo "  $DESTINATION"
echo "Export path:"
echo "  $EXPORT_PATH"
