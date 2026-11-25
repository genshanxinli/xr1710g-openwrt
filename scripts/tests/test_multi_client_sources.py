#!/usr/bin/env python3
"""Regression tests for scripts/wireless/multi-client.sh.

Two audited defects, both stub-level (no device, no iperf3):

1. kill_sources only killed the source pid and the descendants it could see in
   /proc.  A sender that had already been reparented (iperf3 behind a `sh -c`
   wrapper, ringblast behind a subshell) survived, and the next arm then
   measured the previous arm's traffic.  The sources now run in their own
   process group and the group is killed and polled to zero.

2. Every row with any traffic at all was "ok", so an idle client printed
   "0.000 ok" and the aggregate counted it.  A row below --min-mbit is now
   "idle", and an arm with an idle client cannot be ok.

The stubs stand in for iw and ssh; the source itself is a plain sleep, so the
byte counters are what the fake iw reports.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("MULTI_CLIENT_UNDER_TEST")
    or (REPO / "scripts" / "wireless" / "multi-client.sh")
)

MAC1 = "aa:bb:cc:dd:ee:01"
MAC2 = "aa:bb:cc:dd:ee:02"
IP1 = "10.0.0.2"
IP2 = "10.0.0.3"
AP_IF = "phy0-ap0"
FEEDER = "root@feeder.invalid"
FEEDER_IF = "br-lan"

IW_STUB = """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
rates = []
with open(os.path.join(os.environ["MC50_FIX"], "macs")) as fh:
    for line in fh:
        mac, rate = line.split()
        rates.append((mac, float(rate)))
if args == ["dev"]:
    print("Interface %s" % os.environ["MC50_AP_IF"])
    sys.exit(0)
if len(args) == 3 and args[0] == "dev" and args[2] == "info":
    print("Interface %s" % args[1])
    print("\\twdev 0x1")
    print("\\taddr 00:11:22:33:44:55")
    print("\\ttype AP")
    print("\\tchannel 37 (6135 MHz) width: 80 MHz")
    sys.exit(0)
if len(args) == 4 and args[0] == "dev" and args[2:] == ["station", "dump"]:
    now = float(open("/proc/uptime").read().split()[0])
    for mac, rate in rates:
        n = int(rate * 1e6 / 8 * now)
        print("Station %s (on %s)" % (mac, os.environ["MC50_AP_IF"]))
        print("\\tassociated: yes")
        print("\\tsignal: -55 dBm")
        print("\\ttx bytes: %d" % n)
        print("\\trx bytes: %d" % n)
        print("\\ttx retries: 0")
        print("\\ttx failed: 0")
        print("\\ttx bitrate: 1200.0 MBit/s 80MHz NSS 2 MCS 11")
        print("\\trx bitrate: 1200.0 MBit/s 80MHz NSS 2 MCS 11")
    sys.exit(0)
sys.exit(1)
"""

SSH_STUB = """#!/bin/sh
# Everything but the options is the command; the feeder answers locally.
cmd=
for a in "$@"; do cmd=$a; done
case $cmd in
*"cat /sys/class/net/"*) echo 10000; exit 0 ;;
*"ip -4 -o addr"*) echo "4: $MC50_FEEDER_IF    inet 192.168.1.10/24 brd 192.168.1.0/24 scope global"; exit 0 ;;
*"ip route get"*) ip=$(echo "$cmd" | awk '{ for (i = 1; i <= NF; i++) if ($i == "get") { print $(i + 1); exit } }')
	echo "$ip via 192.168.1.1 dev $MC50_FEEDER_IF src 192.168.1.10"; exit 0 ;;
esac
exec sh -c "$cmd"
"""


class Fixture:
    """A temp dir with the iw/ssh stubs on PATH and the fake rates."""

    def __init__(self, rates, out):
        self.tmp = tempfile.mkdtemp(prefix="mc50-")
        self.fix = Path(self.tmp) / "fix"
        self.fix.mkdir()
        self.out = Path(out)
        self.bin = Path(self.tmp) / "bin"
        self.bin.mkdir()
        (self.fix / "macs").write_text(
            "".join("%s %s\n" % (mac, rate) for mac, rate in rates)
        )
        for name, body in (("iw", IW_STUB), ("ssh", SSH_STUB)):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": "%s:%s" % (self.bin, self.env.get("PATH", "/usr/bin:/bin")),
                "MC50_FIX": str(self.fix),
                "MC50_AP_IF": AP_IF,
                "MC50_FEEDER_IF": FEEDER_IF,
                # An empty debugfs root: no token_info reads, no device.
                "DEBUGFS_ROOT": str(self.fix / "debugfs"),
                "KILL_WAIT": "5",
            }
        )
        for k in ("MIN_MBIT", "TARGET_A_GBIT", "TARGET_B_GBIT"):
            self.env.pop(k, None)
        (self.fix / "debugfs").mkdir()

    def args(self, extra=(), arm="a", window=2, warmup=1):
        base = [
            str(SCRIPT),
            "--client", MAC1,
            "--client-ip", "%s=%s" % (MAC1, IP1),
            "--client", MAC2,
            "--client-ip", "%s=%s" % (MAC2, IP2),
            "--source", 'sleep "$SOURCE_SECS"',
            "--arm", arm,
            "--window", str(window),
            "--warmup", str(warmup),
            "--interval", "1",
            "--out", str(self.out),
        ]
        return base + list(extra)

    def run(self, extra=(), arm="a", timeout=90):
        return subprocess.run(
            self.args(extra, arm=arm),
            cwd=str(REPO),
            env=self.env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )


def rows(out):
    """result.tsv as dicts, header included."""
    text = (Path(out) / "result.tsv").read_text()
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return [ln.split("\t") for ln in lines]


def client_rows(out, arm=None):
    return [
        r
        for r in rows(out)[1:]
        if not r[1].startswith("AGGREGATE") and (arm is None or r[0] == arm)
    ]


def aggregate_rows(out, arm=None):
    return [
        r for r in rows(out)[1:] if r[1].startswith("AGGREGATE") and (arm is None or r[0] == arm)
    ]


def status(row):
    return row[14]


def min_mbit_field(row):
    return row[15]


class MinMbitFlagTest(unittest.TestCase):
    def test_min_mbit_flag_turns_a_2_mbit_client_idle(self):
        out = Path(tempfile.mkdtemp(prefix="mc50-out-")) / "out"
        fix = Fixture([(MAC1, 6.0), (MAC2, 2.0)], out)
        proc = fix.run(extra=["--min-mbit", "5"])
        # Measured, but an idle client aborts the arm: v2 exit 4.
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        by_mac = {r[1]: r for r in client_rows(out)}
        self.assertEqual(status(by_mac[MAC1]), "ok", by_mac[MAC1])
        self.assertEqual(status(by_mac[MAC2]), "idle", by_mac[MAC2])
        self.assertEqual(min_mbit_field(by_mac[MAC1]), "5")
        agg = aggregate_rows(out)
        self.assertTrue(agg)
        self.assertNotEqual(status(agg[0]), "ok", agg[0])
        data = json.loads((Path(out) / "result.json").read_text())
        self.assertEqual(data["min_mbit"], 5.0)
        idle = [r for r in data["rows"] if r["client"] == MAC2]
        self.assertEqual(idle[0]["status"], "idle", idle[0])
        self.assertEqual(idle[0]["min_mbit"], 5)


class IdleClientTest(unittest.TestCase):
    def test_idle_client_is_not_ok(self):
        """0.05 Mbit/s prints "0.000" but is not a data point."""
        out = Path(tempfile.mkdtemp(prefix="mc50-out-")) / "out"
        fix = Fixture([(MAC1, 2.0), (MAC2, 0.05)], out)
        proc = fix.run()
        # Measured, but the quiet client aborts the arm: v2 exit 4.
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        by_mac = {r[1]: r for r in client_rows(out)}
        self.assertEqual(status(by_mac[MAC1]), "ok", by_mac[MAC1])
        self.assertNotEqual(status(by_mac[MAC2]), "ok", by_mac[MAC2])
        self.assertIn("0.000", [r[10] for r in by_mac.values()] + [r[11] for r in by_mac.values()])
        agg = aggregate_rows(out)
        self.assertTrue(agg, "an aborted arm still reports its aggregate row")
        self.assertNotEqual(status(agg[0]), "ok", agg[0])
        data = json.loads((Path(out) / "result.json").read_text())
        self.assertNotEqual(data["arms"][0]["status"], "ok", data["arms"][0])


class GrandchildTest(unittest.TestCase):
    def test_kill_sources_kills_grandchildren(self):
        """A reparented sender in the source group dies with the group."""
        out = Path(tempfile.mkdtemp(prefix="mc50-out-")) / "out"
        fix = Fixture([(MAC1, 2.0), (MAC2, 2.0)], out)

        pidfile = fix.out / "arm-a" / "grandchildren.txt"
        samples = fix.out / "arm-a" / "samples.tsv"
        # The subshell exits at once, so the sleep is reparented and no longer
        # in the ppid tree of the recorded pid; only a group kill reaches it.
        source = '( sleep 300 & echo $! >> "$OUT/grandchildren.txt" ) ; sleep "$SOURCE_SECS"'
        # Use a 5s warmup so heavy parallel CPU load cannot finish the arm
        # before SIGINT arrives, and wait until both sources have recorded
        # their grandchildren and warmup sampling has started (guaranteeing
        # start_sources has finished registering every PID in SRC_PIDS).
        args = fix.args(extra=["--source", source], warmup=5)
        proc = subprocess.Popen(
            args,
            cwd=str(REPO),
            env=fix.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        pids = []
        try:
            deadline = time.time() + 25
            while time.time() < deadline:
                if pidfile.exists():
                    pids = [int(x) for x in pidfile.read_text().split()]
                warmup_ready = (
                    samples.exists()
                    and "\nwarmup\t" in samples.read_text()
                )
                if len(pids) >= 1 and warmup_ready:
                    break
                time.sleep(0.1)
            self.assertTrue(pidfile.exists(), "the source never started")
            pids = [int(x) for x in pidfile.read_text().split()]
            self.assertTrue(pids, "the stub source recorded no grandchild")
            # Interrupt during the warm-up, the same way an operator would.
            proc.send_signal(signal.SIGINT)
            out_text = proc.communicate(timeout=30)[0]
            # Re-read in case another entry flushed just before signal delivery.
            pids = sorted(set(pids) | {int(x) for x in pidfile.read_text().split()})
            deadline = time.time() + 10
            alive = list(pids)
            while time.time() < deadline and alive:
                alive = [p for p in alive if Path("/proc/%d/stat" % p).exists()]
                if alive:
                    time.sleep(0.2)
            self.assertEqual(alive, [], "grandchild(ren) still alive after cleanup: %r\n%s" % (alive, out_text))
        finally:
            if proc.poll() is None:
                proc.kill()
            for p in pids:  # a surviving grandchild must not outlive the test
                try:
                    os.kill(p, signal.SIGKILL)
                except OSError:
                    pass


class BothArmsTest(unittest.TestCase):
    def test_a_b_windows_aggregate(self):
        out = Path(tempfile.mkdtemp(prefix="mc50-out-")) / "out"
        fix = Fixture([(MAC1, 2000.0), (MAC2, 3000.0)], out)
        proc = fix.run(arm="both", extra=["--feeder", FEEDER, "--feeder-if", FEEDER_IF], timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        for arm in ("a", "b"):
            crow = client_rows(out, arm)
            self.assertEqual(len(crow), 2, "arm %s: %r" % (arm, crow))
            for r in crow:
                self.assertEqual(status(r), "ok", r)
                self.assertEqual(min_mbit_field(r), "1.0")
            agg = aggregate_rows(out, arm)
            self.assertEqual(len(agg), 1, "arm %s has no aggregate row" % arm)
            self.assertEqual(status(agg[0]), "ok", agg[0])
            tx = float(agg[0][10])
            self.assertAlmostEqual(tx, 5.0, delta=0.5, msg="arm %s aggregate tx %r" % (arm, agg[0]))
        data = json.loads((Path(out) / "result.json").read_text())
        self.assertEqual(len(data["rows"]), 6)
        self.assertEqual([a["arm"] for a in data["arms"]], ["a", "b"])
        self.assertEqual((Path(out) / "meta.txt").read_text().count("min_mbit=1.0"), 1)

class MinMbpsAliasTest(unittest.TestCase):
    """--min-mbps is the same floor as --min-mbit, and the arm says how many
    clients it cost.  An operator reading "ok" next to a quiet client is the
    defect this guards: the count line has to name the below-floor rows."""

    def test_min_mbps_alias_and_status_counts(self):
        out = Path(tempfile.mkdtemp(prefix="mc50-out-")) / "out"
        fix = Fixture([(MAC1, 6.0), (MAC2, 0.05)], out)
        proc = fix.run(extra=["--min-mbps", "5"])
        # Measured, but one client is below the floor: v2 exit 4.
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        self.assertIn("ok=1 below_floor=1 invalid=0", proc.stdout, proc.stdout)
        data = json.loads((Path(out) / "result.json").read_text())
        self.assertEqual(data["min_mbit"], 5.0)

    def test_min_mbps_needs_a_value(self):
        out = Path(tempfile.mkdtemp(prefix="mc50-out-")) / "out"
        fix = Fixture([(MAC1, 6.0), (MAC2, 6.0)], out)
        proc = fix.run(extra=["--min-mbps"])
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("--min-mbps", proc.stderr)


if __name__ == "__main__":
    unittest.main()
