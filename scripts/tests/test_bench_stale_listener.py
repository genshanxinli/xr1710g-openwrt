#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A stale iperf3 listener must not own the next passive run (bench #13).

A08-F9/A06-F1 sibling: `serve_iperf` backgrounds `iperf3 -s -1 -p PORT`
and only kills it on its own timeout.  A harness killed mid-run leaves the
listener behind, still bound to the control port; the next run then either
cannot listen, or the peer's test lands on that foreign server and the
number is measured by a process nobody controls.  Its data ports (PORT+1..
PORT+N) stay bound too.

The sweep must match the server command line, never the client role (which
talks to a peer server of its own), and never a different port.  BusyBox has
no pkill, and `set -f` in this script disables globbing, so /proc is walked
by name.

BENCH_UNDER_TEST points at a copy for the red proof.

Run from the repository root:

    python3 scripts/tests/test_bench_stale_listener.py
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("BENCH_UNDER_TEST")
    or REPO_ROOT / "scripts/bench-10g-unidirectional.sh"
)


def extract_function(name):
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


class StaleListenerSweep(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.proc = root / "proc"
        self.proc.mkdir()
        self.proc.joinpath("self").mkdir()
        self.kill_log = root / "killed.txt"
        self.kill = root / "kill-stub"
        self.kill.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$1\" >>\"$KILL_LOG\"\n"
        )
        self.kill.chmod(0o755)

    def make(self, pid, argv):
        d = self.proc / str(pid)
        d.mkdir()
        (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")

    def sweep(self, port="5201"):
        body = (
            extract_function("sweep_stale_listeners")
            + f"SWEEP_PROC={str(self.proc)!r}\n"
            + f"KILL_BIN={str(self.kill)!r}\n"
            + f"PORT={port}\nDRY_RUN=0\nKILL_LOG={str(self.kill_log)!r}\n"
            + "export KILL_LOG\n"
            + "sweep_stale_listeners\n"
        )
        out = subprocess.run(
            ["sh", "-c", body], capture_output=True, text=True, check=False
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return self.kill_log.read_text().split() if self.kill_log.exists() else []

    def test_a_server_on_our_port_is_killed(self):
        self.make(111, ["/usr/bin/iperf3", "-s", "-1", "-J", "-p", "5201"])
        self.make(222, ["/usr/bin/iperf3", "-c", "10.0.0.2", "-p", "5201"])
        self.make(333, ["/usr/bin/iperf3", "-s", "-1", "-p", "5202"])
        self.assertEqual(self.sweep(), ["111"])

    def test_an_unrelated_command_that_mentions_iperf3_is_left_alone(self):
        self.make(444, ["/bin/sh", "-c", "iperf3 -s -p 5201"])
        self.assertEqual(self.sweep(), [])

    def test_a_clean_proc_tree_kills_nothing(self):
        self.assertEqual(self.sweep(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
