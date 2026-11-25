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
SCRIPT = Path(
    os.environ.get("IRQ_NAPI_AB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/irq-napi-ab.sh"
)

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

# The board's boot CPU carries the timer and the NPU line; neither is a
# usable split target even when its generic interrupt rate is below the
# IRQ_BUSY_PER_S threshold.
TIMER_INTERRUPTS = """ 40:        100          0          0          0  mt76-npu   0 Edge      wifi0
 41:         50          0          0          0  mt76-npu   1 Edge      wifi0
 55:       4000          0          0          0  mt76-npu  55 Edge      wifi0
 56:      30000          0          0          0  arch_timer  56 Edge      arch_timer
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

    def __init__(self, rps_values=None, timer_on_cpu0=False):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        proc = self.root / "proc"
        (proc / "irq" / "49").mkdir(parents=True)
        (proc / "irq" / "50").mkdir(parents=True)
        interrupts = INTERRUPTS
        if timer_on_cpu0:
            interrupts += TIMER_INTERRUPTS
        (proc / "interrupts").write_text(interrupts)
        (proc / "stat").write_text(STAT)
        (proc / "softirqs").write_text("NET_TX 1 2 3 4\n")
        (proc / "uptime").write_text("1234.56 1234.00\n")
        (proc / "irq" / "49" / "smp_affinity").write_text("3\n")
        (proc / "irq" / "50" / "smp_affinity").write_text("4\n")
        for irq in ("49", "50"):
            (proc / "irq" / irq / "smp_affinity").chmod(0o444)
        self.proc = proc
        self.sys_class_net = None
        if rps_values is not None:
            self.sys_class_net = self.root / "sys" / "class" / "net"
            queues = self.sys_class_net / "cpu" / "queues"
            for index, value in enumerate(rps_values):
                rx = queues / f"rx-{index}"
                rx.mkdir(parents=True)
                (rx / "rps_cpus").write_text(value + "\n")

    def cleanup(self):
        self.dir.cleanup()


class WindowMilliseconds(unittest.TestCase):
    """The window is integer milliseconds and zero is refused up front."""

    def test_zero_window_is_refused_with_a_window_message(self):
        out = run_script(["--window-ms", "0"])
        self.assertEqual(out.returncode, 2)
        self.assertIn("--window-ms must be", out.stderr)
        self.assertNotIn("unknown option", out.stderr)
        self.assertNotIn("division", out.stderr.lower())

    def test_zero_seconds_is_refused(self):
        out = run_script(["--seconds", "0"])
        self.assertEqual(out.returncode, 2)
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
    """F2: read-only --irq-map writes result.json; --run exits 2, --dry-run exits 0."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_read_only_map_run_reports_and_exits_2(self):
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
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
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

    def test_read_only_map_dry_run_still_exits_0(self):
        out = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--irq-map", "49:2,50:3",
                "--dry-run",
                "--out-dir", str(self.fixture.root / "out-dry"),
            ]
        )
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        data = json.loads((self.fixture.root / "out-dry" / "result.json").read_text())
        self.assertEqual(data["mode"], "read-only")
        self.assertEqual(data["irq_map_readonly"], 1)

    def test_explicit_writable_irq_outside_irq_names_is_probed(self):
        # IRQ 88 does not match IRQ_NAMES, yet is writable and named in --irq-map.
        (self.fixture.proc / "irq" / "88").mkdir(parents=True)
        aff = self.fixture.proc / "irq" / "88" / "smp_affinity"
        aff.write_text("1\n")
        aff.chmod(0o644)
        (self.fixture.proc / "interrupts").write_text(
            INTERRUPTS + " 88: 10 0 0 0 custom-dev 0 Edge eth0\n"
        )
        out = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--cpus", "0,1,2,3",
                "--irq-map", "88:2",
                "--dry-run",
            ]
        )
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertNotIn("--irq-map is read-only", out.stdout, out.stdout)
        self.assertIn("irq 88 -> cpu2", out.stdout, out.stdout)
        self.assertIn("dry-run OK", out.stdout, out.stdout)


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


class RpsAndBeacon(unittest.TestCase):
    """RPS decides the softirq hotspot; the npu IRQs tick at beacon rate."""

    def run_fixture(self, fixture, extra=()):
        args = [
            "--proc-root", str(fixture.proc),
            "--iface", "phy0.1-ap0",
            "--client", "192.168.1.236",
            "--out-dir", str(fixture.root / "out"),
        ]
        if fixture.sys_class_net is not None:
            args += ["--sys-class-net", str(fixture.sys_class_net)]
        return run_script(args + list(extra))

    def test_split_arm_skips_when_rps_nonzero(self):
        fixture = Fixture(rps_values=["f"] * 32)
        self.addCleanup(fixture.cleanup)
        out = self.run_fixture(fixture)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(
            "SKIP: softirq hotspot is decided by rps_cpus, not by mt76-npu irq affinity",
            out.stdout,
        )

    def test_rps_cpus_is_reported(self):
        fixture = Fixture(rps_values=["f"] * 32)
        self.addCleanup(fixture.cleanup)
        # Under --run, read-only --irq-map exits 2 while still writing result.json.
        out = self.run_fixture(fixture, ["--run", "--irq-map", "49:2"])
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
        json_line = [l for l in out.stdout.splitlines() if l.startswith("result:")]
        self.assertEqual(len(json_line), 1, out.stdout)
        data = json.loads(Path(json_line[0].split("result:", 1)[1].strip()).read_text())
        self.assertEqual(len(data["rps_cpus"]), 32, data.get("rps_cpus"))
        self.assertEqual(data["rps_nonzero_queues"], 32)

    def test_target_cpu_excludes_timer_core(self):
        fixture = Fixture(rps_values=["0"] * 32, timer_on_cpu0=True)
        self.addCleanup(fixture.cleanup)
        out = self.run_fixture(fixture)
        self.assertEqual(out.returncode, 0, out.stderr)
        line = [l for l in out.stdout.splitlines() if "split targets:" in l]
        self.assertEqual(len(line), 1, out.stdout)
        chosen = line[0].split(":", 1)[1].strip().split(",")[0]
        self.assertNotEqual(chosen, "0", out.stdout)

    def test_beacon_rate_warn(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        before = Path(tmp.name) / "before"
        after = Path(tmp.name) / "after"
        before.write_text(
            " 40: 0 0 0 0 mt76-npu 0 Edge wifi0\n"
            " 41: 0 0 0 0 mt76-npu 1 Edge wifi0\n"
        )
        # 500 interrupts in one second, far above the 10..40/s beacon band.
        after.write_text(
            " 40: 500 0 0 0 mt76-npu 0 Edge wifi0\n"
            " 41: 7 0 0 0 mt76-npu 1 Edge wifi0\n"
        )
        body = (
            "say() { printf '%s\n' \"$*\"; }\n"
            + extract_function("irq_total_delta")
            + extract_function("npu_beacon_rate")
        )
        out = run_sh(
            body + f'npu_beacon_rate "{before}" "{after}" 1\n',
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("WARN: npu irq rate is not beacon-like", out.stdout)


class FindingsF3ToF12(unittest.TestCase):
    """Regression tests for #66 findings F3, F4, F6, F7, F9, F12."""

    def setUp(self):
        self.fixture = Fixture(rps_values=["f", "f"])
        self.addCleanup(self.fixture.cleanup)

    def test_f3_unavailable_rps_fails_closed_unless_allowed(self):
        empty_net = self.fixture.root / "empty-net"
        empty_net.mkdir()
        out_block = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--sys-class-net", str(empty_net),
                "--irq-map", "49:2",
                "--dry-run",
                "--out-dir", str(self.fixture.root / "f3-block"),
            ]
        )
        self.assertEqual(out_block.returncode, 0, out_block.stdout + out_block.stderr)
        data_block = json.loads((self.fixture.root / "f3-block" / "result.json").read_text())
        self.assertEqual(data_block["rps_probe"], "unavailable")
        self.assertEqual(data_block["rps_blocks_split"], 1)

        out_allow = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--sys-class-net", str(empty_net),
                "--irq-map", "49:2",
                "--allow-unknown-rps",
                "--dry-run",
                "--out-dir", str(self.fixture.root / "f3-allow"),
            ]
        )
        self.assertEqual(out_allow.returncode, 0, out_allow.stdout + out_allow.stderr)
        data_allow = json.loads((self.fixture.root / "f3-allow" / "result.json").read_text())
        self.assertEqual(data_allow["rps_probe"], "unavailable")
        self.assertEqual(data_allow["rps_blocks_split"], 0)

    def test_f4_rps_mask_flag_and_save_restore(self):
        bad = run_script(["--rps-mask", "zz", "--dry-run"])
        self.assertEqual(bad.returncode, 2, bad.stdout + bad.stderr)

        dry = run_script(
            [
                "--proc-root", str(self.fixture.proc),
                "--sys-class-net", str(self.fixture.sys_class_net),
                "--rps-mask", "0",
                "--dry-run",
            ]
        )
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertIn("--rps-mask", dry.stdout, dry.stdout)

        body = (
            f"SYS_CLASS_NET={self.fixture.sys_class_net}\n"
            "RPS_DEV=cpu\nRPS_SAVED=\nWRITE_COUNT=0\n"
            "note() { printf '%s\\n' \"$*\" >&2; }\n"
            + extract_function("rps_save")
            + extract_function("rps_set_mask")
            + extract_function("rps_restore")
            + "rps_save\n"
            + "rps_set_mask 0 || exit 11\n"
            + "printf 'mid=%s\\n' \"$(cat \"$SYS_CLASS_NET/cpu/queues/rx-0/rps_cpus\")\"\n"
            + "rps_set_mask E || exit 12\n"
            + "printf 'hex=%s\\n' \"$(cat \"$SYS_CLASS_NET/cpu/queues/rx-1/rps_cpus\")\"\n"
            + "rps_restore || exit 13\n"
            + "printf 'end=%s\\n' \"$(cat \"$SYS_CLASS_NET/cpu/queues/rx-0/rps_cpus\")\"\n"
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("mid=0", res.stdout)
        self.assertIn("hex=e", res.stdout)
        self.assertIn("end=f", res.stdout)

    def test_f6_npu_beacon_rate_uses_dynamic_irqs_not_40_41(self):
        before = self.fixture.root / "npu.before"
        after = self.fixture.root / "npu.after"
        before.write_text(
            " 23: 0 0 0 0 mt76-npu 0 Edge wifi0\n"
            " 24: 0 0 0 0 mt76-npu 1 Edge wifi0\n"
        )
        after.write_text(
            " 23: 25 0 0 0 mt76-npu 0 Edge wifi0\n"
            " 24: 10 0 0 0 mt76-npu 1 Edge wifi0\n"
        )
        body = (
            "say() { printf '%s\\n' \"$*\"; }\n"
            "note() { printf '%s\\n' \"$*\" >&2; }\n"
            "IRQ_RECORDS='23|mt76-npu|wifi0\n24|mt76-npu|wifi0'\n"
            + extract_function("irq_total_delta")
            + extract_function("npu_beacon_rate")
            + f'npu_beacon_rate "{before}" "{after}" 1\n'
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("irq23=25.0/s", res.stdout, res.stdout)
        self.assertIn("irq24=10.0/s", res.stdout, res.stdout)
        self.assertIn("beacon_like=yes", res.stdout, res.stdout)
        self.assertNotIn("irq40", res.stdout, res.stdout)

    def test_f7_collect_arm_and_json_emit_hi_and_tasklet_softirqs(self):
        arm_dir = self.fixture.root / "arm"
        arm_dir.mkdir()
        (arm_dir / "softirqs.before").write_text(
            "                    CPU0       CPU1\n"
            "          HI:         10         20\n"
            "      NET_TX:        100        200\n"
            "      NET_RX:        300        400\n"
            "     TASKLET:        500        600\n"
        )
        (arm_dir / "softirqs.after").write_text(
            "                    CPU0       CPU1\n"
            "          HI:         15         30\n"
            "      NET_TX:        110        220\n"
            "      NET_RX:        350        450\n"
            "     TASKLET:        700        900\n"
        )
        for name in ("interrupts.before", "interrupts.after",
                     "station.before", "station.after",
                     "procstat.before", "procstat.after",
                     "iface_tx_bytes.before", "iface_tx_bytes.after",
                     "iface_tx_packets.before", "iface_tx_packets.after"):
            (arm_dir / name).write_text("")
        body = (
            f"ARM_DIR={arm_dir}\nCURRENT_ARM=baseline\nARM_STATUS=ok\nARM_REASON=\n"
            "WINDOW_MS_MEASURED=1000\nWINDOW_MS=1000\nWARMUP=1\nPROCS=1\nRATE=100\n"
            "IFACE=wlan0\nCLIENT_IP=1.2.3.4\nCLIENT_MAC=\nSOURCE_KIND=custom\n"
            "BIND_IFACE=br-lan\nNAPI_PATH=\nNAPI_SAVED=\nAPPLIED_NAPI=\nNAPI_CHANGED=0\n"
            "NAPI_WRITABLE=0\nAPPLIED_SPLIT=\nSPLIT_CHANGED=0\nIRQ_EXCLUDED=\n"
            "APPLIED_AFF=\nARM_WRITES=0\nMPSTAT_OK=0\nIRQ_RECORDS=\nIRQ_WRITABLE=\n"
            "BASELINE_UNCHANGED=1\nRESTORE_FAILED=0\nSOURCE_EXIT=ok\n"
            "ARM_RPS_BEFORE='[]'\nARM_RPS_AFTER='[]'\nARM_RPS_CHANGED=false\n"
            "RESULT_RECORDS=\n"
            "say() { printf '%s\\n' \"$*\"; }\n"
            + extract_function("is_uint")
            + extract_function("as_uint")
            + extract_function("read_uint_file")
            + extract_function("delta_uint")
            + extract_function("delta_or_unavail")
            + extract_function("field_or_unavail")
            + extract_function("softirq_label_percpu")
            + extract_function("softirq_label_total")
            + extract_function("softirq_total_percpu")
            + extract_function("softirq_total_delta")
            + extract_function("procstat_pct_percpu")
            + extract_function("irq_total_delta")
            + extract_function("irq_delta_percpu")
            + extract_function("contains_word")
            + extract_function("affinity_of")
            + extract_function("read_affinity")
            + extract_function("collect_arm")
            + extract_function("record_arm_result")
            + extract_function("print_arm_summary")
            + extract_function("arm_json_records")
            + "collect_arm\nprint_arm_summary\nprintf 'JSON='\narm_json_records\n"
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("softirq_hi_delta=15", res.stdout, res.stdout)
        self.assertIn("softirq_tasklet_delta=500", res.stdout, res.stdout)
        self.assertIn("softirq_hi_percpu=0:5,1:10", res.stdout, res.stdout)
        self.assertIn("softirq_tasklet_percpu=0:200,1:300", res.stdout, res.stdout)
        json_text = res.stdout.split("JSON=", 1)[1].strip()
        rec = json.loads(json_text)
        self.assertEqual(rec["hi"], "15")
        self.assertEqual(rec["tasklet"], "500")
        self.assertEqual(rec["hi_percpu"], "0:5,1:10")
        self.assertEqual(rec["tasklet_percpu"], "0:200,1:300")

    def _run_all_harness(self, out_dir, stub_measure):
        return (
            f"OUT_DIR={out_dir}\nPROG=irq-napi-ab.sh\nRUN=1\n"
            "IFACE=wlan0\nCLIENT=1.2.3.4\nCLIENT_IP=1.2.3.4\nCLIENT_MAC=aa:bb:cc:dd:ee:01\n"
            "CPUS='0 1 2 3'\nIRQ_NAMES=mt76-npu\nNAPI_PATH=\nNAPI_SAVED=\n"
            "ARMS='split'\nWINDOW_MS=1000\nWINDOW=1\nWARMUP=1\nPROCS=1\nRATE=100\n"
            "SPLIT_TARGETS='2 3'\nSPLIT_CHOSEN_CPU=2\nSPLIT_BASIS=test\nSPLIT_MAP=none\n"
            "THREADED_BASELINE=1\nTHREADED_VALUE=0\nTHREADED_SOURCE=auto\n"
            "SOURCE_KIND=custom\nSOURCE='sleep 1'\n"
            f"PROC_ROOT={self.fixture.proc}\nDEBUGFS_ROOT=/none\n"
            "IRQ_MAP_READONLY=0\nIRQ_MAP_REQUEST=\nIRQ_RECORDS=\nIRQ_WRITABLE=\n"
            "IRQ_EXCLUDED=\nTIMER_SOURCE=no-timer-row\nTIMER_SHARES=\nTIMER_RESERVED=\n"
            "RPS_DEV=cpu\nRPS_CPUS='[\"f\"]'\nRPS_NONZERO_QUEUES=1\nRPS_PROBE=ok\n"
            "SPLIT_RPS_BLOCKS=1\nWITH_RPS=0\nRPS_MASK_OPT=\nALLOW_UNKNOWN_RPS=0\n"
            "NPU_IRQ_RATES=not-sampled\nNPU_BEACON_LIKE=not-sampled\n"
            "NAPI_PARAM=/none\nNAPI_WRITABLE=0\nRESTORE_FAILED=0\n"
            "RESULT_RECORDS=\nTMP_FILES=\nARM_CONTRAST_LIST=\n"
            "note() { printf '%s\\n' \"$*\" >&2; }\n"
            "say() { printf '%s\\n' \"$*\"; }\n"
            "stop_sources_quiet() { :; }\nstop_mpstat() { :; }\nrestore_state() { return 0; }\n"
            + extract_function("json_str")
            + extract_function("contains_word")
            + extract_function("read_affinity")
            + extract_function("affinity_perm")
            + extract_function("irq_counts")
            + extract_function("irq_json_records")
            + extract_function("arm_json_records")
            + extract_function("record_arm_result")
            + extract_function("evaluate_acceptance")
            + extract_function("write_result_json")
            + extract_function("print_results")
            + extract_function("on_exit")
            + stub_measure
            + extract_function("run_all")
            + "run_all\n"
        )

    def test_f9_all_skipped_writes_result_json_and_exits_2(self):
        out_dir = self.fixture.root / "f9-skipped"
        stub = (
            "measure_arm() {\n"
            "  CURRENT_ARM=$1; ARM_STATUS=skipped; ARM_REASON=rps-decides-hotspot\n"
            "  GBPS=unavailable; AP_TX_RETRIES_DELTA=unavailable; SOFTIRQ_PCT_PERCPU=\n"
            "  SOFTIRQ_NET_TX_DELTA=unavailable; SOFTIRQ_NET_RX_DELTA=unavailable\n"
            "  SOFTIRQ_HI_DELTA=unavailable; SOFTIRQ_TASKLET_DELTA=unavailable\n"
            "  SOFTIRQ_HI_PERCPU=; SOFTIRQ_TASKLET_PERCPU=; WINDOW_MS_MEASURED=0\n"
            "  APPLIED_NAPI=; APPLIED_SPLIT=; AP_TX_DELTA_BYTES=unavailable\n"
            "  AP_TX_DELTA_PACKETS=unavailable; ARM_RPS_BEFORE='[]'; ARM_RPS_AFTER='[]'\n"
            "  ARM_RPS_CHANGED=false; return 2\n"
            "}\n"
        )
        res = run_sh(self._run_all_harness(out_dir, stub))
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        data = json.loads((out_dir / "result.json").read_text())
        self.assertEqual(len(data["arms"]), 1, data["arms"])
        self.assertEqual(data["arms"][0]["status"], "skipped")
        self.assertEqual(data["arms"][0]["reason"], "rps-decides-hotspot")
        self.assertEqual(data["verdict"], "incomplete")

    def test_f9_station_missing_records_blocked_writes_json_and_exits_3(self):
        out_dir = self.fixture.root / "f9-blocked"
        stub = (
            "measure_arm() {\n"
            "  CURRENT_ARM=$1; ARM_STATUS=blocked; ARM_REASON=station-missing\n"
            "  GBPS=unavailable; AP_TX_RETRIES_DELTA=unavailable; SOFTIRQ_PCT_PERCPU=\n"
            "  SOFTIRQ_NET_TX_DELTA=unavailable; SOFTIRQ_NET_RX_DELTA=unavailable\n"
            "  SOFTIRQ_HI_DELTA=unavailable; SOFTIRQ_TASKLET_DELTA=unavailable\n"
            "  SOFTIRQ_HI_PERCPU=; SOFTIRQ_TASKLET_PERCPU=; WINDOW_MS_MEASURED=1000\n"
            "  APPLIED_NAPI=; APPLIED_SPLIT=; AP_TX_DELTA_BYTES=unavailable\n"
            "  AP_TX_DELTA_PACKETS=unavailable; ARM_RPS_BEFORE='[]'; ARM_RPS_AFTER='[]'\n"
            "  ARM_RPS_CHANGED=false; record_arm_result; return 3\n"
            "}\n"
        )
        res = run_sh(self._run_all_harness(out_dir, stub))
        self.assertEqual(res.returncode, 3, res.stdout + res.stderr)
        data = json.loads((out_dir / "result.json").read_text())
        self.assertEqual(len(data["arms"]), 1, data["arms"])
        self.assertEqual(data["arms"][0]["status"], "blocked")
        self.assertEqual(data["arms"][0]["reason"], "station-missing")

    def test_f12_evaluate_acceptance_verdicts_and_comparisons(self):
        def eval_records(records, threaded_base="1", contrast_list=""):
            out_dir = self.fixture.root / f"f12-{abs(hash((records, threaded_base, contrast_list)))}"
            body = (
                f"OUT_DIR={out_dir}\nPROG=irq-napi-ab.sh\nRUN=1\n"
                "IFACE=wlan0\nCLIENT=1.2.3.4\nCLIENT_IP=1.2.3.4\nCLIENT_MAC=aa:bb:cc:dd:ee:01\n"
                "CPUS='0 1'\nSPLIT_TARGETS='1'\nSPLIT_CHOSEN_CPU=1\nSPLIT_BASIS=test\nSPLIT_MAP='50:1'\n"
                "TIMER_SOURCE=no-timer-row\nTIMER_SHARES=\nTIMER_RESERVED=\n"
                "IRQ_MAP_REQUEST=\nIRQ_MAP_READONLY=0\nRPS_DEV=cpu\nRPS_CPUS='[]'\n"
                "RPS_NONZERO_QUEUES=0\nRPS_PROBE=ok\nSPLIT_RPS_BLOCKS=0\nWITH_RPS=0\n"
                "RPS_MASK_OPT=\nALLOW_UNKNOWN_RPS=0\nNPU_IRQ_RATES=not-sampled\n"
                "NPU_BEACON_LIKE=not-sampled\nIRQ_EXCLUDED=\nNAPI_PATH=\nNAPI_PARAM=\n"
                f"THREADED_BASELINE={threaded_base}\nTHREADED_VALUE=0\nTHREADED_SOURCE=auto\n"
                "NAPI_WRITABLE=1\nARMS='baseline split'\nRESTORE_FAILED=0\n"
                "WINDOW_MS=1000\nWINDOW=1\nWARMUP=1\nPROCS=1\nRATE=100\nSOURCE_KIND=custom\n"
                "IRQ_RECORDS=\nIRQ_WRITABLE=\n"
                f"ARM_CONTRAST_LIST='{contrast_list}'\n"
                f"RESULT_RECORDS='{records}'\n"
                "say() { :; }\nnote() { :; }\n"
                + extract_function("json_str")
                + extract_function("irq_json_records")
                + extract_function("arm_json_records")
                + extract_function("evaluate_acceptance")
                + extract_function("write_result_json")
                + "write_result_json\n"
            )
            res = run_sh(body)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            return json.loads((out_dir / "result.json").read_text())

        base = "baseline|1.000|0|none|10|20|ok|none|1000|none|none|1000|10|[]|[]|false|1|2|none|none\n"
        d_imp = eval_records(base + "split|1.250|0|none|10|20|ok|none|1000|none|50:1|1250|12|[]|[]|false|1|2|none|none\n")
        self.assertEqual(d_imp["verdict"], "improved", d_imp)
        self.assertEqual(len(d_imp["comparisons"]), 1)
        self.assertEqual(d_imp["comparisons"][0]["outcome"], "improved")

        d_noop = eval_records(base + "split|1.005|0|none|10|20|ok|none|1000|none|50:1|1005|10|[]|[]|false|1|2|none|none\n")
        self.assertEqual(d_noop["verdict"], "no-effect", d_noop)

        d_reg = eval_records(base + "split|0.850|0|none|10|20|ok|none|1000|none|50:1|850|8|[]|[]|false|1|2|none|none\n")
        self.assertEqual(d_reg["verdict"], "regressed", d_reg)

        d_nc = eval_records(
            base + "threaded|1.000|0|none|10|20|ok|none|1000|1|none|1000|10|[]|[]|false|1|2|none|none\n",
            threaded_base="1",
        )
        self.assertEqual(d_nc["verdict"], "not-contrasted", d_nc)

        d_inc = eval_records(base)
        self.assertEqual(d_inc["verdict"], "incomplete", d_inc)

    def test_noop_rps_mask_keeps_write_count_and_split_changed_zero(self):
        # Queues in self.fixture already hold "f".  Writing "f" must be a no-op
        # (WRITE_COUNT stays 0) so a no-op --rps-mask f never fakes a contrast.
        body = (
            f"SYS_CLASS_NET={self.fixture.sys_class_net}\n"
            "RPS_DEV=cpu\nWRITE_COUNT=0\n"
            + extract_function("is_uint")
            + extract_function("rps_set_mask")
            + extract_function("rps_set_cpu")
            + "rps_set_mask f; rc1=$?; w1=$WRITE_COUNT\n"
            + "rps_set_mask 1; rc2=$?; w2=$WRITE_COUNT\n"
            + "rps_set_cpu 0; rc3=$?; w3=$WRITE_COUNT\n"
            + 'printf "rc1=%s w1=%s rc2=%s w2=%s rc3=%s w3=%s\\n" "$rc1" "$w1" "$rc2" "$w2" "$rc3" "$w3"\n'
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("rc1=0 w1=0", res.stdout, res.stdout)
        self.assertIn("rc2=0 w2=2", res.stdout, res.stdout)
        self.assertIn("rc3=0 w3=2", res.stdout, res.stdout)

        # Also verify split_changed is computed before WITH_RPS in measure_arm().
        ma = extract_function("measure_arm")
        idx_changed = ma.index('[ "$WRITE_COUNT" -gt "$split_writes_start" ] && split_changed=1')
        idx_rps = ma.index('if [ "$WITH_RPS" -eq 1 ]; then')
        self.assertLess(idx_changed, idx_rps, "split_changed must be evaluated before WITH_RPS")

    def test_f6_npu_beacon_rate_matches_explicit_irq_action_field(self):
        before = self.fixture.root / "npu-exp.before"
        after = self.fixture.root / "npu-exp.after"
        # Put a decoy mt76-npu IRQ 99 in the file while explicit IRQ_RECORDS
        # names 23 and 24 with field 2 == "explicit" and mt76-npu in field 3.
        before.write_text(
            " 23: 0 0 0 0 GICv3 0 Edge custom-23\n"
            " 24: 0 0 0 0 GICv3 1 Edge custom-24\n"
            " 99: 0 0 0 0 GICv3 9 Edge mt76-npu\n"
        )
        after.write_text(
            " 23: 25 0 0 0 GICv3 0 Edge custom-23\n"
            " 24: 10 0 0 0 GICv3 1 Edge custom-24\n"
            " 99: 15 0 0 0 GICv3 9 Edge mt76-npu\n"
        )
        # Explicit --irq sets field 2 to "explicit" and puts mt76-npu in field 3.
        body = (
            "say() { printf '%s\\n' \"$*\"; }\n"
            "note() { printf '%s\\n' \"$*\" >&2; }\n"
            "IRQ_RECORDS='23|explicit|GICv3 0 Edge mt76-npu\n24|explicit|GICv3 1 Edge mt76-npu'\n"
            + extract_function("irq_total_delta")
            + extract_function("npu_beacon_rate")
            + f'npu_beacon_rate "{before}" "{after}" 1\n'
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("irq23=25.0/s", res.stdout, res.stdout)
        self.assertIn("irq24=10.0/s", res.stdout, res.stdout)
        self.assertNotIn("irq99=", res.stdout, res.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
