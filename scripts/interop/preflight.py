from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
from collections.abc import Callable, Iterable, Mapping, Sequence
from urllib.request import urlopen

GENYMOTION_MANUFACTURER = "Genymobile"
_TRIX_ANDROID_SERIAL_ENV = "TRIX_ANDROID_INTEROP_SERIAL"

# `simctl list` device row: name (UUID) (State)
_SIMCTL_DEVICE_LINE = re.compile(
    r"^\s*.+\([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\)"
    r"\s+\([^)]+\)\s*$",
)


def backend_health_url(base_url: str) -> str:
    """Return the absolute `/v0/system/health` URL for a Trix server ``base_url``."""
    trimmed = base_url.rstrip("/")
    return f"{trimmed}/v0/system/health"


def probe_backend_health(base_url: str, *, timeout_seconds: float = 5.0) -> bool:
    """Return True if the server responds with a 2xx on the health endpoint."""
    url = backend_health_url(base_url)
    try:
        with urlopen(url, timeout=timeout_seconds) as response:
            return 200 <= int(response.status) < 300
    except (urllib.error.URLError, OSError, TimeoutError, ValueError):
        return False


def _ios_simctl_has_available_device_json(stdout: str) -> bool:
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        return False
    devices_map = data.get("devices")
    if not isinstance(devices_map, dict):
        return False
    for _runtime, devices in devices_map.items():
        if not isinstance(devices, list):
            continue
        for entry in devices:
            if not isinstance(entry, dict):
                continue
            if entry.get("isAvailable") is False:
                continue
            if entry.get("udid") and entry.get("name"):
                return True
    return False


def _ios_simctl_has_available_device_text(stdout: str) -> bool:
    for raw in stdout.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("=="):
            continue
        if _SIMCTL_DEVICE_LINE.match(line):
            return True
    return False


def check_ios_simulator_available(
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> bool:
    """Return True if `simctl` lists at least one available simulator device."""
    run = run or subprocess.run
    try:
        proc = run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if proc.returncode == 0 and proc.stdout:
        if _ios_simctl_has_available_device_json(proc.stdout):
            return True
    try:
        proc_text = run(
            ["xcrun", "simctl", "list", "devices", "available"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if proc_text.returncode != 0:
        return False
    return _ios_simctl_has_available_device_text(proc_text.stdout or "")


def check_macos_ui_test_runtime_available(
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> bool:
    """Return True if Xcode's `xcodebuild` is resolvable (macOS UI-test host prerequisite)."""
    run = run or subprocess.run
    try:
        proc = run(
            ["xcrun", "--find", "xcodebuild"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if proc.returncode != 0:
        return False
    line = (proc.stdout or "").strip().splitlines()
    if not line:
        return False
    return line[-1].rstrip().endswith("xcodebuild")


def _iter_adb_device_serials(devices_text: str) -> Iterable[str]:
    for raw in devices_text.splitlines():
        line = raw.strip()
        if not line or line.startswith("List of devices"):
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            yield parts[0]


def read_ro_product_manufacturer(
    serial: str,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> str:
    """Return `ro.product.manufacturer` from adb for ``serial`` (empty string on failure)."""
    run = run or subprocess.run
    try:
        proc = run(
            ["adb", "-s", serial, "shell", "getprop", "ro.product.manufacturer"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if proc.returncode != 0:
        return ""
    return (proc.stdout or "").strip()


def list_connected_android_devices_with_manufacturers(
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> list[dict[str, str]]:
    """
    List adb-attached devices with manufacturer from `ro.product.manufacturer`.

    Used for live Genymotion validation (Genymotion reports Genymobile).
    """
    run = run or subprocess.run
    try:
        proc = run(
            ["adb", "devices"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    out: list[dict[str, str]] = []
    for serial in _iter_adb_device_serials(proc.stdout or ""):
        manufacturer = read_ro_product_manufacturer(serial, run=run)
        out.append({"serial": serial, "manufacturer": manufacturer})
    return out


def resolve_android_interop_serial(
    devices: Sequence[Mapping[str, str]],
    explicit_serial: str | None,
) -> str:
    """
    Select the Android serial for interop runs.

    If ``explicit_serial`` is set (e.g. ``TRIX_ANDROID_INTEROP_SERIAL``), it must match a
    connected device whose manufacturer is Genymotion (``Genymobile``).

    Otherwise exactly one such device must be present.
    """
    if explicit_serial is not None:
        candidate = next((d for d in devices if d.get("serial") == explicit_serial), None)
        if candidate is None or candidate.get("manufacturer") != GENYMOTION_MANUFACTURER:
            raise ValueError(
                "TRIX_ANDROID_INTEROP_SERIAL must point at a live Genymotion device.",
            )
        return explicit_serial
    eligible = [d for d in devices if d.get("manufacturer") == GENYMOTION_MANUFACTURER]
    if len(eligible) != 1:
        raise ValueError("Expected exactly one eligible Genymotion device.")
    return eligible[0]["serial"]


def select_genymotion_serial(
    devices: Sequence[Mapping[str, str]],
    explicit_serial: str | None = None,
) -> str:
    """Genymotion-only serial selection (alias of :func:`resolve_android_interop_serial`)."""
    return resolve_android_interop_serial(devices, explicit_serial)


def resolve_android_interop_serial_from_env(
    devices: Sequence[Mapping[str, str]],
    env: Mapping[str, str] | None = None,
) -> str:
    """
    Resolve serial using ``TRIX_ANDROID_INTEROP_SERIAL`` when set (non-empty).

    Validates the env candidate as Genymotion before falling back to the single-device rule.
    """
    env = env or os.environ
    raw = (env.get(_TRIX_ANDROID_SERIAL_ENV) or "").strip()
    explicit: str | None = raw or None
    return resolve_android_interop_serial(devices, explicit_serial=explicit)


def select_android_interop_serial_for_local_run(
    *,
    env: Mapping[str, str] | None = None,
    list_devices: Callable[[], list[dict[str, str]]] | None = None,
) -> str:
    """
    Enumerate adb devices with live manufacturer props, then apply interop selection rules.

    Honors ``TRIX_ANDROID_INTEROP_SERIAL`` first (must be a live Genymotion device).
    """
    env = env or os.environ
    list_devices = list_devices or list_connected_android_devices_with_manufacturers
    devices = list_devices()
    return resolve_android_interop_serial_from_env(devices, env=env)
