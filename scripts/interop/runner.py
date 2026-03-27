from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from scripts.interop.contracts import DriverResult, ScenarioStep
from scripts.interop.evidence import append_step_result, write_scenario_json
from scripts.interop.platforms.base import InteropDriver, action_supported, coerce_driver_result
from scripts.interop.scenarios import ScenarioSuite


class CapabilityGateError(RuntimeError):
    """Raised when a participant driver cannot perform a required action."""


class MissingDriverError(KeyError):
    """Raised when no driver is registered for a step participant."""


@dataclass
class StepRunRecord:
    step_id: str
    ok: bool
    artifacts: dict[str, object] = field(default_factory=dict)


@dataclass
class RunResult:
    step_results: list[StepRunRecord]
    ok: bool


def _participant_for_step(step: ScenarioStep) -> str:
    return step.actor_client if step.actor_client is not None else step.action.actor


def _referenced_participants(step: ScenarioStep) -> set[str]:
    """Every logical client id involved in a step (executor, targets, asserters)."""
    out = {_participant_for_step(step)}
    out.update(step.target_clients)
    out.update(step.asserting_clients)
    return out


def _ensure_drivers_for_referenced_participants(
    suite: ScenarioSuite,
    drivers: Mapping[str, InteropDriver],
) -> None:
    for step in suite.steps:
        for participant in _referenced_participants(step):
            if participant not in drivers:
                raise MissingDriverError(
                    f"No driver registered for participant {participant!r}.",
                )


def _gate_scenario(suite: ScenarioSuite, drivers: Mapping[str, InteropDriver]) -> None:
    for step in suite.steps:
        participant = _participant_for_step(step)
        cap = drivers[participant].capabilities()
        if not action_supported(cap, step.action.name):
            raise CapabilityGateError(
                f"Participant {participant!r} cannot perform action {step.action.name!r}; "
                f"supports_actions={cap.supports_actions!r}.",
            )


def run_steps_with_driver_map(
    suite: ScenarioSuite,
    drivers: Mapping[str, InteropDriver],
    *,
    output_dir: Path | None = None,
    reset: bool = False,
    scenario_label: str | None = None,
) -> RunResult:
    _ensure_drivers_for_referenced_participants(suite, drivers)
    _gate_scenario(suite, drivers)
    if output_dir is not None:
        write_scenario_json(
            output_dir,
            {
                "suite": suite.name,
                "scenario_label": scenario_label,
                "includes_suites": list(suite.includes_suites),
                "steps": [
                    {"step_id": s.step_id, "action": s.action.to_json_dict()}
                    for s in suite.steps
                ],
            },
        )
    records: list[StepRunRecord] = []
    all_ok = True
    try:
        for step in suite.steps:
            participant = _participant_for_step(step)
            driver = drivers[participant]
            raw = driver.perform(step.action)
            dr = coerce_driver_result(raw)
            arts: dict[str, object] = dict(dr.artifacts) if dr.artifacts is not None else {}
            records.append(StepRunRecord(step_id=step.step_id, ok=dr.ok, artifacts=arts))
            if not dr.ok:
                all_ok = False
            if output_dir is not None:
                row: dict[str, object] = {
                    "step_id": step.step_id,
                    "ok": dr.ok,
                    "action_name": step.action.name,
                    "actor": step.actor,
                    "artifacts": arts,
                }
                if dr.detail is not None:
                    row["detail"] = dr.detail
                append_step_result(output_dir, row)
            if not dr.ok:
                break
    finally:
        if reset:
            for driver in drivers.values():
                driver.cleanup()
    return RunResult(step_results=records, ok=all_ok)
