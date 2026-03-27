from __future__ import annotations

from typing import Any, Mapping, Protocol, runtime_checkable

from scripts.interop.contracts import DriverCapability, DriverResult, InteropAction

# Stubs use a wildcard so CLI/scaffold clears capability gating; `perform` still raises
# `NotImplementedError` until real host wiring exists.
STUB_DRIVER_SUPPORTS_ACTIONS: tuple[str, ...] = ("*",)


def stub_driver_capabilities(platform: str) -> DriverCapability:
    return DriverCapability(platform=platform, supports_actions=STUB_DRIVER_SUPPORTS_ACTIONS)


@runtime_checkable
class InteropDriver(Protocol):
    """Host-side driver: perform semantic interop actions for one participant."""

    def perform(self, action: InteropAction) -> Mapping[str, Any] | DriverResult:
        """Execute one action; return JSON-like mapping or :class:`DriverResult`."""
        ...

    def cleanup(self) -> None:
        """Reset driver-local state when the harness requests a run cleanup."""
        ...

    def shutdown(self) -> None:
        """Tear down host resources (processes, simulators, etc.)."""
        ...

    def capabilities(self) -> DriverCapability:
        """Capabilities used for pre-scenario gating."""
        ...


def coerce_driver_result(raw: Mapping[str, Any] | DriverResult) -> DriverResult:
    if isinstance(raw, DriverResult):
        return raw
    if isinstance(raw, Mapping):
        return DriverResult.from_json_dict(raw)
    raise TypeError(
        "Driver perform() must return a mapping or DriverResult; "
        f"got {type(raw).__name__}.",
    )


def action_supported(cap: DriverCapability, action_name: str) -> bool:
    if "*" in cap.supports_actions:
        return True
    return action_name in cap.supports_actions
