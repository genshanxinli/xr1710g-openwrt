#!/usr/bin/env python3
"""Guards for scripts/check-uboot-ubi-volumes.py (review P1-4, X-1).

The checker compares the U-Boot environment patch's ``ubi check``/``ubi read``
volume names against the board DTS ``volname`` properties.  Its own selftest
proves the parser on synthetic input; these tests prove the *live* tree still
agrees, that a one-character drift turns it red, and that CI actually runs it --
before this file the checker had zero callers and could rot green.

Red half: the ``WiredIntoCiTest`` case fails until the step exists in
``.github/workflows/shell-syntax.yml``; point ``UBOOT_UBI_CHECK_UNDER_TEST`` at
an older copy of the checker to see the functional cases fail too.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHECKER = REPO / "scripts" / "check-uboot-ubi-volumes.py"
DTS = REPO / "target" / "linux" / "airoha" / "dts" / "an7581-xr1710g-ubi.dts"
PATCH = REPO / "package" / "boot" / "uboot-airoha" / "patches" / "999-airoha-add-gemtek-xr1710g.patch"
WORKFLOW = REPO / ".github" / "workflows" / "shell-syntax.yml"


def run_checker(*args):
    checker = os.environ.get("UBOOT_UBI_CHECK_UNDER_TEST") or str(CHECKER)
    return subprocess.run([sys.executable, checker, *args],
                          capture_output=True, text=True, timeout=120)


class LiveTreeTest(unittest.TestCase):
    def test_live_inputs_agree(self):
        result = run_checker()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK:", result.stdout)

    def test_selftest_passes(self):
        result = run_checker("--selftest")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("all cases passed", result.stdout)


class DriftTurnsRedTest(unittest.TestCase):
    def test_renamed_dts_volume_is_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            drifted = Path(tmp) / DTS.name
            shutil.copy(DTS, drifted)
            text = drifted.read_text()
            self.assertIn('volname = "fit"', text)
            drifted.write_text(text.replace('volname = "fit"', 'volname = "fitty"'))

            result = run_checker("--dts", str(drifted))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("fit", result.stdout + result.stderr)

    def test_unreadable_dts_exits_two(self):
        result = run_checker("--dts", "target/linux/airoha/dts/does-not-exist.dts")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


class WiredIntoCiTest(unittest.TestCase):
    def test_workflow_runs_selftest_and_live_check(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("check-uboot-ubi-volumes.py --selftest", workflow)
        self.assertIn("check-uboot-ubi-volumes.py", workflow.split("--selftest", 1)[1])
        self.assertIn("package/boot/**", workflow)
        self.assertIn("target/linux/airoha/dts/**", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
