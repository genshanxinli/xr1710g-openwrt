#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline red-green tests for npu-fw-ab.sh and ab-80-160.sh.

Covers:
  * npu-fw-ab.sh:
      - BusyBox-safe tr -c '\040-\176' '\n' fallback in markers_of() when
        `strings` is absent (no GNU `grep -a`).
      - Reboot hold durability: REBOOT_ISSUED=1 and netwatchdog.json are
        flushed before `reboot`, so neither async exit nor SIGTERM from procd
        during `reboot` releases the hold.
      - Failed `reboot` and SIGTERM during pre-reboot `sleep` DO release the
        hold cleanly.
  * ab-80-160.sh:
      - P1-5: refused nw_guard_take never calls unprotected `wifi reload`.
      - Missing 5 GHz client exits 3 (missing-hardware) with v2 record, and
        `--help` documents exit 3 (missing-hardware) and exit 4 (rejected).
      - Standalone copy without lib/no-client.sh still exits 3 cleanly via
        the fallback nc_cause_exit().

Run from the repository root:

    python3 scripts/tests/test_npu_fw_ab_and_ab80.py
"""

import json
import os
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
NPU_SCRIPT = Path(
    os.environ.get("NPU_FW_AB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/npu-fw-ab.sh"
)
AB80_SCRIPT = Path(
    os.environ.get("AB_80_160_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/ab-80-160.sh"
)
SH = shutil.which("sh") or "/bin/sh"


def _write_exec(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _link_tools(bindir: Path, tools: tuple[str, ...]) -> None:
    for name in tools:
        found = shutil.which(name)
        if found is not None:
            dst = bindir / name
            if not dst.exists():
                dst.symlink_to(found)


class NpuFwAbTest(unittest.TestCase):
    """npu-fw-ab.sh P1-4 reboot-hold durability and P2-5 BusyBox tr fallback."""

    TOOLS = (
        "sh", "awk", "sed", "grep", "cut", "tr", "sha256sum", "md5sum",
        "wc", "sort", "cp", "mv", "rm", "mkdir", "chmod", "date", "cat",
        "sync", "head", "tail", "basename", "dirname", "ls", "kill",
    )

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="npu-fw-ab-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        # Intentionally omit `strings` so markers_of() uses the tr fallback.
        _link_tools(self.bin, self.TOOLS)
        self.fw = self.tmp / "fw"
        self.fw.mkdir()
        self.bak = self.tmp / "bak"
        self.bak.mkdir()
        (self.fw / "en7581_MT7996_npu_rv32.bin").write_bytes(
            b"\x00\xfforig\x00TLB7.6.0.0_v01\x00\x80end"
        )
        self.cand = self.tmp / "cand.bin"
        self.cand.write_bytes(
            b"\x00\xfehead\x00TLB7.7.0.0_v08\x00\x99tail"
        )
        self.hold = self.tmp / "nwd.hold"
        self.nwd_log = self.tmp / "nwd.log"
        _write_exec(self.bin / "id", "#!/bin/sh\necho 0\n")
        _write_exec(self.bin / "sleep", "#!/bin/sh\nexit 0\n")
        _write_exec(
            self.bin / "netwatchdog",
            f"""#!/bin/sh
echo "$*" >>"{self.nwd_log}"
case "$*" in
"hold on") : >"{self.hold}" ;;
"hold off") rm -f "{self.hold}" ;;
esac
exit 0
""",
        )

    def env(self):
        return {
            "PATH": str(self.bin),
            "HOME": str(self.tmp),
            "NW_GUARD_HOLD_FILE": str(self.hold),
        }

    def stage_candidate(self):
        res = subprocess.run(
            [
                SH, str(NPU_SCRIPT), "--stage",
                "--candidate", str(self.cand),
                "--firmware-dir", str(self.fw),
                "--backup-root", str(self.bak),
            ],
            env=self.env(), capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        return res

    def test_markers_of_uses_busybox_tr_fallback_without_strings(self):
        self.assertNotIn("grep -a", NPU_SCRIPT.read_text(encoding="utf-8"))
        inspect = subprocess.run(
            [
                SH, str(NPU_SCRIPT), "--inspect",
                "--candidate", str(self.cand),
                "--firmware-dir", str(self.fw),
                "--backup-root", str(self.bak),
            ],
            env=self.env(), capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(inspect.returncode, 0, inspect.stdout + inspect.stderr)
        self.assertIn("TLB7.7.0.0_v08", inspect.stdout)
        self.assertIn("TLB7.6.0.0_v01", inspect.stdout)

    def test_reboot_preserves_hold_and_writes_json_even_if_sigterm_hits_reboot(self):
        self.stage_candidate()
        # Simulate procd sending SIGTERM to the shell during `reboot`, and
        # verify netwatchdog.json already exists on disk before reboot runs.
        pre_json_flag = self.tmp / "json_before_reboot"
        _write_exec(
            self.bin / "reboot",
            f"""#!/bin/sh
echo "REBOOT_CALLED" >>"{self.nwd_log}"
if ls "{self.bak}"/backup-*/netwatchdog.json >/dev/null 2>&1; then
    echo "yes" >"{pre_json_flag}"
fi
kill -TERM "$PPID" 2>/dev/null || true
exit 0
""",
        )
        res = subprocess.run(
            [
                SH, str(NPU_SCRIPT), "--run", "--i-understand-reboot",
                "--firmware-dir", str(self.fw),
                "--backup-root", str(self.bak),
            ],
            env=self.env(), capture_output=True, text=True, timeout=60,
        )
        self.assertTrue(
            pre_json_flag.is_file(),
            "netwatchdog.json was not written before reboot ran: %s"
            % (res.stdout + res.stderr),
        )
        log = self.nwd_log.read_text(encoding="utf-8").splitlines()
        self.assertIn("hold on", log)
        self.assertIn("REBOOT_CALLED", log)
        self.assertNotIn("hold off", log, "hold was released during reboot")
        self.assertTrue(self.hold.exists(), "hold file disappeared during reboot")
        jsons = list(self.bak.glob("backup-*/netwatchdog.json"))
        self.assertEqual(len(jsons), 1)
        data = json.loads(jsons[0].read_text(encoding="utf-8"))
        self.assertEqual(data["action"], "took")

    def test_failed_reboot_and_sigterm_during_sleep_release_hold(self):
        self.stage_candidate()
        # 1. Failing reboot must release the hold.
        _write_exec(self.bin / "reboot", "#!/bin/sh\nexit 1\n")
        res = subprocess.run(
            [
                SH, str(NPU_SCRIPT), "--run", "--i-understand-reboot",
                "--firmware-dir", str(self.fw),
                "--backup-root", str(self.bak),
            ],
            env=self.env(), capture_output=True, text=True, timeout=60,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("hold off", self.nwd_log.read_text(encoding="utf-8"))
        self.assertFalse(self.hold.exists())

        # 2. SIGTERM during sleep 5 must release the hold cleanly (rc 143).
        self.nwd_log.unlink()
        (self.bin / "sleep").unlink()
        (self.bin / "sleep").symlink_to(shutil.which("sleep"))
        _write_exec(self.bin / "reboot", "#!/bin/sh\necho REBOOT\nexit 0\n")
        proc = subprocess.Popen(
            [
                SH, str(NPU_SCRIPT), "--run", "--i-understand-reboot",
                "--firmware-dir", str(self.fw),
                "--backup-root", str(self.bak),
            ],
            env=self.env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        deadline = time.time() + 10
        while not self.hold.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.hold.exists(), "hold never taken before SIGTERM")
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 143, out + err)
        self.assertFalse(self.hold.exists(), "SIGTERM during sleep leaked hold")
        self.assertIn("hold off", self.nwd_log.read_text(encoding="utf-8"))


class Ab80160Test(unittest.TestCase):
    """ab-80-160.sh P1-5 refusal guard, v2 exit codes, and fallback exit."""

    TOOLS = (
        "sh", "awk", "sed", "grep", "cut", "tr", "md5sum", "cp", "mv", "rm",
        "mkdir", "date", "cat", "sleep", "head", "tail", "basename", "dirname",
    )

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ab80-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        _link_tools(self.bin, self.TOOLS)
        _write_exec(self.bin / "id", "#!/bin/sh\necho 0\n")
        self.wifi_log = self.tmp / "wifi.log"
        _write_exec(
            self.bin / "wifi",
            f'#!/bin/sh\necho "WIFI_CALLED $*" >>"{self.wifi_log}"\nexit 0\n',
        )
        _write_exec(
            self.bin / "uci",
            """#!/bin/sh
case "$*" in
*"get wireless.radio1.channel"*) echo 36 ;;
*"get wireless.radio1.htmode"*) echo EHT160 ;;
*"get wireless.radio1.band"*) echo 5g ;;
*"get wireless.radio1.country"*) echo US ;;
*"show wireless.radio1"*) echo "wireless.radio1=wifi-device" ;;
esac
exit 0
""",
        )
        self.wireless = self.tmp / "wireless"
        self.wireless.write_text("config wifi-device radio1\n", encoding="utf-8")

    def write_iw(self, *, with_client: bool):
        sta = (
            'printf "Station aa:bb:cc:dd:ee:ff (on phy0-ap0)\\n\\ttx bytes:\\t100\\n"'
            if with_client
            else ":"
        )
        _write_exec(
            self.bin / "iw",
            f"""#!/bin/sh
case "$*" in
"dev") printf "\\tInterface phy0-ap0\\n\\t\\ttype AP\\n\\t\\tchannel 36 (5180 MHz), width: 160 MHz\\n" ;;
*"info") printf "\\tInterface phy0-ap0\\n\\ttype AP\\n\\tchannel 36 (5180 MHz), width: 160 MHz\\n" ;;
*"station dump") {sta} ;;
esac
exit 0
""",
        )

    def test_refused_nw_guard_never_runs_wifi_reload(self):
        self.write_iw(with_client=True)
        out = self.tmp / "out-refuse"
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.tmp),
            "WIRELESS_CONFIG": str(self.wireless),
            "UCI_DELTA": str(self.tmp / "uci-delta"),
            "NWD_ALLOW_NO_SERVICE": "0",
        }
        res = subprocess.run(
            [
                SH, str(AB80_SCRIPT), "--run",
                "--iface", "phy0-ap0", "--client", "aa:bb:cc:dd:ee:ff",
                "--source", "true", "--out", str(out),
            ],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertIn("netwatchdog", res.stderr)
        self.assertFalse(
            self.wifi_log.exists() and self.wifi_log.read_text().strip(),
            "refused run executed unprotected wifi reload",
        )

    def test_help_documents_exit_3_and_4_and_no_client_exits_3(self):
        help_res = subprocess.run(
            [SH, str(AB80_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(help_res.returncode, 0, help_res.stderr)
        self.assertIn("3 ", help_res.stdout)
        self.assertIn("missing-hardware", help_res.stdout)
        self.assertIn("4 ", help_res.stdout)
        self.assertIn("rejected", help_res.stdout)

        # Missing client -> exit 3 with v2 record, and standalone copy without
        # lib/no-client.sh also exits 3 cleanly via fallback nc_cause_exit().
        self.write_iw(with_client=False)
        out = self.tmp / "out-nosta"
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.tmp),
            "WIRELESS_CONFIG": str(self.wireless),
            "UCI_DELTA": str(self.tmp / "uci-delta"),
            "NWD_ALLOW_NO_SERVICE": "1",
        }
        res = subprocess.run(
            [
                SH, str(AB80_SCRIPT), "--run",
                "--iface", "phy0-ap0", "--client", "aa:bb:cc:dd:ee:ff",
                "--source", "true", "--out", str(out),
            ],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(res.returncode, 3, res.stdout + res.stderr)
        self.assertTrue((out / "no-hardware" / "result.json").is_file())

        # Standalone copy with netwatchdog-guard.sh present but NO lib/no-client.sh.
        standalone = self.tmp / "standalone" / "scripts"
        (standalone / "wireless").mkdir(parents=True)
        (standalone / "lib").mkdir(parents=True)
        shutil.copy2(AB80_SCRIPT, standalone / "wireless" / "ab-80-160.sh")
        shutil.copy2(
            REPO_ROOT / "scripts/lib/netwatchdog-guard.sh",
            standalone / "lib" / "netwatchdog-guard.sh",
        )
        res_sa = subprocess.run(
            [
                SH, str(standalone / "wireless" / "ab-80-160.sh"), "--run",
                "--iface", "phy0-ap0", "--client", "aa:bb:cc:dd:ee:ff",
                "--source", "true", "--out", str(self.tmp / "out-sa"),
            ],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(res_sa.returncode, 3, res_sa.stdout + res_sa.stderr)
        self.assertNotIn("Illegal number", res_sa.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
