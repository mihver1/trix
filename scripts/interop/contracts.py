from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping


def _interop_client_id_sequence(
    field_name: str,
    value: Any,
    *,
    context: str = "InteropAction",
) -> tuple[str, ...]:
    """
    Coerce ``target_clients`` / ``asserting_clients`` to a tuple of strings.

    A single string is treated as one client id (avoids ``tuple("ab")`` bugs).
    """
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,)
    if isinstance(value, (list, tuple)):
        out: list[str] = []
        for item in value:
            if not isinstance(item, str):
                raise TypeError(
                    f"{context}.{field_name} must be a list of strings or a single string; "
                    f"got non-str element {type(item).__name__!r}.",
                )
            out.append(item)
        return tuple(out)
    raise TypeError(
        f"{context}.{field_name} must be a list of strings or a single string; "
        f"got {type(value).__name__}.",
    )


@dataclass(frozen=True)
class InteropAction:
    """Semantic interop action sent to a platform driver."""

    name: str
    actor: str
    target_clients: tuple[str, ...] = field(default_factory=tuple)
    asserting_clients: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "target_clients",
            _interop_client_id_sequence("target_clients", self.target_clients),
        )
        object.__setattr__(
            self,
            "asserting_clients",
            _interop_client_id_sequence("asserting_clients", self.asserting_clients),
        )

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "actor": self.actor,
            "target_clients": list(self.target_clients),
            "asserting_clients": list(self.asserting_clients),
        }

    @staticmethod
    def from_json_dict(payload: Mapping[str, Any]) -> InteropAction:
        return InteropAction(
            name=str(payload["name"]),
            actor=str(payload["actor"]),
            target_clients=_interop_client_id_sequence(
                "target_clients",
                payload.get("target_clients"),
            ),
            asserting_clients=_interop_client_id_sequence(
                "asserting_clients",
                payload.get("asserting_clients"),
            ),
        )


@dataclass(frozen=True)
class ScenarioStep:
    """One scenario step: semantic action plus participant bindings."""

    step_id: str
    action: InteropAction
    actor_client: str | None = None
    target_clients: tuple[str, ...] = field(default_factory=tuple)
    asserting_clients: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "target_clients",
            _interop_client_id_sequence(
                "target_clients",
                self.target_clients,
                context="ScenarioStep",
            ),
        )
        object.__setattr__(
            self,
            "asserting_clients",
            _interop_client_id_sequence(
                "asserting_clients",
                self.asserting_clients,
                context="ScenarioStep",
            ),
        )

    @property
    def actor(self) -> str:
        """Logical actor participant id for this step (from the embedded action)."""
        return self.action.actor


@dataclass(frozen=True)
class StepParticipantBinding:
    """Binds a logical participant id to a concrete driver client id for a step."""

    participant: str
    client_id: str


@dataclass(frozen=True)
class DriverCapability:
    """Host-reported capability for a driver instance."""

    platform: str
    supports_actions: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        object.__setattr__(self, "supports_actions", tuple(self.supports_actions))


@dataclass(frozen=True)
class DriverResult:
    """Normalized outcome from a driver `perform` call."""

    ok: bool
    detail: str | None = None
    artifacts: dict[str, Any] | None = None

    def to_json_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"ok": self.ok}
        if self.detail is not None:
            out["detail"] = self.detail
        if self.artifacts is not None:
            out["artifacts"] = dict(self.artifacts)
        return out

    @staticmethod
    def from_json_dict(payload: Mapping[str, Any]) -> DriverResult:
        artifacts = payload.get("artifacts")
        if artifacts is not None and not isinstance(artifacts, dict):
            raise TypeError("artifacts must be a JSON object when present.")
        return DriverResult(
            ok=bool(payload["ok"]),
            detail=payload.get("detail"),
            artifacts=dict(artifacts) if isinstance(artifacts, dict) else None,
        )


@dataclass
class StepEvidence:
    """Per-step evidence payload: ids, expected/observed state, timeouts/retries, snapshots."""

    resolved_ids: dict[str, str] = field(default_factory=dict)
    expected_state: dict[str, Any] = field(default_factory=dict)
    observed_state: dict[str, Any] = field(default_factory=dict)
    timeout_seconds: float | None = None
    max_retries: int = 0
    retry_attempts_used: int = 0
    retry_backoff_seconds: float | None = None
    state_snapshot_metadata: dict[str, Any] = field(default_factory=dict)

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "resolved_ids": dict(self.resolved_ids),
            "expected_state": dict(self.expected_state),
            "observed_state": dict(self.observed_state),
            "timeout_seconds": self.timeout_seconds,
            "max_retries": self.max_retries,
            "retry_attempts_used": self.retry_attempts_used,
            "retry_backoff_seconds": self.retry_backoff_seconds,
            "state_snapshot_metadata": dict(self.state_snapshot_metadata),
        }

    @staticmethod
    def from_json_dict(payload: Mapping[str, Any]) -> StepEvidence:
        return StepEvidence(
            resolved_ids=dict(payload.get("resolved_ids") or {}),
            expected_state=dict(payload.get("expected_state") or {}),
            observed_state=dict(payload.get("observed_state") or {}),
            timeout_seconds=payload.get("timeout_seconds"),
            max_retries=int(payload.get("max_retries", 0)),
            retry_attempts_used=int(payload.get("retry_attempts_used", 0)),
            retry_backoff_seconds=payload.get("retry_backoff_seconds"),
            state_snapshot_metadata=dict(payload.get("state_snapshot_metadata") or {}),
        )


def build_scenario_label(prefix: str) -> str:
    """Return a unique scenario label for this process run (UTC timestamp + short uuid)."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    suffix = uuid.uuid4().hex[:8]
    return f"{prefix}-{stamp}-{suffix}"
