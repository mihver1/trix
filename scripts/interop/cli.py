from __future__ import annotations

import argparse
import sys
from pathlib import Path

from scripts.interop.contracts import build_scenario_label
from scripts.interop.platforms.android_driver import create_android_driver
from scripts.interop.platforms.ios_driver import create_ios_driver
from scripts.interop.platforms.macos_driver import create_macos_driver
from scripts.interop.platforms.base import InteropDriver
from scripts.interop.runner import (
    CapabilityGateError,
    MissingDriverError,
    run_steps_with_driver_map,
)
from scripts.interop.scenarios import (
    build_interop_cross_suite,
    build_interop_full_suite,
    build_interop_seeded_suite,
)

# Stable exit codes: 0 success, 2 failed step outcome, 3 harness/driver not ready.
_EXIT_HARNESS_ERROR = 3


def resolve_suite(name: str):
    if name == "interop-seeded":
        return build_interop_seeded_suite()
    if name == "interop-cross":
        return build_interop_cross_suite()
    if name == "interop-full":
        return build_interop_full_suite()
    raise ValueError(f"Unknown suite: {name!r}")


def default_participant_drivers(
    *,
    base_url: str | None,
    ios_destination: str | None,
) -> dict[str, InteropDriver]:
    """Map logical participants used by built-in scenarios to platform drivers."""
    return {
        "ios-owner": create_ios_driver(
            base_url=base_url,
            ios_destination=ios_destination,
        ),
        "android-peer": create_android_driver(base_url=base_url),
        "macos-peer": create_macos_driver(base_url=base_url),
    }


def _cmd_run(ns: argparse.Namespace) -> int:
    suite = resolve_suite(ns.suite)
    scenario_label = build_scenario_label(ns.suite)
    drivers = default_participant_drivers(
        base_url=ns.base_url,
        ios_destination=ns.ios_destination,
    )
    result = None
    try:
        try:
            result = run_steps_with_driver_map(
                suite,
                drivers,
                output_dir=ns.output_dir,
                reset=ns.reset,
                scenario_label=scenario_label,
            )
        except CapabilityGateError as exc:
            print(f"interop: capability gate failed: {exc}", file=sys.stderr)
            return _EXIT_HARNESS_ERROR
        except MissingDriverError as exc:
            print(f"interop: missing driver: {exc}", file=sys.stderr)
            return _EXIT_HARNESS_ERROR
        except NotImplementedError as exc:
            print(f"interop: driver not implemented: {exc}", file=sys.stderr)
            return _EXIT_HARNESS_ERROR
    finally:
        for driver in drivers.values():
            driver.shutdown()
    if result is None:
        return _EXIT_HARNESS_ERROR
    return 0 if result.ok else 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m scripts.interop.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    run_p = sub.add_parser("run", help="Run an interop scenario suite.")
    run_p.add_argument(
        "--suite",
        required=True,
        choices=["interop-seeded", "interop-cross", "interop-full"],
        help="Which interop scenario suite to run.",
    )
    run_p.add_argument(
        "--output-dir",
        type=Path,
        default=Path("interop-evidence"),
        help="Directory for scenario.json and step-results.json evidence.",
    )
    run_p.add_argument(
        "--base-url",
        default="http://127.0.0.1:8080",
        help="Trix backend base URL (used for health checks and bootstraps).",
    )
    run_p.add_argument(
        "--ios-destination",
        default=None,
        help="Optional xcodebuild destination string for the iOS driver.",
    )
    run_p.add_argument(
        "--reset",
        action="store_true",
        help="Invoke driver cleanup() hooks after the full run completes.",
    )
    ns = parser.parse_args(argv)
    return _cmd_run(ns)


if __name__ == "__main__":
    sys.exit(main())
