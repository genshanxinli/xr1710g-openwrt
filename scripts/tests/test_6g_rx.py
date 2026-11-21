#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/6g-rx.sh (issue #48).

The board has no 6G STA and no iperf3.  The hardware gate must come first:
"no 6G STA" is a clean skip (rc=0, "SKIP:") and a missing iperf3 must not
turn it into a failure.  The old preflight checked iperf3 before it looked
for a station, so the board exited 1 with "required command not found:
iperf3" and never reached the skip.

Run from the repository root:

    python3 scripts/tests/test_6g_rx.py
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/wireless/6g-rx.sh"

# Everything the discovery path needs.  iperf3 and ethtool are deliberately
# absent: no station exists, so the run must skip before asking for them.
TOOLS = (
    "awk", "cat", "cp", "cut", "date", "dirname", "grep", "head",
    "mkdir", "mv", "rm", "sed", "sh", "sleep", "tr", "ip",
)


def make_path(root):
    """A PATH with the text tools and a stub iw that sees no BSS."""
    bindir = root / "bin"
    bindir.mkdir()
    iw = bindir / "iw"
    iw.write_text("#!/bin/sh\nexit 0\n")
    iw.chmod(0o755)
    for tool in TOOLS:
        found = None
        for d in os.environ.get("PATH", "").split(os.pathsep):
            candidate = Path(d) / tool
            if candidate.is_file() and os.access(candidate, os.X_OK):
                found = candidate
                break
        if found is not None:
            (bindir / tool).symlink_to(found)
    return bindir


class NoStaPreflight(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bindir = make_path(self.root)

    def run_script(self, env_extra=None):
        env = os.environ.copy()
        env["PATH"] = str(self.bindir)
        if env_extra:
            env.update(env_extra)
        return subprocess.run(
            ["sh", str(SCRIPT)],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_missing_iperf3_still_skips_when_no_sta(self):
        out = self.run_script()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("SKIP:", out.stdout)
        self.assertNotIn("iperf3", out.stderr.lower())
        self.assertNotIn("iperf3", out.stdout.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
