#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""result.json records the timer basis and per-arm rps masks (issue #66).

F66-1/F66-2: the harness reserved the timer CPUs from the since-boot share
correctly, but the numbers that decided it never left the script: result.json
had no timer share, no reserved set, and no statement of where the share came
from.  And rps_cpus was read once in preflight and never per arm, so a reader
could not tell a split arm whose masks moved from one whose masks did not.

The contract test (test_irq_napi_ab_contract.py) pins timer_cpus' stdout as
CPU numbers only; the share table therefore comes from the same function in
an explicit "shares" mode, and this file proves both shapes.

Run from the repository root:

    python3 scripts/tests/test_irq_napi_ab_timer_rps.py
"""

import os
import subprocess
import tempfile
import unittest
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("IRQ_NAPI_AB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/irq-napi-ab.sh"
)

HEADER = "           CPU0       CPU1       CPU2       CPU3\n"
# The board's own row: 44.5/18.7/19.7/17.2% of 16,005,708.
BOARD = HEADER + (
    "  11:    7118352    2996988    3145460    2744908  GICv3   30 Level      arch_timer\n"
)
BOARD_SHARES = {
    "0": 44.5,
    "1": 18.7,
    "2": 19.7,
    "3": 17.1,
}


def extract_function(name):
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def run_sh(text, env=None):
    import os as _os
    full_env = _os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        ["sh", "-c", text], capture_output=True, text=True, env=full_env,
        check=False,
    )


class ProcFixture:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        (self.proc / "interrupts").write_text(BOARD)
        (self.proc / "stat").write_text(
            "cpu  1 0 1 1 0 0 0 0 0 0\ncpu0 1 0 1 1 0 0 0 0 0 0\n"
            "cpu1 1 0 1 1 0 0 0 0 0 0\ncpu2 1 0 1 1 0 0 0 0 0 0\n"
            "cpu3 1 0 1 1 0 0 0 0 0 0\n"
        )
        (self.proc / "softirqs").write_text("NET_TX 1 2 3 4\n")
        # The mt7996e-managed shape: 0444 even for root, so --irq-map
        # degrades to the read-only report that writes result.json.
        irq = self.proc / "irq" / "11"
        irq.mkdir(parents=True)
        (irq / "smp_affinity").write_text("1\n")
        (irq / "smp_affinity").chmod(0o444)
        (self.proc / "uptime").write_text("1234.56 1234.00\n")

    def cleanup(self):
        self.dir.cleanup()


class TimerShares(unittest.TestCase):
    """timer_cpus prints reserved CPU numbers; "shares" prints the basis."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)
        self.body = extract_function("timer_cpus")

    def timer(self, arg=""):
        out = run_sh(
            self.body
            + f"PROC_ROOT={self.fixture.proc}\n"
            + f"timer_cpus {arg}\n"
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.split()

    def test_the_share_mode_names_every_cpu_and_its_share(self):
        got = self.timer("shares")
        self.assertEqual(len(got), 4, got)
        parsed = {k: float(v) for k, v in (s.split(":") for s in got)}
        for cpu, want in BOARD_SHARES.items():
            self.assertAlmostEqual(parsed[cpu], want, places=1, msg=got)

    def test_the_reserved_shape_is_unchanged(self):
        # The contract test pins this stdout; a share table must not leak in.
        self.assertEqual(self.timer(), ["0"])


class ResultJsonTimerFields(unittest.TestCase):
    """A dry run states the timer basis in result.json, not just on stdout."""

    def setUp(self):
        self.fixture = ProcFixture()
        self.addCleanup(self.fixture.cleanup)
        self.out = self.fixture.root / "out"

    def test_result_json_carries_share_reserved_and_source(self):
        r = subprocess.run(
            [
                "sh", str(SCRIPT),
                "--proc-root", str(self.fixture.proc),
                "--sys-class-net", str(self.fixture.root / "net"),
                "--cpus", "0,1,2,3",
                "--iface", "phy0.1-ap0",
                "--irq-map", "11:2",
                "--dry-run",
                "--out-dir", str(self.out),
            ],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        record = json.loads((self.out / "result.json").read_text())
        self.assertEqual(record.get("timer_source"), "since-boot")
        self.assertEqual(record.get("timer_reserved"), ["0"])
        share = record.get("irq_timer_share")
        self.assertIsInstance(share, dict, record.keys())
        self.assertEqual(sorted(share), ["0", "1", "2", "3"])
        self.assertAlmostEqual(float(share["0"]), 44.5, places=1)


class ArmRpsMasks(unittest.TestCase):
    """Each arm record keeps the masks it ran under, before and after."""

    def test_the_arm_record_has_rps_before_after_and_changed(self):
        body = (
            extract_function("arm_json_records")
            + "RESULT_RECORDS='baseline|1.23|0|none|100|200|ok|none|"
            "60000|none|none|4000|30|[\"f\",\"f\"]|[\"4\",\"4\"]|true'\n"
            + "arm_json_records\n"
        )
        out = run_sh(body)
        self.assertEqual(out.returncode, 0, out.stderr)
        record = json.loads(out.stdout)
        self.assertEqual(record["arm"], "baseline")
        self.assertEqual(record["rps_before"], ["f", "f"])
        self.assertEqual(record["rps_after"], ["4", "4"])
        self.assertIs(record["rps_changed"], True)
        self.assertEqual(record["split_map"], "none")


if __name__ == "__main__":
    unittest.main(verbosity=2)
