from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from scripts.interop.contracts import (
    InteropAction,
    StepEvidence,
    build_scenario_label,
)
from scripts.interop.evidence import (
    StepResultsFormatError,
    append_step_result,
    write_scenario_json,
)


class InteropContractsTests(unittest.TestCase):
    def test_action_round_trip_preserves_actor_and_targets(self) -> None:
        action = InteropAction(
            name="sendText",
            actor="ios-a",
            target_clients=["android-b"],
            asserting_clients=["macos-c"],
        )
        payload = action.to_json_dict()
        restored = InteropAction.from_json_dict(payload)
        self.assertEqual(restored, action)

    def test_interop_action_from_json_treats_string_as_single_client(self) -> None:
        restored = InteropAction.from_json_dict(
            {
                "name": "sendText",
                "actor": "ios-a",
                "target_clients": "android-b",
                "asserting_clients": "macos-c",
            },
        )
        expected = InteropAction(
            name="sendText",
            actor="ios-a",
            target_clients=("android-b",),
            asserting_clients=("macos-c",),
        )
        self.assertEqual(restored, expected)

    def test_interop_action_from_json_rejects_scalar_non_string_clients(self) -> None:
        with self.assertRaises(TypeError):
            InteropAction.from_json_dict(
                {
                    "name": "sendText",
                    "actor": "ios-a",
                    "target_clients": 1,
                },
            )
        with self.assertRaises(TypeError):
            InteropAction.from_json_dict(
                {
                    "name": "sendText",
                    "actor": "ios-a",
                    "target_clients": ["ok", 2],
                },
            )

    def test_generated_scenario_label_is_unique_per_run(self) -> None:
        first = build_scenario_label("interop-cross")
        second = build_scenario_label("interop-cross")
        self.assertNotEqual(first, second)

    def test_step_evidence_json_round_trip_preserves_required_fields(self) -> None:
        evidence = StepEvidence(
            resolved_ids={"chat_id": "c1", "message_id": "m1"},
            expected_state={"visible": True, "unread": 0},
            observed_state={"visible": True, "unread": 1},
            timeout_seconds=30.0,
            max_retries=3,
            retry_attempts_used=1,
            retry_backoff_seconds=0.5,
            state_snapshot_metadata={"source": "ui-tree", "captured_at_ms": 123},
        )
        payload = evidence.to_json_dict()
        restored = StepEvidence.from_json_dict(payload)
        self.assertEqual(restored, evidence)
        self.assertEqual(payload["resolved_ids"]["chat_id"], "c1")
        self.assertIn("expected_state", payload)
        self.assertIn("observed_state", payload)
        self.assertEqual(payload["timeout_seconds"], 30.0)
        self.assertEqual(payload["max_retries"], 3)
        self.assertEqual(payload["retry_attempts_used"], 1)
        self.assertEqual(payload["retry_backoff_seconds"], 0.5)
        self.assertEqual(payload["state_snapshot_metadata"]["source"], "ui-tree")

    def test_evidence_files_record_required_step_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_scenario_json(
                root,
                {
                    "scenarioLabel": "lbl",
                    "suite": "interop-seeded",
                    "steps": [{"id": "s1"}],
                },
            )
            append_step_result(
                root,
                {
                    "stepId": "s1",
                    "ok": True,
                    "resolved_ids": {"account": "a1"},
                    "expected_state": {"x": 1},
                    "observed_state": {"x": 1},
                    "timeout_seconds": 5.0,
                    "max_retries": 2,
                    "retry_attempts_used": 0,
                    "retry_backoff_seconds": 0.25,
                    "state_snapshot_metadata": {"kind": "checkpoint"},
                    "failure_screenshots": [],
                },
            )
            scenario_path = root / "scenario.json"
            steps_path = root / "step-results.json"
            self.assertTrue(scenario_path.is_file())
            self.assertTrue(steps_path.is_file())
            scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
            steps = json.loads(steps_path.read_text(encoding="utf-8"))
            self.assertEqual(scenario["scenarioLabel"], "lbl")
            self.assertEqual(len(steps), 1)
            row = steps[0]
            self.assertEqual(row["resolved_ids"]["account"], "a1")
            self.assertIn("expected_state", row)
            self.assertIn("observed_state", row)
            self.assertEqual(row["timeout_seconds"], 5.0)
            self.assertIn("max_retries", row)
            self.assertIn("state_snapshot_metadata", row)

    def test_append_step_result_second_row_preserves_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_scenario_json(root, {"scenarioLabel": "lbl", "suite": "s", "steps": []})
            append_step_result(root, {"stepId": "a", "ok": True})
            append_step_result(root, {"stepId": "b", "ok": True})
            steps = json.loads((root / "step-results.json").read_text(encoding="utf-8"))
            self.assertEqual(len(steps), 2)
            self.assertEqual(steps[0]["stepId"], "a")
            self.assertEqual(steps[1]["stepId"], "b")

    def test_append_step_result_rejects_non_list_existing_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "step-results.json"
            path.write_text('{"not": "a list"}\n', encoding="utf-8")
            with self.assertRaises(StepResultsFormatError) as ctx:
                append_step_result(root, {"stepId": "x", "ok": True})
            self.assertIn("JSON array", str(ctx.exception))

    def test_append_step_result_rejects_invalid_json_existing_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "step-results.json").write_text("not-json{{{", encoding="utf-8")
            with self.assertRaises(StepResultsFormatError) as ctx:
                append_step_result(root, {"stepId": "x", "ok": True})
            self.assertIn("valid JSON", str(ctx.exception))

    def test_evidence_failure_only_screenshots_on_failed_step(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_scenario_json(root, {"scenarioLabel": "x", "suite": "s", "steps": []})
            append_step_result(
                root,
                {
                    "stepId": "ui-step",
                    "ok": False,
                    "ui_backed": True,
                    "resolved_ids": {},
                    "expected_state": {},
                    "observed_state": {},
                    "timeout_seconds": None,
                    "max_retries": 0,
                    "retry_attempts_used": 0,
                    "retry_backoff_seconds": None,
                    "state_snapshot_metadata": {},
                    "failure_screenshots": ["/tmp/fail.png"],
                },
            )
            steps = json.loads((root / "step-results.json").read_text(encoding="utf-8"))
            self.assertEqual(steps[0]["failure_screenshots"], ["/tmp/fail.png"])


if __name__ == "__main__":
    unittest.main()
