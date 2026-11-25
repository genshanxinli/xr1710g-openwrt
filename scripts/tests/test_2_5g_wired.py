#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline self-test for scripts/wireless/2.5g-wired.sh (issue #70).

The script used to hardcode lan10g/wan10g.  Neither netdev exists on a
stock or base tree (the ports are lan2 and wan), and lan2 sits in br-lan
by default, so the harness refused to run on the one board it targets.
Three cases pin the replacement behaviour:

  (a) no port advertises 2500baseT   -> "BLOCKED: no device port ...", rc 0
  (b) a 2500baseT port inside br-lan -> the precondition and the exact
      detach commands, then "BLOCKED: lan2 is in br-lan", rc 0
  (c) a 2500baseT port outside a bridge -> the measurement path runs, and
      the host->device arm passes -R to iperf3

Every device-side command runs through a fake ssh that executes the remote
command against a fake sysfs tree and fake ethtool/ip/iperf3/id, so nothing
touches a real bridge, a real NIC, a real unit or the network.

Run: python3 -m unittest scripts.tests.test_2_5g_wired
"""

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "TWO_G5_SCRIPT_UNDER_TEST", REPO / "scripts/wireless/2.5g-wired.sh"
    )
).resolve()

IPERF_JSON = """{
\t"start": {"version": "iperf 3.20"},
\t"intervals": [],
\t"end": {
\t\t"sum_sent": {
\t\t\t"start": 0,
\t\t\t"end": 1,
\t\t\t"seconds": 1,
\t\t\t"bytes": 300000000,
\t\t\t"bits_per_second": 2400000000,
\t\t\t"retransmits": 2
\t\t},
\t\t"sum_received": {
\t\t\t"start": 0,
\t\t\t"end": 1,
\t\t\t"seconds": 1,
\t\t\t"bytes": 294000000,
\t\t\t"bits_per_second": 2352000000
\t\t},
\t\t"cpu_utilization_percent": {"host_total": 3.1, "remote_total": 90.0}
\t}
}"""

FAKES = {
    "id": """#!/bin/sh
case "$1" in
-u) echo 0 ;;
esac
""",
    "ssh": """#!/bin/sh
# The remote command is the last argument; options come first.
for cmd in "$@"; do :; done
PATH=$FAKE_BIN:$PATH exec sh -c "$cmd"
""",
    "ethtool": """#!/bin/sh
case "$1" in
-i) printf 'driver: r8169\\n' ;;
-S) printf '     tx_errors: 0\\n     rx_errors: 0\\n' ;;
*)
	d=$FAKE_DEV_SYS/class/net/$1
	printf 'Settings for %s:\\n' "$1"
	printf '\\tSupported ports: [ TP ]\\n'
	printf '\\tSpeed: %sMb/s\\n' "$(cat "$d/speed" 2>/dev/null || echo 1000)"
	printf '\\tDuplex: %s\\n' "$(cat "$d/duplex" 2>/dev/null || echo Full)"
	printf '\\tLink detected: %s\\n' "$(cat "$d/carrier" 2>/dev/null || echo 1)"
	cat "$d/modes" 2>/dev/null
	;;
esac
""",
    "ip": """#!/bin/sh
printf 'ip %s\\n' "$*" >>"$FAKE_CALLS"
case "$1 $2" in
'-o link') cat "$FAKE_NICS" ;;
'link show') grep -q " $3:" "$FAKE_NICS" && exit 0; exit 1 ;;
'-o -4') exit 0 ;;
'addr add'|'addr del'|'route add'|'route del') exit 0 ;;
'route show')
	[ "$3" = "default" ] && printf 'default via 192.0.2.254 dev eth0\\n'
	exit 0
	;;
'route get') printf '%s dev eth0 src 192.0.2.9\\n' "$3" ;;
'-s link')
	printf 'RX: bytes packets errors dropped missed mcast\\n    0 0 0 0 0 0\\n'
	printf 'TX: bytes packets errors dropped carrier colls\\n    0 0 0 0 0 0\\n'
	;;
esac
""",
"ping": """#!/bin/sh
printf 'ping %s\\n' "$*" >>"$FAKE_CALLS"
exit 1
""",
    "iperf3": """#!/bin/sh
printf 'iperf3 %s\\n' "$*" >>"$FAKE_CALLS"
while [ $# -gt 0 ]; do
case "$1" in
-s)
	# Stand in for the listener until the harness kills it.
	sleep 30
	exit 0
	;;
--help)
	printf 'usage: iperf3 -s ...\\n'
	exit 0
	;;
esac
shift
done
cat "$FAKE_IPERF_JSON"
""",
}


def write_fake(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class ScriptFixture:
    """A fake device (ssh + sysfs) and a fake bench host (NICs + ip)."""

    def __init__(self, tmp):
        self.tmp = Path(tmp)
        self.bin = self.tmp / "bin"
        self.dev = self.tmp / "devsys"
        self.bin.mkdir()
        (self.dev / "class/net").mkdir(parents=True)
        self.calls = self.tmp / "calls.log"
        self.calls.write_text("")
        self.json = self.tmp / "iperf.json"
        self.json.write_text(IPERF_JSON)
        self.nics = self.tmp / "host-nics"
        # A management NIC at 1G, so the 2.5G data NIC is unambiguous.
        self.nics.write_text(
            "1: lo: <LOOPBACK> mtu 65536\n"
            "2: eth0: <BROADCAST> mtu 1500\n")
        for name, body in FAKES.items():
            write_fake(self.bin / name, body)

    def add_dev(self, iface, speed, modes, bridge=None):
        d = self.dev / "class/net" / iface
        d.mkdir(parents=True, exist_ok=True)
        (d / "speed").write_text("%s\n" % speed)
        (d / "duplex").write_text("Full\n")
        (d / "carrier").write_text("1\n")
        if modes:
            (d / "modes").write_text(
                "\tSupported link modes:   %s\n"
                "\tAdvertised link modes:  %s\n" % (modes, modes))
        if bridge:
            # /sys/class/net/<if>/master is a symlink to the bridge.
            (d / "master").symlink_to(bridge)

    def add_host_nic(self, iface, speed=2500):
        lines = self.nics.read_text().splitlines()
        with open(self.nics, "a", encoding="utf-8") as fh:
            fh.write("%d: %s: <BROADCAST> mtu 1500\n" % (len(lines) + 1, iface))
        d = self.dev / "class/net" / iface
        d.mkdir(parents=True, exist_ok=True)
        (d / "speed").write_text("%s\n" % speed)
        (d / "duplex").write_text("Full\n")
        (d / "carrier").write_text("1\n")
        (d / "modes").write_text(
            "\tSupported link modes:   2500baseT/Full\n"
            "\tAdvertised link modes:  2500baseT/Full\n")

    def run(self, *args, timeout=120, env_extra=None, cwd=None):
        env = dict(os.environ)
        env.update({
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "FAKE_BIN": str(self.bin),
            "FAKE_CALLS": str(self.calls),
            "FAKE_DEV_SYS": str(self.dev),
            "FAKE_NICS": str(self.nics),
            "FAKE_IPERF_JSON": str(self.json),
            "DEV_SYSFS": str(self.dev),
            "SSH_OPTS": "-o BatchMode=yes",
        })
        if env_extra:
            env.update(env_extra)
        env.pop("DEVICE", None)
        return subprocess.run(
            ["sh", str(SCRIPT), "--device", "root@192.0.2.1"] + list(args),
            capture_output=True, text=True, env=env, timeout=timeout,
            cwd=str(cwd or self.tmp))

    def logged(self):
        return self.calls.read_text()


class NoDevicePortTest(unittest.TestCase):
    """(a) nothing on the device advertises 2.5G."""

    def test_blocked_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = ScriptFixture(tmp)
            # The only port is 1G: no candidate, and no invented default.
            fx.add_dev("lan2", 1000, "\t1000baseT/Full\n")
            fx.add_dev("lan4", 1000, "\t1000baseT/Full\n")
            run = fx.run("--ports", "lan10g", "--host-lan10g-if", "bench0")
            # A block is not a failure, but the v2 contract no longer lets
            # nothing-measured exit 0: no device port is config-block, so 2.
            self.assertEqual(run.returncode, 2,
                             "BLOCKED is a block, not a failure\n"
                             + run.stdout + run.stderr)
            self.assertIn("BLOCKED: no device port advertises 2500baseT",
                          run.stdout)
            self.assertNotIn("iperf3 -c", fx.logged())
            self.assertFalse(Path(tmp, "out").exists())


class BridgedPortTest(unittest.TestCase):
    """(b) a 2.5G port that is a br-lan member."""

    def test_precondition_then_blocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = ScriptFixture(tmp)
            fx.add_dev("lan2", 2500, "\t2500baseT/Full\n", bridge="br-lan")
            fx.add_host_nic("bench0")
            run = fx.run("--ports", "lan10g", "--host-lan10g-if", "bench0")
            out = run.stdout
            # The port is in a bridge: config-block, v2 exit 2.
            self.assertEqual(run.returncode, 2, out + run.stderr)
            self.assertIn("precondition: lan2 is a member of br-lan", out)
            self.assertIn("ip link set lan2 nomaster", out)
            self.assertIn("BLOCKED: lan2 is in br-lan", out)
            # The script prints the commands; it must not run them.
            self.assertNotIn("nomaster", fx.logged())
            self.assertNotIn("iperf3 -c", fx.logged())

    def test_detach_plan_is_a_plan_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = ScriptFixture(tmp)
            fx.add_dev("lan2", 2500, "\t2500baseT/Full\n", bridge="br-lan")
            run = fx.run("--ports", "lan10g", "--detach-from-bridge")
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("DETACH PLAN", run.stdout)
            self.assertIn("ip link set lan2 master br-lan", run.stdout)
            self.assertNotIn("iperf3 -c", fx.logged())
            self.assertNotIn("nomaster", fx.logged())


class MeasurementTest(unittest.TestCase):
    """(c) a 2.5G port outside a bridge reaches the arms."""

    def test_detected_port_and_bidirectional_arms(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = ScriptFixture(tmp)
            # wan first in directory order, lan2 second: lan2 must win.
            fx.add_dev("wan", 2500, "\t2500baseT/Full\n")
            fx.add_dev("lan2", 2500, "\t2500baseT/Full\n")
            fx.add_host_nic("bench0")
            out_dir = Path(tmp) / "out"
            run = fx.run("--ports", "lan10g", "--host-lan10g-if", "bench0",
                         "--duration", "1", "--proto", "tcp",
                         "--out-dir", str(out_dir), timeout=180)
            self.assertEqual(run.returncode, 0,
                             "measurement failed:\n" + run.stdout + run.stderr)
            self.assertIn("dev_iface=lan2", run.stdout, run.stdout)
            self.assertIn("status: ok", run.stdout)

            calls = fx.logged()
            # Both directions ran; host->device carries -R, device->host does not.
            clients = [line for line in calls.splitlines()
                       if line.startswith("iperf3 -c")]
            self.assertEqual(len(clients), 2, calls)
            self.assertEqual(sum(1 for line in clients if " -R" in line), 1,
                             "exactly one arm must be reversed:\n" + calls)
            self.assertIn("arm lan10g host->device", run.stdout)
            self.assertIn("arm lan10g device->host", run.stdout)
            self.assertIn("tcp=", run.stdout)
            # No bridge, UCI or firewall change was attempted.
            self.assertNotIn("nomaster", calls)
            self.assertNotIn("uci", calls)
            self.assertNotIn("nft", calls)


class SourceTest(unittest.TestCase):
    """Static guards: no nonexistent default port, both BLOCKED lines exist."""

    def setUp(self):
        self.source = SCRIPT.read_text(encoding="utf-8")

    def test_no_hardcoded_lab_iface_default(self):
        self.assertNotIn("DEV_LAN_IF=lan10g", self.source)
        self.assertNotIn("DEV_WAN_IF=wan10g", self.source)
        self.assertIn("DEV_LAN_IF=${DEV_LAN_IF:-}", self.source)
        self.assertIn("DEV_WAN_IF=${DEV_WAN_IF:-}", self.source)

    def test_both_blocked_lines_are_reachable(self):
        self.assertIn("blocked \"no device port advertises 2500baseT\"",
                      self.source)
        self.assertIn('blocked "$dev_if is in $master"', self.source)
        self.assertIn("print_bridge_plan", self.source)
        self.assertIn("detach_plan", self.source)


ALWAYS_2G5_ETHTOOL = """#!/bin/sh
# Answers 2500baseT for every name, the literal '*' included: the board did
# answer it, which is how '*' passed the device-side ethtool filter.
case "$1" in
-i) printf 'driver: r8169\\n' ;;
-S) printf '     tx_errors: 0\\n     rx_errors: 0\\n' ;;
*)
	printf 'Settings for %s:\\n' "$1"
	printf '\\tSpeed: 2500Mb/s\\n'
	printf '\\tDuplex: Full\\n'
	printf '\\tLink detected: yes\\n'
	printf '\\tSupported link modes:   2500baseT/Full\\n'
	;;
esac
"""

# Top-level names of this repository: what an unquoted glob of '*' turns into
# when the host-side loop runs with the repository as its working directory.
REPO_FILE_NAMES = (
    "BSDmakefile",
    "COPYING",
    "Config.in",
    "LICENSES",
    "Makefile",
    "README.md",
)


class MissingDevSysfsTest(unittest.TestCase):
    """DEV_SYSFS with no class/net must not hand the literal '*' to the host."""

    def test_unmatched_glob_is_not_a_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = ScriptFixture(tmp)
            write_fake(fx.bin / "ethtool", ALWAYS_2G5_ETHTOOL)
            run = fx.run(
                "--ports", "both", "--out-dir", str(Path(tmp) / "out"),
                env_extra={"DEV_SYSFS": str(Path(tmp) / "does-not-exist")},
                cwd=REPO,
            )
            out = run.stdout + run.stderr
            # No port on the device advertises 2500baseT: config-block, exit 2.
            self.assertEqual(run.returncode, 2, out)
            for name in REPO_FILE_NAMES:
                self.assertNotIn(
                    name, out,
                    "the literal '*' reached the host loop and expanded against "
                    "the current directory:\n" + out)
            self.assertIn("BLOCKED: no device port advertises 2500baseT",
                          run.stdout)
            self.assertNotIn("device interface", out)

    def test_explicit_ports_skip_without_repo_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            fx = ScriptFixture(tmp)
            run = fx.run(
                "--ports", "both",
                "--dev-lan10g-if", "lan2", "--dev-wan10g-if", "wan",
                "--out-dir", str(Path(tmp) / "out"),
                env_extra={"DEV_SYSFS": str(Path(tmp) / "does-not-exist")},
            )
            out = run.stdout + run.stderr
            # A slow/absent link measured nothing: missing-hardware, exit 3.
            self.assertEqual(run.returncode, 3, out)
            self.assertIn("SKIP: no 2.5G link", run.stdout)
            for name in REPO_FILE_NAMES:
                self.assertNotIn(name, out, out)


if __name__ == "__main__":
    unittest.main()