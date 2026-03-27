from __future__ import annotations

from collections.abc import Sequence

from scripts.interop.contracts import InteropAction, ScenarioStep


class ScenarioSuite:
    """Named collection of :class:`ScenarioStep` records (optionally composed)."""

    __slots__ = ("name", "steps", "includes_suites")

    def __init__(
        self,
        name: str,
        steps: Sequence[ScenarioStep],
        *,
        includes_suites: Sequence[str] | None = None,
    ) -> None:
        self.name = name
        self.steps = tuple(steps)
        self.includes_suites = tuple(includes_suites or ())

    def with_steps(self, steps: Sequence[ScenarioStep]) -> ScenarioSuite:
        return ScenarioSuite(
            name=self.name,
            steps=tuple(steps),
            includes_suites=self.includes_suites,
        )


def _step(
    step_id: str,
    action_name: str,
    actor: str,
    *,
    target_clients: Sequence[str] | str | None = None,
    asserting_clients: Sequence[str] | str | None = None,
    actor_client: str | None = None,
) -> ScenarioStep:
    action = InteropAction(
        name=action_name,
        actor=actor,
        target_clients=target_clients,
        asserting_clients=asserting_clients,
    )
    return ScenarioStep(
        step_id=step_id,
        action=action,
        actor_client=actor_client or actor,
        target_clients=action.target_clients,
        asserting_clients=action.asserting_clients,
    )


def build_interop_seeded_suite() -> ScenarioSuite:
    """Seeded-restore focused steps (single-owner bootstrap + cross-client assertions)."""
    steps = (
        _step("seeded-01", "seededWorkspaceBootstrap", "ios-owner"),
        _step("seeded-02", "seededConversationHydrate", "ios-owner"),
        _step(
            "seeded-03",
            "assertSeededMessageVisible",
            "ios-owner",
            asserting_clients=("macos-peer",),
        ),
    )
    return ScenarioSuite(name="interop-seeded", steps=steps)


def build_interop_cross_suite() -> ScenarioSuite:
    """Cross-client DM / multi-participant scenarios."""
    steps = (
        _step(
            "cross-01",
            "sendDirectMessage",
            "ios-owner",
            target_clients=("android-peer",),
        ),
        _step(
            "cross-02",
            "assertDirectMessageReceived",
            "android-peer",
            asserting_clients=("macos-peer",),
        ),
    )
    return ScenarioSuite(name="interop-cross", steps=steps)


def build_interop_full_suite() -> ScenarioSuite:
    """Default full interop run: seeded flow followed by cross-client flow."""
    seeded = build_interop_seeded_suite()
    cross = build_interop_cross_suite()
    return ScenarioSuite(
        name="interop-full",
        steps=seeded.steps + cross.steps,
        includes_suites=("interop-seeded", "interop-cross"),
    )
