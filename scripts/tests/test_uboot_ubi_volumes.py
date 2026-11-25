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


class HunkBoundaryTest(unittest.TestCase):
    """Edge cases for blank lines at unified-diff hunk boundaries."""

    def _run_patch(self, patch_text):
        with tempfile.TemporaryDirectory() as tmp:
            patch_path = Path(tmp) / "test.patch"
            patch_path.write_text(patch_text, encoding="utf-8")
            return run_checker("--uboot-patch", str(patch_path), "--dts", str(DTS))

    def test_undercounted_new_file_hunk_blank_then_dropped_add_exits_two(self):
        patch_text = "\n".join([
            "--- /dev/null",
            "+++ b/defenvs/selftest",
            "@@ -0,0 +1,2 @@",
            "+boot_production=run ubi_read_production",
            "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
            "",
            "+dropped=1",
            "",
        ])
        result = self._run_patch(patch_text)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_undercounted_mod_hunk_blank_then_dropped_add_exits_two(self):
        patch_text = "\n".join([
            "--- a/defenvs/selftest",
            "+++ b/defenvs/selftest",
            "@@ -1,2 +1,2 @@",
            " boot_production=run ubi_read_production",
            "-ubi_read_production=ubi read $loadaddr old",
            "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
            "",
            "+dropped=1",
            "",
        ])
        result = self._run_patch(patch_text)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_trailing_stripped_context_before_next_hunk_passes(self):
        patch_text = "\n".join([
            "--- a/defenvs/selftest",
            "+++ b/defenvs/selftest",
            "@@ -1,2 +1,2 @@",
            "-ubi_read_production=ubi read $loadaddr old",
            "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
            "",
            "@@ -10,1 +10,1 @@",
            "-bootdelay=1",
            "+bootdelay=3",
            "",
        ])
        result = self._run_patch(patch_text)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_trailing_stripped_context_before_next_file_passes(self):
        patch_text = "\n".join([
            "--- a/defenvs/selftest",
            "+++ b/defenvs/selftest",
            "@@ -1,2 +1,2 @@",
            "-ubi_read_production=ubi read $loadaddr old",
            "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
            "",
            "--- a/f2",
            "+++ b/f2",
            "@@ -1,1 +1,1 @@",
            "-a=1",
            "+a=2",
            "",
        ])
        result = self._run_patch(patch_text)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class WiredIntoCiTest(unittest.TestCase):
    def test_workflow_runs_selftest_and_live_check(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("check-uboot-ubi-volumes.py --selftest", workflow)
        self.assertIn("check-uboot-ubi-volumes.py", workflow.split("--selftest", 1)[1])
        self.assertIn("package/boot/**", workflow)
        self.assertIn("target/linux/airoha/dts/**", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
