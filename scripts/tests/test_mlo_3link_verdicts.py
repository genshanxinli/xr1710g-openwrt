#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verdict tests for scripts/wireless/mlo-3link.sh (issue #89).

The harness decides whether a 3-link MLO negative test passed.  Four verdicts
used to be printed without being decided, so a run that proved nothing could
still end as traffic-ok:

  1. a ping burst with 90% packet loss counted as traffic.  The bound is now
     TRAFFIC_MAX_LOSS and lives in traffic_loss_ok();
  2. per-link counters that read 0 byte still counted as traffic.  They are
     not: classify_result() drops traffic-ok when PER_LINK_NOBYTES is set,
     and per_link_deltas() returns 2;
  3. a station dump with no per-link data walked on into the traffic window
     because the gate rejected only 1 and 2 links.  0 links is a refusal now
     (station_gate() -> exit 4, RESULT=station-no-perlink);
  4. a 6 GHz band whose wifi-device is enabled but whose only wifi-iface is
     disabled was accepted as a usable link.  radio_off_reason() names the
     wifi-iface, because that is what has to be enabled.

The functions under test are copied out of the script, not re-implemented, so
a change in the script is exercised.  Run from the repository root:

    python3 scripts/tests/test_mlo_3link_verdicts.py
"""

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

# Minimal uci stub: the store is flat key=value lines; `show wireless` turns
# wireless.<sec>.type=wifi-<kind> into the "wireless.<sec>=wifi-<kind>" line
# list_sections() greps.
UCI_STUB = """#!/bin/sh
store=$UCI_STORE
[ "$1" = "-q" ] && shift
[ "$1" = "-c" ] && shift 2
cmd=$1
shift || true
case "$cmd" in
get)
	val=$(grep -F -- "$1=" "$store" | tail -n 1 | cut -d= -f2-)
	[ -n "$val" ] || exit 1
	printf '%s\\n' "$val"
	;;
show)
	# only "show wireless" is used
	sed -n 's/^\\(wireless\\.[^.]*\\)\\.type=\\(wifi-[a-z]*\\)$/\\1=\\2/p' "$store"
	;;
*)
	exit 1
	;;
esac
"""

STATION_DUMP = """Station aa:bb:cc:dd:ee:ff (on phy0.2-ap0)
\tLink 0:
\t\ttx_bytes: %d
\t\trx_bytes: %d
"""


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def functions(*names):
    return "\n".join(extract_function(name) for name in names)


def run_sh(body, env=None):
    full_env = {"PATH": os.environ["PATH"]}
    if env:
        full_env.update(env)
    return subprocess.run(
        ["sh", "-c", body], capture_output=True, text=True, env=full_env,
        check=False,
    )


class TrafficLossTest(unittest.TestCase):
    """Leak 1: a 90%-loss burst is not traffic."""

    def setUp(self):
        self.body = functions("traffic_loss_ok")

    def verdict(self, rc, loss, rx):
        body = ("TRAFFIC_MAX_LOSS=10\n" + self.body +
                "traffic_loss_ok %s %s %s\n" % (rc, loss, rx))
        return run_sh(body).returncode

    def test_ninety_percent_loss_is_not_a_pass(self):
        self.assertNotEqual(self.verdict(0, 90, 1), 0)

    def test_ten_percent_loss_is_a_pass(self):
        self.assertEqual(self.verdict(0, 10, 10), 0)

    def test_zero_received_packets_is_not_a_pass(self):
        self.assertNotEqual(self.verdict(0, 0, 0), 0)

    def test_a_failed_command_is_not_a_pass(self):
        self.assertNotEqual(self.verdict(1, 0, 10), 0)


class PerLinkCountersTest(unittest.TestCase):
    """Leak 2: counters that moved no byte are not traffic."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-deltas-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.body = functions("station_fields", "per_link_deltas")
        self.env = {"STATION": "aa:bb:cc:dd:ee:ff", "STATE_DIR": str(self.tmp)}

    def deltas(self, before, after, secs=2):
        first = self.tmp / "before.txt"
        second = self.tmp / "after.txt"
        first.write_text(before)
        second.write_text(after)
        result = run_sh(self.body + 'per_link_deltas "%s" "%s" %d\n'
                        % (first, second, secs), env=self.env)
        return result

    def test_unchanged_counters_report_no_data(self):
        dump = STATION_DUMP % (1000, 500)
        result = self.deltas(dump, dump)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("0.00 Mbit/s", result.stdout)

    def test_moving_counters_report_a_rate(self):
        result = self.deltas(STATION_DUMP % (1000, 500),
                             STATION_DUMP % (1000 + 250000, 500 + 250000))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("link 0 over 2s", result.stdout)


class StationGateTest(unittest.TestCase):
    """Leak 3: a dump with zero per-link entries is a refusal."""

    def setUp(self):
        self.body = functions("station_gate")

    def gate(self, links):
        result = run_sh(self.body +
                        'STATION=aa:bb:cc:dd:ee:ff\nSTATION_LINKS=%s\n'
                        "station_gate\n"
                        'printf "rc=%%s result=%%s\\n" "$?" "$RESULT"\n' % links)
        return result

    def test_zero_links_refuses(self):
        result = self.gate(0)
        self.assertIn("rc=4 result=station-no-perlink", result.stdout)

    def test_two_links_refuses(self):
        result = self.gate(2)
        self.assertIn("rc=4 result=station-not-3link", result.stdout)

    def test_three_links_pass(self):
        result = self.gate(3)
        self.assertIn("rc=0 result=", result.stdout)


class ClassifyResultTest(unittest.TestCase):
    """Leak 2, second half: a traffic-ok is withdrawn."""

    def setUp(self):
        self.body = functions("classify_result")
        self.stubs = """find_mld() { printf '%s\\n' mld0; }
link_count() { printf '3\\n'; }
station_present() { return 0; }
"""

    def classify(self, **globals_):
        lines = ["%s=%s" % (key, value) for key, value in globals_.items()]
        body = (self.stubs + self.body + "\n".join(lines) + "\n"
                "classify_result\n"
                'printf "result=%s stop=%s\\n" "$RESULT" "$STOP"\n')
        return run_sh(body)

    def test_traffic_ok_is_withdrawn_when_no_byte_moved(self):
        result = self.classify(
            TRAFFIC_OK=1, PER_LINK_NOBYTES=1, TRAFFIC_TIMEOUT=0,
            TRAFFIC_TOOL="ping", TRAFFIC_LOSS=10, STATION="aa:bb:cc:dd:ee:ff",
        )
        # With the AP still holding 3 links and the station still associated,
        # zero per-link bytes is the black-hole signature, not a pass.
        self.assertNotIn("result=traffic-ok", result.stdout)
        self.assertIn("result=blackhole", result.stdout)

    def test_traffic_ok_survives_when_counters_moved(self):
        result = self.classify(
            TRAFFIC_OK=1, PER_LINK_NOBYTES=0, TRAFFIC_TIMEOUT=0,
            TRAFFIC_TOOL="ping", TRAFFIC_LOSS=10, STATION="aa:bb:cc:dd:ee:ff",
        )
        self.assertIn("result=traffic-ok", result.stdout)


class RadioOffReasonTest(unittest.TestCase):
    """Leak 4: a disabled VAP is not a disabled wifi-device."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-uci-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "uci"
        stub.write_text(UCI_STUB)
        stub.chmod(0o755)
        self.store = self.tmp / "store"
        self.env = {
            "PATH": "%s:%s" % (bin_dir, os.environ["PATH"]),
            "UCI_STORE": str(self.store),
            "CFG_DIR": str(self.tmp),
        }
        self.body = functions("uci_get", "list_sections", "radio_band",
                              "radio_is_disabled", "radio_off_reason")

    def set_uci(self, lines):
        self.store.write_text("\n".join(lines) + "\n")

    def reason(self, section, band):
        body = (self.body +
                'radio_off_reason %s %s\n' % (section, band) +
                'printf "rc=%s\\n" "$?"\n')
        return run_sh(body, env=self.env).stdout

    def test_a_band_whose_vaps_are_all_disabled_names_the_vap(self):
        self.set_uci([
            "wireless.radio2.type=wifi-device",
            "wireless.radio2.band=6g",
            "wireless.radio2.disabled=0",
            "wireless.default_radio2.type=wifi-iface",
            "wireless.default_radio2.device=radio2",
            "wireless.default_radio2.disabled=1",
        ])
        out = self.reason("radio2", "6g")
        self.assertIn("wifi-iface", out)
        self.assertNotIn("wireless.radio2 (6g) is disabled", out)
        self.assertIn("wireless.default_radio2.disabled=0", out)
        self.assertIn("rc=0", out)

    def test_a_band_with_one_enabled_vap_is_usable(self):
        self.set_uci([
            "wireless.radio1.type=wifi-device",
            "wireless.radio1.band=5g",
            "wireless.radio1.disabled=0",
            "wireless.ap5.type=wifi-iface",
            "wireless.ap5.device=radio1",
            "wireless.ap5.disabled=0",
            "wireless.sta5.type=wifi-iface",
            "wireless.sta5.device=radio1",
            "wireless.sta5.disabled=1",
        ])
        out = self.reason("radio1", "5g")
        self.assertIn("rc=1", out)

    def test_a_disabled_wifi_device_is_still_named(self):
        self.set_uci([
            "wireless.radio0.type=wifi-device",
            "wireless.radio0.band=2g",
            "wireless.radio0.disabled=1",
        ])
        out = self.reason("radio0", "2.4")
        self.assertIn("wireless.radio0 (2.4) is disabled", out)


class BridgeLocalIpTest(unittest.TestCase):
    """MLO-1: --local-ip must target the bridge master when MLD is bridged."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-bridge-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.ip_log = self.tmp / "ip.log"
        ip_stub = self.bin / "ip"
        ip_stub.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >>"{self.ip_log}"\n'
            'if [ "$1" = addr ] && [ "$2" = show ]; then exit 0; fi\n'
            "exit 0\n"
        )
        ip_stub.chmod(0o755)
        self.sys_net = self.tmp / "sys_class_net"
        (self.sys_net / "mld0").mkdir(parents=True)
        (self.sys_net / "br-lan").mkdir(parents=True)
        self.env = {
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "MLO3_SYS_CLASS_NET": str(self.sys_net),
        }

    def _run_ip_ops(self):
        body = (
            "PROG=mlo-3link.sh\nCMD_TIMEOUT=5\nMLD=mld0\n"
            "LOCAL_IP=192.168.250.1/24\nIP_ADDED=0\nIP_DEV=\n"
            f"SYS_CLASS_NET={self.sys_net}\n"
            "say() { printf '%s\\n' \"$*\"; }\n"
            "warn() { printf '%s\\n' \"$*\" >&2; }\n"
            "die() { printf 'DIE: %s\\n' \"$*\" >&2; exit 1; }\n"
            "need_cmd() { :; }\n"
            "run_limited() { shift; \"$@\"; }\n"
            + functions("resolve_ip_dev", "add_local_ip", "del_local_ip")
            + "add_local_ip\ndel_local_ip\n"
        )
        return run_sh(body, env=self.env)

    def test_bridged_mld_adds_and_removes_ip_on_bridge_master(self):
        (self.sys_net / "mld0" / "master").symlink_to("../br-lan")
        res = self._run_ip_ops()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        log = self.ip_log.read_text()
        self.assertIn("addr add 192.168.250.1/24 dev br-lan", log, log)
        self.assertIn("link set br-lan up", log, log)
        self.assertIn("addr del 192.168.250.1/24 dev br-lan", log, log)
        self.assertNotIn("dev mld0", log, log)

    def test_unbridged_mld_uses_mld_directly(self):
        res = self._run_ip_ops()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        log = self.ip_log.read_text()
        self.assertIn("addr add 192.168.250.1/24 dev mld0", log, log)
        self.assertIn("addr del 192.168.250.1/24 dev mld0", log, log)


class ReachabilityProbeTest(unittest.TestCase):
    """MLO-2: unreachable peer / refused control port is traffic-unreachable, not blackhole."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-probe-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.capture = self.tmp / "cap"
        self.capture.mkdir()

    def _stub(self, name, body):
        p = self.bin / name
        p.write_text(body)
        p.chmod(0o755)

    def _probe_and_classify(self, tool):
        body = (
            f"CAPTURE={self.capture}\nPEER=192.168.250.2\n"
            "LOCAL_IP=192.168.250.1/24\nCMD_TIMEOUT=5\n"
            f"TRAFFIC_TOOL={tool}\nTRAFFIC_OK=0\nPER_LINK_NOBYTES=0\n"
            "TRAFFIC_TIMEOUT=0\nTRAFFIC_LOSS=100\nSTATION=aa:bb:cc:dd:ee:ff\n"
            "TRAFFIC_UNREACHABLE=0\nTRAFFIC_UNREACHABLE_REASON=\n"
            "say() { :; }\nwarn() { :; }\n"
            "have() { command -v \"$1\" >/dev/null 2>&1; }\n"
            "run_limited() { shift; \"$@\"; }\n"
            "find_mld() { printf 'mld0\\n'; }\n"
            "link_count() { printf '3\\n'; }\n"
            "station_present() { return 0; }\n"
            + functions("probe_peer_reachability", "classify_result")
            + "probe_peer_reachability; prc=$?\n"
            + "classify_result\n"
            + 'printf "prc=%s unreach=%s result=%s\\n" "$prc" "$TRAFFIC_UNREACHABLE" "$RESULT"\n'
        )
        env = {"PATH": "%s:%s" % (self.bin, os.environ["PATH"])}
        return run_sh(body, env=env)

    def test_no_route_marks_traffic_unreachable_not_blackhole(self):
        self._stub("ip", "#!/bin/sh\nexit 1\n")
        res = self._probe_and_classify("ping")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("prc=1 unreach=1 result=traffic-unreachable", res.stdout, res.stdout)

    def test_iperf3_connection_refused_marks_traffic_unreachable(self):
        self._stub("ip", "#!/bin/sh\nexit 0\n")
        self._stub(
            "iperf3",
            "#!/bin/sh\n"
            "echo 'iperf3: error - unable to connect to server: Connection refused' >&2\n"
            "exit 1\n",
        )
        res = self._probe_and_classify("iperf3")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("prc=1 unreach=1 result=traffic-unreachable", res.stdout, res.stdout)

    def test_silent_timeout_remains_blackhole_candidate(self):
        self._stub("ip", "#!/bin/sh\nexit 0\n")
        self._stub(
            "iperf3",
            "#!/bin/sh\n"
            "echo 'iperf3: error - unable to connect to server: Connection timed out' >&2\n"
            "exit 124\n",
        )
        res = self._probe_and_classify("iperf3")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("prc=0 unreach=0 result=blackhole", res.stdout, res.stdout)


class EhtPreconditionTest(unittest.TestCase):
    """MLO-3: check_eht_precondition checks live hostapd/iw first, then UCI htmode."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-eht-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.store = self.tmp / "store"
        uci = self.bin / "uci"
        uci.write_text(UCI_STUB)
        uci.chmod(0o755)
        iw = self.bin / "iw"
        iw.write_text("#!/bin/sh\nexit 0\n")
        iw.chmod(0o755)
        self.hostapd_dir = self.tmp / "run"
        self.hostapd_dir.mkdir()

    def _run_eht(self, uci_lines):
        self.store.write_text("\n".join(uci_lines) + "\n")
        body = (
            "DEV24=radio0\nDEV5=radio1\nDEV6=radio2\n"
            f"CFG_DIR={self.tmp}\nHOSTAPD_CONF_DIR={self.hostapd_dir}\n"
            "RESULT=\nSTOP=\n"
            "warn() { printf '%s\\n' \"$*\" >&2; }\n"
            "have() { command -v \"$1\" >/dev/null 2>&1; }\n"
            + functions("uci_get", "radio_index", "radio_has_eht", "check_eht_precondition")
            + "check_eht_precondition; rc=$?\n"
            + 'printf "rc=%s result=%s stop=%s\\n" "$rc" "$RESULT" "$STOP"\n'
        )
        env = {
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "UCI_STORE": str(self.store),
        }
        return run_sh(body, env=env)

    def test_live_hostapd_ieee80211be_passes_without_uci_htmode(self):
        for idx in (0, 1, 2):
            (self.hostapd_dir / f"hostapd-phy0.{idx}.conf").write_text("ieee80211be=1\n")
        res = self._run_eht([
            "wireless.radio0.radio=0",
            "wireless.radio1.radio=1",
            "wireless.radio2.radio=2",
        ])
        self.assertIn("rc=0", res.stdout, res.stdout + res.stderr)

    def test_live_hostapd_without_eht_refuses_with_links_config(self):
        (self.hostapd_dir / "hostapd-phy0.0.conf").write_text("ieee80211be=1\n")
        (self.hostapd_dir / "hostapd-phy0.1.conf").write_text("ieee80211be=1\n")
        (self.hostapd_dir / "hostapd-phy0.2.conf").write_text("ieee80211be=0\n")
        res = self._run_eht([
            "wireless.radio0.radio=0", "wireless.radio0.htmode=EHT20",
            "wireless.radio1.radio=1", "wireless.radio1.htmode=EHT80",
            "wireless.radio2.radio=2", "wireless.radio2.htmode=EHT320",
        ])
        self.assertIn("rc=1 result=links-config", res.stdout, res.stdout + res.stderr)

    def test_uci_htmode_fallback_accepts_eht_and_rejects_he(self):
        res_ok = self._run_eht([
            "wireless.radio0.radio=0", "wireless.radio0.htmode=EHT20",
            "wireless.radio1.radio=1", "wireless.radio1.htmode=EHT80",
            "wireless.radio2.radio=2", "wireless.radio2.htmode=EHT320",
        ])
        self.assertIn("rc=0", res_ok.stdout, res_ok.stdout + res_ok.stderr)

        res_bad = self._run_eht([
            "wireless.radio0.radio=0", "wireless.radio0.htmode=EHT20",
            "wireless.radio1.radio=1", "wireless.radio1.htmode=HE80",
            "wireless.radio2.radio=2", "wireless.radio2.htmode=EHT320",
        ])
        self.assertIn("rc=1 result=links-config", res_bad.stdout, res_bad.stdout + res_bad.stderr)

    def test_multi_iface_iw_dev_keeps_earlier_6g_eht_match(self):
        iw = self.bin / "iw"
        iw.write_text(
            "#!/bin/sh\n"
            "cat <<'EOF'\n"
            "phy#0\n"
            "\tInterface phy0-ap2\n"
            "\t\tssid lab-6g\n"
            "\t\ttype AP\n"
            "\t\tchannel 37 (6135 MHz), width: 320 MHz, center1: 6265 MHz\n"
            "\tInterface phy0-ap0\n"
            "\t\tssid lab-24\n"
            "\t\ttype AP\n"
            "\t\tchannel 6 (2437 MHz), width: 20 MHz\n"
            "EOF\n"
        )
        iw.chmod(0o755)
        self.store.write_text("wireless.radio2.radio=2\n")
        body = (
            f"CFG_DIR={self.tmp}\nHOSTAPD_CONF_DIR={self.hostapd_dir}\n"
            "have() { command -v \"$1\" >/dev/null 2>&1; }\n"
            + functions("uci_get", "radio_index", "radio_has_eht")
            + "radio_has_eht radio2 6g; printf 'rc=%s\\n' \"$?\"\n"
        )
        env = {
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "UCI_STORE": str(self.store),
            "MLO3_HOSTAPD_CONF_DIR": str(self.hostapd_dir),
        }
        res = run_sh(body, env=env)
        self.assertIn("rc=0", res.stdout, res.stdout + res.stderr)

    def test_ssid_containing_eht_or_mld_is_not_false_positive(self):
        iw = self.bin / "iw"
        iw.write_text(
            "#!/bin/sh\n"
            "cat <<'EOF'\n"
            "phy#0\n"
            "\tInterface phy0-ap1\n"
            "\t\tssid My-EHT-Guest\n"
            "\t\ttype AP\n"
            "\t\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz\n"
            "\tInterface phy0-ap0\n"
            "\t\tssid MLD-Legacy-24\n"
            "\t\ttype AP\n"
            "\t\tchannel 6 (2437 MHz), width: 20 MHz\n"
            "EOF\n"
        )
        iw.chmod(0o755)
        self.store.write_text("wireless.radio0.radio=0\nwireless.radio1.radio=1\n")
        body = (
            f"CFG_DIR={self.tmp}\nHOSTAPD_CONF_DIR={self.hostapd_dir}\n"
            "have() { command -v \"$1\" >/dev/null 2>&1; }\n"
            + functions("uci_get", "radio_index", "radio_has_eht")
            + "radio_has_eht radio1 5g; r1=$?\n"
            + "radio_has_eht radio0 2.4; r0=$?\n"
            + "printf 'r1=%s r0=%s\\n' \"$r1\" \"$r0\"\n"
        )
        env = {
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "UCI_STORE": str(self.store),
            "MLO3_HOSTAPD_CONF_DIR": str(self.hostapd_dir),
        }
        res = run_sh(body, env=env)
        self.assertIn("r1=1 r0=1", res.stdout, res.stdout + res.stderr)

    def test_hostapd_conf_dir_override_guards_tmp_run_fallback(self):
        self.store.write_text("wireless.radio0.radio=0\n")
        body = (
            f"CFG_DIR={self.tmp}\nHOSTAPD_CONF_DIR={self.hostapd_dir}\n"
            "have() { return 1; }\n"
            + functions("uci_get", "radio_index", "radio_has_eht")
            + "set -x\n"
            + "radio_has_eht radio0 2.4 || true\n"
        )
        env = {
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "UCI_STORE": str(self.store),
            "MLO3_HOSTAPD_CONF_DIR": str(self.hostapd_dir),
        }
        res = run_sh(body, env=env)
        self.assertNotIn("/tmp/run/hostapd-phy", res.stderr, res.stderr)


class ElapsedAndHeaderTest(unittest.TestCase):
    """MLO-4 + exit-code header alignment."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-mlo4-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_elapsed_seconds_clamps_to_at_least_1(self):
        body = (
            functions("elapsed_seconds")
            + 'printf "small=%s\\n" "$(elapsed_seconds 100.00 100.25 10)"\n'
            + 'printf "norm=%s\\n" "$(elapsed_seconds 100.00 114.50 10)"\n'
            + 'printf "fb=%s\\n" "$(elapsed_seconds "" "" 10)"\n'
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("small=1.00", res.stdout)
        self.assertIn("norm=14.50", res.stdout)
        self.assertIn("fb=10.00", res.stdout)

    def test_empty_before_dump_fails_cleanly_in_per_link_deltas(self):
        before = self.tmp / "before.txt"
        after = self.tmp / "after.txt"
        before.write_text("")
        after.write_text(STATION_DUMP % (5000, 5000))
        body = (
            f"STATE_DIR={self.tmp}\nSTATION=aa:bb:cc:dd:ee:ff\n"
            + functions("station_fields", "per_link_deltas")
            + f'per_link_deltas "{before}" "{after}" 5\n'
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)

    def test_unavailable_per_link_counters_do_not_silently_pass(self):
        body = (
            "find_mld() { printf 'mld0\\n'; }\n"
            "link_count() { printf '3\\n'; }\n"
            "station_present() { return 0; }\n"
            "TRAFFIC_OK=1\nPER_LINK_NOBYTES=0\nPER_LINK_UNAVAILABLE=1\n"
            "TRAFFIC_TIMEOUT=0\nTRAFFIC_TOOL=ping\nTRAFFIC_LOSS=0\n"
            "STATION=aa:bb:cc:dd:ee:ff\n"
            + functions("classify_result")
            + "classify_result\n"
            + 'printf "result=%s\\n" "$RESULT"\n'
        )
        res = run_sh(body)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("result=per-link-unavailable", res.stdout)
        self.assertNotIn("result=traffic-ok", res.stdout)

    def test_header_and_result_json_align_exit_codes_and_elapsed_field(self):
        text = SCRIPT.read_text()
        header = "\n".join(text.splitlines()[:75])
        self.assertIn("3    missing-hardware", header)
        self.assertIn("black-hole", header.split("1    ", 1)[1].splitlines()[0])
        self.assertIn('"traffic_elapsed_s":', text)


if __name__ == "__main__":
    unittest.main()
