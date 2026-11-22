#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A missing iperf3 on the 10G bench is a record, not a bare error (#13).

The defect: scripts/bench-10g-unidirectional.sh died with exit 1 and
"iperf3 not found in PATH", so scripts/wireless/hw-gap-report.sh never saw
the gap.  It now writes a wireless-no-client/v1 record and exits 2 - a
recorded prerequisite, neither a failed run (1) nor a clean skip (0).

There is no --source here: with --peer-connects this box runs
"iperf3 -s -1" and the peer drives, and result.json is parsed out of
iperf3's own JSON schema, so a substitute generator would not produce a
citable baseline.

Run from the repository root:

    python3 scripts/tests/test_bench_missing_iperf3.py

BENCH_UNDER_TEST=/path/to/copy runs the same case against another script:
that is the red proof.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("BENCH_UNDER_TEST")
    or REPO_ROOT / "scripts/bench-10g-unidirectional.sh"
)

# Enough of the script's own preflight to reach the iperf3 gate, minus iperf3.
TOOLS = (
    "sh", "ip", "awk", "sed", "grep", "cut", "tr", "date", "mkdir", "rm",
    "mv", "cat", "sleep", "dirname", "basename", "uname", "id",
)


class MissingIperf3(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), SCRIPT)
        self.tmp = Path(tempfile.mkdtemp(prefix="bench-tool-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name in TOOLS:
            real = shutil.which(name)
            if real is not None:
                (self.bin / name).symlink_to(real)
        if (self.bin / "iperf3").exists():
            raise AssertionError("iperf3 must not be on this PATH")
        # PATH holds the real tools and nothing else, so iperf3 is really
        # absent instead of being shadowed by the system one.
        self.env = dict(
            os.environ, PATH=str(self.bin), HOME=str(self.tmp)
        )
        self.out = self.tmp / "out"

    def test_missing_iperf3_is_a_recorded_gap(self):
        result = subprocess.run(
            [
                "sh", str(SCRIPT),
                "--target", "127.0.0.1",
                "--iface", "lo",
                "--duration", "1",
                "--parallel", "1",
                "--result-dir", str(self.out),
            ],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=120,
            check=False,
        )
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 2, combined)
        self.assertIn("BLOCKED: missing iperf3", result.stdout)
        self.assertIn("iperf3 not found in PATH", result.stderr)
        self.assertIn("no-client record:", result.stderr)
        # A subdirectory, so a result.json from an earlier run survives.
        record = json.loads((self.out / "no-client" / "result.json").read_text())
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["status"], "no-client")
        self.assertEqual(record["missing"], "iperf3")
        self.assertEqual(str(record["ticket"]), "13")
        self.assertIn("bench-10g-unidirectional.sh", record["script"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
