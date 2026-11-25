#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Skip-record placement for scripts/wireless/edca-6g-ab.sh (#43 E1).

A skip must not leave $RESULT_DIR/result.json behind: the overwrite guard
refuses every later real run in the same --result-dir, so the hardware gap
that caused the skip also blocks the measurement that proves the gap closed.
Both skip paths keep their record under $RESULT_DIR/no-client/, where
hw-gap-report.sh collects it.

EDCA6G_UNDER_TEST is inherited by test_edca_6g_ab; a red proof can point
both files at one pre-fix copy.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_edca_6g_ab import Harness, TARGET

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("EDCA6G_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/edca-6g-ab.sh"
)


class LibOnlySkipTest(unittest.TestCase):
    """Drive the two skip functions directly, without a radio."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="edca-skip-record."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = self.tmp / "res"
        self.env = os.environ.copy()
        self.env.update({"EDCA6G_LIB_ONLY": "1", "RESULT_DIR": str(self.out)})

    def run_skip(self, call):
        return subprocess.run(
            ["sh", "-c", '. "$0" || exit 9; ' + call, str(SCRIPT)],
            env=self.env, capture_output=True, text=True, timeout=120,
            check=False,
        )

    def assert_only_subdir_record(self, out, rc, cause):
        proc_out = out.stdout + out.stderr
        # v2: a skip exits with its cause, never the old measured-success 0.
        self.assertEqual(out.returncode, rc, proc_out)
        self.assertIn("SKIP", out.stdout, proc_out)
        self.assertFalse(
            (self.out / "result.json").exists(),
            "a skip left a top-level result.json; the next real run will be "
            "refused: %s" % proc_out,
        )
        record = self.out / "no-client" / "no-hardware" / "result.json"
        self.assertTrue(record.is_file(), proc_out)
        data = json.loads(record.read_text())
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["cause"], cause)

    def test_no_6g_sta_record_is_subdir_only(self):
        self.assert_only_subdir_record(
            self.run_skip('skip_no_client "no 6G STA"'), 3, "missing-hardware")

    def test_no_tool_record_is_subdir_only(self):
        self.assert_only_subdir_record(
            self.run_skip('skip_no_tool "iperf3 not found"'), 2, "missing-tool")


class RealRunAfterSkipTest(Harness):
    """The skip must not poison the overwrite guard for the real run."""

    def test_real_run_proceeds_after_a_no_tool_skip(self):
        skip = self.run_harness(
            "--target", TARGET, "--result-dir", self.out,
            EDCA6G_IPERF3="iperf3-not-installed-h4347",
        )
        combined = skip.stdout + skip.stderr
        # Missing iperf3 is missing-tool: the skip exits 2.
        self.assertEqual(skip.returncode, 2, combined)
        self.assertIn("SKIP", skip.stdout, combined)
        self.assertFalse((self.out / "result.json").exists(), combined)

        real = self.run_harness(
            "--target", TARGET, "--edca-apply", self.edca_apply,
            "--settle", 0, "--result-dir", self.out,
        )
        combined = real.stdout + real.stderr
        self.assertEqual(real.returncode, 0, combined)
        self.assertNotIn("refusing to overwrite", combined)
        self.assertTrue((self.out / "result.json").is_file(), combined)
        data = json.loads((self.out / "result.json").read_text())
        self.assertEqual(data["schema"], "edca-6g-ab/v1", data)
        self.assertTrue(data["arms"], data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
