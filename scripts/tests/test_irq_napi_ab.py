#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Behaviour tests for scripts/wireless/irq-napi-ab.sh.

The three defects this harness had on the board (issue #66):

  1. "[ "$WINDOW_S" = 0 ]" never matched the "%.2f" value "0.00", so every
     rate divided by a zero window.  The window is now an integer number of
     milliseconds and a zero window is refused before anything runs.
  2. The automatic split pinned candidate IRQs to the boot CPU (and later to
     "any non-cpu0 CPU"), while cpu0 carries arch_timer (~2.5 M IRQ/s) and
     IRQ55 (~1.69 M/s): the split arm could not show a difference.  The target
     is now the most idle CPU, sampled from /proc/stat, excluding a CPU whose
     interrupt rate is already hot.
  3. --irq-map failed fast when an IRQ's smp_affinity is read-only (the
     mt7996e-managed lines 49..57 on the XR1710G image).  It now degrades to a
     read-only report of every requested IRQ and exits 0.

Also covered: the threaded arm's default value is the opposite of what the
board runs (the image has napi_threaded=1, so testing 1 again measures
nothing).

The functions under test are copied out of the script, not re-implemented, so
a change in the script is exercised.  Run from the repository root:

    python3 scripts/tests/test_irq_napi_ab.py
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/wireless/irq-napi-ab.sh"

# /proc/interrupts the board reports: the managed mt7996e MSI lines, and the
# two files that back them are mode 0444 even for root.
INTERRUPTS = """            CPU0       CPU1       CPU2       CPU3
 49:          0          0          0          0  mt7996e-hif   0 Edge      wifi1
 50:          1          2          3     987654  mt7996e-hif   1 Edge      wifi1
"""

STAT = """cpu  100 0 100 900 0 0 0 0 0 0
cpu0 100 0 100 800 0 0 0 0 0 0
cpu1 100 0 100 700 0 0 0 0 0 0
cpu2 100 0 100 950 0 0 0 0 0 0
cpu3 100 0 100 900 0 0 0 0 0 0
"""


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def run_sh(body, cwd=None):
    return subprocess.run(
        ["sh", "-c", body], capture_output=True, text=True, cwd=cwd, check=False
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


class Fixture:
    """A fake /proc with the two managed, read-only mt7996e IRQ lines."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        proc = self.root / "proc"
        (proc / "irq" / "49").mkdir(parents=True)
        (proc / "irq" / "50").mkdir(parents=True)
        (proc / "interrupts").write_text(INTERRUPTS)
        (proc / "stat").write_text(STAT)
        (proc / "softirqs").write_text("NET_TX 1 2 3 4\n")
        (proc / "uptime").write_text("1234.56 1234.00\n")
        (proc / "irq" / "49" / "smp_affinity").write_text("3\n")
        (proc / "irq" / "50" / "smp_affinity").write_text("4\n")
        for irq in ("49", "50"):
            (proc / "irq" / irq / "smp_affinity").chmod(0o444)
        self.proc = proc

    def cleanup(self):
        self.dir.cleanup()


class WindowMilliseconds(unittest.TestCase):
    """The window is integer milliseconds and zero is refused up front."""

    def test_zero_window_is_refused_with_a_window_message(self):
        out = run_script(["--window-ms", "0"])
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("--window-ms must be", out.stderr)
        self.assertNotIn("unknown option", out.stderr)
        self.assertNotIn("division", out.stderr.lower())

    def test_zero_seconds_is_refused(self):
        out = run_script(["--seconds", "0"])
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("--seconds must be", out.stderr)

    def test_fractional_seconds_become_integer_milliseconds(self):
        out = run_script(["--seconds", "0.5", "--dry-run"])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("window_ms=500", out.stdout)

    def test_window_ms_is_used_directly(self):
        out = run_script(["--window-ms", "2500", "--dry-run"])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("window_ms=2500", out.stdout)
        # The source still gets whole seconds, rounded up.
        self.assertIn("window=3", out.stdout)


class SplitTargets(unittest.TestCase):
    """The split target is the most idle CPU, never one carrying a hot IRQ."""

    def setUp(self):
        self.body = (
            extract_function("split_targets_from_metrics")
            + extract_function("cpu_metrics")
        )

    def test_metrics_turn_two_samples_into_idle_and_rate(self):
        tagged = (
            "stat a 0 100 1000\nstat a 1 200 1000\n"
            "stat b 0 400 2000\nstat b 1 700 2000\n"
            "irq a 0 0\nirq a 1 0\nirq b 0 2500000\nirq b 1 300\n"
        )
        out = run_sh(self.body + "cpu_metrics <<'EOF'\n" + tagged + "EOF\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        lines = dict(
            (line.split()[1], line)
            for line in out.stdout.strip().splitlines()
        )
        # cpu0: 300 of 1000 jiffies idle, 2.5 M interrupts in the interval.
        self.assertIn("idle_pct 30.0", lines["0"])
        self.assertIn("irq_per_s 2500000", lines["0"])
        # cpu1: 500 of 1000 idle, 300 interrupts.
        self.assertIn("idle_pct 50.0", lines["1"])
        self.assertIn("irq_per_s 300", lines["1"])

    def test_boot_cpu_with_a_hot_line_is_excluded(self):
        metrics = (
            "cpu 0 idle_pct 97.0 irq_per_s 2500000\n"
            "cpu 1 idle_pct 60.0 irq_per_s 120\n"
            "cpu 2 idle_pct 91.0 irq_per_s 40\n"
            "cpu 3 idle_pct 88.0 irq_per_s 10\n"
        )
        out = run_sh(
            self.body
            + f"split_targets_from_metrics 50000 1 <<'EOF'\n{metrics}EOF\n"
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("cpu0(2500000/s)", out.stdout)
        targets = [
            line.split(None, 1)[1]
            for line in out.stdout.splitlines()
            if line.startswith("targets ")
        ][0]
        # cpu0 is the most idle but is already saturated: not a target.
        self.assertEqual(targets.split()[0], "2")
        self.assertNotIn("0", targets.split())

    def test_first_target_is_the_most_idle_cpu(self):
        metrics = (
            "cpu 0 idle_pct 50.0 irq_per_s 100\n"
            "cpu 1 idle_pct 70.0 irq_per_s 100\n"
            "cpu 2 idle_pct 95.0 irq_per_s 100\n"
        )
        out = run_sh(
            self.body
            + f"split_targets_from_metrics 50000 2 <<'EOF'\n{metrics}EOF\n"
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("idlest=cpu2(95.0% idle, 100 irq/s)", out.stdout)
        self.assertIn("sample=2s", out.stdout)
        targets = [
            line.split(None, 1)[1]
            for line in out.stdout.splitlines()
            if line.startswith("targets ")
        ][0]
        self.assertEqual(targets, "2 1 0")


class PerCpuInterruptTotals(unittest.TestCase):
    """/proc/interrupts parsing keeps CPU0 and does not shift the columns.

    The header has no label column, so $1 is CPU0 while a data row has the
    IRQ number in $1.  The old loop started at $2 and read every CPU one
    column to the left, dropping the last CPU; the idle/rate sample that
    picks the split target then named the wrong CPUs (and could hand the
    boot CPU's hot line to another core).
    """

    def setUp(self):
        self.body = extract_function("irq_cpu_totals")

    def test_cpu0_is_first_and_nothing_is_dropped(self):
        out = run_sh(
            self.body
            + "f=$(mktemp)\ncat >\"$f\" <<'EOF'\n"
            + INTERRUPTS
            + "EOF\nirq_cpu_totals \"$f\" t\nrm -f \"$f\"\n",
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(
            out.stdout.strip().splitlines(),
            [
                "irq t 0 1",       # IRQ 49 has 0, IRQ 50 has 1 on CPU0
                "irq t 1 2",
                "irq t 2 3",
                "irq t 3 987654",
            ],
        )


class ReadOnlyIrqMap(unittest.TestCase):
    """A read-only --irq-map is a report, not a failure."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_read_only_map_reports_and_exits_zero(self):
        out = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--irq-map", "49:2,50:3",
                "--run",
                "--iface", "phy0.1-ap0",
                "--client", "192.168.1.236",
                "--out-dir", str(self.fixture.root / "out"),
            ]
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("read-only", out.stdout)
        self.assertIn("requested map: 49:2 50:3", out.stdout)
        for irq in ("49", "50"):
            line = [
                l for l in out.stdout.splitlines() if f"irq {irq} requested_cpu" in l
            ]
            self.assertEqual(len(line), 1, out.stdout)
            self.assertIn("writable=no", line[0])
            self.assertIn("mode=-r--r--r--", line[0])
        # The read-only path still writes its result.json.
        json_line = [l for l in out.stdout.splitlines() if l.startswith("result:")]
        self.assertEqual(len(json_line), 1, out.stdout)
        data = json.loads(Path(json_line[0].split("result:", 1)[1].strip()).read_text())
        self.assertEqual(data["mode"], "read-only")
        self.assertEqual(data["irq_map_readonly"], 1)


class ThreadedDefault(unittest.TestCase):
    """The threaded arm tests the opposite of the board's current value."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def run_with_param(self, value, extra=()):
        param = self.fixture.root / f"napi_threaded_{value}"
        param.write_text(f"{value}\n")
        return run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--napi-param", str(param),
                *extra,
            ]
        )

    def test_board_running_threaded_tests_zero(self):
        out = self.run_with_param("1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("baseline_threaded=1", out.stdout)
        self.assertIn("arm_value=0", out.stdout)

    def test_board_running_unthreaded_tests_one(self):
        out = self.run_with_param("0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("baseline_threaded=0", out.stdout)
        self.assertIn("arm_value=1", out.stdout)

    def test_explicit_value_wins(self):
        out = self.run_with_param("1", ["--threaded-value", "1"])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("baseline_threaded=1", out.stdout)
        self.assertIn("arm_value=1", out.stdout)

    def test_unknown_baseline_falls_back_to_one(self):
        out = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--napi-param", str(self.fixture.root / "missing"),
            ]
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("baseline_threaded=unavailable", out.stdout)
        self.assertIn("arm_value=1", out.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
