#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline regression tests for scripts/wireless/4ss-lab.sh (issue #4).

Covers:
  1. --dry-run (default mode) is strictly read-only, writes zero files, and
     exits 0 even when iw is missing or no 4SS client is associated.
  2. --run with missing iw classifies as missing-tool (exit 2), not
     missing-hardware (exit 3).
  3. --run with no 4SS client classifies as missing-hardware (exit 3) and
     writes a v2 no-hardware/result.json record.
  4. 2SS refusal (refuse_association) and rejected/invalid arms (reject_run)
     both exit 4 (precondition-mismatch), never colliding with exit 3.
  5. setsid process-group cleanup kills reparented grandchildren on stop_sources.
  6. Standalone copy without lib/no-client.sh falls back cleanly via
     nc_cause_exit() (exit 3 for missing-hardware, exit 2 for missing-tool).

FOURSS_LAB_UNDER_TEST points the tests at another copy of the script for
red-green proof.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("FOURSS_LAB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/4ss-lab.sh"
)

TOOLS = (
    "sh", "awk", "sed", "grep", "cut", "tr", "head", "tail", "cat", "rm",
    "mkdir", "date", "dirname", "basename", "mv", "sleep", "uname", "setsid",
)

IW_NO_4SS = """#!/bin/sh
case "$*" in
"dev") printf '\\tInterface phy1-ap0\\n' ;;
"dev phy1-ap0 info")
	printf '\\tInterface phy1-ap0\\n\\ttype AP\\n\\tchannel 36 (5180 MHz), width: 160 MHz\\n'
	;;
"dev phy1-ap0 station dump") : ;;
esac
exit 0
"""

IW_2SS_CLIENT = """#!/bin/sh
case "$*" in
"dev") printf '\\tInterface phy1-ap0\\n' ;;
"dev phy1-ap0 info")
	printf '\\tInterface phy1-ap0\\n\\ttype AP\\n\\tchannel 36 (5180 MHz), width: 160 MHz\\n'
	;;
"dev phy1-ap0 station dump")
	printf 'Station aa:bb:cc:dd:ee:01 (on phy1-ap0)\\n'
	printf '\\tsignal:\\t-50 dBm\\n'
	printf '\\ttx bitrate:\\t2401.9 MBit/s 160MHz EHT-MCS 11 EHT-NSS 2\\n'
	printf '\\trx bitrate:\\t2401.9 MBit/s 160MHz EHT-MCS 11 EHT-NSS 2\\n'
	;;
esac
exit 0
"""


def extract_function(name):
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


class FourSsLabTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="4ss-lab-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.clean_bin = self.tmp / "clean-bin"
        self.clean_bin.mkdir()
        for tool in TOOLS:
            real = shutil.which(tool)
            if real:
                (self.clean_bin / tool).symlink_to(real)
        self.sandbox_tmp = self.tmp / "tmpdir"
        self.sandbox_tmp.mkdir()

    def _bin_with_iw(self, name, iw_body):
        b = self.tmp / name
        b.mkdir()
        for p in self.clean_bin.iterdir():
            (b / p.name).symlink_to(p.resolve())
        iw = b / "iw"
        iw.write_text(iw_body)
        iw.chmod(0o755)
        return b

    def _run(self, script_path, args, bin_dir):
        env = {
            "PATH": str(bin_dir),
            "HOME": str(self.tmp),
            "TMPDIR": str(self.sandbox_tmp),
        }
        return subprocess.run(
            ["sh", str(script_path)] + list(args),
            capture_output=True, text=True, env=env, timeout=30, check=False,
        )

    def test_dry_run_without_iw_writes_nothing_and_exits_0(self):
        out_dir = self.tmp / "dry-no-iw"
        proc = self._run(SCRIPT, ["--dry-run", "--out", str(out_dir)], self.clean_bin)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(out_dir.exists(), "dry-run must not create --out")
        self.assertEqual(list(self.sandbox_tmp.iterdir()), [], "dry-run wrote to TMPDIR")

    def test_dry_run_without_4ss_client_writes_nothing_and_exits_0(self):
        b = self._bin_with_iw("bin-no4ss-dry", IW_NO_4SS)
        out_dir = self.tmp / "dry-no-client"
        proc = self._run(SCRIPT, ["--out", str(out_dir)], b)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(out_dir.exists(), "default dry-run must not create --out")
        self.assertEqual(list(self.sandbox_tmp.iterdir()), [], "default dry-run wrote to TMPDIR")

    def test_run_missing_iw_exits_2_missing_tool(self):
        out_dir = self.tmp / "run-no-iw"
        proc = self._run(SCRIPT, ["--run", "--out", str(out_dir)], self.clean_bin)
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 2, combined)
        rec = out_dir / "no-hardware" / "result.json"
        self.assertTrue(rec.is_file(), combined)
        data = json.loads(rec.read_text())
        self.assertEqual(data["cause"], "missing-tool", data)
        self.assertEqual(data["missing"], "iw", data)
        self.assertEqual(data["exit"], 2, data)

    def test_run_no_4ss_client_exits_3_missing_hardware(self):
        b = self._bin_with_iw("bin-no4ss-run", IW_NO_4SS)
        out_dir = self.tmp / "run-no-client"
        proc = self._run(SCRIPT, ["--run", "--out", str(out_dir)], b)
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 3, combined)
        self.assertIn("SKIP: no 4SS client", proc.stdout)
        rec = out_dir / "no-hardware" / "result.json"
        self.assertTrue(rec.is_file(), combined)
        data = json.loads(rec.read_text())
        self.assertEqual(data["cause"], "missing-hardware", data)
        self.assertEqual(data["missing"], "4ss-client", data)
        self.assertEqual(data["exit"], 3, data)
        self.assertEqual(str(data["ticket"]), "4", data)

    def test_2ss_refusal_and_reject_run_exit_4(self):
        b = self._bin_with_iw("bin-2ss", IW_2SS_CLIENT)
        proc = self._run(
            SCRIPT,
            ["--run", "--iface", "phy1-ap0", "--client", "aa:bb:cc:dd:ee:01"],
            b,
        )
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        self.assertIn("REFUSE:", proc.stdout)

        # Arm rejection must also exit 4 (precondition-mismatch), never 3.
        text = SCRIPT.read_text()
        self.assertNotIn('reject_run 3 ', text)
        self.assertIn('reject_run "$(nc_cause_exit precondition-mismatch)"', text)

    def test_setsid_pgid_cleanup_kills_reparented_grandchild(self):
        if shutil.which("setsid") is None:
            self.skipTest("setsid is required")
        out_dir = self.tmp / "pgid-out"
        out_dir.mkdir()
        body = (
            "have() { command -v \"$1\" >/dev/null 2>&1; }\n"
            f"OUT={out_dir}\n"
            "T_IFACE=phy1-ap0 T_CLIENT=aa:bb:cc:dd:ee:01 CLIENT_IP=192.0.2.2 AP_IP=192.0.2.1\n"
            "WINDOW=5 WARMUP=2 SOURCE_SECS=30 PROCS=1 TX_SOURCE=x RX_SOURCE=\n"
            "SOURCES_PIDS= SOURCES_PGIDS= KILL_WAIT=3\n"
            + extract_function("proc_pgid")
            + extract_function("is_group_leader")
            + extract_function("group_pids")
            + extract_function("left_in_groups")
            + extract_function("wait_groups_gone")
            + extract_function("start_sources")
            + extract_function("stop_sources")
            + 'start_sources AP-STA "( sleep 300 & echo \\$! > \\"$OUT/gc.pid\\" ) ; sleep 30"\n'
            + "sleep 0.4\n"
            + 'gc=$(cat "$OUT/gc.pid")\n'
            + "stop_sources\n"
            + "sleep 0.2\n"
            + 'if [ -e "/proc/$gc/stat" ]; then kill -9 "$gc" 2>/dev/null || :; echo SURVIVED; exit 1; fi\n'
            + 'echo CLEANED=$gc\n'
        )
        res = subprocess.run(["sh", "-c", body], capture_output=True, text=True, check=False)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("CLEANED=", res.stdout)

    def test_standalone_copy_without_no_client_lib_uses_fallback_exit_codes(self):
        st_dir = self.tmp / "standalone-4ss"
        st_dir.mkdir()
        copy = st_dir / "4ss-lab.sh"
        copy.write_text(SCRIPT.read_text())
        copy.chmod(0o755)
        b_no4ss = self._bin_with_iw("bin-st-no4ss", IW_NO_4SS)
        proc3 = self._run(copy, ["--run"], b_no4ss)
        self.assertEqual(proc3.returncode, 3, proc3.stdout + proc3.stderr)
        proc2 = self._run(copy, ["--run"], self.clean_bin)
        self.assertEqual(proc2.returncode, 2, proc2.stdout + proc2.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
