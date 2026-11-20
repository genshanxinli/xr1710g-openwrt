#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the XR1710G wireless uci-defaults and TX queue length hotplug.

Run from the repository root:

    python3 -m unittest scripts.tests.test_wireless_defaults

Both scripts under test hardcode OpenWrt paths (`/lib/functions.sh`,
`/etc/config/wireless`, `/sys/class/net`) and shell out to `uci`, `logger`
and `ip`.  The tests copy the script into a temporary directory and rewrite
only that one source line, then run it with a mocked PATH, so the body of the
script -- every branch that decides a default -- is the real one.

What is deliberately not covered: the scripts only run on
`board_name = gemtek,xr1710g-ubi`, so the board name is supplied instead of
being probed, and `sysctl` is not exercised at all (the sysctl file is
plain data checked by hand, not by this test).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UCI_DEFAULTS = REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/uci-defaults"
HOTPLUG = REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/hotplug.d/net"

BOARD = "gemtek,xr1710g-ubi"

MOCK_UCI = r'''#!/usr/bin/env python3
import json, os, sys

state_path = os.environ["MOCK_UCI_STATE"]


def load():
    with open(state_path) as handle:
        return json.load(handle)


def save(state):
    with open(state_path, "w") as handle:
        json.dump(state, handle, indent=1, sort_keys=True)


def main(argv):
    quiet = False
    if argv[:1] == ["-q"]:
        quiet = True
        argv = argv[1:]
    if not argv:
        return 1
    command = argv[0]
    state = load()
    if command == "get" and len(argv) == 2:
        parts = argv[1].split(".")
        if parts[0] != "wireless" or len(parts) not in (2, 3):
            return 1
        section = state["sections"].get(parts[1])
        if section is None:
            return 1
        if len(parts) == 2:
            print(section["type"])
            return 0
        value = section["options"].get(parts[2])
        if value is None:
            return 1
        print(value)
        return 0
    if command == "set" and len(argv) == 2:
        target, _, value = argv[1].partition("=")
        parts = target.split(".")
        if len(parts) != 3:
            return 1
        section = state["sections"].setdefault(
            parts[1], {"type": "wifi-device", "options": {}})
        section["options"][parts[2]] = value
        save(state)
        return 0
    if command == "commit":
        save(state)
        return 0
    if not quiet:
        sys.stderr.write("mock uci: unsupported %r\n" % (argv,))
    return 1


sys.exit(main(sys.argv[1:]))
'''

MOCK_LOGGER = r'''#!/bin/sh
# logger -t TAG message: keep the tag, so a test can prove which script
# logged, and append the message.
tag=-
while [ $# -gt 1 ]; do
	case "$1" in
	-t) tag=$2; shift 2 ;;
	*) break ;;
	esac
done
printf '%s %s\n' "$tag" "$*" >> "$MOCK_LOGGER_LOG"
'''

MOCK_IP = r'''#!/bin/sh
# ip link set dev IFACE qlen N -- record the call and write the value the
# way the kernel would (net-sysfs.c tx_queue_len_store).
printf '%s\n' "$*" >> "$MOCK_IP_LOG"
[ "$1 $2 $3" = "link set dev" ] || exit 1
dev=$4
[ "$5" = "qlen" ] || exit 1
printf '%s\n' "$6" > "$MOCK_IP_SYS_NET/$dev/tx_queue_len"
'''

LIB_FUNCTIONS = r'''board_name() {
	cat "$BOARD_NAME_FILE"
}
'''


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


class Harness:
    """A throwaway root with a mocked uci, logger, board name and PATH."""

    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="wlan-defaults."))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.lib = self.tmp / "lib"
        self.lib.mkdir()
        write_exec(self.bin / "uci", MOCK_UCI)
        write_exec(self.bin / "logger", MOCK_LOGGER)
        (self.lib / "functions.sh").write_text(LIB_FUNCTIONS)
        self.uci_state = self.tmp / "uci.json"
        self.log = self.tmp / "logger.log"
        self.log.write_text("")
        self.config_path = self.tmp / "wireless"
        self.config_path.write_text("")
        self.scripts_dir = self.tmp / "uci-defaults"
        self.scripts_dir.mkdir()
        for name in ("51_wireless-tuning", "58_xr1710g-wifi-htmode"):
            self._install_script(name)
        self.board = self.tmp / "board"
        self.board.write_text(BOARD + "\n")
        self.env = dict(os.environ)
        self.env.update({
            "PATH": "%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            "MOCK_UCI_STATE": str(self.uci_state),
            "MOCK_LOGGER_LOG": str(self.log),
            "BOARD_NAME_FILE": str(self.board),
        })

    def _install_script(self, name):
        source = (UCI_DEFAULTS / name).read_text()
        # Two path rewrites and nothing else: the firmware paths
        # /lib/functions.sh and /etc/config/wireless point at the mock lib
        # and at the harness's config file.  Every branch that decides a
        # value stays the real script's code.
        source = source.replace(
            ". /lib/functions.sh", '. "%s/functions.sh"' % self.lib)
        source = source.replace(
            "/etc/config/wireless", str(self.config_path))
        target = self.scripts_dir / name
        target.write_text(source)
        target.chmod(0o755)

    def config(self, sections):
        state = {"sections": {
            name: {"type": body.get("type", "wifi-device"),
                   "options": dict(body.get("options", {}))}
            for name, body in sections.items()
        }}
        self.uci_state.write_text(json.dumps(state))

    def dump(self):
        return json.loads(self.uci_state.read_text())["sections"]

    def options(self, section):
        return self.dump()[section]["options"]

    def run(self, name):
        result = subprocess.run(
            ["sh", str(self.scripts_dir / name)],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        self.logs = self.log.read_text()
        return result

    def log_lines(self):
        return [line for line in self.log.read_text().splitlines() if line]

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


BASE_SECTIONS = {
    "radio0": {"options": {"channel": "1", "htmode": "EHT20"}},
    "radio1": {"options": {}},
    "radio2": {"options": {}},
    "default_radio0": {"type": "wifi-iface", "options": {}},
    "default_radio1": {"type": "wifi-iface", "options": {}},
    "default_radio2": {"type": "wifi-iface", "options": {}},
}


def sections(**overrides):
    """BASE_SECTIONS with per-section option overrides applied."""
    merged = {name: {"type": body["type"] if "type" in body else "wifi-device",
                     "options": dict(body["options"])}
              for name, body in BASE_SECTIONS.items()}
    for key, value in overrides.items():
        name, option = key.split("__")
        if value is None:
            merged[name]["options"].pop(option, None)
        else:
            merged[name]["options"][option] = value
    return merged


class WirelessTuningTest(unittest.TestCase):
    def setUp(self):
        self.harness = Harness()
        self.addCleanup(self.harness.cleanup)

    def run_both(self):
        for name in ("51_wireless-tuning", "58_xr1710g-wifi-htmode"):
            result = self.harness.run(name)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")

    def test_default_goes_to_149_and_narrows_to_eht80(self):
        self.harness.config(sections(
            radio1__channel="36", radio1__htmode="EHT160"))
        self.run_both()
        options = self.harness.options("radio1")
        self.assertEqual(options["channel"], "149")
        self.assertEqual(options["htmode"], "EHT80")
        self.assertIn("UNII-3", self.harness.logs)

    def test_marker_pins_auto_to_channel_36_and_restores_eht160(self):
        # The defect: with the marker on, `auto` used to skip both branches,
        # so ACS could pick 149 and then EHT160 was requested on UNII-3.
        self.harness.config(sections(
            radio1__channel="auto", radio1__htmode="EHT80",
            radio1__xr1710g_5g160="1"))
        self.run_both()
        options = self.harness.options("radio1")
        self.assertEqual(options["channel"], "36")
        self.assertEqual(options["htmode"], "EHT160")
        self.assertIn("not UNII-3", self.harness.logs)

    def test_auto_from_an_empty_channel_is_also_pinned(self):
        self.harness.config(sections(radio1__xr1710g_5g160="1"))
        self.run_both()
        options = self.harness.options("radio1")
        self.assertEqual(options["channel"], "36")
        self.assertEqual(options["htmode"], "EHT160")

    def test_explicit_he160_is_not_overwritten(self):
        # The defect: `!= EHT160` widened a deliberate HE160 to EHT160.
        self.harness.config(sections(
            radio1__channel="36", radio1__htmode="HE160",
            radio1__xr1710g_5g160="1"))
        self.run_both()
        options = self.harness.options("radio1")
        self.assertEqual(options["channel"], "36")
        self.assertEqual(options["htmode"], "HE160")
        self.assertEqual(self.harness.options("radio1").get(
            "xr1710g_5g160"), "1")

    def test_vht160_is_not_overwritten_either(self):
        self.harness.config(sections(
            radio1__channel="44", radio1__htmode="VHT160",
            radio1__xr1710g_5g160="1"))
        self.run_both()
        self.assertEqual(self.harness.options("radio1")["htmode"], "VHT160")

    def test_dfs_primary_channel_is_reported(self):
        self.harness.config(sections(
            radio1__channel="52", radio1__htmode="EHT80",
            radio1__xr1710g_5g160="1"))
        self.run_both()
        self.assertEqual(self.harness.options("radio1")["htmode"], "EHT160")
        self.assertIn("DFS", self.harness.logs)
        self.assertIn("CAC", self.harness.logs)

    def test_doth_zero_is_reported(self):
        self.harness.config(sections(
            radio1__channel="36", radio1__htmode="EHT80",
            radio1__doth="0", radio1__xr1710g_5g160="1"))
        self.run_both()
        self.assertIn("doth=0", self.harness.logs)

    def test_marker_on_unii3_leaves_the_channel_alone(self):
        self.harness.config(sections(
            radio1__channel="149", radio1__htmode="EHT160",
            radio1__xr1710g_5g160="1"))
        self.run_both()
        # 51 does not touch 149 under the marker; 58 is what narrows it.
        self.assertEqual(self.harness.options("radio1")["channel"], "149")
        self.assertEqual(self.harness.options("radio1")["htmode"], "EHT80")

    def test_uapsd_is_turned_off_on_every_ap_iface(self):
        self.harness.config(sections())
        self.harness.run("51_wireless-tuning")
        for iface in ("default_radio0", "default_radio1", "default_radio2"):
            self.assertEqual(self.harness.options(iface)["uapsd"], "0")

    def test_operator_values_are_not_overwritten(self):
        self.harness.config(sections(
            default_radio0__uapsd="1",
            default_radio1__disassoc_low_ack="1",
            radio0__channel="11"))
        self.harness.run("51_wireless-tuning")
        self.assertEqual(self.harness.options("default_radio0")["uapsd"], "1")
        self.assertEqual(
            self.harness.options("default_radio1")["disassoc_low_ack"], "1")
        self.assertEqual(self.harness.options("radio0")["channel"], "11")

    def test_two_runs_are_idempotent_and_add_no_keys(self):
        for prepared in (sections(radio1__channel="36"),
                         sections(radio1__channel="auto",
                                  radio1__htmode="EHT160",
                                  radio1__xr1710g_5g160="1")):
            self.harness.config(prepared)
            self.run_both()
            first = self.harness.dump()
            self.run_both()
            self.assertEqual(self.harness.dump(), first)


class TxQueueLenHotplugTest(unittest.TestCase):
    def setUp(self):
        self.harness = Harness()
        self.addCleanup(self.harness.cleanup)
        self.sys_net = self.harness.tmp / "sys-class-net"
        self.sys_net.mkdir()
        self.ip_log = self.harness.tmp / "ip.log"
        self.ip_log.write_text("")
        write_exec(self.harness.bin / "ip", MOCK_IP)
        self.script = self.harness.tmp / "60-wlan-txqueuelen"
        shutil.copy(HOTPLUG / "60-wlan-txqueuelen", self.script)
        self.script.chmod(0o755)
        self.harness.env.update({
            "MOCK_IP_LOG": str(self.ip_log),
            "MOCK_IP_SYS_NET": str(self.sys_net),
            "WLAN_QLEN_SYS_NET": str(self.sys_net),
            "TX_QUEUE_LEN": "5000",
        })

    def device(self, name, qlen="1000", wireless=False):
        path = self.sys_net / name
        path.mkdir()
        (path / "tx_queue_len").write_text(qlen + "\n")
        if wireless:
            (path / "phy80211").mkdir()
        return path

    def run_hotplug(self, name, action="add"):
        env = dict(self.harness.env, ACTION=action, DEVICENAME=name)
        result = subprocess.run(
            ["sh", str(self.script)], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_bridge_and_wlan_vifs_get_the_new_length(self):
        self.device("br-lan")
        self.device("phy0.0-ap0", wireless=True)
        self.device("phy0.2-ap0", wireless=True)
        for name in ("br-lan", "phy0.0-ap0", "phy0.2-ap0"):
            self.run_hotplug(name)
            self.assertEqual(
                (self.sys_net / name / "tx_queue_len").read_text().strip(),
                "5000")

    def test_ethernet_ports_and_wan_are_left_alone(self):
        for name in ("lan2", "wan", "cpu"):
            self.device(name)
            self.run_hotplug(name)
            self.assertEqual(
                (self.sys_net / name / "tx_queue_len").read_text().strip(),
                "1000")
        self.assertEqual(self.ip_log.read_text(), "")

    def test_other_events_are_ignored(self):
        self.device("br-lan")
        for action in ("remove", "bind", ""):
            self.assertNotEqual(action, "add")
            self.run_hotplug("br-lan", action=action)
        self.assertEqual(
            (self.sys_net / "br-lan" / "tx_queue_len").read_text().strip(),
            "1000")

    def test_matching_value_is_not_rewritten(self):
        self.device("br-lan", qlen="5000")
        self.run_hotplug("br-lan")
        self.assertEqual(self.ip_log.read_text(), "")

    def test_ip_is_preferred_and_sysfs_is_the_fallback(self):
        self.device("br-lan")
        self.run_hotplug("br-lan")
        self.assertIn("link set dev br-lan qlen 5000",
                      self.ip_log.read_text())

        # Now without `ip` on PATH: the sysfs write has to do the same thing.
        self.ip_log.write_text("")
        (self.sys_net / "br-lan" / "tx_queue_len").write_text("1000\n")
        empty = self.harness.tmp / "no-ip-path"
        empty.mkdir()
        env = dict(self.harness.env, ACTION="add", DEVICENAME="br-lan")
        env["PATH"] = str(empty)  # a PATH with no ip, uci or logger at all
        result = subprocess.run(
            [shutil.which("sh"), str(self.script)], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.sys_net / "br-lan" / "tx_queue_len").read_text().strip(),
            "5000")


if __name__ == "__main__":
    unittest.main()
