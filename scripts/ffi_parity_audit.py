#!/usr/bin/env python3

from __future__ import annotations

import argparse
import dataclasses
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FFI_RS = ROOT / "crates" / "trix-core" / "src" / "ffi.rs"
CONTRACT_CONFIG = ROOT / "contracts" / "ffi-usage-contract.json"


@dataclasses.dataclass(frozen=True)
class ExportedCallable:
    owner: str | None
    name: str
    kind: str

    @property
    def label(self) -> str:
        if self.owner is None:
            return self.name
        return f"{self.owner}.{self.name}"

    @property
    def camel_name(self) -> str:
        parts = self.name.split("_")
        return parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])

    @property
    def search_patterns(self) -> tuple[str, ...]:
        if self.owner is None:
            return (
                rf"\b{re.escape(self.camel_name)}\s*\(",
            )

        if self.kind == "constructor" and self.name == "new":
            return (
                rf"\b{re.escape(self.owner)}\s*\(",
            )

        if self.kind == "constructor":
            return (
                rf"\b{re.escape(self.owner)}\s*\.\s*{re.escape(self.camel_name)}\s*\(",
            )

        return (
            rf"\.\s*{re.escape(self.camel_name)}\s*\(",
        )


PLATFORMS: dict[str, dict[str, object]] = {
    "ios": {
        "root": ROOT / "apps" / "ios" / "TrixiOS",
        "suffixes": {".swift"},
        "ignore": ("/Bridge/Generated/",),
    },
    "macos": {
        "root": ROOT / "apps" / "macos" / "Sources" / "TrixMac",
        "suffixes": {".swift"},
        "ignore": ("/Generated/",),
    },
    "android": {
        "root": ROOT / "apps" / "android" / "app" / "src" / "main" / "java" / "chat" / "trix" / "android",
        "suffixes": {".kt", ".java"},
        "ignore": ("/core/ffi/",),
    },
}


# Some low-level FFI exports are implementation details of higher-level exported
# control flows. If a client uses the higher-level binding, the lower-level
# binding should not be flagged as a parity gap for that platform.
TRANSITIVE_COVERAGE: dict[str, tuple[str, ...]] = {
    "ffi_account_bootstrap_payload": (
        "FfiAccountRootMaterial.account_bootstrap_payload",
    ),
    "ffi_prepare_attachment_upload": (
        "FfiServerApiClient.upload_attachment",
    ),
    "ffi_build_attachment_message_body": (
        "FfiServerApiClient.upload_attachment",
    ),
    "ffi_decrypt_attachment_payload": (
        "FfiServerApiClient.download_attachment",
    ),
    "ffi_device_revoke_payload": (
        "FfiServerApiClient.revoke_device_with_account_root",
    ),
    "FfiServerApiClient.create_chat": (
        "FfiSyncCoordinator.create_chat_control",
    ),
    "FfiServerApiClient.create_message": (
        "FfiSyncCoordinator.send_message_body",
    ),
    "FfiServerApiClient.add_chat_members": (
        "FfiSyncCoordinator.add_chat_members_control",
    ),
    "FfiServerApiClient.remove_chat_members": (
        "FfiSyncCoordinator.remove_chat_members_control",
    ),
    "FfiServerApiClient.add_chat_devices": (
        "FfiSyncCoordinator.add_chat_devices_control",
    ),
    "FfiServerApiClient.remove_chat_devices": (
        "FfiSyncCoordinator.remove_chat_devices_control",
    ),
    "FfiServerApiClient.reserve_key_packages": (
        "FfiSyncCoordinator.create_chat_control",
        "FfiSyncCoordinator.add_chat_devices_control",
    ),
    "FfiServerApiClient.get_account_key_packages": (
        "FfiSyncCoordinator.create_chat_control",
        "FfiSyncCoordinator.add_chat_members_control",
    ),
    "FfiServerApiClient.create_blob_upload": (
        "FfiServerApiClient.upload_attachment",
    ),
    "FfiServerApiClient.upload_blob": (
        "FfiServerApiClient.upload_attachment",
    ),
    "FfiServerApiClient.head_blob": (
        "FfiServerApiClient.upload_attachment",
    ),
    "FfiServerApiClient.download_blob": (
        "FfiServerApiClient.download_attachment",
    ),
    "FfiServerWebSocketClient.next_frame": (
        "FfiRealtimeDriver.next_websocket_event",
    ),
    "FfiServerWebSocketClient.send_ack": (
        "FfiRealtimeDriver.next_websocket_event",
    ),
    "FfiRealtimeDriver.process_websocket_frame": (
        "FfiRealtimeDriver.next_websocket_event",
    ),
    "FfiAccountRootMaterial.sign_account_bootstrap": (
        "FfiServerApiClient.create_account_with_materials",
        "FfiServerApiClient.approve_device_with_account_root",
    ),
    "FfiAccountRootMaterial.device_revoke_payload": (
        "FfiServerApiClient.revoke_device_with_account_root",
    ),
    "FfiAccountRootMaterial.sign_device_revoke": (
        "FfiServerApiClient.revoke_device_with_account_root",
    ),
    "FfiDeviceKeyMaterial.sign_auth_challenge": (
        "FfiServerApiClient.authenticate_with_device_key",
    ),
    "FfiMlsFacade.create_group": (
        "FfiSyncCoordinator.create_chat_control",
    ),
    "FfiMlsFacade.add_members": (
        "FfiSyncCoordinator.create_chat_control",
        "FfiSyncCoordinator.add_chat_members_control",
        "FfiSyncCoordinator.add_chat_devices_control",
    ),
    "FfiMlsFacade.remove_members": (
        "FfiSyncCoordinator.remove_chat_members_control",
        "FfiSyncCoordinator.remove_chat_devices_control",
    ),
    "FfiMlsFacade.generate_key_package": (
        "FfiMlsFacade.generate_publish_key_packages",
    ),
    "FfiMlsFacade.generate_key_packages": (
        "FfiMlsFacade.generate_publish_key_packages",
    ),
    "FfiMlsFacade.create_application_message": (
        "FfiSyncCoordinator.send_message_body",
    ),
    "FfiLocalHistoryStore.apply_chat_list": (
        "FfiSyncCoordinator.sync_chat_histories_into_store",
    ),
    "FfiLocalHistoryStore.apply_chat_history": (
        "FfiSyncCoordinator.sync_chat_histories_into_store",
        "FfiSyncCoordinator.create_chat_control",
        "FfiSyncCoordinator.add_chat_members_control",
        "FfiSyncCoordinator.remove_chat_members_control",
        "FfiSyncCoordinator.add_chat_devices_control",
        "FfiSyncCoordinator.remove_chat_devices_control",
    ),
    "FfiLocalHistoryStore.set_chat_mls_group_id": (
        "FfiSyncCoordinator.create_chat_control",
        "FfiLocalHistoryStore.project_chat_with_facade",
    ),
    "FfiLocalHistoryStore.apply_projected_messages": (
        "FfiSyncCoordinator.create_chat_control",
        "FfiSyncCoordinator.add_chat_members_control",
        "FfiSyncCoordinator.remove_chat_members_control",
        "FfiSyncCoordinator.add_chat_devices_control",
        "FfiSyncCoordinator.remove_chat_devices_control",
        "FfiLocalHistoryStore.project_chat_with_facade",
    ),
    "FfiMlsFacade.join_group_from_welcome": (
        "FfiLocalHistoryStore.project_chat_with_facade",
    ),
    "FfiMlsFacade.process_message": (
        "FfiLocalHistoryStore.project_chat_messages",
        "FfiLocalHistoryStore.project_chat_with_facade",
    ),
    "FfiMlsConversation.group_id": (
        "FfiLocalHistoryStore.project_chat_with_facade",
    ),
    "FfiMlsConversation.epoch": (
        "FfiSyncCoordinator.send_message_body",
    ),
    "FfiLocalHistoryStore.new_persistent": (
        "FfiClientStore.open",
    ),
    "FfiLocalHistoryStore.new_encrypted": (
        "FfiClientStore.open",
    ),
    "FfiSyncCoordinator.new_persistent": (
        "FfiClientStore.open",
    ),
    "FfiSyncCoordinator.new_encrypted": (
        "FfiClientStore.open",
    ),
    "FfiMlsFacade.storage_root": (
        "FfiClientStore.mls_storage_root",
    ),
}


def empty_contract_config() -> dict[str, object]:
    return {
        "allowed_orphans": set(),
        "allowed_platform_gaps": {platform: set() for platform in PLATFORMS},
    }


def normalize_contract_config(payload: dict[str, object] | None) -> dict[str, object]:
    config = empty_contract_config()
    if payload is None:
        return config

    allowed_orphans = payload.get("allowed_orphans") or []
    if not isinstance(allowed_orphans, list):
        raise ValueError("allowed_orphans must be a JSON array.")
    config["allowed_orphans"] = {str(label) for label in allowed_orphans}

    allowed_platform_gaps = payload.get("allowed_platform_gaps") or {}
    if not isinstance(allowed_platform_gaps, dict):
        raise ValueError("allowed_platform_gaps must be a JSON object.")

    normalized_platform_gaps: dict[str, set[str]] = {platform: set() for platform in PLATFORMS}
    for platform, labels in allowed_platform_gaps.items():
        if platform not in PLATFORMS:
            raise ValueError(f"unknown platform in allowed_platform_gaps: {platform}")
        if not isinstance(labels, list):
            raise ValueError(f"allowed_platform_gaps.{platform} must be a JSON array.")
        normalized_platform_gaps[platform] = {str(label) for label in labels}
    config["allowed_platform_gaps"] = normalized_platform_gaps
    return config


def load_contract_config() -> dict[str, object]:
    if not CONTRACT_CONFIG.exists():
        return empty_contract_config()
    payload = json.loads(CONTRACT_CONFIG.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{CONTRACT_CONFIG} must contain a JSON object.")
    return normalize_contract_config(payload)


def validate_contract_config(
    contract: dict[str, object],
    known_labels: set[str],
) -> list[str]:
    errors: list[str] = []

    allowed_orphans: set[str] = contract["allowed_orphans"]  # type: ignore[assignment]
    for label in sorted(allowed_orphans - known_labels):
        errors.append(f"allowed_orphans references unknown FFI symbol: {label}")

    allowed_platform_gaps: dict[str, set[str]] = contract["allowed_platform_gaps"]  # type: ignore[assignment]
    for platform, labels in allowed_platform_gaps.items():
        for label in sorted(labels - known_labels):
            errors.append(
                f"allowed_platform_gaps.{platform} references unknown FFI symbol: {label}"
            )

    return errors


def filter_contract_issues(
    orphan_labels: list[str],
    gap_labels_by_platform: dict[str, list[str]],
    contract: dict[str, object],
) -> tuple[list[str], dict[str, list[str]]]:
    allowed_orphans: set[str] = contract["allowed_orphans"]  # type: ignore[assignment]
    allowed_platform_gaps: dict[str, set[str]] = contract["allowed_platform_gaps"]  # type: ignore[assignment]

    remaining_orphans = [label for label in orphan_labels if label not in allowed_orphans]
    remaining_gaps = {
        platform: [
            label
            for label in labels
            if label not in allowed_platform_gaps[platform]
        ]
        for platform, labels in gap_labels_by_platform.items()
    }
    return remaining_orphans, remaining_gaps


def parse_ffi_exports() -> list[ExportedCallable]:
    lines = FFI_RS.read_text().splitlines()
    callables: list[ExportedCallable] = []
    awaiting_export = False
    current_owner: str | None = None
    current_brace_depth = 0
    next_is_constructor = False

    for line in lines:
        stripped = line.strip()

        if stripped == "#[uniffi::export]":
            awaiting_export = True
            continue

        if current_owner is not None:
            if stripped == "#[uniffi::constructor]":
                next_is_constructor = True
                continue

            method_match = re.match(r"pub fn\s+([A-Za-z0-9_]+)\s*\(", stripped)
            if method_match:
                callables.append(
                    ExportedCallable(
                        owner=current_owner,
                        name=method_match.group(1),
                        kind="constructor" if next_is_constructor else "method",
                    )
                )
                next_is_constructor = False

            current_brace_depth += line.count("{") - line.count("}")
            if current_brace_depth <= 0:
                current_owner = None
                current_brace_depth = 0
                next_is_constructor = False
            continue

        if not awaiting_export:
            continue

        function_match = re.match(r"fn\s+([A-Za-z0-9_]+)\s*\(", stripped)
        if function_match:
            callables.append(
                ExportedCallable(
                    owner=None,
                    name=function_match.group(1),
                    kind="function",
                )
            )
            awaiting_export = False
            continue

        impl_match = re.match(r"impl\s+([A-Za-z0-9_]+)\s*\{?", stripped)
        if impl_match:
            current_owner = impl_match.group(1)
            current_brace_depth = line.count("{") - line.count("}")
            awaiting_export = False
            next_is_constructor = False
            continue

        awaiting_export = False

    return callables


def load_platform_text(platform: str) -> str:
    config = PLATFORMS[platform]
    root = config["root"]
    suffixes = config["suffixes"]
    ignore = config["ignore"]
    chunks: list[str] = []

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() not in suffixes:
            continue
        posix = path.as_posix()
        if any(fragment in posix for fragment in ignore):
            continue
        chunks.append(path.read_text())

    return "\n".join(chunks)


def collect_usage(callables: list[ExportedCallable]) -> dict[ExportedCallable, dict[str, str]]:
    platform_text = {platform: load_platform_text(platform) for platform in PLATFORMS}
    usage: dict[ExportedCallable, dict[str, str]] = {}

    for callable_ in callables:
        usage[callable_] = {}
        compiled = [re.compile(pattern) for pattern in callable_.search_patterns]
        for platform, text in platform_text.items():
            usage[callable_][platform] = (
                "direct" if any(pattern.search(text) for pattern in compiled) else "none"
            )

    label_to_callable = {callable_.label: callable_ for callable_ in callables}
    changed = True
    while changed:
        changed = False
        for target_label, coverer_labels in TRANSITIVE_COVERAGE.items():
            target = label_to_callable.get(target_label)
            if target is None:
                continue

            coverers = [label_to_callable[label] for label in coverer_labels if label in label_to_callable]
            if not coverers:
                continue

            for platform in PLATFORMS:
                if usage[target][platform] != "none":
                    continue
                if any(usage[coverer][platform] != "none" for coverer in coverers):
                    usage[target][platform] = "derived"
                    changed = True

    return usage


def render_matrix(callables: list[ExportedCallable], usage: dict[ExportedCallable, dict[str, str]]) -> str:
    label_width = max(len("FFI Symbol"), max(len(callable_.label) for callable_ in callables))
    lines = [
        "Trix FFI Usage Matrix Audit",
        "",
        f"Extracted {len(callables)} exported FFI callables from ffi.rs",
        "Legend: \u2713 direct usage, ~ covered by higher-level FFI binding, \u00b7 unused",
        "",
        f"{'FFI Symbol'.ljust(label_width)}  iOS   macOS Android",
        f"{'-' * label_width}  ----- ----- -------",
    ]

    for callable_ in callables:
        status = usage[callable_]
        lines.append(
            f"{callable_.label.ljust(label_width)}  "
            f"{('✓' if status['ios'] == 'direct' else '~' if status['ios'] == 'derived' else '·'):<5} "
            f"{('✓' if status['macos'] == 'direct' else '~' if status['macos'] == 'derived' else '·'):<5} "
            f"{('✓' if status['android'] == 'direct' else '~' if status['android'] == 'derived' else '·'):<7}"
        )

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit platform usage of exported trix-core FFI callables.")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero when any orphaned callable or platform gap is found.",
    )
    parser.add_argument(
        "--fail-on-orphans",
        action="store_true",
        help="Exit non-zero when any exported callable is unused by every client.",
    )
    parser.add_argument(
        "--fail-on-gaps",
        action="store_true",
        help="Exit non-zero when a callable is used by some client platforms but not all.",
    )
    args = parser.parse_args()

    callables = parse_ffi_exports()
    known_labels = {callable_.label for callable_ in callables}
    try:
        contract = load_contract_config()
    except ValueError as exc:
        print(f"error: invalid FFI contract config: {exc}", file=sys.stderr)
        return 1
    contract_errors = validate_contract_config(contract, known_labels)
    if contract_errors:
        print("error: FFI contract config contains stale or invalid labels:", file=sys.stderr)
        for error in contract_errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    usage = collect_usage(callables)
    print(render_matrix(callables, usage))
    print()
    print("Summary")

    total = len(callables)
    used_counts = {
        platform: sum(1 for callable_ in callables if usage[callable_][platform] != "none")
        for platform in PLATFORMS
    }
    direct_counts = {
        platform: sum(1 for callable_ in callables if usage[callable_][platform] == "direct")
        for platform in PLATFORMS
    }
    derived_counts = {
        platform: sum(1 for callable_ in callables if usage[callable_][platform] == "derived")
        for platform in PLATFORMS
    }
    orphans = [callable_ for callable_ in callables if not any(usage[callable_][platform] != "none" for platform in PLATFORMS)]
    gaps = [
        callable_
        for callable_ in callables
        if any(usage[callable_][platform] != "none" for platform in PLATFORMS)
        and not all(usage[callable_][platform] != "none" for platform in PLATFORMS)
    ]
    orphan_labels = [callable_.label for callable_ in orphans]
    gap_labels_by_platform = {
        platform: [
            callable_.label
            for callable_ in gaps
            if usage[callable_][platform] == "none"
        ]
        for platform in PLATFORMS
    }
    contract_orphans, contract_gap_labels_by_platform = filter_contract_issues(
        orphan_labels,
        gap_labels_by_platform,
        contract,
    )

    print(f"Total exported callables: {total}")
    print(f"Used by iOS:             {used_counts['ios']} / {total}")
    print(f"Used by macOS:           {used_counts['macos']} / {total}")
    print(f"Used by Android:         {used_counts['android']} / {total}")
    print(
        "Transitive-only usage:   "
        f"iOS {derived_counts['ios']}, macOS {derived_counts['macos']}, Android {derived_counts['android']}"
    )
    print(
        "Direct usage only:       "
        f"iOS {direct_counts['ios']}, macOS {direct_counts['macos']}, Android {direct_counts['android']}"
    )
    print(f"Orphaned:                {len(orphans)} / {total}")
    print(f"Contract orphans:        {len(contract_orphans)}")
    print(
        "Contract gaps:           "
        f"iOS {len(contract_gap_labels_by_platform['ios'])}, "
        f"macOS {len(contract_gap_labels_by_platform['macos'])}, "
        f"Android {len(contract_gap_labels_by_platform['android'])}"
    )

    if orphans:
        print()
        print("Orphaned exported callables")
        for callable_ in orphans:
            print(f"  - {callable_.label}")

    if gaps:
        print()
        print("Platform-specific gaps")
        for platform in PLATFORMS:
            missing = gap_labels_by_platform[platform]
            if not missing:
                continue
            print(f"  {platform} missing:")
            for label in missing:
                print(f"    - {label}")

    fail_on_orphans = args.strict or args.fail_on_orphans
    fail_on_gaps = args.strict or args.fail_on_gaps
    if fail_on_orphans and contract_orphans:
        return 1
    if fail_on_gaps and any(contract_gap_labels_by_platform[platform] for platform in PLATFORMS):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
