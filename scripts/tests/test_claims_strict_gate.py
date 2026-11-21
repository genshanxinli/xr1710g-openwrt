#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The unverified budget has to fail the job, not just be printed.

`.github/workflows/claims.yml` used to run `scripts/check-claims.py` without
`--strict`, so the 5 unverified rows were only a number in the summary line: a
PR could add a sixth and the ledger job stayed green.  This test pins both
halves:

  * a ledger over budget exits non-zero (the red proof, kept as a test), and
  * the workflow command carries `--strict --max-unverified N` with N at least
    the current count, so the budget cannot drift above the ledger unnoticed.

Run from the repository root:

    python3 scripts/tests/test_claims_strict_gate.py
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
GATE = REPO_ROOT / "scripts/check-claims.py"
LEDGER = REPO_ROOT / "scripts/claims.yaml"
WORKFLOW = REPO_ROOT / ".github/workflows/claims.yml"

# Rows flipped to unverified to build the over-budget fixture.  Any five
# `supported` rows will do; the point is the count, not which rows.
RED_FLIPS = 5


def run_gate(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(GATE), *args],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def current_unverified() -> int:
    result = run_gate()
    match = re.search(r"\(\d+ supported, \d+ refuted, (\d+) unverified\)", result.stdout)
    if match is None:
        raise AssertionError(f"cannot read the unverified count from: {result.stdout}")
    return int(match.group(1))


def make_red_ledger(directory: Path) -> tuple[Path, int]:
    """Copy the real ledger with RED_FLIPS supported rows demoted."""
    text = LEDGER.read_text(encoding="utf-8")
    red, flips = re.subn(
        r"status: supported", "status: unverified", text, count=RED_FLIPS
    )
    if flips != RED_FLIPS:
        raise AssertionError(f"expected {RED_FLIPS} supported rows, flipped {flips}")
    path = directory / "claims.yaml"
    path.write_text(red, encoding="utf-8")
    return path, current_unverified() + RED_FLIPS


class StrictBudgetTest(unittest.TestCase):
    def test_red_ledger_exits_non_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger, over = make_red_ledger(Path(tmp))
            budget = 5  # the shipped budget of 9
            result = run_gate("--ledger", str(ledger), "--strict", "--max-unverified", "9")
            self.assertGreater(over, 9, "the fixture must exceed the shipped budget")
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("strict:", result.stderr)
            self.assertIn("exceed the budget of 9", result.stderr)
            self.assertIn(f"{over} unverified claim(s)", result.stderr)
            self.assertNotEqual(budget, 0)

    def test_current_ledger_is_within_a_strict_run(self):
        result = run_gate("--strict", "--max-unverified", "9")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("within the budget of 9", result.stdout)

    def test_workflow_enforces_a_strict_budget(self):
        data = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        commands = [
            step["run"]
            for job in data["jobs"].values()
            for step in job.get("steps", [])
            if "check-claims.py" in step.get("run", "")
        ]
        self.assertTrue(commands, "no step runs scripts/check-claims.py")

        strict = [cmd for cmd in commands if "--strict" in cmd]
        self.assertEqual(
            len(strict),
            1,
            "the ledger job must run --strict exactly once; without it the "
            f"unverified count never fails a PR (commands: {commands})",
        )
        match = re.search(r"--max-unverified\s+(\d+)", strict[0])
        self.assertIsNotNone(match, f"no numeric --max-unverified in: {strict[0]}")
        budget = int(match.group(1))
        count = current_unverified()
        self.assertGreaterEqual(budget, count, "the budget is below the current count")
        self.assertLessEqual(
            budget,
            count + 6,
            "the budget drifted far above the ledger; lower it or explain why in the workflow",
        )


if __name__ == "__main__":
    unittest.main()
