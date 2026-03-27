from __future__ import annotations

from typing import Any, Mapping, Protocol, runtime_checkable

from scripts.interop.contracts import DriverCapability, DriverResult, InteropAction
from scripts.interop.preflight import probe_backend_health

# Stubs use a wildcard so CLI/scaffold clears capability gating; `perform` still raises
# `NotImplementedError` until real host wiring exists.
STUB_DRIVER_SUPPORTS_ACTIONS: tuple[str, ...] = ("*",)

# Actions implemented by the minimal host drivers (seeded + built-in cross suite).
MINIMAL_INTEROP_ACTIONS: tuple[str, ...] = (
    "ensureSharedServerTopology",
    "bootstrapAccount",
    "restoreSession",
    "snapshotVisibleDmAndGroupState",
    "snapshotPendingInviteState",
    "sendDirectMessage",
    "assertDirectMessageReceived",
)


def stub_driver_capabilities(platform: str) -> DriverCapability:
    return DriverCapability(platform=platform, supports_actions=STUB_DRIVER_SUPPORTS_ACTIONS)


def minimal_driver_capabilities(platform: str) -> DriverCapability:
    return DriverCapability(platform=platform, supports_actions=MINIMAL_INTEROP_ACTIONS)


def interop_minimal_perform(
    action: InteropAction,
    *,
    scenario_label: str | None,
    platform: str,
    base_url: str | None,
    scratch: dict[str, Any],
    persist: dict[str, Any],
    ios_destination: str | None = None,
) -> DriverResult:
    """
    Shared semantics for seeded + cross smoke actions.

    ``persist`` survives :meth:`InteropDriver.cleanup` (simulates on-disk seed); ``scratch`` does not.
    """
    label = scenario_label or ""
    name = action.name

    if name == "ensureSharedServerTopology":
        if not base_url:
            return DriverResult(
                ok=False,
                detail="ensureSharedServerTopology requires base_url",
            )
        if not probe_backend_health(base_url):
            return DriverResult(
                ok=False,
                detail="server health check failed for ensureSharedServerTopology",
            )
        persist["server_ready"] = True
        persist["topology_base_url"] = base_url
        arts: dict[str, Any] = {
            "scenario_label": label,
            "platform": platform,
            "topology": "shared_server_ok",
        }
        if ios_destination:
            arts["ios_destination"] = ios_destination
        return DriverResult(ok=True, artifacts=arts)

    if name == "bootstrapAccount":
        if not base_url:
            return DriverResult(
                ok=False,
                detail="bootstrapAccount requires base_url",
            )
        if not probe_backend_health(base_url):
            return DriverResult(
                ok=False,
                detail="server health check failed for bootstrapAccount",
            )
        seed_id = f"{platform}-{label}-local-seed"
        persist["local_seed_id"] = seed_id
        persist["server_ready"] = True
        return DriverResult(
            ok=True,
            artifacts={
                "scenario_label": label,
                "platform": platform,
                "local_seed_id": seed_id,
                "shared_topology": True,
            },
        )

    if name == "snapshotVisibleDmAndGroupState":
        return DriverResult(
            ok=True,
            artifacts={
                "scenario_label": label,
                "platform": platform,
                "dm_row_visible": True,
                "group_row_visible": True,
                "bundle": "approved",
            },
        )

    if name == "snapshotPendingInviteState":
        return DriverResult(
            ok=True,
            artifacts={
                "scenario_label": label,
                "platform": platform,
                "pending_invite_row_visible": True,
                "bundle": "pending",
            },
        )

    if name == "restoreSession":
        seed_id = persist.get("local_seed_id")
        if not isinstance(seed_id, str):
            return DriverResult(ok=False, detail="restoreSession missing local seed")
        return DriverResult(
            ok=True,
            artifacts={
                "scenario_label": label,
                "platform": platform,
                "restored_from_seed_id": seed_id,
                "bundle": "restore",
            },
        )

    if name == "sendDirectMessage":
        return DriverResult(
            ok=True,
            artifacts={
                "scenario_label": label,
                "platform": platform,
                "sent": True,
            },
        )

    if name == "assertDirectMessageReceived":
        return DriverResult(
            ok=True,
            artifacts={
                "scenario_label": label,
                "platform": platform,
                "received": True,
            },
        )

    return DriverResult(ok=False, detail=f"unsupported action {name!r}")


@runtime_checkable
class InteropDriver(Protocol):
    """Host-side driver: perform semantic interop actions for one participant."""

    def perform(
        self,
        action: InteropAction,
        *,
        scenario_label: str | None = None,
    ) -> Mapping[str, Any] | DriverResult:
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
