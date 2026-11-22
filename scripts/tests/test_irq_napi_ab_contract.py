#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Contract tests for scripts/wireless/irq-napi-ab.sh (issue #66).

Three things the device run of 2026-11-22 showed:

  1. A blocked run exited 1.  rc=1 is documented in the script header as
     "setup/run/rollback failure (the trap has still tried to restore)", so a
     missing prerequisite was reported as a crash.  Every sibling harness
     (6g-rx.sh, 6g-clear-air.sh, 6g320-matrix.sh, edca-6g-ab.sh,
     multi-client.sh) exits 2 there.
  2. timer_cpus() tested a counter, and a counter cannot separate the timer
     CPUs on this board: GICv3 hands every arch_timer tick to all four CPUs,
     so the increment version (the first fix) reserved all four as well --
     7.4-rc3 deltas per tick were +429/+171/+193/+84 -- and the split target
     list came out empty again.  The test is now a rate, IRQ_TIMER_PER_S
     interrupts/s, over a window long enough to hold several ticks, with the
     since-boot share as the backstop for a window that saw no tick.
  3. The refusal path ran before the EXIT trap that removes TMP_FILES was
     installed, so every refused --run left irq-napi-ab.$$.irq-before/after
     behind.

The functions under test are copied out of the script, not re-implemented.
Point IRQ_NAPI_AB_UNDER_TEST at a copy to test that copy instead.
"""

import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("IRQ_NAPI_AB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/irq-napi-ab.sh"
)

HEADER = "           CPU0       CPU1       CPU2       CPU3\n"

# The board's own arch_timer rows, 7.4-rc3 at f3a119a90b, one tick apart.
# Every CPU's column grows (+429/+171/+193/+84): this is the shape the
# increment test could not classify, and the shape the rate test has to
# narrow down to the boot CPU.  Over the tick's ~2 s the rates are 215/86/97/42
# per second, which is where IRQ_TIMER_PER_S=150 comes from.
BOARD_BEFORE = HEADER + (
    "  11:    7118352    2996988    3145460    2744908  GICv3   30 Level      arch_timer\n"
)
BOARD_AFTER = HEADER + (
    "  11:    7118781    2997159    3145653    2744992  GICv3   30 Level      arch_timer\n"
)

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
    """Reserved CPUs are the timer CPUs, picked by rate, not by movement."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)
        self.body = (
            extract_function("is_uint")
            + extract_function("sample_sleep")
            + extract_function("timer_cpus")
        )

    def before(self, text):
        path = self.fixture.root / "interrupts.before"
        path.write_text(text)
        return path

    def timer_cpus(self, after, before, window=1, env=""):
        """Reserve against a SNAPSHOT that is `window` seconds old."""
        (self.fixture.proc / "interrupts").write_text(after)
        out = run_sh(
            self.body
            + env
            + f'PROC_ROOT={self.fixture.proc}\n'
            + f"timer_cpus {self.before(before)} {window}\n"
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.split()

    def test_cumulative_counts_alone_reserve_nobody(self):
        # Both columns are since-boot totals: equal numbers are no interrupt.
        # Four equal columns are 25% each, under IRQ_TIMER_SHARE_PCT=30.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        after = HEADER + (line % " 987654  987654  987654  987654")
        self.assertEqual(self.timer_cpus(after, after), [])

    def test_a_timer_increment_reserves_that_cpu(self):
        # 600 interrupts in the one-second window is 600/s, over the 150/s
        # threshold; the share stays under 30% so the rate clause is what
        # fires here.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        before = HEADER + (line % " 10000  10000  10000  10000")
        after = HEADER + (line % " 10000  10000  10600  10000")
        self.assertEqual(self.timer_cpus(after, before, window=1), ["2"])

    def test_an_increment_below_the_rate_is_not_reserved(self):
        # The old increment test reserved cpu2 for this; 42 interrupts in a
        # second is 42/s, an idle CPU's trickle, not the timer CPU.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        before = HEADER + (line % " 10000  10000  10000  10000")
        after = HEADER + (line % " 10000  10000  10042  10000")
        self.assertEqual(self.timer_cpus(after, before, window=1), [])

    def test_an_irq55_increment_reserves_that_cpu(self):
        # IRQ 55 is the vendor kernel's numbered timer line; inert on
        # 7.4-rc3 (no 55 row) but still matched where the kernel has it.
        line = " 55:     %s  mt76-npu  55 Edge      wifi0\n"
        before = HEADER + (line % " 20000  20000  20000  20000")
        after = HEADER + (line % " 20000  20000  20000  20400")
        self.assertEqual(self.timer_cpus(after, before, window=1), ["3"])

    def test_the_board_shape_reserves_the_boot_cpu_only(self):
        # The failing shape: all four columns grow, +429/+171/+193/+84 per
        # tick.  The tick is ~2 s old, so the rates are 215/86/97/42 per
        # second and only cpu0 clears 150/s.
        self.assertEqual(self.timer_cpus(BOARD_AFTER, BOARD_BEFORE, window=2), ["0"])

    def test_the_board_shape_is_not_four_reserved_cpus(self):
        # The regression this file exists for: '0 1 2 3' empties the split
        # target list and the fallback then pinned cpu0.
        got = self.timer_cpus(BOARD_AFTER, BOARD_BEFORE, window=2)
        self.assertNotEqual(got, ["0", "1", "2", "3"], got)
        self.assertEqual(len(got), 1, got)

    def test_a_one_second_window_on_the_board_shape_misclassifies(self):
        # Why IRQ_TIMER_SAMPLE_S defaults to 6 s and not to IRQ_SAMPLE_S: at
        # 1 s the per-tick deltas are read as per-second rates, cpu1 (171/s)
        # and cpu2 (193/s) clear a 150/s threshold as well, and the split
        # loses two targets.  The default has to hold several ticks.
        got = self.timer_cpus(BOARD_AFTER, BOARD_BEFORE, window=1)
        self.assertEqual(got, ["0", "1", "2"], got)
        text = SCRIPT.read_text()
        m = re.search(
            r"^IRQ_TIMER_SAMPLE_S=\$\{IRQ_TIMER_SAMPLE_S:-(\d+)\}", text, re.M
        )
        self.assertIsNotNone(m, "IRQ_TIMER_SAMPLE_S default is not in the script")
        self.assertGreaterEqual(
            int(m.group(1)),
            3,
            "the default window must hold 3+ ticks; at 1 s the board shape "
            "misclassifies cpu1 and cpu2",
        )

    def test_a_silent_window_still_reserves_the_boot_cpu(self):
        # Tickless idle: no column moves at all, so the rate clause says
        # nothing.  The since-boot share still names cpu0 (44.5% of
        # 16,005,708 against 18.7/19.7/17.2).
        self.assertEqual(self.timer_cpus(BOARD_AFTER, BOARD_AFTER, window=6), ["0"])

    def test_both_thresholds_are_overridable_from_the_environment(self):
        # IRQ_TIMER_PER_S and IRQ_TIMER_SHARE_PCT are the tuning knobs: a
        # board with a different tick cadence needs a different cut, and
        # neither needs an edit to the script.  Both set above the board's
        # own numbers, so nothing is reserved.
        got = self.timer_cpus(
            BOARD_AFTER,
            BOARD_BEFORE,
            window=2,
            env="IRQ_TIMER_PER_S=1000\nIRQ_TIMER_SHARE_PCT=100\n",
        )
        self.assertEqual(got, [], got)

    def test_a_table_without_timer_rows_does_not_pay_the_window(self):
        # No arch_timer and no 55 row: nothing to reserve, and no reason to
        # sleep IRQ_TIMER_SAMPLE_S inside a dry run.
        (self.fixture.proc / "interrupts").write_text(INTERRUPTS)
        started = time.monotonic()
        out = run_sh(
            self.body
            + "IRQ_TIMER_SAMPLE_S=6\n"
            + f'PROC_ROOT={self.fixture.proc}\n'
            + "timer_cpus\n"
        )
        elapsed = time.monotonic() - started
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.split(), [])
        self.assertLess(elapsed, 3.0, f"timer_cpus slept {elapsed:.1f}s for nothing")


class SplitTargetChoice(unittest.TestCase):
    """An empty target list blocks; it never falls back to every CPU."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)

    def choose(self, stub, interrupts=None, cpus="0 1 2 3"):
        proc = self.fixture.proc
        (proc / "interrupts").write_text(
            INTERRUPTS if interrupts is None else interrupts
        )
        body = (
            f"PROG=test\nMISSING=\nMISSING_N=0\nCPUS='{cpus}'\n"
            # PROC_ROOT has to be set before choose_split_targets runs:
            # the fallback reads $PROC_ROOT/interrupts.
            f"PROC_ROOT={proc}\n"
            + extract_function("note")
            + extract_function("add_missing")
            + extract_function("is_uint")
            + extract_function("sample_sleep")
            + extract_function("timer_cpus")
            + extract_function("choose_split_targets")
            + stub
            + "choose_split_targets\n"
            + 'printf "targets=[%s]\\nmissing=[%s]\\nbasis=[%s]\\n" '
            + '"$SPLIT_TARGETS" "$MISSING" "$SPLIT_BASIS"\n'
        )
        out = run_sh(body + "exit 0\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        fields = {}
        for line in out.stdout.splitlines():
            if line.startswith(("targets=[", "missing=[", "basis=[")):
                key, _, value = line.partition("=[")
                fields[key] = value[:-1] if value.endswith("]") else value
        return fields, out.stderr

    def test_an_empty_target_list_blocks_instead_of_pinning_cpu0(self):
        # The sample worked and excluded every CPU.  The old code set
        # SPLIT_TARGETS=$CPUS here, i.e. including cpu0.
        stub = (
            "pick_split_targets() {\n"
            '\tprintf "basis excluded=cpu0(50000/s) cpu1(50000/s) '
            'cpu2(50000/s) cpu3(50000/s) sample=1s\\n"\n'
            '\tprintf "targets \\n"\n'
            "}\n"
        )
        fields, err = self.choose(stub)
        self.assertEqual(fields["targets"], "")
        self.assertNotEqual(fields["targets"], "0 1 2 3")
        self.assertIn("split-no-target", fields["missing"])
        self.assertIn("every CPU is busy or timer-reserved", fields["basis"])
        self.assertIn("no CPU left to pin to", err)

    def test_a_failed_sample_uses_the_non_cpu0_rule(self):
        # /proc/stat or /proc/interrupts unreadable: the pre-sample rule,
        # and the report has to name that cause, not the empty target list.
        fields, _ = self.choose("pick_split_targets() { return 1; }\n")
        self.assertEqual(fields["targets"], "1 2 3")
        self.assertIn("no idle sample", fields["basis"])
        self.assertIn("unreadable", fields["basis"])
        self.assertEqual(fields["missing"], "")

    def test_a_failed_sample_with_every_cpu_reserved_blocks(self):
        # The fallback itself cannot name a target: blocked, not $CPUS.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        table = HEADER + (line % " 6000  4000")
        fields, err = self.choose(
            "pick_split_targets() { return 1; }\n", interrupts=table, cpus="0 1"
        )
        # share: cpu0 60%, cpu1 40%, both at or over IRQ_TIMER_SHARE_PCT=30.
        self.assertEqual(fields["targets"], "")
        self.assertIn("split-no-target", fields["missing"])
        self.assertIn("no CPU left to pin to", err)


if __name__ == "__main__":
    unittest.main()
