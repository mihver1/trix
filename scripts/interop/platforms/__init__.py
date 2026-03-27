"""Platform-specific interop drivers (host side)."""

from scripts.interop.platforms.android_driver import AndroidInteropDriver, create_android_driver
from scripts.interop.platforms.base import (
    STUB_DRIVER_SUPPORTS_ACTIONS,
    InteropDriver,
    action_supported,
    coerce_driver_result,
    stub_driver_capabilities,
)
from scripts.interop.platforms.ios_driver import IOSInteropDriver, create_ios_driver
from scripts.interop.platforms.macos_driver import MacOSInteropDriver, create_macos_driver

__all__ = [
    "STUB_DRIVER_SUPPORTS_ACTIONS",
    "AndroidInteropDriver",
    "IOSInteropDriver",
    "InteropDriver",
    "MacOSInteropDriver",
    "action_supported",
    "coerce_driver_result",
    "stub_driver_capabilities",
    "create_android_driver",
    "create_ios_driver",
    "create_macos_driver",
]
