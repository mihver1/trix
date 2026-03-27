from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping


class StepResultsFormatError(ValueError):
    """``step-results.json`` exists but is not valid JSON array data."""


def write_scenario_json(output_dir: Path, document: Mapping[str, Any]) -> Path:
    """Write `scenario.json` under ``output_dir`` (created if missing)."""
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "scenario.json"
    text = json.dumps(dict(document), indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")
    return path


def append_step_result(output_dir: Path, entry: Mapping[str, Any]) -> Path:
    """Append one record to ``step-results.json`` (JSON array), creating the file if needed."""
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "step-results.json"
    existing: list[Any] = []
    if path.exists():
        text = path.read_text(encoding="utf-8")
        try:
            raw = json.loads(text)
        except json.JSONDecodeError as error:
            raise StepResultsFormatError(
                "step-results.json exists but is not valid JSON.",
            ) from error
        if not isinstance(raw, list):
            raise StepResultsFormatError(
                "step-results.json must contain a JSON array of step results; "
                f"found {type(raw).__name__}.",
            )
        existing = list(raw)
    row = _normalize_step_result_row(dict(entry))
    existing.append(row)
    path.write_text(
        json.dumps(existing, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return path


def _normalize_step_result_row(row: dict[str, Any]) -> dict[str, Any]:
    """Keep failure screenshot paths only for failed UI-backed steps."""
    out = dict(row)
    ok = out.get("ok")
    ui = bool(out.get("ui_backed"))
    shots = out.get("failure_screenshots")
    if ok is True:
        if shots in (None, [], ()):
            out.pop("failure_screenshots", None)
    elif ok is False and ui:
        if shots is None:
            out["failure_screenshots"] = []
    return out
