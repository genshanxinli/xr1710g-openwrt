#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""An unreachable device is not a missing 2500baseT port (issue #70).

The defect: scripts/wireless/2.5g-wired.sh resolved the device ports in one
SSH round trip.  When that first contact failed, the candidate list was empty
and the script printed

    BLOCKED: no device port advertises 2500baseT

with exit 0: it asserted a hardware property it had never read.  The fix
checks reachability first and stops with exit 2 and

    BLOCKED: cannot reach <USER@DEVICE> (<first ssh error line>)

so a network fault is never recorded as the "2.5g-peer" hardware gap.

The test uses a stub ssh that fails the way the bench host did in the issue,
so the host-key state of the machine running the tests is irrelevant.  Run
from the repository root:

    python3 scripts/tests/test_2g5_ssh_unreachable.py

TWO_G5_SCRIPT_UNDER_TEST=/path/to/copy (or 2G5_SCRIPT_UNDER_TEST through
`env`) runs the case against another script, so the red proof (a copy with
the reachability check deleted) is one env var.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# A leading digit is legal in an environment name but not in a shell
# assignment, so both spellings are honoured.
WIRED = Path(
    os.environ.get("TWO_G5_SCRIPT_UNDER_TEST")
    or os.environ.get("2G5_SCRIPT_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/2.5g-wired.sh"
)

# The preflight path needs these before it reaches the device probe:
# check_link_tools (ip awk sed grep tr cut date) plus dirname for the
# no-client library path.
PREFLIGHT_TOOLS = ("ip", "awk", "sed", "grep", "tr", "cut", "date", "dirname")
UNREACHABLE = "root@192.0.2.1"

# What the bench host printed in the issue: ssh refuses the host key and
# never opens a session, so the device never answers ethtool.
SSH_STUB = """\
#!/bin/sh
printf "Host '192.0.2.1' is not in the trusted hosts file.\\n" >&2
printf "Didn't validate host key\\n" >&2
exit 255
"""


class UnreachableTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="2g5-unreachable-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name in PREFLIGHT_TOOLS:
            real = shutil.which(name)
            if real is None:
                self.skipTest("%s is not installed on this host" % name)
            (self.bin / name).symlink_to(real)
        ssh = self.bin / "ssh"
        ssh.write_text(SSH_STUB)
        ssh.chmod(0o755)
        self.sh = shutil.which("sh")
        self.assertIsNotNone(self.sh)

    def test_unreachable_is_not_a_hardware_verdict(self):
        result = subprocess.run(
            [self.sh, str(WIRED), "--device", UNREACHABLE],
            capture_output=True,
            text=True,
            cwd=str(self.tmp),
            env={"PATH": str(self.bin), "HOME": str(self.tmp)},
            check=False,
        )
        # Environment problem, not a hardware verdict: non-zero and named.
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BLOCKED: cannot reach %s" % UNREACHABLE,
                      result.stdout)
        self.assertIn("Host '192.0.2.1' is not in the trusted hosts file.",
                      result.stdout)
        # The old fold: an unchecked SSH failure must never become this.
        self.assertNotIn("no device port advertises 2500baseT", result.stdout)
        self.assertNotIn("2.5g-peer", result.stdout + result.stderr)
        self.assertNotIn("SKIP", result.stdout)


if __name__ == "__main__":
    unittest.main()
