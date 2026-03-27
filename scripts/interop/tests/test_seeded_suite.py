from __future__ import annotations

import unittest

from scripts.interop.contracts import DriverCapability, InteropAction, ScenarioStep
from scripts.interop.runner import run_steps_with_driver_map
from scripts.interop.scenarios import ScenarioSuite, build_interop_seeded_suite


class SeededInteropSuiteTests(unittest.TestCase):
    def test_seeded_suite_uses_shared_server_fixture_plus_per_client_local_seeds(self) -> None:
        suite = build_interop_seeded_suite()
        self.assertTrue(any(step.action.name == "bootstrapAccount" for step in suite.steps))
        self.assertTrue(any(step.action.name == "restoreSession" for step in suite.steps))
        self.assertTrue(any("pending" in step.step_id for step in suite.steps))

    def test_seeded_suite_covers_approved_pending_and_restore_bundles(self) -> None:
        suite = build_interop_seeded_suite()
        names = {step.action.name for step in suite.steps}
        self.assertIn("ensureSharedServerTopology", names)
        self.assertIn("snapshotVisibleDmAndGroupState", names)
        self.assertIn("snapshotPendingInviteState", names)
        self.assertIn("restoreSession", names)

    def test_runner_passes_scenario_label_on_every_driver_perform(self) -> None:
        class _LabelRecorder:
            def __init__(self, platform: str) -> None:
                self.platform = platform
                self.labels: list[str | None] = []

            def perform(self, action: InteropAction, *, scenario_label: str | None = None):  # noqa: ANN201
                self.labels.append(scenario_label)
                return {"ok": True}

            def cleanup(self) -> None:
                return None

            def shutdown(self) -> None:
                return None

            def capabilities(self) -> DriverCapability:
                return DriverCapability(platform=self.platform, supports_actions=("*",))

        suite = build_interop_seeded_suite()
        ios = _LabelRecorder("ios")
        android = _LabelRecorder("android")
        macos = _LabelRecorder("macos")
        drivers = {
            "ios-owner": ios,
            "android-peer": android,
            "macos-peer": macos,
        }
        run_steps_with_driver_map(suite, drivers, scenario_label="seeded-label-xyz")
        all_labels: list[str | None] = ios.labels + android.labels + macos.labels
        self.assertGreater(len(all_labels), 0)
        self.assertTrue(all(lab == "seeded-label-xyz" for lab in all_labels))

    def test_runner_invokes_cleanup_after_flagged_steps(self) -> None:
        class _CountingDriver:
            def __init__(self, platform: str) -> None:
                self.platform = platform
                self.cleanups = 0

            def perform(self, action: InteropAction, *, scenario_label: str | None = None):  # noqa: ANN201
                return {"ok": True}

            def cleanup(self) -> None:
                self.cleanups += 1

            def shutdown(self) -> None:
                return None

            def capabilities(self) -> DriverCapability:
                return DriverCapability(platform=self.platform, supports_actions=("*",))

        step_a = ScenarioStep(
            step_id="a1",
            action=InteropAction(name="noopA", actor="ios-owner"),
            actor_client="ios-owner",
        )
        step_b = ScenarioStep(
            step_id="b1",
            action=InteropAction(name="noopB", actor="ios-owner"),
            actor_client="ios-owner",
        )
        suite = ScenarioSuite(
            name="cleanup-test",
            steps=(step_a, step_b),
            cleanup_after_step_ids=("a1",),
        )
        drv = _CountingDriver("ios")
        run_steps_with_driver_map(suite, {"ios-owner": drv}, scenario_label="lbl")
        self.assertEqual(drv.cleanups, 1)


if __name__ == "__main__":
    unittest.main()
