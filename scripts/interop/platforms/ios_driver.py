from __future__ import annotations

from scripts.interop.contracts import DriverCapability, InteropAction
from scripts.interop.platforms.base import InteropDriver, stub_driver_capabilities


class IOSInteropDriver:
    """Stub iOS host driver; real XCTest wiring lands in later tasks."""

    def capabilities(self) -> DriverCapability:
        return stub_driver_capabilities("ios")

    def perform(self, action: InteropAction):  # noqa: ANN201
        raise NotImplementedError("iOS interop driver not implemented yet.")

    def cleanup(self) -> None:
        return None

    def shutdown(self) -> None:
        return None


def create_ios_driver() -> InteropDriver:
    return IOSInteropDriver()
