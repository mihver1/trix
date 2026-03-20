#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"

HOST_LIBRARY_PATH="$REPO_ROOT/target/debug/libtrix_core.dylib"
GENERATED_DIR="$IOS_DIR/TrixiOS/Bridge/Generated"
ARTIFACTS_DIR="$IOS_DIR/Vendor"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/TrixCoreFFI.xcframework"

IOS_DEVICE_TARGET="aarch64-apple-ios"
IOS_SIMULATOR_TARGET="aarch64-apple-ios-sim"
IOS_DEPLOYMENT_TARGET="17.0"

ensure_target() {
  local target="$1"
  if ! rustup target list --installed | grep -qx "$target"; then
    echo "Installing Rust target $target"
    rustup target add "$target"
  fi
}

mkdir -p "$GENERATED_DIR" "$ARTIFACTS_DIR"

ensure_target "$IOS_DEVICE_TARGET"
ensure_target "$IOS_SIMULATOR_TARGET"

pushd "$REPO_ROOT" >/dev/null

cargo build -p trix-core --lib

cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library "$HOST_LIBRARY_PATH" \
  --language swift \
  --out-dir "$GENERATED_DIR"

cp "$GENERATED_DIR/trix_coreFFI.modulemap" "$GENERATED_DIR/module.modulemap"

IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
  cargo build -p trix-core --target "$IOS_DEVICE_TARGET" --release --lib
IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
  cargo build -p trix-core --target "$IOS_SIMULATOR_TARGET" --release --lib

rm -rf "$XCFRAMEWORK_PATH"

xcodebuild -create-xcframework \
  -library "$REPO_ROOT/target/$IOS_DEVICE_TARGET/release/libtrix_core.a" \
  -headers "$GENERATED_DIR" \
  -library "$REPO_ROOT/target/$IOS_SIMULATOR_TARGET/release/libtrix_core.a" \
  -headers "$GENERATED_DIR" \
  -output "$XCFRAMEWORK_PATH"

popd >/dev/null

echo "Generated Swift bindings in $GENERATED_DIR"
echo "Built xcframework at $XCFRAMEWORK_PATH"
