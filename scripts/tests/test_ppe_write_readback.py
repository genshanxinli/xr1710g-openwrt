#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression guards for scripts/ppe-write-readback.sh (issue #62).

The deliverable is a double-gated card: no write without --confirm-write +
--slot + --expected-hash, a 80-byte backup hashed with sha256 before the
single REQ|WR, an immediate readback, a restore, and result.json.  Set
PPE_WRITE_READBACK_SCRIPT to run the guard against a copy (red proof).
"""

import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "PPE_WRITE_READBACK_SCRIPT",
        REPO_ROOT / "scripts" / "ppe-write-readback.sh",
    )
)

# Assert on content, not on line numbers.
KEY_LINES = (
    ("the header forbids running before M0",
     "#  FORBIDDEN on a board that has not passed M0:"),
    ("the only write primitive is one devmem of the same value",
     'devmem "$_w_addr" 32 "$(hex32 "$_w_value")" >/dev/null 2>&1'),
    ("--confirm-write requires --slot",
     'die "refusing write: --confirm-write requires --slot"'),
    ("--confirm-write requires --expected-hash",
     'die "refusing write: --confirm-write requires --expected-hash"'),
    ("the 80-byte backup is sha256-summed before any write",
     '_s_sum=$(sha256sum "$1" 2>/dev/null)'),
    ("the backup is taken before the write path proceeds",
     "if ! create_backup; then"),
    ("the original 80 bytes are restored after the write",
     'hw_write_entry "$PPE_INDEX" "$ENTRY_INDEX" "$BEFORE_WORDS"'),
    ("result.json records the run",
     "_r_json=$backup_dir/result.json"),
    ("result.json is written on both the OK and failure paths",
     'write_result "$RESULT_STATUS"'),
)

RESTORE_WRITES = 'hw_write_entry "$PPE_INDEX" "$ENTRY_INDEX" "$BEFORE_WORDS"'


def run_script(arguments):
    return subprocess.run(
        ["bash", str(SCRIPT)] + arguments,
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


class PpeWriteReadbackGuard(unittest.TestCase):
    def test_key_lines_are_still_present(self):
        text = SCRIPT.read_text(encoding="utf-8")
        for guarantee, needle in KEY_LINES:
            with self.subTest(guarantee):
                self.assertIsNotNone(
                    line_of(text, needle),
                    "%s: key line %r is missing from %s"
                    % (guarantee, needle, SCRIPT),
                )
        # the normal path, the failure path and the trap all restore.
        self.assertGreaterEqual(text.count(RESTORE_WRITES), 3)

    def test_dry_run_works_without_a_device_and_issues_no_write(self):
        result = run_script(["--dry-run"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run complete: no write command was issued", result.stdout)
        self.assertIn("M0 prerequisite", result.stdout)
        self.assertIn("device: /dev/mem (not opened)", result.stdout)

    def test_confirm_write_without_slot_is_refused(self):
        result = run_script(["--confirm-write"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("--confirm-write requires --slot", result.stderr)

    def test_confirm_write_without_expected_hash_is_refused(self):
        result = run_script(["--confirm-write", "--slot", "0x2004"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("--confirm-write requires --expected-hash", result.stderr)

    def test_dry_run_wins_over_a_full_write_triple(self):
        result = run_script([
            "--dry-run", "--confirm-write",
            "--slot", "0x2004", "--expected-hash", "0x4e2a",
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run wins and nothing is written", result.stdout)
        self.assertIn("write sequence if the gate is open", result.stdout)


if __name__ == "__main__":
    unittest.main()
