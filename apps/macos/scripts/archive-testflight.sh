#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_SCRIPT="${TRIX_MACOS_BRIDGE_SCRIPT:-$APP_ROOT/scripts/generate-trix-core-bridge.sh}"
CORE_BUILD_SCRIPT="${TRIX_MACOS_CORE_BUILD_SCRIPT:-$APP_ROOT/scripts/build-trix-core-universal.sh}"

SCHEME="${TRIX_SCHEME:-TrixMac}"
CONFIGURATION="${TRIX_CONFIGURATION:-Release}"
DIST_ROOT="${TRIX_DIST_ROOT:-$APP_ROOT/dist/testflight}"
ARCHIVE_PATH="${TRIX_ARCHIVE_PATH:-$DIST_ROOT/$SCHEME.xcarchive}"
EXPORT_PATH="${TRIX_EXPORT_PATH:-$DIST_ROOT/export}"
EXPORT_OPTIONS_PLIST="${TRIX_EXPORT_OPTIONS_PLIST:-$APP_ROOT/AppStoreConnectExportOptions.plist}"
DESTINATION="${TRIX_ASC_DESTINATION:-export}"
SKIP_EXPORT="${TRIX_SKIP_EXPORT:-0}"
INTERNAL_ONLY="${TRIX_TESTFLIGHT_INTERNAL_ONLY:-0}"
BUILD_NUMBER="${TRIX_MACOS_BUILD_NUMBER:-$(date '+%Y%m%d%H%M')}"

case "$DESTINATION" in
  export|upload) ;;
  *)
    echo "Unsupported TRIX_ASC_DESTINATION: $DESTINATION" >&2
    echo "Expected 'export' or 'upload'." >&2
    exit 1
    ;;
esac

validate_exported_package_signing() {
  local export_root="$1"
  local app_path=""
  local pkg_path=""
  local expanded_dir=""
  local profile_path=""
  local profile_plist=""
  local profile_name=""
  local aps_environment=""

  app_path="$(find "$export_root" -maxdepth 3 -name '*.app' -print -quit || true)"
  if [[ -z "$app_path" ]]; then
    pkg_path="$(find "$export_root" -maxdepth 1 -name '*.pkg' -print -quit || true)"
    if [[ -z "$pkg_path" ]]; then
      echo "Expected an exported .app or .pkg under $export_root" >&2
      return 1
    fi

    expanded_dir="$(mktemp -d "${TMPDIR:-/tmp}/trix-exported-pkg.XXXXXX")"
    pkgutil --expand-full "$pkg_path" "$expanded_dir" >/dev/null
    app_path="$(find "$expanded_dir" -maxdepth 5 -name '*.app' -print -quit || true)"
    if [[ -z "$app_path" ]]; then
      echo "Unable to locate exported app inside package: $pkg_path" >&2
      rm -rf "$expanded_dir"
      return 1
    fi
  fi

  profile_path="$app_path/Contents/embedded.provisionprofile"
  if [[ ! -f "$profile_path" ]]; then
    echo "Expected embedded.provisionprofile in exported app: $app_path" >&2
    rm -rf "$expanded_dir"
    return 1
  fi

  profile_plist="$(mktemp "${TMPDIR:-/tmp}/trix-export-profile.XXXXXX")"
  security cms -D -i "$profile_path" > "$profile_plist"
  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist" 2>/dev/null || true)"
  aps_environment="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "$profile_plist" 2>/dev/null || true)"
  rm -f "$profile_plist"

  if [[ "$profile_name" != *"Store Provisioning Profile"* ]]; then
    echo "Exported app did not use a store provisioning profile: ${profile_name:-<missing>}" >&2
    rm -rf "$expanded_dir"
    return 1
  fi

  if [[ "$aps_environment" != "production" ]]; then
    echo "Exported app is not production signed for APNs: ${aps_environment:-<missing>}" >&2
    rm -rf "$expanded_dir"
    return 1
  fi

  echo "Validated exported signing profile: $profile_name"
  echo "Validated APNs entitlement environment: $aps_environment"
  rm -rf "$expanded_dir"
}

export_contains_distributable() {
  local export_root="$1"
  find "$export_root" -maxdepth 3 \( -name '*.app' -o -name '*.pkg' \) -print -quit | grep -q .
}

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

TMP_EXPORT_OPTIONS_PLIST="$(mktemp "${TMPDIR:-/tmp}/trix-app-store-connect-export-options.XXXXXX")"
trap 'rm -f "$TMP_EXPORT_OPTIONS_PLIST"' EXIT

cp "$EXPORT_OPTIONS_PLIST" "$TMP_EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Set :destination $DESTINATION" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null

if [[ "$INTERNAL_ONLY" == "1" || "$INTERNAL_ONLY" == "true" ]]; then
  if ! /usr/libexec/PlistBuddy -c "Set :testFlightInternalTestingOnly true" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :testFlightInternalTestingOnly bool true" "$TMP_EXPORT_OPTIONS_PLIST" >/dev/null
  fi
fi

echo "==> Regenerating macOS UniFFI bridge"
bash "$BRIDGE_SCRIPT"

echo "==> Building fresh macOS trix-core archive ($CONFIGURATION)"
CONFIGURATION="$CONFIGURATION" bash "$CORE_BUILD_SCRIPT"

echo "Using CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
echo "==> Archiving macOS app for App Store Connect"
archive_cmd=(
  xcodebuild
  -project "$APP_ROOT/TrixMac.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -allowProvisioningUpdates
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
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
if [[ "$DESTINATION" == "export" ]]; then
  validate_exported_package_signing "$EXPORT_PATH"
elif export_contains_distributable "$EXPORT_PATH"; then
  validate_exported_package_signing "$EXPORT_PATH"
else
  echo "Upload destination selected; no local exported package to validate"
fi

echo
echo "Archive:"
echo "  $ARCHIVE_PATH"
echo "Export destination:"
echo "  $DESTINATION"
echo "Export path:"
echo "  $EXPORT_PATH"
