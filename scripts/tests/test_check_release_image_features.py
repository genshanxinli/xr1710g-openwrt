#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Unittest discovery wrapper for scripts/tests/check-release-image-features.py.

`python3 -m unittest discover -s scripts/tests -p 'test_*.py'` skips
`check-release-image-features.py` because its filename does not start with
`test_`.  This thin wrapper wires the full offline release-gate suite into
standard discovery while forwarding RELEASE_GATE_UNDER_TEST for red-green runs.
"""

import os
import subprocess
import sys
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
RUNNER = TESTS_DIR / "check-release-image-features.py"


class ReleaseImageFeaturesSuiteTest(unittest.TestCase):
    def test_release_image_features_suite(self):
        proc = subprocess.run(
            [sys.executable, str(RUNNER)],
            env=dict(os.environ),
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"check-release-image-features.py failed (rc={proc.returncode}):\n"
            f"{proc.stdout}\n{proc.stderr}",
        )
        self.assertIn("all tests passed", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
