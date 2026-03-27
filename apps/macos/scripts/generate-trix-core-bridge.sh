#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

HOST_LIBRARY_PATH="$REPO_ROOT/target/debug/libtrix_core.dylib"
SWIFT_OUTPUT="$APP_ROOT/Sources/TrixMac/Generated"
FFI_OUTPUT="$APP_ROOT/Sources/trix_coreFFI"
TMPDIR="$(mktemp -d /tmp/trix-macos-bridge.XXXXXX)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

mkdir -p "$SWIFT_OUTPUT" "$FFI_OUTPUT"

pushd "$REPO_ROOT" >/dev/null

MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" cargo build -p trix-core --lib

cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library "$HOST_LIBRARY_PATH" \
  --language swift \
  --out-dir "$TMPDIR"

cp "$TMPDIR/trix_core.swift" "$SWIFT_OUTPUT/trix_core.swift"
cp "$TMPDIR/trix_coreFFI.h" "$FFI_OUTPUT/trix_coreFFI.h"
cp "$TMPDIR/trix_coreFFI.modulemap" "$FFI_OUTPUT/module.modulemap"

popd >/dev/null

echo "Generated Swift bindings in $SWIFT_OUTPUT"
echo "Generated FFI headers in $FFI_OUTPUT"
