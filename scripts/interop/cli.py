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


def default_participant_drivers() -> dict[str, InteropDriver]:
    """Map logical participants used by built-in scenarios to stub platform drivers."""
    return {
        "ios-owner": create_ios_driver(),
        "android-peer": create_android_driver(),
        "macos-peer": create_macos_driver(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m scripts.interop.cli")
    parser.add_argument(
        "--suite",
        required=True,
        choices=["interop-seeded", "interop-cross", "interop-full"],
        help="Which interop scenario suite to run.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Directory for scenario.json and step-results.json evidence.",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Invoke driver cleanup() hooks after the run.",
    )
    ns = parser.parse_args(argv)
    suite = resolve_suite(ns.suite)
    scenario_label = build_scenario_label(ns.suite)
    drivers = default_participant_drivers()
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


if __name__ == "__main__":
    sys.exit(main())
