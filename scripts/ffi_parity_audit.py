#!/usr/bin/env python3

from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FFI_RS = ROOT / "crates" / "trix-core" / "src" / "ffi.rs"


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


def collect_usage(callables: list[ExportedCallable]) -> dict[ExportedCallable, dict[str, bool]]:
    platform_text = {platform: load_platform_text(platform) for platform in PLATFORMS}
    usage: dict[ExportedCallable, dict[str, bool]] = {}

    for callable_ in callables:
        usage[callable_] = {}
        compiled = [re.compile(pattern) for pattern in callable_.search_patterns]
        for platform, text in platform_text.items():
            usage[callable_][platform] = any(pattern.search(text) for pattern in compiled)

    return usage


def render_matrix(callables: list[ExportedCallable], usage: dict[ExportedCallable, dict[str, bool]]) -> str:
    label_width = max(len("FFI Symbol"), max(len(callable_.label) for callable_ in callables))
    lines = [
        "Trix FFI Usage Matrix Audit",
        "",
        f"Extracted {len(callables)} exported FFI callables from ffi.rs",
        "",
        f"{'FFI Symbol'.ljust(label_width)}  iOS   macOS Android",
        f"{'-' * label_width}  ----- ----- -------",
    ]

    for callable_ in callables:
        status = usage[callable_]
        lines.append(
            f"{callable_.label.ljust(label_width)}  "
            f"{'✓' if status['ios'] else '·':<5} "
            f"{'✓' if status['macos'] else '·':<5} "
            f"{'✓' if status['android'] else '·':<7}"
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
    usage = collect_usage(callables)
    print(render_matrix(callables, usage))
    print()
    print("Summary")

    total = len(callables)
    used_counts = {
        platform: sum(1 for callable_ in callables if usage[callable_][platform])
        for platform in PLATFORMS
    }
    orphans = [callable_ for callable_ in callables if not any(usage[callable_].values())]
    gaps = [
        callable_
        for callable_ in callables
        if any(usage[callable_].values()) and not all(usage[callable_].values())
    ]

    print(f"Total exported callables: {total}")
    print(f"Used by iOS:             {used_counts['ios']} / {total}")
    print(f"Used by macOS:           {used_counts['macos']} / {total}")
    print(f"Used by Android:         {used_counts['android']} / {total}")
    print(f"Orphaned:                {len(orphans)} / {total}")

    if orphans:
        print()
        print("Orphaned exported callables")
        for callable_ in orphans:
            print(f"  - {callable_.label}")

    if gaps:
        print()
        print("Platform-specific gaps")
        for platform in PLATFORMS:
            missing = [
                callable_.label
                for callable_ in gaps
                if not usage[callable_][platform]
            ]
            if not missing:
                continue
            print(f"  {platform} missing:")
            for label in missing:
                print(f"    - {label}")

    fail_on_orphans = args.strict or args.fail_on_orphans
    fail_on_gaps = args.strict or args.fail_on_gaps
    if fail_on_orphans and orphans:
        return 1
    if fail_on_gaps and gaps:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
