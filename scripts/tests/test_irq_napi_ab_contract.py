#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Contract tests for scripts/wireless/irq-napi-ab.sh (issue #66).

Three things the device run of 2026-11-22 showed:

  1. A blocked run exited 1.  rc=1 is documented in the script header as
     "setup/run/rollback failure (the trap has still tried to restore)", so a
     missing prerequisite was reported as a crash.  Every sibling harness
     (6g-rx.sh, 6g-clear-air.sh, 6g320-matrix.sh, edca-6g-ab.sh,
     multi-client.sh) exits 2 there.
  2. timer_cpus() tested the cumulative /proc/interrupts column, and both
     arch_timer and irq55 counts are cumulative since boot: on a gateway up
     for a while every CPU looked reserved, the split target list came out
     empty and the fallback picked cpu0 -- the one CPU #66 exists to keep out.
     The test is now an increment between two samples.
  3. The refusal path ran before the EXIT trap that removes TMP_FILES was
     installed, so every refused --run left irq-napi-ab.$$.irq-before/after
     behind.

The functions under test are copied out of the script, not re-implemented.
Point IRQ_NAPI_AB_UNDER_TEST at a copy to test that copy instead.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("IRQ_NAPI_AB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/irq-napi-ab.sh"
)

HEADER = "           CPU0       CPU1       CPU2       CPU3\n"

# No station, but the two NPU lines exist: preflight then writes the
# irq-before/after pair for the beacon-rate sanity check.
INTERRUPTS = HEADER + (
    " 40:        100          0          0          0  mt76-npu   0 Edge      wifi0\n"
    " 41:         50          0          0          0  mt76-npu   1 Edge      wifi0\n"
)


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def run_sh(text):
    return subprocess.run(
        ["sh", "-c", text], capture_output=True, text=True, check=False
    )


def run_script(args, env=None):
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        ["sh", str(SCRIPT)] + args,
        capture_output=True,
        text=True,
        env=full_env,
        check=False,
    )


class ProcFixture:
    """A minimal /proc plus a private TMPDIR, cleaned up by the test."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.proc = self.root / "proc"
        self.tmp = self.root / "tmp"
        self.proc.mkdir()
        self.tmp.mkdir()
        (self.proc / "interrupts").write_text(INTERRUPTS)
        (self.proc / "stat").write_text(
            "cpu  1 0 1 1 0 0 0 0 0 0\ncpu0 1 0 1 1 0 0 0 0 0 0\n"
            "cpu1 1 0 1 1 0 0 0 0 0 0\ncpu2 1 0 1 1 0 0 0 0 0 0\n"
            "cpu3 1 0 1 1 0 0 0 0 0 0\n"
        )
        (self.proc / "softirqs").write_text("NET_TX 1 2 3 4\n")
        (self.proc / "uptime").write_text("1234.56 1234.00\n")

    def leftovers(self):
        return sorted(p.name for p in self.tmp.iterdir())

    def cleanup(self):
        self.dir.cleanup()


class ExitStatus(unittest.TestCase):
    """A blocked run is rc=2, never the rc=1 the header calls a failure."""

    def test_missing_prerequisites_exit_2(self):
        out = run_script(["--run"])
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("refusing to run; nothing was changed", out.stderr)

    def test_invalid_argument_still_exits_2(self):
        out = run_script(["--seconds", "0"])
        self.assertEqual(out.returncode, 2, out.stderr)

    def test_clean_dry_run_still_exits_0(self):
        out = run_script(["--dry-run"])
        self.assertEqual(out.returncode, 0, out.stderr)


class TempFiles(unittest.TestCase):
    """No refused run leaves its in-progress files in TMPDIR."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)

    def test_refused_run_leaves_no_temp_files(self):
        out = run_script(
            ["--proc-root", str(self.fixture.proc), "--run"],
            env={"TMPDIR": str(self.fixture.tmp)},
        )
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertEqual(
            self.fixture.leftovers(),
            [],
            "refused run left temp files behind: " + out.stderr,
        )

    def test_the_beacon_pair_really_is_created(self):
        # Without this, the test above would pass on a run that creates
        # nothing at all.
        out = run_script(
            [
                "--proc-root",
                str(self.fixture.proc),
                "--iface",
                "phy0.1-ap0",
                "--client",
                "aa:bb:cc:dd:ee:ff",
                "--client-ip",
                "192.0.2.10",
                "--run",
                "--out-dir",
                str(self.fixture.root / "out"),
            ],
            env={"TMPDIR": str(self.fixture.tmp)},
        )
        # The run may refuse (no real hardware) or fail later; either way the
        # pair was written and then removed.
        self.assertIn("npu_irq", out.stdout + out.stderr)
        self.assertEqual(self.fixture.leftovers(), [], out.stderr)


class TimerCpus(unittest.TestCase):
    """Reserved CPUs are the ones taking timer/irq55 interrupts now."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)
        self.body = (
            extract_function("sample_sleep")
            + extract_function("timer_cpus")
        )

    def before(self, text):
        path = self.fixture.root / "interrupts.before"
        path.write_text(text)
        return path

    def timer_cpus(self, after, before):
        (self.fixture.proc / "interrupts").write_text(after)
        out = run_sh(
            self.body
            + f'PROC_ROOT={self.fixture.proc}\n'
            + f"timer_cpus {self.before(before)}\n"
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.split()

    def test_cumulative_counts_alone_reserve_nobody(self):
        # Both columns are since-boot totals: equal numbers are no interrupt.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        after = HEADER + (line % " 987654  987654  987654  987654")
        self.assertEqual(self.timer_cpus(after, after), [])

    def test_a_timer_increment_reserves_that_cpu(self):
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        before = HEADER + (line % " 1000  1000  1000  1000")
        after = HEADER + (line % " 1000  1000  1042  1000")
        self.assertEqual(self.timer_cpus(after, before), ["2"])

    def test_an_irq55_increment_reserves_that_cpu(self):
        line = " 55:     %s  mt76-npu  55 Edge      wifi0\n"
        before = HEADER + (line % " 4000  0  0  0")
        after = HEADER + (line % " 4000  0  0  5")
        self.assertEqual(self.timer_cpus(after, before), ["3"])


if __name__ == "__main__":
    unittest.main()
