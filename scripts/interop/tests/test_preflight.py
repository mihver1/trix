from __future__ import annotations

import json
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

from scripts.interop.preflight import (
    backend_health_url,
    check_ios_simulator_available,
    check_macos_ui_test_runtime_available,
    probe_backend_health,
    resolve_android_interop_serial,
    resolve_android_interop_serial_from_env,
    select_genymotion_serial,
)


class PreflightTests(unittest.TestCase):
    def test_select_genymotion_serial_rejects_non_genymobile_targets(self) -> None:
        devices = [
            {"serial": "emulator-5554", "manufacturer": "Google"},
        ]
        with self.assertRaises(ValueError) as ctx:
            select_genymotion_serial(devices, explicit_serial=None)
        self.assertIn("Genymotion", str(ctx.exception))

    def test_android_serial_override_selects_candidate_to_validate_first(self) -> None:
        devices = [
            {"serial": "10.0.0.15:5555", "manufacturer": "Genymobile"},
            {"serial": "192.168.56.101:5555", "manufacturer": "Genymobile"},
        ]
        selected = resolve_android_interop_serial(
            devices,
            explicit_serial="10.0.0.15:5555",
        )
        self.assertEqual(selected, "10.0.0.15:5555")

    def test_android_serial_override_still_requires_live_genymotion_device(self) -> None:
        devices = [
            {"serial": "emulator-5554", "manufacturer": "Google"},
        ]
        with self.assertRaises(ValueError) as ctx:
            resolve_android_interop_serial(
                devices,
                explicit_serial="emulator-5554",
            )
        self.assertIn("Genymotion", str(ctx.exception))

    def test_select_genymotion_serial_rejects_two_devices_without_explicit_serial(self) -> None:
        devices = [
            {"serial": "10.0.0.1:5555", "manufacturer": "Genymobile"},
            {"serial": "10.0.0.2:5555", "manufacturer": "Genymobile"},
        ]
        with self.assertRaises(ValueError) as ctx:
            select_genymotion_serial(devices, explicit_serial=None)
        self.assertIn("Genymotion", str(ctx.exception))

    def test_resolve_android_interop_serial_from_env_uses_trix_var(self) -> None:
        devices = [
            {"serial": "192.168.56.101:5555", "manufacturer": "Genymobile"},
        ]
        out = resolve_android_interop_serial_from_env(
            devices,
            env={"TRIX_ANDROID_INTEROP_SERIAL": "192.168.56.101:5555"},
        )
        self.assertEqual(out, "192.168.56.101:5555")

    def test_backend_health_url_normalizes_base(self) -> None:
        self.assertEqual(
            backend_health_url("http://127.0.0.1:8080/"),
            "http://127.0.0.1:8080/v0/system/health",
        )

    def test_probe_backend_health_accepts_200(self) -> None:
        mock_response = MagicMock()
        mock_response.__enter__.return_value.status = 200
        mock_response.__enter__.return_value.read.return_value = b"{}"
        with patch("scripts.interop.preflight.urlopen", return_value=mock_response):
            self.assertTrue(
                probe_backend_health(
                    "http://127.0.0.1:8080",
                    timeout_seconds=1.0,
                )
            )

    def test_probe_backend_health_rejects_non_2xx(self) -> None:
        mock_response = MagicMock()
        mock_response.__enter__.return_value.status = 503
        with patch("scripts.interop.preflight.urlopen", return_value=mock_response):
            self.assertFalse(
                probe_backend_health(
                    "http://127.0.0.1:8080",
                    timeout_seconds=1.0,
                )
            )

    def test_probe_backend_health_unreachable_returns_false(self) -> None:
        with patch(
            "scripts.interop.preflight.urlopen",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            self.assertFalse(
                probe_backend_health(
                    "http://127.0.0.1:8080",
                    timeout_seconds=1.0,
                )
            )

    def test_check_ios_simulator_available_accepts_simctl_json_device(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                    {
                        "state": "Shutdown",
                        "isAvailable": True,
                        "name": "iPhone 17",
                        "udid": "2E9B1234-5678-90AB-CDEF-123456789012",
                    },
                ],
            },
        }
        proc = MagicMock()
        proc.returncode = 0
        proc.stdout = json.dumps(payload)
        with patch("scripts.interop.preflight.subprocess.run", return_value=proc):
            self.assertTrue(check_ios_simulator_available())

    def test_check_ios_simulator_available_falls_back_to_text_device_line(self) -> None:
        proc_json = MagicMock()
        proc_json.returncode = 0
        proc_json.stdout = json.dumps({"devices": {}})
        proc_text = MagicMock()
        proc_text.returncode = 0
        proc_text.stdout = (
            "    iPhone 17 (2E9B1234-5678-90AB-CDEF-123456789012) (Shutdown)\n"
        )
        with patch(
            "scripts.interop.preflight.subprocess.run",
            side_effect=[proc_json, proc_text],
        ):
            self.assertTrue(check_ios_simulator_available())

    def test_check_macos_ui_test_runtime_uses_xcrun(self) -> None:
        proc = MagicMock()
        proc.returncode = 0
        proc.stdout = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n"
        with patch("scripts.interop.preflight.subprocess.run", return_value=proc):
            self.assertTrue(check_macos_ui_test_runtime_available())


if __name__ == "__main__":
    unittest.main()
