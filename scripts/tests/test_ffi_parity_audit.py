import unittest

from scripts import ffi_parity_audit as audit


class FfiParityAuditTests(unittest.TestCase):
    def test_normalize_contract_config_fills_missing_platforms(self) -> None:
        config = audit.normalize_contract_config(
            {
                "allowed_orphans": ["foo.bar"],
                "allowed_platform_gaps": {"ios": ["ios.only"]},
            }
        )

        self.assertEqual(config["allowed_orphans"], {"foo.bar"})
        self.assertEqual(config["allowed_platform_gaps"]["ios"], {"ios.only"})
        self.assertEqual(config["allowed_platform_gaps"]["macos"], set())
        self.assertEqual(config["allowed_platform_gaps"]["android"], set())

    def test_validate_contract_config_rejects_unknown_labels(self) -> None:
        config = audit.normalize_contract_config(
            {
                "allowed_orphans": ["known", "missing.orphan"],
                "allowed_platform_gaps": {"android": ["missing.gap"]},
            }
        )

        errors = audit.validate_contract_config(config, {"known"})

        self.assertEqual(
            errors,
            [
                "allowed_orphans references unknown FFI symbol: missing.orphan",
                "allowed_platform_gaps.android references unknown FFI symbol: missing.gap",
            ],
        )

    def test_filter_contract_issues_removes_allowlisted_entries(self) -> None:
        config = audit.normalize_contract_config(
            {
                "allowed_orphans": ["allowed.orphan"],
                "allowed_platform_gaps": {
                    "ios": ["allowed.ios"],
                    "macos": ["allowed.macos"],
                    "android": ["allowed.android"],
                },
            }
        )

        orphans, gaps = audit.filter_contract_issues(
            ["allowed.orphan", "new.orphan"],
            {
                "ios": ["allowed.ios", "new.ios"],
                "macos": ["allowed.macos"],
                "android": ["allowed.android", "new.android"],
            },
            config,
        )

        self.assertEqual(orphans, ["new.orphan"])
        self.assertEqual(gaps["ios"], ["new.ios"])
        self.assertEqual(gaps["macos"], [])
        self.assertEqual(gaps["android"], ["new.android"])
