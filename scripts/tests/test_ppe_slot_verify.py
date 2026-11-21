#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression guards for scripts/ppe-slot-verify.py (issue #115).

The deliverable is an offline slot/hash verifier: it must fold a five-tuple
with patch 212's two branches and must call a dump INCONSISTENT when its
slots contradict the declared geometry.  Set PPE_SLOT_VERIFY_SCRIPT to point
the guard at a copy (the red proof uses this to run against a damaged copy).
"""

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "PPE_SLOT_VERIFY_SCRIPT", REPO_ROOT / "scripts" / "ppe-slot-verify.py"
    )
)

# Assert on content, not on line numbers: line numbers drift, these strings do
# not.  Each entry is (what the line guarantees, exact substring of the line).
KEY_LINES = (
    ("fold_hash keeps the '& (n - 1)' branch for power-of-two tables",
     "return hash_value & (num_entries - 1)"),
    ("fold_hash keeps the modulo-3 branch for 24576 entries",
     "return ((hash_value >> 13) % 3) * PPE_SRAM_NUM_ENTRIES + ("),
    ("a slot beyond the declared table is INCONSISTENT",
     "dumped slot 0x%x is outside the declared %d-entry table"),
    ("an all-below-0x2000 dump cannot claim 32768 entries",
     "so the dump's index space is "),
    ("the metadata line carries image= and geometry=",
     '"image=%s geometry=%d dumped_slots=%d compared=%d skipped=%d "'),
    ("the CSV row has the four occupancy intervals",
     '"[24576..32767]",'),
    ("a non-OK verdict exits non-zero",
     "return EXIT_VERDICT"),
)

LOW_SLOT_DUMP = (
    "01fc4 UNB IPv6 5T "
    "orig=fe80:0000:0000:0000:02e0:4cff:fee2:012b:42401"
    "->ff02:0000:0000:0000:0000:0000:0000:00fb:100 "
    "eth=00:00:00:00:00:00->00:00:00:00:00:00 etype=0000 "
    "data=00000000 vlan=0,0 ib1=5a000143 ib2=02e04cff "
    "packets=n/a bytes=n/a\n"
)


def run_script(arguments, stdin_text=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT)] + arguments,
        input=stdin_text,
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


class PpeSlotVerifyGuard(unittest.TestCase):
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
        self.assertIn("self-test PASS", result.stdout)

    def test_sample_prints_the_metadata_line_first(self):
        result = run_script(["--sample"])
        self.assertEqual(result.returncode, 0, result.stderr)
        first = result.stdout.splitlines()[0]
        self.assertIn("image=sample", first)
        self.assertIn("geometry=32768", first)
        for column in (
            "[0..8191]",
            "[8192..16383]",
            "[16384..24575]",
            "[24576..32767]",
        ):
            self.assertIn(column, result.stdout)

    def test_all_low_slot_dump_contradicts_geometry_32768(self):
        result = run_script(
            ["--image", "test-low", "--geometry", "32768"], LOW_SLOT_DUMP
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("status=INCONSISTENT", result.stdout.splitlines()[0])
        self.assertIn("INCONSISTENT", result.stderr)

    def test_match_rate_counts_exact_hits_only(self):
        result = run_script(["--sample"])
        line = result.stdout.splitlines()[0]
        match = re.search(r"match_rate=(\d+)/(\d+)", line)
        self.assertIsNotNone(match, line)
        hits, compared = (int(part) for part in match.groups())
        self.assertEqual(hits, compared, "the synthetic sample is self-consistent")
        self.assertGreater(compared, 0)


if __name__ == "__main__":
    unittest.main()
