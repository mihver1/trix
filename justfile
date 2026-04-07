# Trix project task runner
# Usage: just <recipe>

set dotenv-load := true
set positional-arguments := true

repo_root := justfile_directory()
version := `cat VERSION | tr -d '[:space:]'`
ios_dir := repo_root / "apps/ios"
macos_dir := repo_root / "apps/macos"
macos_admin_dir := repo_root / "apps/macos-admin"
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
    IFS='.' read -r major minor patch <<< "$current"
    case "{{ level }}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) echo "error: expected major, minor, or patch" >&2; exit 1 ;;
    esac
    next="${major}.${minor}.${patch}"
    echo "$next" > "{{ repo_root }}/VERSION"
    echo "==> $current -> $next"
    just sync-version
    git add -A
    git commit -m "bump version to $next"
    git tag "v$next"
    echo "==> tagged v$next"

# Sync VERSION file into all platform configs
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
    # Android build.gradle.kts
    sed -i '' "s/versionName = \".*\"/versionName = \"$v\"/" "{{ android_gradle }}"
    # Cargo.toml workspace version
    sed -i '' '/\[workspace\.package\]/,/^\[/ s/^version = ".*"/version = "'"$v"'"/' "{{ repo_root }}/Cargo.toml"
    echo "    ios/project.yml"
    echo "    macos/project.yml"
    echo "    macos-admin/project.yml"
    echo "    android/app/build.gradle.kts"
    echo "    Cargo.toml"

# ── TestFlight ────────────────────────────────────────────────

# Build iOS app and upload to TestFlight
ios-testflight build_number="": (_testflight-preflight) sync-version
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_IOS_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_IOS_MARKETING_VERSION="{{ version }}"
    echo "==> iOS TestFlight build v{{ version }} (CURRENT_PROJECT_VERSION=$TRIX_IOS_BUILD_NUMBER)"
    bash "{{ ios_dir }}/scripts/build-testflight.sh" --upload --skip-prechecks

# Build macOS app and upload to TestFlight
macos-testflight build_number="" destination="upload": (_testflight-preflight) sync-version
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_MACOS_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_ASC_DESTINATION="{{ destination }}"
    echo "==> macOS TestFlight build v{{ version }} (CURRENT_PROJECT_VERSION=$TRIX_MACOS_BUILD_NUMBER)"
    bash "{{ macos_dir }}/scripts/archive-testflight.sh"

# Build iOS archive only (no upload)
ios-archive build_number="":
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_IOS_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    echo "==> iOS archive (CURRENT_PROJECT_VERSION=$TRIX_IOS_BUILD_NUMBER)"
    bash "{{ ios_dir }}/scripts/build-testflight.sh" --skip-prechecks

# Build macOS archive only (no upload)
macos-archive build_number="":
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_MACOS_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_SKIP_EXPORT="1"
    echo "==> macOS archive (CURRENT_PROJECT_VERSION=$TRIX_MACOS_BUILD_NUMBER)"
    bash "{{ macos_dir }}/scripts/archive-testflight.sh"

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
xcodegen-all: xcodegen-ios xcodegen-macos xcodegen-macos-admin

# Regenerate iOS Xcode project
xcodegen-ios:
    cd "{{ ios_dir }}" && xcodegen generate

# Regenerate macOS Xcode project
xcodegen-macos:
    cd "{{ macos_dir }}" && xcodegen generate

# Regenerate macOS Admin Xcode project
xcodegen-macos-admin:
    cd "{{ macos_admin_dir }}" && xcodegen generate

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
