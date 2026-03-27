from __future__ import annotations

from typing import Any

from scripts.interop.contracts import DriverCapability, InteropAction
from scripts.interop.platforms.base import (
    InteropDriver,
    interop_minimal_perform,
    minimal_driver_capabilities,
)


class IOSInteropDriver:
    """Host driver for iOS Simulator / XCTest interop (minimal semantic actions)."""

    def __init__(
        self,
        *,
        base_url: str | None = None,
        ios_destination: str | None = None,
    ) -> None:
        self._base_url = base_url
        self._ios_destination = ios_destination
        self._scratch: dict[str, Any] = {}
        self._persist: dict[str, Any] = {}

    def capabilities(self) -> DriverCapability:
        return minimal_driver_capabilities("ios")

    def perform(
        self,
        action: InteropAction,
        *,
        scenario_label: str | None = None,
    ):
        return interop_minimal_perform(
            action,
            scenario_label=scenario_label,
            platform="ios",
            base_url=self._base_url,
            scratch=self._scratch,
            persist=self._persist,
            ios_destination=self._ios_destination,
        )

    def cleanup(self) -> None:
        self._scratch.clear()

    def shutdown(self) -> None:
        return None


def create_ios_driver(
    *,
    base_url: str | None = None,
    ios_destination: str | None = None,
) -> InteropDriver:
    return IOSInteropDriver(base_url=base_url, ios_destination=ios_destination)
