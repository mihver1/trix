#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export TRIX_CORE_ARTIFACTS_PATH="${TRIX_CORE_ARTIFACTS_PATH:-$REPO_ROOT/target/release}"

BUNDLE_ID="${TRIX_BUNDLE_ID:-com.softgrid.trixapp}"
APP_NAME="${TRIX_APP_NAME:-TrixMac}"
MARKETING_VERSION="${TRIX_MARKETING_VERSION:-0.1.0-beta}"
BUILD_VERSION="${TRIX_BUILD_VERSION:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
DIST_ROOT="$APP_ROOT/dist"
BUNDLE_ROOT="$DIST_ROOT/$APP_NAME.app"
CONTENTS_ROOT="$BUNDLE_ROOT/Contents"
MACOS_ROOT="$CONTENTS_ROOT/MacOS"
RESOURCES_ROOT="$CONTENTS_ROOT/Resources"
ICON_SOURCE="$APP_ROOT/Sources/TrixMac/Resources/AppIcon.icns"

echo "==> Building trix-core release artifact"
cargo build -p trix-core --release --lib --manifest-path "$REPO_ROOT/Cargo.toml"

echo "==> Regenerating macOS UniFFI bridge"
"$SCRIPT_DIR/generate-trix-core-bridge.sh"

echo "==> Regenerating app icons"
swift "$REPO_ROOT/scripts/generate-app-icons.swift"

echo "==> Building macOS client release binary"
(
  cd "$APP_ROOT"
  swift build -c release
)

BINARY_PATH="$(find "$APP_ROOT/.build" -type f -path '*release/TrixMac' | head -n 1)"
if [[ -z "$BINARY_PATH" ]]; then
  echo "Could not find release TrixMac binary under $APP_ROOT/.build" >&2
  exit 1
fi

echo "==> Packaging app bundle"
rm -rf "$BUNDLE_ROOT"
mkdir -p "$MACOS_ROOT" "$RESOURCES_ROOT"

cp "$BINARY_PATH" "$MACOS_ROOT/$APP_NAME"
cp "$ICON_SOURCE" "$RESOURCES_ROOT/AppIcon.icns"

cat > "$CONTENTS_ROOT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MACOSX_DEPLOYMENT_TARGET}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Codesigning bundle"
  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$BUNDLE_ROOT"
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  ZIP_PATH="$DIST_ROOT/$APP_NAME.zip"
  echo "==> Preparing notarization archive"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$BUNDLE_ROOT" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$BUNDLE_ROOT"
fi

echo
echo "Built bundle:"
echo "  $BUNDLE_ROOT"
