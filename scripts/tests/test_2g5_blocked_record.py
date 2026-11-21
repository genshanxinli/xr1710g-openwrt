#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The two BLOCKED paths of the 2.5G harness leave a record (issue #70).

The defect: `blocked()` printed one BLOCKED line and exited 0 without writing
anything, so both of the gaps it reports were invisible in
scripts/wireless/hw-gap-report.sh, which reads result.json records:

  * scripts/wireless/2.5g-wired.sh "no device port advertises 2500baseT"
    is missing hardware ("2.5g-peer").
  * scripts/wireless/2.5g-wired.sh "<dev> is in <bridge>" is a configuration
    block on this board ("port-in-bridge"), not a purchase.

Both now write a status "blocked" record through no_client_record, and the
record (plus its path) goes to stderr so the single BLOCKED line stays the
only thing on stdout - the same stdout contract skip_no_link keeps for SKIP.

The first case runs the real script with a stub ssh that answers nothing, so
port detection finds no 2500baseT port.  The second case sources the script
(G25_WIRED_LIB_ONLY=1) and calls check_device with a stub ssh that reports
lan2 inside a bridge; that keeps the test off the root and iperf3 gates that
sit before check_device in main().

    python3 scripts/tests/test_2g5_blocked_record.py

TWO_G5_SCRIPT_UNDER_TEST=/path/to/copy (or 2G5_SCRIPT_UNDER_TEST) runs the
same cases against another script: that is the red proof, a copy with the
missing key or the record call taken out.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# A leading digit is legal in an environment name but not in a shell
# assignment, so both spellings are honoured.
WIRED = Path(
    os.environ.get("TWO_G5_SCRIPT_UNDER_TEST")
    or os.environ.get("2G5_SCRIPT_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/2.5g-wired.sh"
)
REPORT = REPO_ROOT / "scripts/wireless/hw-gap-report.sh"
SH = shutil.which("sh") or "/bin/sh"
UNREACHABLE = "root@192.0.2.1"

# ssh that answers, but has no 2500baseT port to show.
NO_PORT_SSH = "#!/bin/sh\nexit 0\n"

# ssh that answers as a device whose lan2 sits inside br-lan.
BRIDGED_SSH = """\
#!/bin/sh
# The remote command is the last argument: the SSH options come first.
eval "cmd=\\${$#}"
case "$cmd" in
*master*) printf 'br-lan\\n'; exit 0 ;;
*"id -u"*) printf '0\\n'; exit 0 ;;
esac
exit 0
"""

# check_device is past the root and iperf3 gates in main(), so the second case
# drives it directly from a sourced script.
CHECK_DEVICE = """\
. "$1"
# $0 is the sh -c name here, so the script's own lib probe looks in ./lib;
# source the lib by the script's real path instead.
. "$(dirname "$1")/lib/no-client.sh"
DEVICE=root@192.0.2.1
SEL_PORTS=lan10g
DEV_LAN_IF=lan2
OUT_DIR_OPT=$2
check_device
"""


class BlockedRecordTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="2g5-blocked-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.env = dict(
            os.environ,
            PATH="%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            HOME=str(self.tmp),
        )
        # Sourcing must not fall through to main(); a run must not stop early.
        self.sourced_env = dict(self.env, G25_WIRED_LIB_ONLY="1")
        self.assertTrue(WIRED.is_file(), WIRED)

    def stub_ssh(self, body):
        ssh = self.bin / "ssh"
        if ssh.is_symlink() or ssh.exists():
            ssh.unlink()
        ssh.write_text(body)
        ssh.chmod(0o755)

    def no_port_block(self):
        """Run the real script at the "no 2500baseT port" block (:809)."""
        self.stub_ssh(NO_PORT_SSH)
        out = self.tmp / "no-port"
        result = subprocess.run(
            [SH, str(WIRED), "--device", UNREACHABLE,
             "--host-lan10g-if", "hw89nope0", "--ports", "lan10g",
             "--out-dir", str(out)],
            capture_output=True, text=True, cwd=str(self.tmp),
            env=self.env, check=False,
        )
        return result, out

    def bridged_block(self):
        """Source the script and run check_device on a bridged lan2 (:831)."""
        self.stub_ssh(BRIDGED_SSH)
        out = self.tmp / "bridged"
        result = subprocess.run(
            [SH, "-c", CHECK_DEVICE, "check-device", str(WIRED), str(out)],
            capture_output=True, text=True, cwd=str(self.tmp),
            env=self.sourced_env, check=False,
        )
        return result, out

    def read_record(self, out):
        path = out / "result.json"
        self.assertTrue(path.is_file(), "no record under %s" % out)
        return json.loads(path.read_text(encoding="utf-8"))

    def report(self, *dirs):
        proc = subprocess.run(
            [SH, str(REPORT)] + [str(d) for d in dirs],
            capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    # --- the two blocks -------------------------------------------------

    def test_no_port_block_records_missing_hardware(self):
        result, out = self.no_port_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        # stdout is the single BLOCKED line, exactly as before the record.
        self.assertEqual(
            result.stdout, "BLOCKED: no device port advertises 2500baseT\n")
        record = self.read_record(out)
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["missing"], "2.5g-peer")
        self.assertEqual(record["ticket"], "70")
        self.assertIn("2.5g-wired.sh", record["script"])
        self.assertIn("2500baseT", record["reason"])
        self.assertIn("blocked record:", result.stderr)
        self.assertNotIn("blocked record", result.stdout)

    def test_bridged_port_block_records_configuration(self):
        result, out = self.bridged_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        blocked_lines = [l for l in result.stdout.splitlines()
                         if l.startswith("BLOCKED:")]
        self.assertEqual(blocked_lines, ["BLOCKED: lan2 is in br-lan"],
                         result.stdout)
        # The bridge plan was already on stdout; the record adds nothing.
        self.assertNotIn("blocked record", result.stdout)
        record = self.read_record(out)
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["missing"], "port-in-bridge")
        self.assertEqual(record["ticket"], "70")
        self.assertIn("br-lan", record["reason"])
        self.assertIn("blocked record:", result.stderr)

    # --- the report now shows both --------------------------------------

    def test_gap_report_separates_the_two_classes(self):
        _, no_port = self.no_port_block()
        _, bridged = self.bridged_block()
        text = self.report(no_port, bridged)
        rows = {}
        for line in text.splitlines():
            if not line.startswith("| `"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rows[cells[0].strip("`")] = cells
        self.assertEqual(set(rows), {"2.5g-peer", "port-in-bridge"}, text)
        self.assertEqual(rows["2.5g-peer"][4], "hardware", text)
        self.assertEqual(rows["port-in-bridge"][4], "configuration", text)
        self.assertIn("#70", rows["port-in-bridge"][1])
        config_line = [l for l in text.splitlines()
                       if "configuration blocks" in l]
        self.assertEqual(len(config_line), 1, text)
        self.assertIn("1 of them are configuration blocks",
                      config_line[0])
        self.assertIn("`port-in-bridge`", config_line[0])
        self.assertNotIn("`2.5g-peer`", config_line[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
