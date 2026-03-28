#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Debug}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCHS="${ARCHS:-arm64 x86_64}"

case "${TRIX_CORE_CARGO_PROFILE:-}" in
  release)
    CARGO_PROFILE="release"
    CARGO_RELEASE_FLAG="--release"
    ;;
  debug)
    CARGO_PROFILE="debug"
    CARGO_RELEASE_FLAG=""
    ;;
  "")
    if [[ "${SWIFT_OPTIMIZATION_LEVEL:-}" == "-Onone" ]]; then
      CARGO_PROFILE="debug"
      CARGO_RELEASE_FLAG=""
    else
      CARGO_PROFILE="release"
      CARGO_RELEASE_FLAG="--release"
    fi
    ;;
  *)
    echo "Unsupported TRIX_CORE_CARGO_PROFILE: ${TRIX_CORE_CARGO_PROFILE}" >&2
    exit 1
    ;;
esac

OUTPUT_DIR="$REPO_ROOT/target/macos-universal/$CONFIGURATION"
OUTPUT_PATH="$OUTPUT_DIR/libtrix_core.a"

mkdir -p "$OUTPUT_DIR"

ensure_target() {
  local target="$1"

  if ! rustup target list --installed | /usr/bin/grep -qx "$target"; then
    if [[ "${CI:-}" == "1" || "${CI:-}" == "true" ]]; then
      echo "Missing Rust target $target. Install it before building: rustup target add $target" >&2
      exit 1
    fi

    echo "Installing Rust target $target"
    rustup target add "$target"
  fi
}

declare -a REQUESTED_ARCHS=()
declare -a ARCHIVE_INPUTS=()
seen_archs=""

for arch in $ARCHS; do
  case " $seen_archs " in
    *" $arch "*) continue ;;
  esac

  seen_archs="$seen_archs $arch"
  REQUESTED_ARCHS+=("$arch")
done

for arch in "${REQUESTED_ARCHS[@]}"; do
  case "$arch" in
    arm64)
      rust_target="aarch64-apple-darwin"
      ;;
    x86_64)
      rust_target="x86_64-apple-darwin"
      ;;
    *)
      echo "Unsupported macOS architecture: $arch" >&2
      exit 1
      ;;
  esac

  ensure_target "$rust_target"

  echo "Building trix-core for $rust_target ($CONFIGURATION)"
  if [[ -n "$CARGO_RELEASE_FLAG" ]]; then
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      cargo build -p trix-core --lib --manifest-path "$REPO_ROOT/Cargo.toml" --target "$rust_target" "$CARGO_RELEASE_FLAG"
  else
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      cargo build -p trix-core --lib --manifest-path "$REPO_ROOT/Cargo.toml" --target "$rust_target"
  fi

  ARCHIVE_INPUTS+=("$REPO_ROOT/target/$rust_target/$CARGO_PROFILE/libtrix_core.a")
done

if [[ "${#ARCHIVE_INPUTS[@]}" -eq 1 ]]; then
  cp "${ARCHIVE_INPUTS[0]}" "$OUTPUT_PATH"
else
  lipo -create "${ARCHIVE_INPUTS[@]}" -output "$OUTPUT_PATH"
fi

echo "Prepared universal trix-core archive at $OUTPUT_PATH"
