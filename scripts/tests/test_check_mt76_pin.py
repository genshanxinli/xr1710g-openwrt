#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Unittest discovery wrapper for scripts/tests/test_check_mt76_pin.sh (#9).

Forwards MT76_PIN_CHECK_UNDER_TEST through os.environ so red-green runs work
both directly and under `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`.
"""

import os
import subprocess
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SHELL_TEST = TESTS_DIR / "test_check_mt76_pin.sh"


class CheckMt76PinSuiteTest(unittest.TestCase):
    def test_check_mt76_pin_shell_cases(self):
        proc = subprocess.run(
            ["sh", str(SHELL_TEST)],
            env=dict(os.environ),
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"test_check_mt76_pin.sh failed (rc={proc.returncode}):\n"
            f"{proc.stdout}\n{proc.stderr}",
        )
        self.assertIn("all check-mt76-pin cases passed", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
