#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Behaviour tests for scripts/wireless/thermal-soak.sh.

Three things this harness got wrong on the board (issue #53):

  1. print_soak_row compared two "%.1f" wifi temperatures with "test -gt",
     so the first decimal value aborted the row with
       sh: 35.0: bad number
     and every following sample printed no row.
  2. Every non-zero iperf3 cycle was counted as an outage.  A soak with 18
     transient iperf3 failures and no association loss therefore printed
     outages=18 with an empty events.log.
  3. The summary had no machine-readable form, so failures and outages could
     not be told apart without reading the CSV.

Each case below runs a function of the real script against a fixture; the
functions are copied out of the file, not re-implemented here, so a change to
the script is exercised.  Run from the repository root:

    python3 scripts/tests/test_thermal_soak.py
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# THERMAL_SOAK_UNDER_TEST points the tests at another copy of the script so a
# red proof can run them against the pre-fix version (repo convention).
SCRIPT = Path(
    os.environ.get("THERMAL_SOAK_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/thermal-soak.sh"
)

# An AP whose two radios sit in different bands, as --soak requires.
IW_STUB = """#!/bin/sh
case "$*" in
"dev") printf '\\tInterface wlan0\\n\\tInterface wlan1\\n' ;;
"dev wlan0 info")
	printf '\\tInterface wlan0\\n\\ttype AP\\n\\tchannel 6 (2437 MHz), width: 20 MHz\\n'
	printf '\\ttxpower 20.00 dBm\\n'
	;;
"dev wlan1 info")
	printf '\\tInterface wlan1\\n\\ttype AP\\n\\tchannel 37 (6115 MHz), width: 320 MHz\\n'
	printf '\\ttxpower 20.00 dBm\\n'
	;;
esac
exit 0
"""

# A generator that is not iperf3.  leg_loop() only counts a cycle as ok when
# the JSON carries a moving sum_sent, which is what iperf3 -J prints.
SOURCE_STUB = """#!/bin/sh
sleep 1
cat <<'JSON'
{
	"end": {
		"sum_sent": {
			"bits_per_second": 1234000000.0
		},
		"sum_received": {
			"bits_per_second": 1234000000.0
		}
	}
}
JSON
"""

TOOLS = (
    "sh", "awk", "sed", "grep", "cut", "tr", "sort", "head", "tail", "wc",
    "date", "mkdir", "rm", "mv", "cat", "sleep", "find", "ls", "env",
    "dirname", "basename", "nproc", "uname", "id", "expr", "timeout", "ip",
)

CYCLES_HEADER = (
    "time,epoch,elapsed_s,leg,iface,client,cycle,ok,assoc,throughput_mbps,"
    "src,seconds,retries,tx_packets,tx_failed,per_pct,retry_pct,outage_s,err,run"
)


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def extract_assignment(name):
    """The right-hand side of a top-level NAME='...' assignment."""
    for line in SCRIPT.read_text().splitlines():
        m = re.match(rf"^{name}='(.*)'$", line)
        if m:
            return m.group(1)
    raise AssertionError(f"{name} assignment is missing")


def run_sh(body, cwd):
    return subprocess.run(
        ["sh", "-c", body], capture_output=True, text=True, cwd=cwd, check=False
    )


class TemperatureCompare(unittest.TestCase):
    """A "%.1f" temperature must never reach "test -gt" as a number."""

    def _soak_row(self, tw0, tw1, tw2):
        body = (
            "hms_utc() { echo 00:00:00; }\n"
            + extract_function("print_soak_row")
            + f'S_TW0="{tw0}"\nS_TW1="{tw1}"\nS_TW2="{tw2}"\n'
            'S_TCPU=55.6\nS_ELAPSED=10\nS_FREQ=1400\nS_RPM=1200\n'
            'S_TXPA=20\nS_TXPB=18\nS_RATE_A=0.000\nS_RATE_B=0.000\n'
            'S_ASSOC_A=1\nS_ASSOC_B=1\nS_THROTTLE=0\nSER_TOTAL=0\n'
            "print_soak_row\n"
        )
        return run_sh(body, self.tmp)

    def test_decimal_temperatures_do_not_abort_the_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.tmp = tmp
            for tws in (("35.0", "41.5", "na"), ("41.5", "35.0", "36.2"),
                        ("na", "35.0", "na"), ("35.0", "35.0", "35.0")):
                out = self._soak_row(*tws)
                self.assertEqual(
                    out.returncode, 0,
                    f"print_soak_row failed for {tws}: {out.stderr}",
                )
                # busybox sh says "bad number", dash says "Illegal number";
                # both mean a decimal reached "test -gt".
                self.assertEqual(out.stderr, "", f"stderr for {tws}: {out.stderr}")
                self.assertNotIn("bad number", out.stderr)
                self.assertNotIn("Illegal number", out.stderr)
                self.assertIn("55.6", out.stdout)

    def test_maximum_takes_the_largest_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.tmp = tmp
            out = self._soak_row("35.0", "41.5", "36.2")
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("41.5", out.stdout)


class LegCounters(unittest.TestCase):
    """outages and failures are separate counters, in text and in JSON."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.run_dir = Path(self.dir.name)
        self.run_id = "run-1"
        self.script = (
            "summary_window() { echo 120; }\n"
            "nw_hold_state() { echo off; }\n"
            + extract_function("cycles_summary")
            + extract_function("json_str")
            + extract_function("leg_json")
            + extract_function("write_result_json")
            + f'RUN="{self.run_dir}"\nRUN_ID="{self.run_id}"\nMODE=soak\n'
            "DURATION=120\nSAMPLES=7\nINTERVAL=10\nIPERF_TIME=20\n"
            "IPERF_GAP=5\nSTREAMS=1\nDIRECTION=down\nCPU_LOAD=0\n"
            'IFACE_A="phy0.1-ap0"\nIFACE_B="phy0.2-ap0"\n'
            'IP_A="192.168.1.5"\nIP_B="192.168.1.6"\n'
            "SER_TOTAL=0\nTHR_DMESG_TOTAL=0\nREBOOTS=0\n"
            'HOLD_PRIOR="off"\n'
        )

    def write_cycles(self, leg, rows):
        path = self.run_dir / f"cycles-{leg}.csv"
        lines = [CYCLES_HEADER]
        for i, row in enumerate(rows, start=1):
            fields = [
                "2026-11-20T10:00:00Z", str(1700000000 + i), "10", leg,
                "phy0.1-ap0", "f8:fe:5e:00:00:01", str(i),
            ]
            fields += row
            fields.append(self.run_id)
            self.assertEqual(len(fields), 20, fields)
            lines.append(",".join(fields))
        path.write_text("\n".join(lines) + "\n")

    def transient_rows(self, n):
        # The shape the board produced: iperf3 died with a transient error and
        # the post-cycle station check found no station, so assoc=0 -- but the
        # station never went away and there is no event line.  Before the fix
        # "assoc=0" alone counted as an outage, so 18 such cycles printed
        # outages=18 with an empty events.log.  ok=0, no outage seconds.
        return [[
            "0", "0", "na", "na", "20", "na", "na", "na",
            "na", "na", "", "control socket has closed unexpectedly",
        ] for _ in range(n)]

    def real_outage_rows(self, seconds):
        # The station really went away: the leg_loop waited for the reconnect
        # and wrote the observed seconds into the outage column.
        return [[
            "0", "0", "na", "na", str(seconds), "na", "na", "na",
            "na", "na", str(seconds), "association lost",
        ]]

    def test_five_transient_failures_are_not_outages(self):
        self.write_cycles("a", self.transient_rows(5))
        out = run_sh(self.script + 'cycles_summary a\n', self.dir.name)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("cycles=5 ok=0 failures=5", out.stdout)
        self.assertIn("outages=0 outage_s=0", out.stdout)
        self.assertNotIn("outages=5", out.stdout)

    def test_one_association_loss_is_one_outage(self):
        self.write_cycles("a", self.real_outage_rows(45))
        out = run_sh(self.script + 'cycles_summary a\n', self.dir.name)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("failures=1", out.stdout)
        self.assertIn("outages=1 outage_s=45", out.stdout)

    def test_result_json_separates_failures_from_outages(self):
        self.write_cycles("a", self.transient_rows(5))
        self.write_cycles("b", self.real_outage_rows(45))
        run_sh(self.script + 'write_result_json\n', self.dir.name)
        path = self.run_dir / "result.json"
        self.assertTrue(path.is_file(), "result.json was not written")
        data = json.loads(path.read_text())
        self.assertEqual(data["legs"]["a"]["failures"], 5)
        self.assertEqual(data["legs"]["a"]["outages"], 0)
        self.assertEqual(data["legs"]["b"]["failures"], 1)
        self.assertEqual(data["legs"]["b"]["outages"], 1)
        self.assertEqual(data["legs"]["b"]["outage_s"], 45)


class StderrClassification(unittest.TestCase):
    """Only an unreachable-target line may turn a failure into an outage."""

    def matches(self, pattern, text):
        return subprocess.run(
            ["grep", "-Eqi", pattern], input=text, text=True, check=False
        ).returncode == 0

    def test_transient_iperf3_errors_are_not_outage_class(self):
        outage = extract_assignment("IPERF_OUTAGE_RE")
        transient = extract_assignment("IPERF_TRANSIENT_RE")
        for text in (
            "iperf3: error - interrupted",
            "iperf3: error - control socket has closed unexpectedly",
            "iperf3: error - the server has terminated",
        ):
            self.assertTrue(self.matches(transient, text), text)
            self.assertFalse(self.matches(outage, text), text)

    def test_unreachable_target_is_outage_class(self):
        outage = extract_assignment("IPERF_OUTAGE_RE")
        for text in (
            "iperf3: error - unable to connect to server: Connection refused",
            "iperf3: error - unable to connect to server: No route to host",
            "iperf3: error - unable to connect to server: Network is unreachable",
        ):
            self.assertTrue(self.matches(outage, text), text)


class MissingTool(unittest.TestCase):
    """No iperf3 is a recorded gap (exit 2), and --source replaces the load."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in TOOLS:
            real = shutil.which(name)
            if real is not None:
                (self.bin / name).symlink_to(real)
        (self.bin / "iw").write_text(IW_STUB)
        (self.bin / "iw").chmod(0o755)
        (self.bin / "udpblast").write_text(SOURCE_STUB)
        (self.bin / "udpblast").chmod(0o755)
        # PATH holds the real tools and nothing else: iperf3 is really absent
        # instead of being shadowed by the system one.
        self.env = dict(
            os.environ,
            PATH=str(self.bin),
            HOME=str(self.root),
            NWD_ALLOW_NO_SERVICE="1",
        )

    def run_soak(self, out, extra=()):
        return subprocess.run(
            [
                "sh", str(SCRIPT),
                "--soak",
                "--iface-a", "wlan0",
                "--iface-b", "wlan1",
                "--client-ip-a", "192.0.2.9",
                "--client-ip-b", "192.0.2.10",
                "--duration", "4",
                "--out", str(out),
                *extra,
            ],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=180,
            check=False,
        )

    def test_missing_iperf3_records_the_gap_and_exits_2(self):
        out = self.root / "no-tool"
        result = self.run_soak(out)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 2, combined)
        self.assertIn("SKIP: iperf3 is required", result.stderr)
        self.assertIn("missing iperf3", result.stderr)
        record = json.loads((out / "result.json").read_text())
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["status"], "no-client")
        self.assertEqual(record["missing"], "iperf3")
        self.assertEqual(str(record["ticket"]), "53")

    def test_source_runs_the_load_without_iperf3(self):
        out = self.root / "source"
        result = self.run_soak(out, ["--source", "sh %s" % (self.bin / "udpblast")])
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertNotIn("iperf3 is required", combined)
        rows = (out / "cycles-a.csv").read_text().splitlines()
        header, first = rows[0].split(","), rows[1].split(",")
        row = dict(zip(header, first))
        self.assertEqual(row["ok"], "1", rows[1])
        self.assertEqual(row["src"], "iperf", rows[1])
        self.assertEqual(row["throughput_mbps"], "1234.000", rows[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
