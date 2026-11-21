#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression guards for scripts/ppe-flowgen.py (issue #114).

The deliverable must vary the destination IP (>= 10000 distinct) and the
source port, must preview the four-slot windows for 32768/24576/16384, and
must never print a requested value as a measured one.  Set
PPE_FLOWGEN_SCRIPT to run the guard against a copy (used by the red proof).
"""

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("PPE_FLOWGEN_SCRIPT", REPO_ROOT / "scripts" / "ppe-flowgen.py")
)

# Assert on content, not on line numbers.
KEY_LINES = (
    ("fold_hash keeps the '& (n - 1)' branch",
     "return hash_value & (num_entries - 1)"),
    ("fold_hash keeps the modulo-3 branch for 24576",
     "return ((hash_value >> PPE_SRAM_BITS) % 3) * PPE_SRAM_NUM_ENTRIES + ("),
    ("the self-test demands >= 10000 distinct destinations",
     "len({flow.dst_ip for flow in flows}) >= 10000"),
    ("the measured line is the only PREPARED line",
     '"PREPARED flows=%d distinct_dst=%d distinct_sport=%d pps=%.1f"'),
    ("planned output is labelled as planned",
     "(planned values, not measured)"),
    ("--plan/--dry-run refuse to be mistaken for a measurement",
     'print("traffic source, not a measurement conclusion")'),
)

DISTINCT_DST = re.compile(r"distinct_dst=(\d+)")


def run_script(arguments):
    return subprocess.run(
        [sys.executable, str(SCRIPT)] + arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )


def line_of(text, needle):
    """Return the current 1-based line number of needle, or None."""
    index = text.find(needle)
    if index < 0:
        return None
    return text.count("\n", 0, index) + 1


class PpeFlowgenGuard(unittest.TestCase):
    def test_key_lines_are_still_present(self):
        text = SCRIPT.read_text(encoding="utf-8")
        for guarantee, needle in KEY_LINES:
            with self.subTest(guarantee):
                self.assertIsNotNone(
                    line_of(text, needle),
                    "%s: key line %r is missing from %s"
                    % (guarantee, needle, SCRIPT),
                )

    def test_self_test_still_passes(self):
        result = run_script(["--self-test"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("checks passed", result.stdout)

    def test_plan_covers_more_than_10000_destinations_and_all_windows(self):
        result = run_script(["--plan"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("traffic source, not a measurement conclusion", result.stdout)

        plan_line = next(
            line for line in result.stdout.splitlines() if line.startswith("PLAN ")
        )
        match = DISTINCT_DST.search(plan_line)
        self.assertIsNotNone(match, plan_line)
        self.assertGreaterEqual(int(match.group(1)), 10000)

        for window in (
            "[0..8191]",
            "[8192..16383]",
            "[16384..24575]",
            "[24576..32767]",
        ):
            self.assertIn(window, result.stdout)
        for geometry in ("n=32768", "n=24576", "n=16384"):
            self.assertIn(geometry, result.stdout)

    def test_dry_run_is_declared_and_plans_only(self):
        result = run_script(["--dry-run"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY-RUN: no sockets created, no packets sent", result.stdout)
        self.assertIn("(planned values, not measured)", result.stdout)
        self.assertNotIn("PREPARED", result.stdout)

    def test_sending_without_rate_and_duration_is_rejected(self):
        result = run_script([])
        self.assertEqual(result.returncode, 2)
        self.assertIn("required to send traffic", result.stderr)


if __name__ == "__main__":
    unittest.main()
