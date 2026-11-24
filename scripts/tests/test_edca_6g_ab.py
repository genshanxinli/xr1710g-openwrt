#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/edca-6g-ab.sh (issue #43).

Two behaviours are guarded here, both without a radio:

  * The preflight order.  "No 6G STA" and "no iperf3 on the AP" are clean
    skips: rc=0 plus a "SKIP:" line, with the reason written to
    no-client/result.json (never a top-level result.json).  Before the fix
    the iperf3 check ran before the STA was looked for, so a board without a 6G client exited 1 even though there
    was nothing to measure.
  * --rounds / --cooldown.  N rounds replay the same arm sequence, so the
    arms.jsonl records come out A/B/A/B and result.json carries rounds,
    cooldown_s, a per-round timeline and a per-arm median/min/max/range.

The harness is exercised through its documented EDCA6G_* mock hooks with
fake iw and iperf3 executables on PATH; nothing here touches a wireless
device, /sys, /etc/config or the network.

Run from the repository root:

    python3 scripts/tests/test_edca_6g_ab.py
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# EDCA6G_UNDER_TEST points the tests at another copy of the script so a red
# proof can run them against the pre-fix version (repo convention).
SCRIPT = Path(
    os.environ.get("EDCA6G_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/edca-6g-ab.sh"
)
TARGET = "192.0.2.1"  # TEST-NET-1, never routed
STA_MAC = "aa:bb:cc:dd:ee:ff"

# Fake iw: one 6 GHz AP on 6115 MHz.  SCENARIO decides whether a station is
# associated; the fixed strings mirror the real "iw dev <if>. info" output.
IW_MOCK = """#!/bin/sh
case "$*" in
"dev")
	printf '\\tInterface phy1-ap0\\n'
	printf '\\tInterface phy0-ap0\\n'
	;;
"dev phy0-ap0 info")
	printf '\\tInterface phy0-ap0\\n\\ttype AP\\n'
	printf '\\tchannel 6 (2437 MHz), width: 20 MHz\\n'
	;;
"dev phy1-ap0 info")
	printf '\\tInterface phy1-ap0\\n\\ttype AP\\n'
	printf '\\tchannel 37 (6115 MHz), width: 320 MHz, center1: 6105 MHz\\n'
	printf '\\twiphy 1\\n'
	;;
"dev phy1-ap0 station dump")
	if [ "$SCENARIO" = sta ]; then
		printf 'Station %s (on phy1-ap0)\\n' "$STA_MAC"
		printf '\\tinactive time:\\t100 ms\\n'
		printf '\\ttx bytes:\\t1000\\n'
		printf '\\trx bytes:\\t2000\\n'
		printf '\\ttx retries:\\t3\\n'
		printf '\\trx packets:\\t40\\n'
		printf '\\tsignal:\\t-52 [-55, -58] dBm\\n'
		printf '\\ttx bitrate:\\t5762.5 MBit/s 320MHz 2SS MCS 13\\n'
	fi
	;;
esac
exit 0
"""

# Fake iperf3: a fixed 1 s JSON result whose throughput climbs by 0.1 Gbit/s
# per call, so a per-round record is distinguishable from a per-arm one.
IPERF3_MOCK = """#!/bin/sh
_n=$(cat "$IPERF_COUNTER" 2>/dev/null || echo 0)
_n=$((_n + 1))
printf '%s\\n' "$_n" >"$IPERF_COUNTER"
_bps=$((3000000000 + _n * 100000000))
printf '{"end":{"sum_received":{"start":0,"seconds":1.0001,'
printf '"bits_per_second":%s},"sum_sent":{"bits_per_second":%s,' "$_bps" "$_bps"
printf '"retransmits":%s}}}\\n' "$_n"
"""


class Harness(unittest.TestCase):
    """Runs the real script against fake iw/iperf3 in a throw-away tree."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="edca-6g-ab-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.write_mock("iw", IW_MOCK)
        self.write_mock("iperf3", IPERF3_MOCK)
        # Fixtures for every absolute path the harness may touch.
        self.edca_apply = self.tmp / "edca_apply"
        self.edca_apply.write_text("63\n")
        self.wireless = self.tmp / "wireless"
        self.wireless.write_text("config wifi-device radio2\n\toption band 6g\n")
        (self.tmp / "sys" / "phy1-ap0" / "statistics").mkdir(parents=True)
        (self.tmp / "debugfs" / "phy1" / "mt76").mkdir(parents=True)
        self.counter = self.tmp / "iperf.counter"
        self.out = self.tmp / "out"

    def write_mock(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def env(self, scenario="sta", **extra):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{env.get('PATH', '/usr/bin:/bin')}",
                "SCENARIO": scenario,
                "STA_MAC": STA_MAC,
                "IPERF_COUNTER": str(self.counter),
                # Mock hooks documented in the harness header.
                "EDCA6G_SYSFS_NET": str(self.tmp / "sys"),
                "EDCA6G_DEBUGFS": str(self.tmp / "debugfs"),
                "EDCA6G_WIRELESS_CONF": str(self.wireless),
                # Two arms keep the round order short and readable.
                "EDCA6G_ARMS": "0 63",
                # netwatchdog is not part of this test.
                "NWD_ALLOW_NO_SERVICE": "1",
                "NW_GUARD_HOLD_FILE": str(self.tmp / "netwatchdog.hold"),
            }
        )
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def run_harness(self, *args, scenario="sta", **extra):
        return subprocess.run(
            ["sh", str(SCRIPT), *map(str, args)],
            env=self.env(scenario=scenario, **extra),
            capture_output=True,
            text=True,
            timeout=120,
        )

    def result_json(self):
        return json.loads((self.out / "result.json").read_text())


class SkipPaths(Harness):
    """A run that cannot measure must skip, not fail."""

    def test_no_6g_sta_skips_with_zero(self):
        proc = self.run_harness(
            "--target", TARGET, "--result-dir", self.out, scenario="no-sta"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("SKIP", proc.stdout)
        self.assertIn("no 6G STA", proc.stdout)
        # A skip caused by missing hardware leaves a machine-readable record,
        # so scripts/wireless/hw-gap-report.sh can list it as a hardware gap.
        self.assertIn("missing 6ghz-eht-client", proc.stdout)
        self.assertIn("once it is available run: sh scripts/wireless/edca-6g-ab.sh",
                      proc.stdout)
        # The record goes to a subdirectory: a top-level result.json would
        # trip the harness's own overwrite guard on the next real run.
        self.assertFalse((self.out / "result.json").exists())
        data = json.loads((self.out / "no-client" / "result.json").read_text())
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["missing"], "6ghz-eht-client")
        self.assertEqual(str(data["ticket"]), "43")
        self.assertIn("no 6G STA", data["reason"])
        self.assertTrue(data["command"])
        self.assertTrue(data["criteria"])

    def test_missing_iperf3_skips_with_zero(self):
        # The iperf3 check must come after the STA gate: with a STA present a
        # missing iperf3 still ends in "SKIP", rc=0, never in a failure.
        proc = self.run_harness(
            "--target",
            TARGET,
            "--result-dir",
            self.out,
            EDCA6G_IPERF3="iperf3-not-installed-h4347",
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("SKIP", proc.stdout)
        self.assertIn("iperf3 not found", proc.stdout)
        # No top-level result.json: a skip must not poison the overwrite
        # guard for the real run that follows once the tool is installed.
        self.assertFalse((self.out / "result.json").exists())
        # The gap lands as a wireless-no-client/v1 record, in a subdirectory
        # so it never overwrites the harness's own result.json.
        record = json.loads((self.out / "no-client" / "result.json").read_text())
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["status"], "no-client")
        self.assertEqual(str(record["ticket"]), "43")
        self.assertEqual(record["missing"], "iperf3")


class Rounds(Harness):
    """--rounds replays the arm sequence instead of measuring once."""

    def run_rounds(self, rounds, cooldown=0):
        proc = self.run_harness(
            "--target",
            TARGET,
            "--edca-apply",
            self.edca_apply,
            "--settle",
            0,
            "--rounds",
            rounds,
            "--cooldown",
            cooldown,
            "--result-dir",
            self.out,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def test_two_rounds_record_abab_order(self):
        self.run_rounds(2)
        records = [
            json.loads(line)
            for line in (self.out / "arms.jsonl").read_text().splitlines()
            if line.strip()
        ]
        self.assertEqual(
            [(r["round"], r["arm"]) for r in records],
            [(1, 0), (1, 63), (2, 0), (2, 63)],
        )
        self.assertTrue(all(r["valid"] for r in records))

        data = self.result_json()
        self.assertEqual(data["rounds"], 2)
        self.assertEqual(data["cooldown_s"], 0)
        self.assertEqual(len(data["rounds_timeline"]), 2)
        for entry in data["rounds_timeline"]:
            self.assertTrue(entry["started"])
            self.assertTrue(entry["ended"])
            self.assertEqual(entry["arms"], [0, 63])
        self.assertEqual([a["arm"] for a in data["aggregate"]], [0, 63])
        for agg in data["aggregate"]:
            self.assertEqual(agg["n"], 2)
            self.assertLessEqual(agg["gbps_min"], agg["gbps_median"])
            self.assertLessEqual(agg["gbps_median"], agg["gbps_max"])
            self.assertAlmostEqual(
                agg["gbps_range"], agg["gbps_max"] - agg["gbps_min"], places=3
            )

        rows = [
            line.split("\t")
            for line in (self.out / "summary.tsv").read_text().splitlines()[1:]
            if line.strip()
        ]
        self.assertEqual([(r[0], r[1]) for r in rows], [("1", "0"), ("1", "63"), ("2", "0"), ("2", "63")])

    def test_default_is_one_round(self):
        self.run_rounds(1)
        data = self.result_json()
        self.assertEqual(data["rounds"], 1)
        self.assertEqual(len(data["arms"]), 2)
        self.assertEqual([a["round"] for a in data["arms"]], [1, 1])

    def test_bad_rounds_is_a_usage_error(self):
        proc = self.run_harness(
            "--target", TARGET, "--rounds", 0, "--result-dir", self.out
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)


class SourceSlot(Harness):
    """--source measures without iperf3 on the AP."""

    def test_source_replaces_the_iperf3_client(self):
        self.write_mock("udpblast", IPERF3_MOCK)
        proc = self.run_harness(
            "--target",
            TARGET,
            "--edca-apply",
            self.edca_apply,
            "--settle",
            0,
            "--source",
            "sh %s" % (self.bin / "udpblast"),
            "--result-dir",
            self.out,
            EDCA6G_IPERF3="iperf3-not-installed-h4347",
        )
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, combined)
        self.assertNotIn("SKIP", proc.stdout)
        records = [
            json.loads(line)
            for line in (self.out / "arms.jsonl").read_text().splitlines()
            if line.strip()
        ]
        self.assertEqual([r["arm"] for r in records], [0, 63])
        self.assertTrue(all(r["valid"] for r in records), records)
        self.assertTrue(all(r["iperf3"]["gbps"] > 0 for r in records), records)
        self.assertFalse((self.out / "no-client").exists(), combined)


class SkipRunReachesTheGapReport(unittest.TestCase):
    """skip_run must leave a record hw-gap-report.sh actually collects.

    Red half: at 5d8660fce9 skip_run called write_skip_result, whose
    "status": "skip" is one of the two values hw-gap-report.sh drops
    (scripts/wireless/hw-gap-report.sh:120-122 collects "no-client" and
    "blocked" only), so an edca skip read exactly like "this harness was
    never run".  This case drives skip_run through EDCA6G_LIB_ONLY=1 and
    then asks the real report, so it fails on a copy that still writes
    "skip" and on a copy without the library hook (the source would execute
    the whole harness and exit 2).
    """

    def test_skip_run_writes_a_record_the_gap_report_collects(self):
        tmp = Path(tempfile.mkdtemp(prefix="edca-skip-run."))
        self.addCleanup(shutil.rmtree, tmp, True)
        out = tmp / "res"
        env = os.environ.copy()
        env.update({"EDCA6G_LIB_ONLY": "1", "RESULT_DIR": str(out)})
        proc = subprocess.run(
            [
                "sh",
                "-c",
                # $0 is the script path, so the script's
                # "$(dirname "$0")/../lib/*" lookups resolve as usual.
                '. "$0" || exit 9; '
                'skip_run "no 2.5G feeder on the bench host" iperf3',
                str(SCRIPT),
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, combined)
        self.assertIn("SKIP: no 2.5G feeder on the bench host", proc.stdout)

        # The record first: a skip that leaves nothing collectable is the bug.
        record = out / "no-client" / "result.json"
        self.assertTrue(
            record.is_file(),
            "no gap record under %s: %s"
            % (out, sorted(p.as_posix() for p in out.rglob("*"))),
        )
        data = json.loads(record.read_text())
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["missing"], "iperf3")
        self.assertEqual(str(data["ticket"]), "43")
        self.assertIn("missing iperf3", proc.stdout)

        report = subprocess.run(
            ["sh", str(REPO_ROOT / "scripts/wireless/hw-gap-report.sh"), str(out)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertIn("| `iperf3` | #43 |", report.stdout)


class OweBlockRecord(unittest.TestCase):
    """An OWE configuration block must also record under no-client/.

    Red half: skip_no_client used to pass $RESULT_DIR straight to
    nc_owe_mismatch_block, so a blocked run left a top-level result.json and
    the harness's overwrite guard then refused the next real run in the same
    --result-dir.  The library hook is stubbed, so no radio is needed.
    """

    def test_owe_block_record_is_subdir_only(self):
        tmp = Path(tempfile.mkdtemp(prefix="edca-owe-block."))
        self.addCleanup(shutil.rmtree, tmp, True)
        out = tmp / "res"
        env = os.environ.copy()
        env.update({"EDCA6G_LIB_ONLY": "1", "RESULT_DIR": str(out)})
        proc = subprocess.run(
            [
                "sh",
                "-c",
                '. "$0" || exit 9; '
                "IFACE=phy1-ap0; "
                "nc_owe_mismatch() { "
                'printf "%s\\n" "phy1-ap0: live Encryption OWE (CCMP), but '
                'wireless.wifi6g.encryption is open (none)"; }; '
                'skip_no_client "no 6G STA"',
                str(SCRIPT),
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 2, combined)
        self.assertIn("BLOCKED", proc.stdout, combined)
        self.assertFalse(
            (out / "result.json").exists(),
            "a blocked run left a top-level result.json; the next real run "
            "will be refused: %s" % combined,
        )
        record = json.loads((out / "no-client" / "result.json").read_text())
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["missing"], "6ghz-owe-mismatch")
        self.assertEqual(str(record["ticket"]), "43")


if __name__ == "__main__":
    unittest.main(verbosity=2)
