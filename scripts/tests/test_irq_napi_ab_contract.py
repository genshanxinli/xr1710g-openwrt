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
     list came out empty again.  The second fix (a windowed rate) does not
     hold either: the tick is ~2 s apart, so a 6 s window holds 0-3 ticks and
     cpu0 read anywhere from 55/s to 184/s on the same board under the same
     load.  The test is now the since-boot share of the timer counts, which
     two independent runs put at 44.5/18.7/19.7/17.2% and 45.0/18.5/19.8/16.7%.
  3. The refusal path ran before the EXIT trap that removes TMP_FILES was
     installed, so every refused --run left irq-napi-ab.$$.irq-before/after
     behind.

The functions under test are copied out of the script, not re-implemented.
Point IRQ_NAPI_AB_UNDER_TEST at a copy to test that copy instead.
"""

import os
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

# The board's own arch_timer row, 7.4-rc3 at f3a119a90b, two samples one tick
# apart.  Every CPU's column grows (+429/+171/+193/+84): this is the shape the
# increment test could not classify.  The since-boot split of 16,005,708 is
# 44.5/18.7/19.7/17.2%, which is what IRQ_TIMER_SHARE_PCT=30 cuts.
BOARD_BEFORE = HEADER + (
    "  11:    7118352    2996988    3145460    2744908  GICv3   30 Level      arch_timer\n"
)
BOARD_AFTER = HEADER + (
    "  11:    7118781    2997159    3145653    2744992  GICv3   30 Level      arch_timer\n"
)

# The same row as a device read it on six --dry-run runs.  The since-boot
# counts never move (they are the same run of the same board, only the second
# sample differs), while the per-CPU deltas the old rate test divided by the
# window are exactly the 55/s..184/s spread the board showed, 139.0/s and
# 143.7/s included.  One tuple per run: (cpu0, cpu1, cpu2, cpu3) delta.
DRY_RUN_DELTAS = [
    (330, 132, 149, 65),    # cpu0 55.0/s
    (429, 171, 193, 84),    # cpu0 71.5/s -- one tick
    (660, 263, 297, 129),   # cpu0 110.0/s
    (834, 333, 376, 163),   # cpu0 139.0/s -- below the old 150/s cut
    (862, 344, 389, 169),   # cpu0 143.7/s -- below the old 150/s cut
    (1104, 441, 497, 215),  # cpu0 184.0/s
]

# Counts in BOARD_AFTER, per CPU.
BOARD_COUNTS = [7118781, 2997159, 3145653, 2744992]

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


def timer_row(counts):
    return HEADER + (
        "  11:    " + "    ".join(str(c) for c in counts) + "  GICv3   30 Level      arch_timer\n"
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
    """Reserved CPUs are the timer CPUs, picked by since-boot share."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)
        # is_uint is only needed by the old rate version's window guard; it
        # is kept in the body so the red proof calls that version fairly.
        self.body = (
            extract_function("is_uint")
            + extract_function("sample_sleep")
            + extract_function("timer_cpus")
        )

    def before(self, text):
        path = self.fixture.root / "interrupts.before"
        path.write_text(text)
        return path

    def timer_cpus(self, after, before=None, window=1, env=""):
        """Reserve from `after`; pass `before` to feed the old rate test."""
        (self.fixture.proc / "interrupts").write_text(after)
        call = "timer_cpus"
        if before is not None:
            call += f" {self.before(before)} {window}"
        out = run_sh(
            self.body + env + f'PROC_ROOT={self.fixture.proc}\n' + call + "\n"
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.split()

    def test_cumulative_counts_alone_reserve_nobody(self):
        # Four equal columns are 25% each, under IRQ_TIMER_SHARE_PCT=30.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        after = HEADER + (line % " 987654  987654  987654  987654")
        self.assertEqual(self.timer_cpus(after), [])

    def test_the_cpu_holding_the_share_is_reserved(self):
        # 6000 of 10000 timer interrupts since boot is 60%: the boot CPU's
        # shape, even though nothing ticks between the two samples.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        after = HEADER + (line % " 1000  1000  6000  1000")
        self.assertEqual(self.timer_cpus(after), ["2"])

    def test_a_one_tick_blip_does_not_carry_the_share(self):
        # 42 interrupts over one second is an idle CPU's trickle, and the
        # since-boot split stays at 25%: not the timer CPU.
        line = " 56:     %s  arch_timer  56 Edge      arch_timer\n"
        before = HEADER + (line % " 10000  10000  10000  10000")
        after = HEADER + (line % " 10000  10000  10042  10000")
        self.assertEqual(self.timer_cpus(after, before, window=1), [])

    def test_an_irq55_line_is_a_timer_row(self):
        # IRQ 55 is the vendor kernel's numbered timer line; inert on
        # 7.4-rc3 (no 55 row) but still matched where the kernel has it.
        line = " 55:     %s  mt76-npu  55 Edge      wifi0\n"
        after = HEADER + (line % " 1000  1000  1000  6000")
        self.assertEqual(self.timer_cpus(after), ["3"])

    def test_the_board_shape_reserves_the_boot_cpu_only(self):
        # 44.5/18.7/19.7/17.2% of 16,005,708: only cpu0 clears 30%.
        self.assertEqual(self.timer_cpus(BOARD_AFTER, BOARD_BEFORE, window=2), ["0"])

    def test_the_board_shape_is_not_four_reserved_cpus(self):
        # The regression this file exists for: '0 1 2 3' empties the split
        # target list and the fallback then pinned cpu0.
        got = self.timer_cpus(BOARD_AFTER, BOARD_BEFORE, window=2)
        self.assertNotEqual(got, ["0", "1", "2", "3"], got)
        self.assertEqual(len(got), 1, got)

    def test_six_device_runs_read_the_same_share_the_same_way(self):
        # The core fix: six runs of the same board, same since-boot counts,
        # deltas from 55/s to 184/s (139.0 and 143.7 among them).  Whatever
        # the rate columns say, the reserved set is the share set: cpu0.
        # Against the rate-first version five of the six read [] here.
        for delta in DRY_RUN_DELTAS:
            before = timer_row([c - d for c, d in zip(BOARD_COUNTS, delta)])
            got = self.timer_cpus(BOARD_AFTER, before, window=6)
            self.assertEqual(
                got,
                ["0"],
                f"delta {delta} moved the reserved set to {got}",
            )

    def test_cpu0_at_139_per_second_is_still_reserved(self):
        # The device read cpu0 at 139.0/s, under the old 150/s cut, while it
        # held 44.5% of the timer.  A reserved set without cpu0 lets the
        # split arm pin to cpu0, the one CPU this test exists to keep out.
        delta = DRY_RUN_DELTAS[3]
        before = timer_row([c - d for c, d in zip(BOARD_COUNTS, delta)])
        self.assertEqual(self.timer_cpus(BOARD_AFTER, before, window=6), ["0"])
        self.assertAlmostEqual(delta[0] / 6, 139.0, places=1)

    def test_the_share_cut_is_overridable_from_the_environment(self):
        # IRQ_TIMER_SHARE_PCT is the tuning knob: a board with a different
        # tick distribution needs a different cut and no edit to the script.
        self.assertEqual(
            self.timer_cpus(BOARD_AFTER, env="IRQ_TIMER_SHARE_PCT=100\n"), []
        )
        self.assertEqual(
            self.timer_cpus(BOARD_AFTER, env="IRQ_TIMER_SHARE_PCT=40\n"), ["0"]
        )
        self.assertEqual(
            self.timer_cpus(BOARD_AFTER, env="IRQ_TIMER_SHARE_PCT=10\n"),
            ["0", "1", "2", "3"],
        )

    def test_a_table_without_timer_rows_does_not_wait_for_a_sample(self):
        # No arch_timer and no 55 row: nothing to reserve, and no reason to
        # sleep inside a dry run.
        (self.fixture.proc / "interrupts").write_text(INTERRUPTS)
        started = time.monotonic()
        out = run_sh(self.body + f'PROC_ROOT={self.fixture.proc}\ntimer_cpus\n')
        elapsed = time.monotonic() - started
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.split(), [])
        self.assertLess(elapsed, 3.0, f"timer_cpus waited {elapsed:.1f}s for nothing")


class RpsMasks(unittest.TestCase):
    """--with-rps writes the mask of a real CPU, never 2^"" = 1."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)
        self.net = self.root / "net"
        self.queues = self.net / "cpu" / "queues"
        self.files = []
        for q in ("rx-0", "rx-1"):
            f = self.queues / q / "rps_cpus"
            f.parent.mkdir(parents=True)
            f.write_text("f\n")
            self.files.append(f)
        self.body = extract_function("is_uint") + extract_function("rps_set_cpu")

    def run_set(self, cpu):
        return run_sh(
            self.body
            + f"SYS_CLASS_NET={self.net}\nRPS_DEV=cpu\nWRITE_COUNT=0\n"
            + f'rps_set_cpu {cpu!r}\n'
            + 'printf "rc=%s writes=%s\\n" "$?" "$WRITE_COUNT"\n'
        )

    def test_cpu2_writes_the_cpu2_mask(self):
        out = self.run_set("2")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("rc=0 writes=2", out.stdout)
        for f in self.files:
            self.assertEqual(f.read_text().strip(), "4", f"{f} mask")

    def test_a_blank_cpu_is_refused_and_writes_nothing(self):
        # SPLIT_CHOSEN_CPU empty used to reach 2^"" = 1 and put all 32
        # queues on cpu0.
        out = self.run_set("")
        self.assertIn("rc=1 writes=0", out.stdout)
        for f in self.files:
            self.assertEqual(f.read_text().strip(), "f", f"{f} was overwritten")

    def test_a_non_numeric_cpu_is_refused(self):
        out = self.run_set("x")
        self.assertIn("rc=1 writes=0", out.stdout)
        for f in self.files:
            self.assertEqual(f.read_text().strip(), "f", f"{f} was overwritten")


class ExplicitMapChosenCpu(unittest.TestCase):
    """An explicit --irq-map names the CPU the rps masks follow."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)
        proc = self.fixture.proc
        (proc / "interrupts").write_text(
            HEADER
            + " 50:        900        100        100        100  mt7996e    0 Edge      pcie0\n"
            + " 51:        800        100        100        100  mt7996e    1 Edge      pcie1\n"
        )
        for irq in ("50", "51"):
            d = proc / "irq" / irq
            d.mkdir(parents=True)
            f = d / "smp_affinity"
            f.write_text("1\n")
            f.chmod(0o644)
        self.net = self.fixture.root / "net"
        (self.net / "cpu" / "queues" / "rx-0").mkdir(parents=True)
        (self.net / "cpu" / "queues" / "rx-0" / "rps_cpus").write_text("f\n")

    def test_the_first_map_record_names_the_rps_cpu(self):
        out = run_script(
            [
                "--proc-root",
                str(self.fixture.proc),
                "--sys-class-net",
                str(self.net),
                # online_cpus reads the host's /sys, not PROC_ROOT: pin the
                # list so the map validation does not depend on the runner.
                "--cpus",
                "0,1,2,3",
                "--irq-map",
                "50:2,51:3",
                "--with-rps",
                "--dry-run",
            ]
        )
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        # Before the fix this line said "cpu?" (SPLIT_CHOSEN_CPU was only set
        # on the automatic branch) and rps_set_cpu then wrote mask 1.
        self.assertIn(
            "--with-rps: the split arm also writes rps_cpus to cpu2",
            out.stdout,
        )


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
