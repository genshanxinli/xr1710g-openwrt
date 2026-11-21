#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The 2.5G speed gate is a floor, not an exact rate (issue #70).

The defect: scripts/wireless/2.5g-wired.sh required the bench-host NIC and the
device port to report exactly 2500 Mb/s.  A 10G host NIC cabled to a 2.5G line
negotiates 2500 at the device and still reports 10000 in its own sysfs, and a
link that negotiated 10G is even further from "slow" - both were folded into

    SKIP: no 2.5G link

which is the issue's hardware verdict, not the truth.  The gate is now
`require_2g5_speed`: >= 2500 Mb/s and link up, with a note when the link is
faster than the floor.

The cases drive the real function through a stub ethtool, so the parse in
link_speed() is exercised too, and then reproduce the caller's skip line so
the greppable text is asserted, not just the exit status.

    python3 scripts/tests/test_2g5_speed_gate.py

TWO_G5_SCRIPT_UNDER_TEST=/path/to/copy (or 2G5_SCRIPT_UNDER_TEST) runs the
same cases against another script: that is the red proof, a copy with the gate
put back to "exactly 2500".
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

# What the link reports; empty means ethtool cannot tell (link down/unknown).
ETHTOOL_STUB = """\
#!/bin/sh
case "$1" in
-i) printf 'driver: stub\\n'; exit 0 ;;
esac
printf 'Settings for %s:\\n' "$1"
if [ -n "${STUB_SPEED-}" ]; then
	printf '\\tSpeed: %sMb/s\\n' "$STUB_SPEED"
else
	printf '\\tSpeed: Unknown!\\n'
fi
printf '\\tDuplex: Full\\n\\tLink detected: yes\\n'
"""

# Source the script as a library, gate the speed, and print the verdict with
# the same wording the callers use, so the message is checked as well.
DRIVER = """\
. "$1"
speed=$(link_speed eth1)
if require_2g5_speed host eth1 "$speed"; then
	printf 'accepted speed=%s\\n' "${speed:-unknown}"
else
	printf "skip_no_link host eth1 link is '%s' Mb/s, need >= 2500\\n" "${speed:-unknown}"
fi
"""


class SpeedGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="2g5-speed-gate-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        ethtool = self.bin / "ethtool"
        ethtool.write_text(ETHTOOL_STUB)
        ethtool.chmod(0o755)
        self.sh = shutil.which("sh")
        self.assertIsNotNone(self.sh)
        self.assertTrue(WIRED.is_file(), WIRED)

    def gate(self, speed):
        """Run the gate with a link that reports SPEED Mb/s."""
        env = dict(
            os.environ,
            PATH="%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            STUB_SPEED=speed,
            HOME=str(self.tmp),
            # Sourcing must not fall through to main().
            G25_WIRED_LIB_ONLY="1",
        )
        return subprocess.run(
            [self.sh, "-c", DRIVER, "gate", str(WIRED)],
            capture_output=True,
            text=True,
            cwd=str(self.tmp),
            env=env,
            check=False,
        )

    def test_10g_host_nic_is_accepted_with_a_note(self):
        result = self.gate("10000")
        self.assertIn("accepted speed=10000", result.stdout, result.stderr)
        self.assertIn(">= 2500, accepted", result.stderr)
        self.assertNotIn("SKIP", result.stdout)

    def test_2500_is_accepted(self):
        result = self.gate("2500")
        self.assertIn("accepted speed=2500", result.stdout, result.stderr)
        self.assertNotIn("accepted)", result.stderr)

    def test_1000_is_skipped_and_names_the_floor(self):
        result = self.gate("1000")
        self.assertIn(
            "skip_no_link host eth1 link is '1000' Mb/s, need >= 2500",
            result.stdout,
            result.stderr,
        )

    def test_unknown_speed_is_skipped(self):
        result = self.gate("")
        self.assertIn(
            "skip_no_link host eth1 link is 'unknown' Mb/s, need >= 2500",
            result.stdout,
            result.stderr,
        )

    def test_both_call_sites_carry_the_floor_wording(self):
        source = WIRED.read_text()
        self.assertIn(
            "skip_no_link \"host $iface link is '${speed:-unknown}' Mb/s, need >= 2500\"",
            source,
        )
        self.assertIn(
            "skip_no_link \"device $dev_if link is '${speed:-unknown}' Mb/s, need >= 2500\"",
            source,
        )


if __name__ == "__main__":
    unittest.main()
