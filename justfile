# Trix project task runner
# Usage: just <recipe>

set dotenv-load := true
set positional-arguments := true

repo_root := justfile_directory()
version_file := repo_root / "version.conf"
version := `awk -F= '/^[[:space:]]*VERSION[[:space:]]*=/{gsub(/[[:space:]"]/, "", $2); print $2; found=1; exit} END{if(!found) exit 1}' version.conf`
ios_dir := repo_root / "apps/ios"
macos_dir := repo_root / "apps/macos"
macos_admin_dir := repo_root / "apps/macos-admin"
trix_apple_dir := repo_root / "apple"
trix_ios_derived_data := "/tmp/trix-ios-dd"
trix_macos_derived_data := "/tmp/trix-macos-dd"
trix_app_bundle_id := "com.softgrid.trixapp"
android_gradle := repo_root / "apps/android/app/build.gradle.kts"

# ── Versioning ────────────────────────────────────────────────

# Show current version
version:
    @echo "{{ version }}"

# Bump version: just bump major|minor|patch
bump level:
    #!/usr/bin/env bash
    set -euo pipefail
    current="{{ version }}"
    version_file="{{ version_file }}"

    IFS='.' read -r major minor patch <<< "$current"
    if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]] ||
       [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
      echo "error: VERSION in $version_file must be semver-like MAJOR.MINOR.PATCH, got '$current'" >&2
      exit 1
    fi

    case "{{ level }}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) echo "error: expected major, minor, or patch" >&2; exit 1 ;;
    esac
    next="${major}.${minor}.${patch}"
    if grep -qE '^[[:space:]]*VERSION[[:space:]]*=' "$version_file"; then
      sed -i '' -E "s/^[[:space:]]*VERSION[[:space:]]*=.*/VERSION=$next/" "$version_file"
    else
      printf '\nVERSION=%s\n' "$next" >> "$version_file"
    fi
    echo "==> $current -> $next"
    just sync-version
    git add -A
    git commit -m "bump version to $next"
    git tag "v$next"
    echo "==> tagged v$next"

# Sync version.conf into all platform configs
sync-version:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{ version }}"
    echo "==> syncing version $v to all platforms"
    # iOS project.yml
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $v/" "{{ ios_dir }}/project.yml"
    # macOS project.yml
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $v/" "{{ macos_dir }}/project.yml"
    # macOS Admin project.yml
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $v/" "{{ macos_admin_dir }}/project.yml"
    # XMPP Apple project.yml
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $v/" "{{ trix_apple_dir }}/project.yml"
    # Android build.gradle.kts
    sed -i '' "s/versionName = \".*\"/versionName = \"$v\"/" "{{ android_gradle }}"
    # Cargo.toml workspace version
    sed -i '' '/\[workspace\.package\]/,/^\[/ s/^version = ".*"/version = "'"$v"'"/' "{{ repo_root }}/Cargo.toml"
    echo "    ios/project.yml"
    echo "    macos/project.yml"
    echo "    macos-admin/project.yml"
    echo "    apple/project.yml"
    echo "    android/app/build.gradle.kts"
    echo "    Cargo.toml"

# ── TestFlight ────────────────────────────────────────────────

# Build iOS app and upload to TestFlight
ios-testflight build_number="": (_testflight-preflight) sync-version
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    export TRIX_ASC_DESTINATION="upload"
    echo "==> XMPP Trix iOS TestFlight build v{{ version }} (CURRENT_PROJECT_VERSION=$TRIX_APPLE_BUILD_NUMBER)"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform ios

# Build macOS app and upload to TestFlight
macos-testflight build_number="" destination="upload": (_testflight-preflight) sync-version
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    export TRIX_ASC_DESTINATION="{{ destination }}"
    echo "==> XMPP Trix macOS TestFlight build v{{ version }} (CURRENT_PROJECT_VERSION=$TRIX_APPLE_BUILD_NUMBER)"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform macos

# Build iOS archive only (no upload)
ios-archive build_number="":
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    echo "==> XMPP Trix iOS archive (CURRENT_PROJECT_VERSION=$TRIX_APPLE_BUILD_NUMBER)"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform ios --unsigned-archive

# Build macOS archive only (no upload)
macos-archive build_number="":
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    echo "==> XMPP Trix macOS archive (CURRENT_PROJECT_VERSION=$TRIX_APPLE_BUILD_NUMBER)"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform macos --unsigned-archive

# Build macOS beta .app bundle (direct, not App Store)
macos-beta:
    bash "{{ macos_dir }}/scripts/build-beta.sh"

# Validate an existing iOS IPA against App Store Connect
ios-validate ipa_path:
    bash "{{ ios_dir }}/scripts/build-testflight.sh" --ipa "{{ ipa_path }}" --validate

# Upload an existing iOS IPA to TestFlight
ios-upload ipa_path:
    bash "{{ ios_dir }}/scripts/build-testflight.sh" --ipa "{{ ipa_path }}" --upload

_testflight-preflight:
    @command -v xcodebuild >/dev/null || (echo "error: xcodebuild not found" >&2 && exit 1)
    @command -v cargo >/dev/null || (echo "error: cargo not found" >&2 && exit 1)
    @command -v xcodegen >/dev/null || (echo "error: xcodegen not found" >&2 && exit 1)

# ── Build ─────────────────────────────────────────────────────

# Run cargo check + contract checks
check:
    make -C "{{ repo_root }}" check

# Run contract checks only (FFI surface, API JSON, OpenAPI, UniFFI bindings)
contract-check:
    make -C "{{ repo_root }}" contract-check

# Build trix-core Rust library
build-core:
    cargo build -p trix-core --lib

# Build trix-core in release mode
build-core-release:
    cargo build -p trix-core --lib --release

# Build universal macOS trix-core (arm64 + x86_64)
build-core-universal:
    bash "{{ macos_dir }}/scripts/build-trix-core-universal.sh"

# Run the backend server (trixd)
run-server:
    cargo run -p trixd

# Build the XMPP Trix iOS app for a simulator; signing: automatic|unsigned
trix-ios-build signing="automatic" simulator="iPhone 17": xcodegen-trix-apple
    #!/usr/bin/env bash
    set -euo pipefail
    signing="{{ signing }}"
    simulator="{{ simulator }}"
    build_args=(
      -project "{{ trix_apple_dir }}/TrixMatrix.xcodeproj"
      -scheme TrixMatrixiOS
      -destination "platform=iOS Simulator,name=$simulator"
      -derivedDataPath "{{ trix_ios_derived_data }}"
      build
    )
    case "$signing" in
      automatic) ;;
      unsigned) build_args+=(CODE_SIGNING_ALLOWED=NO) ;;
      *) echo "error: signing must be automatic or unsigned" >&2; exit 1 ;;
    esac
    echo "==> building Trix iOS app for $simulator (signing=$signing)"
    xcodebuild "${build_args[@]}"

# Build, install, and launch the XMPP Trix iOS app in a simulator; signing: automatic|unsigned
trix-ios-run signing="automatic" simulator="iPhone 17":
    #!/usr/bin/env bash
    set -euo pipefail
    simulator="{{ simulator }}"
    just --justfile "{{ repo_root }}/justfile" trix-ios-build "{{ signing }}" "$simulator"
    app="{{ trix_ios_derived_data }}/Build/Products/Debug-iphonesimulator/Trix.app"
    if [[ ! -d "$app" ]]; then
      echo "error: built app not found at $app" >&2
      exit 1
    fi
    echo "==> booting $simulator"
    xcrun simctl boot "$simulator" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator" -b
    echo "==> installing $app"
    xcrun simctl install "$simulator" "$app"
    echo "==> launching {{ trix_app_bundle_id }} on $simulator"
    xcrun simctl launch --terminate-running-process "$simulator" "{{ trix_app_bundle_id }}"

# Build the XMPP Trix macOS app; signing: automatic|unsigned
trix-macos-build signing="automatic": xcodegen-trix-apple
    #!/usr/bin/env bash
    set -euo pipefail
    signing="{{ signing }}"
    derived_data="{{ trix_macos_derived_data }}"
    build_args=(
      -project "{{ trix_apple_dir }}/TrixMatrix.xcodeproj"
      -scheme TrixMatrixMac
      -destination 'platform=macOS'
      -derivedDataPath "$derived_data"
      build
    )
    case "$signing" in
      automatic) ;;
      unsigned) build_args+=(CODE_SIGNING_ALLOWED=NO) ;;
      *) echo "error: signing must be automatic or unsigned" >&2; exit 1 ;;
    esac
    rm -rf \
      "$derived_data/Build/Intermediates.noindex" \
      "$derived_data/ModuleCache.noindex" \
      "$derived_data/SDKStatCaches.noindex"
    echo "==> building Trix macOS app (signing=$signing)"
    xcodebuild "${build_args[@]}"

# Build and launch the XMPP Trix macOS app; signing: automatic|unsigned
trix-macos-run signing="automatic":
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{ repo_root }}/justfile" trix-macos-build "{{ signing }}"
    app="{{ trix_macos_derived_data }}/Build/Products/Debug/Trix.app"
    if [[ ! -d "$app" ]]; then
      echo "error: built app not found at $app" >&2
      exit 1
    fi
    echo "==> launching $app"
    open "$app"

# Compatibility lanes for callers that still use the previous Matrix names.
matrix-ios-build signing="automatic" simulator="iPhone 17":
    just --justfile "{{ repo_root }}/justfile" trix-ios-build "{{ signing }}" "{{ simulator }}"

matrix-ios-run signing="automatic" simulator="iPhone 17":
    just --justfile "{{ repo_root }}/justfile" trix-ios-run "{{ signing }}" "{{ simulator }}"

matrix-macos-build signing="automatic":
    just --justfile "{{ repo_root }}/justfile" trix-macos-build "{{ signing }}"

matrix-macos-run signing="automatic":
    just --justfile "{{ repo_root }}/justfile" trix-macos-run "{{ signing }}"

# ── Code generation ───────────────────────────────────────────

# Generate UniFFI Swift + Kotlin bindings
ffi-bindings:
    make -C "{{ repo_root }}" ffi-bindings

# Generate UniFFI Swift bindings only
ffi-bindings-swift:
    make -C "{{ repo_root }}" ffi-bindings-swift

# Generate UniFFI Kotlin bindings only
ffi-bindings-kotlin:
    make -C "{{ repo_root }}" ffi-bindings-kotlin

# Regenerate iOS UniFFI bridge
ios-bridge:
    bash "{{ ios_dir }}/scripts/generate-trix-core-bridge.sh"

# Regenerate macOS UniFFI bridge
macos-bridge:
    bash "{{ macos_dir }}/scripts/generate-trix-core-bridge.sh"

# Generate localized strings from shared YAML catalog
strings:
    ruby scripts/generate_strings.rb

# ── Xcode project generation ─────────────────────────────────

# Regenerate all Xcode projects via XcodeGen
xcodegen-all: xcodegen-ios xcodegen-macos xcodegen-macos-admin xcodegen-trix-apple

# Regenerate iOS Xcode project
xcodegen-ios:
    cd "{{ ios_dir }}" && xcodegen generate

# Regenerate macOS Xcode project
xcodegen-macos:
    cd "{{ macos_dir }}" && xcodegen generate

# Regenerate macOS Admin Xcode project
xcodegen-macos-admin:
    cd "{{ macos_admin_dir }}" && xcodegen generate

# Regenerate XMPP Trix Apple Xcode project
xcodegen-trix-apple:
    cd "{{ trix_apple_dir }}" && xcodegen generate

# Compatibility lane for callers that still use the previous Matrix name.
xcodegen-matrix-apple: xcodegen-trix-apple

# ── Formatting & linting ─────────────────────────────────────

# Format Rust code
fmt:
    cargo fmt --all

# Check Rust formatting without modifying
fmt-check:
    cargo fmt --all -- --check

# Run FFI parity audit
ffi-audit:
    python3 scripts/ffi_parity_audit.py --strict

# ── Info ──────────────────────────────────────────────────────

# List available recipes
[private]
default:
    @just --list
