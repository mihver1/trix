from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from scripts.interop.contracts import DriverCapability, InteropAction, ScenarioStep
from scripts.interop.runner import (
    CapabilityGateError,
    MissingDriverError,
    run_steps_with_driver_map,
)
from scripts.interop.scenarios import ScenarioSuite, build_interop_seeded_suite


class _FakeDriver:
    def __init__(self, names: list[str] | None = None) -> None:
        self.calls: list[str] = []
        self.cleaned = False
        self.shutdown_called = False
        self._names = names

    def perform(self, action, *, scenario_label=None):  # noqa: ANN001
        self.calls.append(action.name)
        return {"ok": True}

    def cleanup(self) -> None:
        self.cleaned = True

    def shutdown(self) -> None:
        self.shutdown_called = True

    def capabilities(self) -> DriverCapability:
        return DriverCapability(platform="fake", supports_actions=("*",))


class InteropRunnerTests(unittest.TestCase):
    def test_runner_executes_steps_sequentially(self) -> None:
        suite = build_interop_seeded_suite()
        trimmed = suite.with_steps(suite.steps[:2])
        driver = _FakeDriver()
        run_steps_with_driver_map(trimmed, {"ios-owner": driver})
        want = [trimmed.steps[0].action.name, trimmed.steps[1].action.name]
        self.assertEqual(driver.calls, want)

    def test_runner_passes_driver_artifact_paths_into_evidence(self) -> None:
        artifacts = {"log_path": "/tmp/ios-driver.log", "screenshot_path": None}

        class _ArtifactDriver(_FakeDriver):
            def perform(self, action, *, scenario_label=None):  # noqa: ANN001
                return {"ok": True, "artifacts": dict(artifacts)}

        suite = build_interop_seeded_suite().with_steps(
            build_interop_seeded_suite().steps[:1],
        )
        result = run_steps_with_driver_map(suite, {"ios-owner": _ArtifactDriver()})
        self.assertEqual(result.step_results[0].artifacts["log_path"], "/tmp/ios-driver.log")

    def test_capability_gating_runs_before_first_step(self) -> None:
        suite = build_interop_seeded_suite().with_steps(
            build_interop_seeded_suite().steps[:1],
        )

        class _StrictDriver(_FakeDriver):
            def capabilities(self) -> DriverCapability:
                return DriverCapability(platform="fake", supports_actions=("other-action",))

        driver = _StrictDriver()
        with self.assertRaises(CapabilityGateError):
            run_steps_with_driver_map(suite, {"ios-owner": driver})
        self.assertEqual(driver.calls, [])

    def test_reset_requests_driver_cleanup(self) -> None:
        s = build_interop_seeded_suite()
        suite = s.with_steps(s.steps[:1])
        driver = _FakeDriver()
        run_steps_with_driver_map(suite, {"ios-owner": driver}, reset=True)
        self.assertTrue(driver.cleaned)

    def test_evidence_file_written_per_step(self) -> None:
        s = build_interop_seeded_suite()
        suite = s.with_steps(s.steps[:1])
        driver = _FakeDriver()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            run_steps_with_driver_map(suite, {"ios-owner": driver}, output_dir=out)
            path = out / "step-results.json"
            self.assertTrue(path.is_file())
            rows = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(len(rows), 1)
            self.assertIn("artifacts", rows[0])

    def test_runner_fails_fast_when_step_returns_not_ok(self) -> None:
        class _FailThenNeverCalledDriver(_FakeDriver):
            def perform(self, action, *, scenario_label=None):  # noqa: ANN001
                self.calls.append(action.name)
                if len(self.calls) == 1:
                    return {"ok": False, "detail": "simulated failure"}
                return {"ok": True}

        s = build_interop_seeded_suite()
        suite = s.with_steps(s.steps[:2])
        driver = _FailThenNeverCalledDriver()
        result = run_steps_with_driver_map(suite, {"ios-owner": driver})
        self.assertFalse(result.ok)
        self.assertEqual(len(result.step_results), 1)
        self.assertEqual(driver.calls, [suite.steps[0].action.name])

    def test_fail_fast_still_writes_evidence_for_failed_step_only(self) -> None:
        class _FailDriver(_FakeDriver):
            def perform(self, action, *, scenario_label=None):  # noqa: ANN001
                self.calls.append(action.name)
                return {"ok": False, "detail": "first step failed"}

        s = build_interop_seeded_suite()
        suite = s.with_steps(s.steps[:2])
        driver = _FailDriver()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            run_steps_with_driver_map(suite, {"ios-owner": driver}, output_dir=out)
            rows = json.loads((out / "step-results.json").read_text(encoding="utf-8"))
            self.assertEqual(len(rows), 1)
            self.assertIs(rows[0]["ok"], False)

    def test_missing_driver_for_actor_raises_missing_driver_error(self) -> None:
        step = ScenarioStep(
            step_id="m1",
            action=InteropAction(name="noop", actor="ghost-participant"),
            actor_client="ghost-participant",
        )
        suite = ScenarioSuite("missing", [step])
        with self.assertRaises(MissingDriverError):
            run_steps_with_driver_map(suite, {"ios-owner": _FakeDriver()})

    def test_missing_driver_for_referenced_target_raises_missing_driver_error(self) -> None:
        step = ScenarioStep(
            step_id="m2",
            action=InteropAction(
                name="noop",
                actor="ios-owner",
                target_clients=("no-such-peer",),
            ),
            actor_client="ios-owner",
            target_clients=("no-such-peer",),
        )
        suite = ScenarioSuite("missing-target", [step])
        with self.assertRaises(MissingDriverError):
            run_steps_with_driver_map(suite, {"ios-owner": _FakeDriver()})

    def test_missing_driver_for_referenced_asserter_raises_missing_driver_error(self) -> None:
        step = ScenarioStep(
            step_id="m3",
            action=InteropAction(
                name="noop",
                actor="ios-owner",
                asserting_clients=("missing-assert",),
            ),
            actor_client="ios-owner",
            asserting_clients=("missing-assert",),
        )
        suite = ScenarioSuite("missing-assert", [step])
        with self.assertRaises(MissingDriverError):
            run_steps_with_driver_map(suite, {"ios-owner": _FakeDriver()})


if __name__ == "__main__":
    unittest.main()
