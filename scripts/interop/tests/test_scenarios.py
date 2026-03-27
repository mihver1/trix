from __future__ import annotations

import unittest

from scripts.interop.scenarios import (
    build_interop_cross_suite,
    build_interop_full_suite,
    build_interop_seeded_suite,
)


class InteropScenariosTests(unittest.TestCase):
    def test_seeded_suite_declares_per_step_participants(self) -> None:
        suite = build_interop_seeded_suite()
        self.assertEqual(suite.name, "interop-seeded")
        self.assertTrue(any(step.actor == "ios-owner" for step in suite.steps))
        self.assertTrue(any(step.asserting_clients for step in suite.steps))

    def test_interop_full_defaults_to_seeded_plus_cross_composition(self) -> None:
        suite = build_interop_full_suite()
        self.assertEqual(suite.name, "interop-full")
        self.assertEqual(suite.includes_suites, ("interop-seeded", "interop-cross"))

    def test_cross_suite_has_distinct_name_and_steps(self) -> None:
        cross = build_interop_cross_suite()
        seeded = build_interop_seeded_suite()
        self.assertEqual(cross.name, "interop-cross")
        self.assertGreater(len(cross.steps), 0)
        self.assertNotEqual(cross.steps, seeded.steps)


if __name__ == "__main__":
    unittest.main()
