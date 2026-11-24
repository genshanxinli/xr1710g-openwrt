#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Contract test for the generated MLO interface block (#89 MLO-1).

block_text() emits the wifi-iface for the 3-link MLD.  Without
"option network 'lan'" the generated netdev is not a member of br-lan, so
iperf from the STA never reaches the AP and every run ends as "blackhole".
The sibling harness (6g-clear-air.sh) already emits the option; this test
pins the same line here.

MLO_3LINK_UNDER_TEST points the test at another copy of the script so a red
proof can run against the pre-fix version (repo convention).
"""

import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("MLO_3LINK_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/mlo-3link.sh"
)


def extract_function(name):
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


class BlockTextTest(unittest.TestCase):
    def block(self):
        body = (
            "MARKER=mlo-test SECTION=mlo0\n"
            "DEV24=wlan0 DEV5=wlan1 DEV6=wlan2\n"
            "SSID=mlo-test KEY=secret\n" + extract_function("block_text")
            + "block_text\n"
        )
        return subprocess.run(
            ["sh", "-c", body], capture_output=True, text=True, check=False
        )

    def test_block_bridges_the_mld_into_lan(self):
        result = self.block()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "option network 'lan'", result.stdout,
            "block_text() has no option network; the MLD is unbridged and "
            "the run reports blackhole instead of measuring traffic:\n"
            + result.stdout,
        )

    def test_block_still_names_all_three_links(self):
        result = self.block()
        for dev in ("wlan0", "wlan1", "wlan2"):
            self.assertIn("list device '%s'" % dev, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
