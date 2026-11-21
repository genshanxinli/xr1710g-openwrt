#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Preflight ordering tests for the three 2.5G harnesses (issue #70).

The defect: every one of these scripts checked for local `iperf3` before it
looked at the link, so a bench host without iperf3 got

    error: missing local command(s): iperf3

and never reached the verdict the issue actually cares about:

 * scripts/wireless/2.5g-wired.sh  - "SKIP: no 2.5G link" (exit 0)
 * scripts/wireless/b-path-25g.sh  - "SKIP: no 2.5G feeder" (exit 0)
 * tools/wan-bench/2.5g.sh         - "local link speed is 1000 Mb/s, expected
   2500" (exit 1)

Reordering is the whole fix: the link verdict is decided before any traffic
tool is demanded.  A missing iperf3 is still a hard error, but only once there
is actually a 2.5G link to measure.

The tests build a PATH that has every command the scripts need except iperf3,
so the tool check is exercised for real instead of being mocked away.  Run
from the repository root:

    python3 scripts/tests/test_2g5_preflight_order.py
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WIRED = REPO_ROOT / "scripts/wireless/2.5g-wired.sh"
BPATH = REPO_ROOT / "scripts/wireless/b-path-25g.sh"
WANBENCH = REPO_ROOT / "tools/wan-bench/2.5g.sh"

# Every external command the preflight path may call, minus iperf3.
PREFLIGHT_TOOLS = (
    "ssh", "ethtool", "ip", "awk", "sed", "grep", "tr", "cut", "date",
    "id", "mkdir", "cat", "rm", "sleep", "readlink", "head", "tail", "wc",
    "python3",
)
# A device that does not answer: no case below is allowed to reach SSH.
UNREACHABLE = "root@192.0.2.1"


def make_tool_path(root):
    """A PATH with the real tools except iperf3; nothing is re-implemented."""
    bin_dir = Path(root) / "bin"
    bin_dir.mkdir()
    missing = []
    for name in PREFLIGHT_TOOLS:
        real = shutil.which(name)
        if real is None:
            missing.append(name)
            continue
        (bin_dir / name).symlink_to(real)
    if "iperf3" in os.listdir(bin_dir):
        raise AssertionError("iperf3 must not be on the preflight PATH")
    return bin_dir, missing


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="2g5-order-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin, missing = make_tool_path(self.tmp)
        self.sh = shutil.which("sh")
        # ip/ethtool/ssh are load-bearing for the preflight itself.
        for tool in ("ip", "ethtool", "ssh"):
            if tool in missing:
                self.skipTest("%s is not installed on this host" % tool)

    def run_script(self, script, args, env=None):
        child_env = {"PATH": str(self.bin), "HOME": str(self.tmp)}
        if env:
            child_env.update(env)
        return subprocess.run(
            [self.sh, str(script)] + args,
            capture_output=True,
            text=True,
            cwd=str(self.tmp),
            env=child_env,
            check=False,
        )


class WiredTest(Base):
    """scripts/wireless/2.5g-wired.sh: an absent host NIC is a clean skip."""

    def test_absent_nic_skips_before_the_iperf3_check(self):
        result = self.run_script(
            WIRED,
            ["--device", UNREACHABLE, "--host-lan10g-if", "hw89nope0",
             "--ports", "lan10g"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SKIP: no 2.5G link", result.stdout)
        self.assertNotIn("iperf3", result.stderr)




class BPathTest(Base):
    """scripts/wireless/b-path-25g.sh: no feeder is a clean skip."""

    def test_absent_feeder_skips_before_the_iperf3_check(self):
        result = self.run_script(
            BPATH,
            ["--device", UNREACHABLE, "--feeder-iface", "hw89nope0"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "SKIP: no 2.5G feeder")
        self.assertNotIn("iperf3", result.stderr)


class WanBenchTest(Base):
    """tools/wan-bench/2.5g.sh: a 1G NIC is reported as a link fault."""

    def setUp(self):
        super().setUp()
        self.sysfs = self.tmp / "sys"
        speed_dir = self.sysfs / "class/net/fake0"
        speed_dir.mkdir(parents=True)
        (speed_dir / "speed").write_text("1000\n")

    def test_one_gigabit_nic_reports_the_link_before_the_tool(self):
        result = self.run_script(
            WANBENCH,
            ["--iface", "fake0", "--peer", "192.0.2.9", "--out", "gate.json"],
            env={"SYSFS": str(self.sysfs)},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("local link speed is 1000 Mb/s, expected 2500",
                      result.stderr)
        self.assertNotIn("iperf3", result.stderr)


if __name__ == "__main__":
    unittest.main()
