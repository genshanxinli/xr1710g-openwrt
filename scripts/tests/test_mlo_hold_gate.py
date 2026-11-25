#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The hold gate of mlo-3link.sh downgrades a missing netwatchdog (issue #89).

The defect: nw_hold_active() failed hard whenever netwatchdog was not
installed, but this repository has never packaged it and the board does not
install it, so gates_require() exited 2 before any config write.  The
missing-hardware branch ("missing=6ghz-mlo-3link-client", v2 exit 3) sits
after that gate, so the "no 3-link MLD client" criterion could neither be met
nor be disproved.

The fix keeps the gate for the risk it was written for: an installed
netwatchdog that does not hold can reboot the board mid-experiment and must
still refuse.  A board without netwatchdog has no watchdog to reboot it, so
only that case is downgraded to a warning, and gates_report() says
"hold (downgraded)" instead of a plain PASS.

Four gate cases run the real script against a stub PATH:
  1. no netwatchdog, default policy  -> gates pass, report says downgraded;
  2. no netwatchdog, NWD_REQUIRE_SERVICE=1 -> exit 2, report says FAIL;
  3. netwatchdog installed, status fails -> exit 2;
  4. netwatchdog installed and holding -> PASS, no "downgraded".

A fifth case runs the whole script (under `unshare -Ur` for the root check)
with stubbed uci/iw/wifi/ip, so the formerly unreachable no-station branch is
exercised end to end: exit 3, a no-hardware record, and a restored config.

Run from the repository root:

    python3 scripts/tests/test_mlo_hold_gate.py

MLO3_SCRIPT_UNDER_TEST=/path/to/copy runs the same cases against another
script.  That is the red proof: a copy whose missing-service branch returns 1
again must fail these cases.
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
    os.environ.get("MLO3_SCRIPT_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/mlo-3link.sh"
)
SH = shutil.which("sh") or "/bin/sh"
UNSHARE = shutil.which("unshare")
HOLD_FILE = Path("/tmp/netwatchdog.hold")


def _unshare_works():
    """Probe unshare -Ur so restricted sandboxes returning ENOSYS/EPERM skip cleanly."""
    if UNSHARE is None:
        return False
    try:
        res = subprocess.run(
            [UNSHARE, "-Ur", SH, "-c", "true"],
            capture_output=True, text=True, check=False,
        )
        return res.returncode == 0
    except OSError:
        return False


UNSHARE_OK = _unshare_works()

WIRELESS = """\
config wifi-device 'radio0'
\toption band '2g'
\toption radio '0'
\toption channel '6'
\toption htmode 'EHT20'
config wifi-device 'radio1'
\toption band '5g'
\toption radio '1'
\toption channel '36'
\toption htmode 'EHT80'
config wifi-device 'radio2'
\toption band '6g'
\toption radio '2'
\toption channel '37'
\toption htmode 'EHT320'
config wifi-iface 'default0'
\toption device 'radio0'
\toption ssid 'home'
\toption encryption 'sae'
config wifi-iface 'default1'
\toption device 'radio1'
\toption ssid 'home5'
\toption encryption 'sae'
config wifi-iface 'default2'
\toption device 'radio2'
\toption ssid 'home6'
\toption encryption 'sae'
"""

# A fixed wireless tree.  `-c` is ignored: append_block only asks whether the
# generated file parses, and section_exists only asks whether a section is new.
UCI_STUB = """#!/bin/sh
quiet=0
while [ $# -gt 0 ]; do
	case "$1" in
	-q) quiet=1; shift ;;
	-c) shift 2 ;;
	*) break ;;
	esac
done
cmd=${1:-}
arg=${2:-}
case "$cmd" in
show)
	case "$arg" in
	wireless)
		cat <<'EOF'
wireless.radio0=wifi-device
wireless.radio1=wifi-device
wireless.radio2=wifi-device
wireless.default0=wifi-iface
wireless.default1=wifi-iface
wireless.default2=wifi-iface
EOF
		exit 0
		;;
	wireless.mlo3link) exit 1 ;;
	wireless.*) exit 0 ;;
	esac
	exit 1
	;;
get)
	key=${arg#wireless.}
	case "$key" in
	radio0.band) printf '2g\\n' ;;
	radio1.band) printf '5g\\n' ;;
	radio2.band) printf '6g\\n' ;;
	radio0.radio) printf '0\\n' ;;
	radio1.radio) printf '1\\n' ;;
	radio2.radio) printf '2\\n' ;;
	radio0.htmode) printf 'EHT20\\n' ;;
	radio1.htmode) printf 'EHT80\\n' ;;
	radio2.htmode) printf 'EHT320\\n' ;;
	default0.device) printf 'radio0\\n' ;;
	default1.device) printf 'radio1\\n' ;;
	default2.device) printf 'radio2\\n' ;;
	default0.ssid) printf 'home\\n' ;;
	default1.ssid) printf 'home5\\n' ;;
	default2.ssid) printf 'home6\\n' ;;
	*) exit 1 ;;
	esac
	exit 0
	;;
delete|commit) exit 0 ;;
esac
exit 1
"""

# The test MLD exists (and has three links) only while the marked block is in
# the config, so the restore path can observe it disappear.
IW_STUB = """#!/bin/sh
[ -n "${WIRELESS_CFG:-}" ] || exit 1
grep -q '^# >>> mlo-3link: BEGIN' "$WIRELESS_CFG" 2>/dev/null || exit 0
case "$*" in
dev) printf '\\tInterface mlo3link0\\n' ;;
"dev mlo3link0 info")
	cat <<'EOF'
Interface mlo3link0
	ssid MLO-3LINK-NEG
	MLD with links: 3
	- link ID 0
	  channel 2412 MHz
	  txpower 20.00 dBm
	- link ID 1
	  channel 5180 MHz
	  txpower 20.00 dBm
	- link ID 2
	  channel 6115 MHz
	  txpower 20.00 dBm
EOF
	;;
"dev mlo3link0 station dump") : ;;
esac
exit 0
"""

WIFI_STUB = "#!/bin/sh\nexit 0\n"
IP_STUB = "#!/bin/sh\nexit 0\n"
DMESG_STUB = "#!/bin/sh\nexit 0\n"
LOGREAD_STUB = "#!/bin/sh\nexit 0\n"

NETWATCHDOG_OK = """#!/bin/sh
case "$*" in
status) printf 'hold: ACTIVE\\n' ;;
esac
exit 0
"""
NETWATCHDOG_FAIL = "#!/bin/sh\nexit 1\n"


class HoldGateTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), SCRIPT)
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-hold-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.cfg = self.tmp / "cfg"
        self.cfg.mkdir()
        self.config = self.cfg / "wireless"
        self.config.write_text(WIRELESS, encoding="utf-8")
        self.state = self.tmp / "state"
        self.stub("uci", UCI_STUB)
        self.stub("iw", IW_STUB)
        self.stub("wifi", WIFI_STUB)
        self.stub("ip", IP_STUB)
        self.stub("dmesg", DMESG_STUB)
        self.stub("logread", LOGREAD_STUB)
        self.env = dict(
            os.environ,
            PATH="%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            HOME=str(self.tmp),
            MLO3_CONFIG=str(self.config),
            MLO3_STATE_DIR=str(self.state),
            WIRELESS_CFG=str(self.config),
            MLO3_STATION_TIMEOUT="2",
        )

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def hold_file(self, present=True):
        """Create /tmp/netwatchdog.hold for the installed-service cases."""
        if not present:
            self.assertFalse(HOLD_FILE.exists(), "a stale %s" % HOLD_FILE)
            return
        created = not HOLD_FILE.exists()
        HOLD_FILE.write_text("test\n", encoding="utf-8")
        if created:
            self.addCleanup(lambda: HOLD_FILE.exists() and HOLD_FILE.unlink())

    def run_script(self, *args, env=None, root=False):
        full = dict(self.env, **(env or {}))
        argv = [SH, str(SCRIPT)] + list(args)
        if root:
            argv = [UNSHARE, "-Ur"] + argv
        return subprocess.run(
            argv, capture_output=True, text=True, cwd=str(self.tmp),
            env=full, check=False,
        )

    def dry_run(self, env=None):
        return self.run_script(
            "--dry-run", "--ssid", "MLO-3LINK-NEG", "--no-serial",
            "--i-understand-risk", env=env)

    def gate_run(self, env=None):
        """A real run: the gates run before the root and config checks."""
        return self.run_script(
            "--ssid", "MLO-3LINK-NEG", "--no-serial", "--i-understand-risk",
            "--peer", "192.0.2.1", "--local-ip", "192.168.250.1/24",
            "--station-timeout", "2", env=env)

    # --- 1. missing service, default policy -----------------------------

    def test_missing_service_downgrades_to_a_warning(self):
        out = self.dry_run()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("hold (downgraded)", out.stdout, out.stdout)
        self.assertIn("PASS  netwatchdog is not installed; the hold gate is "
                      "downgraded to a warning", out.stdout)
        self.assertIn("downgraded to a warning because there is no watchdog "
                      "to restart the board", out.stderr)
        self.assertNotIn("a real run would be refused", out.stdout)

    # --- 2. missing service, strict policy ------------------------------

    def test_missing_service_with_require_service_refuses(self):
        out = self.gate_run(env={"NWD_REQUIRE_SERVICE": "1"})
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
        self.assertIn("refusing before any config write", out.stderr)
        self.assertIn("FAIL  netwatchdog is not installed", out.stderr)
        self.assertNotIn("downgraded", out.stderr)

    # --- 3. installed service, no working hold --------------------------

    def test_installed_service_with_failing_status_refuses(self):
        self.stub("netwatchdog", NETWATCHDOG_FAIL)
        self.hold_file()
        out = self.gate_run()
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
        self.assertIn("refusing before any config write", out.stderr)
        self.assertIn("FAIL  netwatchdog status failed", out.stderr)
        self.assertNotIn("downgraded", out.stderr)

    # --- 4. installed service and an active hold ------------------------

    def test_installed_service_with_active_hold_passes(self):
        self.stub("netwatchdog", NETWATCHDOG_OK)
        self.hold_file()
        out = self.dry_run()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("PASS  netwatchdog hold is ACTIVE", out.stdout)
        self.assertNotIn("downgraded", out.stdout + out.stderr)

    # --- 5. the no-station branch is reachable --------------------------

    @unittest.skipIf(not UNSHARE_OK, "unshare -Ur is not supported in this environment")
    def test_no_station_branch_is_reachable(self):
        before = self.config.read_text(encoding="utf-8")
        out = self.run_script(
            "--ssid", "MLO-3LINK-NEG", "--no-serial", "--i-understand-risk",
            "--peer", "192.0.2.1", "--local-ip", "192.168.250.1/24",
            "--station-timeout", "2", "--traffic", "ping", root=True)
        text = out.stdout + out.stderr
        # The gate no longer refuses; the run reaches its own verdict.
        self.assertNotIn("refusing before any config write", text)
        # v2: missing hardware is not-measured and exits 3, never the v1 4.
        self.assertEqual(out.returncode, 3, text)
        self.assertIn("missing 6ghz-mlo-3link-client", out.stdout)
        self.assertIn("result: no station associated", out.stdout)
        # The record survives cleanup, which rewrites $CAPTURE/result.json;
        # v2 adds the no-hardware/ level under the no-client/ evidence dir.
        records = sorted(
            self.state.glob("runs/*/no-client/no-hardware/result.json"))
        self.assertEqual(len(records), 1, text)
        record = json.loads(records[0].read_text(encoding="utf-8"))
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertEqual(record["contract"], "v2")
        self.assertEqual(record["cause"], "missing-hardware")
        self.assertEqual(record["outcome"], "not-measured")
        self.assertEqual(record["exit"], 3)
        self.assertEqual(record["status"], "no-client")
        self.assertEqual(record["missing"], "6ghz-mlo-3link-client")
        self.assertEqual(record["ticket"], "89")
        # And the marked block is gone again.
        self.assertEqual(self.config.read_text(encoding="utf-8"), before)


if __name__ == "__main__":
    unittest.main()
