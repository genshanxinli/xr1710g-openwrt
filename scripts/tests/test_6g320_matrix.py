#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/6g320-matrix.sh (issue #47).

Three defects are guarded here, none of them needing a radio:

  * A 320 MHz block anchored at 7115 MHz (ch233) extends to 7275 MHz, past
    the 7125 MHz band edge.  The discovery range alone accepted it and the
    row was printed as ok.  ``--check-rows`` now validates the block
    geometry and reports INVALID plus invalid_rows in result.json.
  * The pre-arm gate required 320 MHz unconditionally, so an explicitly
    named 160-only client -- selected on purpose -- was skipped as "no 320
    client" and every 160-only row was unreachable.  The gate now compares
    against the width the client had at selection time.
  * The same discovery check must keep accepting a legal block
    (ch37 6135 MHz, width 320, center1 6105 MHz).

The run-path cases use a fake iw/iperf3/ssh on PATH and point --ap-addr at
TEST-NET-1; no wireless device, ssh target or network is touched.

Run from the repository root:

    python3 scripts/tests/test_6g320_matrix.py
"""

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/wireless/6g320-matrix.sh"

# Fake iw: a 6 GHz 320 MHz AP whose client's rate width is controlled by
# STATION_WIDTH (320 or 160 MHz).  The strings mirror real iw output.
IW_MOCK = """#!/bin/sh
case "$*" in
"dev")
	printf '\\tInterface phy1-ap0\\n'
	;;
"dev phy1-ap0 info")
	printf '\\tInterface phy1-ap0\\n\\ttype AP\\n'
	printf '\\tchannel 37 (6115 MHz), width: 320 MHz, center1: 6105 MHz\\n'
	printf '\\tssid test6g\\n'
	;;
"dev phy1-ap0 station dump")
	printf 'Station aa:bb:cc:dd:ee:ff (on phy1-ap0)\\n'
	printf '\\tinactive time:\\t100 ms\\n'
	printf '\\trx bytes:\\t1000\\n'
	printf '\\ttx retries:\\t3\\n'
	printf '\\tsignal:\\t-52 [-55, -58] dBm\\n'
	printf '\\ttx bitrate:\\t1200.0 MBit/s %sMHz 2SS MCS 11\\n' "$STATION_WIDTH"
	printf '\\trx bitrate:\\t1200.0 MBit/s %sMHz 2SS MCS 11\\n' "$STATION_WIDTH"
	;;
"reg get")
	printf 'global\\ncountry CN: DFS-ETSI\\n'
	;;
esac
exit 0
"""

IPERF3_MOCK = """#!/bin/sh
case "$*" in
*" -s"*|"-s "*) sleep 3 ;;
*) printf 'iperf 3.20 (cJSON 1.7.15)\\n' ;;
esac
exit 0
"""

SSH_MOCK = """#!/bin/sh
printf 'ssh stub: %s\\n' "$*" >&2
exit 255
"""


class Matrix(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="6g320-matrix-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.write_mock("iw", IW_MOCK)
        self.write_mock("iperf3", IPERF3_MOCK)
        self.write_mock("ssh", SSH_MOCK)
        self.rows = self.tmp / "rows.jsonl"
        self.result = self.tmp / "check.json"

    def write_mock(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def run_script(self, *args, width="320"):
        env = os.environ.copy()
        env["PATH"] = f"{self.bin}{os.pathsep}{env.get('PATH', '/usr/bin:/bin')}"
        env["STATION_WIDTH"] = width
        return subprocess.run(
            ["sh", str(SCRIPT), *map(str, args)],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
        )

    def write_rows(self, *rows):
        self.rows.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def check(self, *rows):
        self.write_rows(*rows)
        return self.run_script(
            "--check-rows", self.rows, "--result-json", self.result
        )

    # ---------------------------------------------------------------- channel

    def test_ch233_7115_320_is_invalid(self):
        """Regression: this row was accepted and printed as ok before #47."""
        proc = self.check({"channel": 233, "center_freq": 7115, "width": 320})
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("INVALID", proc.stderr)
        row = json.loads(proc.stdout.strip())
        self.assertEqual(row["status"], "invalid")
        self.assertIn("7275", row["invalid_reason"])
        data = json.loads(self.result.read_text())
        self.assertEqual(data["invalid_rows"], 1)
        self.assertIs(data["ok"], False)

    def test_ch37_6135_320_center1_6105_is_ok(self):
        proc = self.check(
            {"channel": 37, "center_freq": 6135, "width": 320, "center1": 6105}
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        row = json.loads(proc.stdout.strip())
        self.assertEqual(row["status"], "ok")
        self.assertIsNone(row["invalid_reason"])
        data = json.loads(self.result.read_text())
        self.assertEqual(data["invalid_rows"], 0)
        self.assertIs(data["ok"], True)

    def test_mixed_file_counts_only_invalid_rows(self):
        proc = self.check(
            {"channel": 233, "center_freq": 7115, "width": 320},
            {"channel": 37, "center_freq": 6135, "width": 320, "center1": 6105},
        )
        self.assertEqual(proc.returncode, 1)
        rows = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual([r["status"] for r in rows], ["invalid", "ok"])
        data = json.loads(self.result.read_text())
        self.assertEqual(data["checked_rows"], 2)
        self.assertEqual(data["invalid_rows"], 1)
        self.assertEqual([r["row"] for r in data["invalid"]], [1])

    def test_illegal_width_is_invalid(self):
        proc = self.check({"channel": 37, "center_freq": 6135, "width": 1600})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not a 6 GHz channel width", proc.stderr)

    def test_missing_width_is_invalid(self):
        proc = self.check({"channel": 37, "center_freq": 6135})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("width", proc.stderr)

    def test_block_below_band_edge_is_invalid(self):
        # 5955 MHz is a legal primary channel but not a legal 320 MHz block
        # centre: the block would start at 5795 MHz.
        proc = self.check({"channel": 1, "center_freq": 5955, "width": 320})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("5795", proc.stderr)

    # ------------------------------------------------------------ run path

    def run_client(self, width):
        return self.run_script(
            "--client-mac",
            "aa:bb:cc:dd:ee:ff",
            "--client-ssh",
            "root@192.0.2.9",
            "--client-model",
            "Test BE200",
            "--client-driver",
            "iwlwifi",
            "--client-firmware",
            "fw-1",
            "--ap-addr",
            "192.0.2.1",
            "--duration",
            1,
            "--omit",
            0,
            "--streams",
            1,
            "--port",
            5299,
            "--raw-dir",
            self.tmp / "raw",
            width=width,
        )

    def test_160_only_client_is_measured_not_skipped(self):
        """Regression: this run printed "SKIP: no 320 client" before #47."""
        proc = self.run_client("160")
        self.assertNotIn("SKIP", proc.stdout + proc.stderr, proc.stderr)
        rows = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual(len(rows), 1, proc.stdout + proc.stderr)
        row = rows[0]
        self.assertEqual(row["ap"]["width_mhz"], 320)
        self.assertEqual(row["association"]["width_mhz"], 160)
        # The row is reachable and says why it is not a 320 MHz result.
        for arm in ("ap_to_sta", "sta_to_ap"):
            self.assertEqual(row["arms"][arm]["status"], "invalid")
            self.assertIn("160 MHz", row["arms"][arm]["invalid_reason"])
        self.assertEqual(proc.returncode, 1, "an invalid arm is exit 1")

    def test_320_client_still_selected(self):
        proc = self.run_client("320")
        self.assertNotIn("SKIP", proc.stdout + proc.stderr, proc.stderr)
        rows = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual(len(rows), 1, proc.stdout + proc.stderr)
        self.assertEqual(rows[0]["association"]["width_mhz"], 320)
        self.assertEqual(rows[0]["ap"]["center1_mhz"], 6105)


if __name__ == "__main__":
    unittest.main(verbosity=2)
