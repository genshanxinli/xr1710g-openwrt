#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A missing iperf3 on the 2.5G harnesses is a record, not a bare error (#70).

The defect: both scripts died with "error: missing local command(s): iperf3"
(exit 1), so scripts/wireless/hw-gap-report.sh never saw the gap and the next
person on the same board hit the same wall.

Both now write a wireless-no-client/v1 record with missing "iperf3" and exit
2 - a recorded prerequisite, neither a failed run (1) nor a clean skip (0).
There is no --source here: every 2.5G arm needs iperf3 on both ends, with this
host playing the server for one direction and the client for the other.

The scripts are sourced (G25_WIRED_LIB_ONLY / G25_BPATH_LIB_ONLY) and
check_traffic_tools is called directly, on a PATH that has the real tools
except iperf3, so the gate is exercised for real and nothing touches a NIC,
a device or the network.

    python3 scripts/tests/test_2g5_missing_tool.py

TWO_G5_SCRIPT_UNDER_TEST and G25_BPATH_UNDER_TEST point the tests at other
copies of the scripts: that is the red proof.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WIRED = Path(
    os.environ.get("TWO_G5_SCRIPT_UNDER_TEST")
    or os.environ.get("2G5_SCRIPT_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/2.5g-wired.sh"
)
BPATH = Path(
    os.environ.get("G25_BPATH_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/b-path-25g.sh"
)
SH = shutil.which("sh") or "/bin/sh"

# Everything a sourced preflight and the record itself may call, minus iperf3.
TOOLS = (
    "ssh", "ethtool", "ip", "awk", "sed", "grep", "tr", "cut", "date",
    "id", "mkdir", "cat", "mv", "rm", "sleep", "readlink", "head", "tail",
    "wc", "dirname", "basename", "printf", "uname", "ls", "env", "chmod",
    "touch", "sort", "expr", "test",
)

# Sourcing the script must not fall through to main(); then drive the gate.
DRIVE = """\
. "$1"
. "$(dirname "$1")/lib/no-client.sh"
OUT_DIR_OPT=$2
check_traffic_tools "$3"
"""


def make_tool_path(root):
    """A PATH with the real tools except iperf3."""
    bin_dir = Path(root) / "bin"
    bin_dir.mkdir()
    for name in TOOLS:
        real = shutil.which(name)
        if real is not None:
            (bin_dir / name).symlink_to(real)
    if "iperf3" in os.listdir(bin_dir):
        raise AssertionError("iperf3 must not be on the preflight PATH")
    return bin_dir


class Base:
    """Shared cases; the subclasses below name one script each."""

    script = None
    lib_only = None
    reason = None

    def setUp(self):
        self.assertTrue(self.script.is_file(), self.script)
        self.tmp = Path(tempfile.mkdtemp(prefix="2g5-tool-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = make_tool_path(self.tmp)
        # PATH holds the real tools and nothing else, so iperf3 is really
        # absent instead of being shadowed by the system one.
        self.env = dict(
            os.environ, PATH=str(self.bin), HOME=str(self.tmp),
            **{self.lib_only: "1"}
        )
        self.out = self.tmp / "out"

    def drive(self, gate):
        return subprocess.run(
            [SH, "-c", DRIVE, "check", str(self.script), str(self.out), gate],
            capture_output=True,
            text=True,
            cwd=str(self.tmp),
            env=self.env,
            check=False,
        )

    def test_missing_iperf3_is_a_recorded_gap(self):
        result = self.drive("run")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 2, combined)
        self.assertIn("BLOCKED: missing iperf3", result.stdout)
        self.assertIn("missing iperf3", result.stderr)
        self.assertIn("no-client record:", result.stderr)
        record = json.loads((self.out / "no-hardware/result.json").read_text())
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["status"], "no-client")
        self.assertEqual(record["missing"], "iperf3")
        self.assertEqual(str(record["ticket"]), "70")
        self.assertIn(self.reason, record["reason"])
        self.assertEqual(len(record["criteria"]), 3)

    def test_dry_run_keeps_going(self):
        result = self.drive("dry-run")
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("dry-run continues", result.stderr)
        self.assertFalse((self.out / "no-hardware/result.json").exists(), combined)

    def test_the_device_gate_records_instead_of_dying(self):
        # The device side is one line inside check_device; driving it needs a
        # full port dump, so guard the shape instead.
        body = " ".join(self.script.read_text().split())
        self.assertIn("dev_have iperf3 || missing_tool iperf3", body)
        self.assertNotIn("dev_have iperf3 || die", body)


class Wired(Base, unittest.TestCase):
    """scripts/wireless/2.5g-wired.sh, host side."""

    script = WIRED
    lib_only = "G25_WIRED_LIB_ONLY"
    reason = "bench host"


class BPath(Base, unittest.TestCase):
    """scripts/wireless/b-path-25g.sh, feeder host side."""

    script = BPATH
    lib_only = "G25_BPATH_LIB_ONLY"
    reason = "feeder host"


if __name__ == "__main__":
    unittest.main(verbosity=2)
