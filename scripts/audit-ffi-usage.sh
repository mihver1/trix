#!/usr/bin/env bash
# audit-ffi-usage.sh — Extracts all UniFFI-exported functions/constructors from
# trix-core FFI layer and checks their usage across client platforms.
#
# Usage:  ./scripts/audit-ffi-usage.sh [--verbose]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FFI_RS="$REPO_ROOT/crates/trix-core/src/ffi.rs"

# Client bridge files per platform
IOS_BRIDGE=(
    "$REPO_ROOT/apps/ios/TrixiOS/Bridge/TrixCoreServerBridge.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Bridge/TrixCorePersistentBridge.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Bridge/TrixCoreMessageBridge.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/App/AppModel.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Security/LocalDeviceIdentity.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Features/Chats/MessagingLabView.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Features/Chats/ChatDetailView.swift"
    "$REPO_ROOT/apps/ios/TrixiOS/Features/Home/DashboardView.swift"
)
MACOS_BRIDGE=(
    "$REPO_ROOT/apps/macos/Sources/TrixMac/Bridge/TrixAPIClient.swift"
    "$REPO_ROOT/apps/macos/Sources/TrixMac/Bridge/TrixCoreFFIConversions.swift"
    "$REPO_ROOT/apps/macos/Sources/TrixMac/Bridge/TrixAPIModels.swift"
    "$REPO_ROOT/apps/macos/Sources/TrixMac/Bridge/DeviceIdentity.swift"
    "$REPO_ROOT/apps/macos/Sources/TrixMac/App/AppModel.swift"
    "$REPO_ROOT/apps/macos/Sources/TrixMac/Support/SessionStore.swift"
)
ANDROID_BRIDGE=(
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/auth/AuthBootstrapCoordinator.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/auth/AuthApiClient.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/auth/Ed25519KeyMaterial.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/chat/ChatRepository.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/chat/AttachmentRepository.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/devices/DeviceRepository.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/runtime/RealtimeSessionManager.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/runtime/SyncWorker.kt"
    "$REPO_ROOT/apps/android/app/src/main/java/chat/trix/android/core/system/SystemApiClient.kt"
)

VERBOSE="${1:-}"

# ── Extract FFI method names ──
# We look for pub fn inside #[uniffi::export] impl blocks and standalone ffi_ functions.
# The extraction uses perl for reliable parsing.
extract_ffi_methods() {
    perl -ne '
        # Match: pub fn method_name( or fn ffi_method_name(
        if (/^\s*(?:pub\s+)?fn\s+([a-z_][a-z0-9_]*)\s*[(<]/) {
            my $name = $1;
            # Skip internal helpers
            next if $name =~ /^(from|ffi_error|lock|build_runtime|clone_server_api_client|to_32_bytes)$/;
            next if $name =~ /_(to|from)_(ffi|api|storage)$/;
            next if $name =~ /^(parse_|has_any_|has_persistent_|cleanup_|migrate_|load_legacy|legacy_|cleanup_legacy|remove_dir_|remove_file_|sqlite_path|empty_json|json_to_|aad_json_to|normalize_aad)/;
            next if $name =~ /_helpers_|_round_trip|_match_and_|_sets_ciphersuite/;
            print "$name\n";
        }
    ' "$FFI_RS" | sort -u
}

# Convert Rust snake_case to Swift/Kotlin camelCase for matching
snake_to_camel() {
    local input="$1"
    echo "$input" | perl -pe 's/_([a-z])/uc($1)/ge'
}

# Search for method usage in a set of files
method_used_in() {
    local method="$1"
    shift
    local files=("$@")
    local camel
    camel="$(snake_to_camel "$method")"

    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        if grep -q -E "(\.${camel}\b|\b${camel}\(|\.${method}\b|\b${method}\()" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ── Main ──
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            Trix FFI Usage Matrix Audit                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

methods="$(extract_ffi_methods)"
total="$(echo "$methods" | wc -l | tr -d ' ')"
echo "Extracted $total FFI methods from ffi.rs"
echo ""

printf "%-50s  %-5s %-5s %-7s\n" "FFI Method" "iOS" "macOS" "Android"
printf "%-50s  %-5s %-5s %-7s\n" "$(printf '%0.s─' {1..50})" "─────" "─────" "───────"

ios_count=0
macos_count=0
android_count=0
orphaned_count=0
orphaned_list=""

while IFS= read -r method; do
    ios="·"
    macos="·"
    android="·"
    used=false

    if method_used_in "$method" "${IOS_BRIDGE[@]}"; then
        ios="✓"
        ios_count=$((ios_count + 1))
        used=true
    fi
    if method_used_in "$method" "${MACOS_BRIDGE[@]}"; then
        macos="✓"
        macos_count=$((macos_count + 1))
        used=true
    fi
    if method_used_in "$method" "${ANDROID_BRIDGE[@]}"; then
        android="✓"
        android_count=$((android_count + 1))
        used=true
    fi

    if [ "$used" = false ]; then
        orphaned_count=$((orphaned_count + 1))
        orphaned_list="${orphaned_list}  - ${method}\n"
    fi

    if [ "$VERBOSE" = "--verbose" ] || [ "$used" = false ]; then
        printf "%-50s  %-5s %-5s %-7s\n" "$method" "$ios" "$macos" "$android"
    fi
done <<< "$methods"

echo ""
echo "── Summary ──"
echo "Total FFI methods:     $total"
echo "Used by iOS:           $ios_count / $total"
echo "Used by macOS:         $macos_count / $total"
echo "Used by Android:       $android_count / $total"
echo "Orphaned (no client):  $orphaned_count / $total"

if [ "$orphaned_count" -gt 0 ]; then
    echo ""
    echo "── Orphaned FFI methods (not used by any client) ──"
    echo -e "$orphaned_list"
fi

echo ""
echo "── Platform-specific gaps ──"
echo ""
echo "iOS missing (used by macOS or Android but not iOS):"
while IFS= read -r method; do
    ios_has=false
    others_have=false
    if method_used_in "$method" "${IOS_BRIDGE[@]}"; then ios_has=true; fi
    if method_used_in "$method" "${MACOS_BRIDGE[@]}" || method_used_in "$method" "${ANDROID_BRIDGE[@]}"; then others_have=true; fi
    if [ "$ios_has" = false ] && [ "$others_have" = true ]; then
        printf "  - %s\n" "$method"
    fi
done <<< "$methods"

echo ""
echo "macOS missing (used by iOS or Android but not macOS):"
while IFS= read -r method; do
    macos_has=false
    others_have=false
    if method_used_in "$method" "${MACOS_BRIDGE[@]}"; then macos_has=true; fi
    if method_used_in "$method" "${IOS_BRIDGE[@]}" || method_used_in "$method" "${ANDROID_BRIDGE[@]}"; then others_have=true; fi
    if [ "$macos_has" = false ] && [ "$others_have" = true ]; then
        printf "  - %s\n" "$method"
    fi
done <<< "$methods"

echo ""
echo "Android missing (used by iOS or macOS but not Android):"
while IFS= read -r method; do
    android_has=false
    others_have=false
    if method_used_in "$method" "${ANDROID_BRIDGE[@]}"; then android_has=true; fi
    if method_used_in "$method" "${IOS_BRIDGE[@]}" || method_used_in "$method" "${MACOS_BRIDGE[@]}"; then others_have=true; fi
    if [ "$android_has" = false ] && [ "$others_have" = true ]; then
        printf "  - %s\n" "$method"
    fi
done <<< "$methods"
