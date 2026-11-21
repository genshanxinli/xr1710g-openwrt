#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""`sh pppoe-decap-hw-bench.sh` must reach bash, not the parser (issue #70).

The script body is bash (declare -A, arrays).  Called through `sh`, it used to
die at the first bash-only line with

    syntax error: unexpected "("

before any guard could run.  The delivered script is `#!/bin/sh` and re-execs
under bash, so --help must print normal usage instead.  Run from the
repository root:

    python3 scripts/tests/test_pppoe_decap_bash_guard.py
"""

import os
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "PPPOE_BENCH_UNDER_TEST",
        REPO_ROOT / "scripts/pppoe-decap-hw-bench.sh",
    )
)


class BashGuardTest(unittest.TestCase):
    def test_sh_call_prints_usage_instead_of_a_syntax_error(self):
        sh = shutil.which("sh")
        if sh is None or shutil.which("bash") is None:
            self.skipTest("sh and bash are required")
        result = subprocess.run(
            [sh, str(SCRIPT), "--help"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: pppoe-decap-hw-bench.sh", result.stdout)
        self.assertNotIn("syntax error", result.stderr)


if __name__ == "__main__":
    unittest.main()
