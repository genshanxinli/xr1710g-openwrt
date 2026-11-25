#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/edca-6g-ab.sh (issue #43).

Two behaviours are guarded here, both without a radio:

  * The preflight order.  "No 6G STA" and "no iperf3 on the AP" are clean
    skips: rc=3 (missing-hardware) / rc=2 (missing-tool) plus a "SKIP:" line,
    with the reason written under no-client/no-hardware/result.json (never a
    top-level result.json).  Before the fix
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

    def test_no_6g_sta_skips_with_cause_exit(self):
        proc = self.run_harness(
            "--target", TARGET, "--result-dir", self.out, scenario="no-sta"
        )
        # Nothing was measured: the v2 contract records missing-hardware and
        # exits 3; 0 is reserved for a run that measured.
        self.assertEqual(proc.returncode, 3, proc.stderr)
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
        data = json.loads(
            (self.out / "no-client" / "no-hardware" / "result.json").read_text())
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["cause"], "missing-hardware")
        self.assertEqual(data["missing"], "6ghz-eht-client")
        self.assertEqual(str(data["ticket"]), "43")
        self.assertIn("no 6G STA", data["reason"])
        self.assertTrue(data["command"])
        self.assertTrue(data["criteria"])

    def test_missing_iperf3_skips_with_2(self):
        # The iperf3 check must come after the STA gate: with a STA present a
        # missing iperf3 still ends in "SKIP", never in a failure.  The v2
        # cause is missing-tool, so the exit code is 2, not the old 0.
        proc = self.run_harness(
            "--target",
            TARGET,
            "--result-dir",
            self.out,
            EDCA6G_IPERF3="iperf3-not-installed-h4347",
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("SKIP", proc.stdout)
        self.assertIn("iperf3 not found", proc.stdout)
        # No top-level result.json: a skip must not poison the overwrite
        # guard for the real run that follows once the tool is installed.
        self.assertFalse((self.out / "result.json").exists())
        # The gap lands as a wireless-no-client/v1 record, in a subdirectory
        # so it never overwrites the harness's own result.json.
        record = json.loads(
            (self.out / "no-client" / "no-hardware" / "result.json").read_text())
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["status"], "no-client")
        self.assertEqual(record["cause"], "missing-tool")
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
        # skip_run exits with its cause's code: missing-tool (iperf3) is 2.
        self.assertEqual(proc.returncode, 2, combined)
        self.assertIn("SKIP: no 2.5G feeder on the bench host", proc.stdout)

        # The record first: a skip that leaves nothing collectable is the bug.
        record = out / "no-client" / "no-hardware" / "result.json"
        self.assertTrue(
            record.is_file(),
            "no gap record under %s: %s"
            % (out, sorted(p.as_posix() for p in out.rglob("*"))),
        )
        data = json.loads(record.read_text())
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["cause"], "missing-tool")
        self.assertEqual(data["exit"], 2)
        self.assertEqual(data["missing"], "iperf3")
        self.assertEqual(str(data["ticket"]), "43")
        self.assertIn("missing iperf3", proc.stdout)

        report = subprocess.run(
            ["sh", str(REPO_ROOT / "scripts/wireless/hw-gap-report.sh"), "--strict", str(out)],
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
        record = json.loads(
            (out / "no-client" / "no-hardware" / "result.json").read_text())
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["cause"], "config-block")
        self.assertEqual(record["missing"], "6ghz-owe-mismatch")
        self.assertEqual(str(record["ticket"]), "43")


class EarlyGlobalsAndTrapSafety(unittest.TestCase):
    """#43 E2: die(), restore_all(), on_exit() must never crash under set -u."""

    def test_die_works_when_netwatchdog_guard_is_missing(self):
        tmp = Path(tempfile.mkdtemp(prefix="edca-e2-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        isolated_dir = tmp / "wireless"
        isolated_dir.mkdir()
        copy = isolated_dir / "edca-6g-ab.sh"
        copy.write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        proc = subprocess.run(
            ["sh", str(copy), "--help"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("shared library not found", proc.stderr)
        self.assertNotIn("log_line: not found", proc.stderr)
        self.assertNotIn("parameter not set", proc.stderr)

    def test_restore_all_and_on_exit_safe_before_setup(self):
        tmp = Path(tempfile.mkdtemp(prefix="edca-e2-trap."))
        self.addCleanup(shutil.rmtree, tmp, True)
        env = os.environ.copy()
        env.update({"EDCA6G_LIB_ONLY": "1"})
        proc = subprocess.run(
            [
                "sh",
                "-c",
                '. "$0" || exit 9; restore_all; on_exit 0',
                str(SCRIPT),
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("parameter not set", proc.stderr)
        self.assertNotIn("unbound variable", proc.stderr)

        # Subcase: RESULT_DIR set and RESTORED=0 -> on_exit exercises
        # restore_all() + write_result() cleanly before setup has run.
        out = tmp / "early-out"
        out.mkdir()
        env2 = os.environ.copy()
        env2.update({"EDCA6G_LIB_ONLY": "1", "RESULT_DIR": str(out)})
        proc2 = subprocess.run(
            [
                "sh",
                "-c",
                '. "$0" || exit 9; RESTORED=0; on_exit 1',
                str(SCRIPT),
            ],
            env=env2,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(proc2.returncode, 1, proc2.stdout + proc2.stderr)
        self.assertNotIn("parameter not set", proc2.stderr)
        self.assertNotIn("unbound variable", proc2.stderr)
        self.assertTrue((out / "result.json").is_file(), proc2.stdout + proc2.stderr)
        data = json.loads((out / "result.json").read_text(encoding="utf-8"))
        self.assertEqual(data["schema"], "edca-6g-ab/v1")
        self.assertIs(data["ok"], False)


class HostapdLiveVerification(Harness):
    """#43 E3: EDCA6G_HOSTAPD_CLI checks live status and prefers get_config."""

    def setup_hostapd_mocks(self, *, cli_state="ENABLED", emit_get_config=True,
                            conf_stale=False):
        self.run_dir = self.tmp / "run"
        self.run_dir.mkdir()
        self.burst_state = self.tmp / "uci_tx_burst"
        self.burst_state.write_text("2.0\n")
        self.hostapd_conf = self.run_dir / "hostapd-phy1.conf"
        self.hostapd_conf.write_text(
            "interface=phy1-ap0\ntx_queue_data2_burst=2.0\n"
        )
        self.write_mock(
            "uci",
            """#!/bin/sh
case "$*" in
"-q show wireless"*)
	printf 'wireless.radio2=wifi-device\\n'
	printf "wireless.radio2.band='6g'\\n"
	printf "wireless.radio2.phy='phy1'\\n"
	;;
"-q get wireless.radio2.phy"*) printf 'phy1\\n' ;;
"-q get wireless.radio2.band"*) printf '6g\\n' ;;
"-q set wireless.radio2.tx_burst="*)
	printf '%s\\n' "${3#*=}" >"$BURST_STATE"
	;;
"-q commit wireless"*) ;;
esac
exit 0
""",
        )
        self.write_mock(
            "wifi",
            """#!/bin/sh
b=$(cat "$BURST_STATE" 2>/dev/null || echo 2.0)
if [ "${CONF_STALE:-0}" = 1 ]; then
	b=9.9
fi
{
	printf 'interface=phy1-ap0\\n'
	printf 'tx_queue_data2_burst=%s\\n' "$b"
} >"$HOSTAPD_CONF_PATH"
exit 0
""",
        )
        self.write_mock(
            "hostapd_cli",
            """#!/bin/sh
case "$*" in
*" status"*)
	printf 'state=%s\\n' "${CLI_STATE:-ENABLED}"
	;;
*" get_config"*)
	printf 'bssid=02:00:00:00:00:01\\n'
	if [ "${EMIT_GET_CONFIG:-1}" = 1 ]; then
		b=$(cat "$BURST_STATE" 2>/dev/null || echo 2.0)
		printf 'tx_queue_data2_burst=%s\\n' "$b"
	fi
	;;
esac
exit 0
""",
        )
        return {
            "EDCA6G_UCI": str(self.bin / "uci"),
            "EDCA6G_WIFI": str(self.bin / "wifi"),
            "EDCA6G_HOSTAPD_CLI": str(self.bin / "hostapd_cli"),
            "EDCA6G_RUN_DIR": str(self.run_dir),
            "BURST_STATE": str(self.burst_state),
            "HOSTAPD_CONF_PATH": str(self.hostapd_conf),
            "CLI_STATE": cli_state,
            "EMIT_GET_CONFIG": "1" if emit_get_config else "0",
            "CONF_STALE": "1" if conf_stale else "0",
        }

    def test_prefers_get_config_when_emitted(self):
        extra = self.setup_hostapd_mocks(
            cli_state="ENABLED", emit_get_config=True, conf_stale=True
        )
        proc = self.run_harness(
            "--target", TARGET, "--mechanism", "hostapd",
            "--settle", 0, "--assoc-timeout", 2, "--result-dir", self.out,
            **extra,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        arms = self.result_json()["arms"]
        self.assertEqual([a["applied_tu"] for a in arms], [0, 63])
        self.assertTrue(
            all(a["applied_source"] == "hostapd-cli" for a in arms), arms
        )

    def test_falls_back_to_conf_with_live_status(self):
        extra = self.setup_hostapd_mocks(
            cli_state="ENABLED", emit_get_config=False, conf_stale=False
        )
        proc = self.run_harness(
            "--target", TARGET, "--mechanism", "hostapd",
            "--settle", 0, "--assoc-timeout", 2, "--result-dir", self.out,
            **extra,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        arms = self.result_json()["arms"]
        self.assertEqual([a["applied_tu"] for a in arms], [0, 63])
        self.assertTrue(
            all(a["applied_source"] == "hostapd-conf+live-status" for a in arms),
            arms,
        )

    def test_fails_when_live_status_is_not_enabled(self):
        extra = self.setup_hostapd_mocks(
            cli_state="DISABLED", emit_get_config=True, conf_stale=False
        )
        proc = self.run_harness(
            "--target", TARGET, "--mechanism", "hostapd",
            "--settle", 0, "--assoc-timeout", 2, "--result-dir", self.out,
            **extra,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("state=ENABLED", proc.stderr)


class MinMbitGate(Harness):
    """#43 E4: --min-mbit fails an arm whose throughput is below the floor."""

    def test_below_default_min_mbit_invalidates_arm(self):
        self.write_mock(
            "iperf3",
            """#!/bin/sh
printf '{"end":{"sum_received":{"start":0,"seconds":1.0,"bits_per_second":500000},'
printf '"sum_sent":{"bits_per_second":500000,"retransmits":0}}}\\n'
""",
        )
        proc = self.run_harness(
            "--target", TARGET, "--edca-apply", self.edca_apply,
            "--settle", 0, "--result-dir", self.out,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        records = [
            json.loads(line)
            for line in (self.out / "arms.jsonl").read_text().splitlines()
            if line.strip()
        ]
        self.assertEqual(len(records), 1)
        self.assertFalse(records[0]["valid"])
        self.assertIn("min-mbit", records[0]["invalid_reason"])

    def test_custom_min_mbit_floor_is_honoured(self):
        proc = self.run_harness(
            "--target", TARGET, "--edca-apply", self.edca_apply,
            "--settle", 0, "--min-mbit", "5000", "--result-dir", self.out,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        records = [
            json.loads(line)
            for line in (self.out / "arms.jsonl").read_text().splitlines()
            if line.strip()
        ]
        self.assertFalse(records[0]["valid"])
        bad_lead = self.run_harness(
            "--target", TARGET, "--min-mbit", "01", "--dry-run"
        )
        self.assertEqual(bad_lead.returncode, 2, bad_lead.stdout + bad_lead.stderr)


class LaaMacAndRandomization(Harness):
    """#43 E5: LAA MAC warning in preflight + wait_sta randomization diagnostic."""

    def test_laa_mac_warns_and_universal_mac_stays_quiet(self):
        proc_laa = self.run_harness(
            "--target", TARGET, "--edca-apply", self.edca_apply,
            "--settle", 0, "--result-dir", self.out,
            STA_MAC="aa:bb:cc:dd:ee:ff",
        )
        self.assertEqual(proc_laa.returncode, 0, proc_laa.stdout + proc_laa.stderr)
        self.assertIn("locally-administered", proc_laa.stderr)

        out2 = self.tmp / "out-univ"
        proc_univ = self.run_harness(
            "--target", TARGET, "--edca-apply", self.edca_apply,
            "--settle", 0, "--result-dir", out2,
            STA_MAC="00:11:22:33:44:55",
        )
        self.assertEqual(proc_univ.returncode, 0, proc_univ.stdout + proc_univ.stderr)
        self.assertNotIn("locally-administered", proc_univ.stderr)

    def test_wait_sta_diagnoses_different_mac_as_randomization(self):
        env = self.env(STA_MAC="fe:ed:fa:ce:00:01")
        env["EDCA6G_LIB_ONLY"] = "1"
        proc = subprocess.run(
            [
                "sh",
                "-c",
                '. "$0" || exit 9; '
                'IFACE=phy1-ap0; STATION=aa:bb:cc:dd:ee:ff; ASSOC_TIMEOUT=1; '
                'wait_sta',
                str(SCRIPT),
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("fe:ed:fa:ce:00:01", proc.stderr)
        self.assertIn("randomization", proc.stderr)


class ArmOrdering(Harness):
    """#43 E6: --order fixed|rotate|mirror controls per-round arm sequence."""

    def test_rotate_and_mirror_orders_and_json_recording(self):
        for order, expected in (
            ("fixed", [[0, 63, 171], [0, 63, 171], [0, 63, 171]]),
            ("rotate", [[0, 63, 171], [63, 171, 0], [171, 0, 63]]),
            ("mirror", [[0, 63, 171], [171, 63, 0], [0, 63, 171]]),
        ):
            with self.subTest(order=order):
                out = self.tmp / ("order-" + order)
                proc = self.run_harness(
                    "--target", TARGET, "--edca-apply", self.edca_apply,
                    "--settle", 0, "--rounds", 3, "--cooldown", 0,
                    "--order", order, "--result-dir", out,
                    EDCA6G_ARMS="0 63 171",
                )
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                data = json.loads((out / "result.json").read_text())
                self.assertEqual(data["order"], order)
                self.assertEqual(
                    [r["arms"] for r in data["rounds_timeline"]], expected
                )
        bad = self.run_harness(
            "--target", TARGET, "--order", "bogus", "--result-dir", self.tmp / "bad"
        )
        self.assertEqual(bad.returncode, 2, bad.stdout + bad.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
