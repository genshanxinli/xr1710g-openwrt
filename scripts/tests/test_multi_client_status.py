#!/usr/bin/env python3
"""Regression tests for two audited defects in scripts/wireless/multi-client.sh.

1. A08-F1: kill_sources() waited for each source leader *before* the KILL
   escalation, so a leader that traps or ignores SIGTERM (a user-supplied
   --source wrapper) never returned from wait, the KILL_WAIT watchdog was
   never reached, and the whole A/B harness wedged.  The fix polls the
   group, KILLs the survivors, polls again, and only then reaps.

2. M1: an arm that failed per-client validation wrote its AGGREGATE(n) row
   with the internal token "abort", outside the documented status
   vocabulary (ok|idle|invalid|ABORTED), and result.json's dedupe consumed
   that row first, so the arm status was never a documented value.

MULTI_CLIENT_UNDER_TEST points the tests at another copy of the script so a
red proof can run against the pre-fix version (repo convention).
"""

import json
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("MULTI_CLIENT_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/multi-client.sh"
)

STATUS_VOCAB = {"ok", "idle", "invalid", "ABORTED"}


def extract_function(name):
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def functions(*names):
    return "\n".join(extract_function(name) for name in names)


class KillSourcesTest(unittest.TestCase):
    """A SIGTERM-ignoring leader must not block the harness forever."""

    def setUp(self):
        if shutil.which("setsid") is None:
            self.skipTest("setsid(1) is required to build a process group")
        self.tmp = Path(tempfile.mkdtemp(prefix="mc50-kill-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pidfile = self.tmp / "leader.pid"

    def cleanup_group(self):
        if not self.pidfile.exists():
            return
        try:
            pid = int(self.pidfile.read_text().split()[0])
        except (OSError, ValueError):
            return
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass

    def test_kill_escalation_is_reached_for_a_term_ignoring_leader(self):
        self.addCleanup(self.cleanup_group)
        pidfile = shlex.quote(str(self.pidfile))
        body = (
            "warn() { :; }\n"
            "KILL_WAIT=2\n"
            + functions(
                "proc_pgid", "is_group_leader", "group_pids",
                "left_in_groups", "wait_groups_gone", "kill_sources",
            )
            + 'setsid sh -c \'trap "" TERM; sleep 300\' &\n'
            "_p=$!\n"
            + ("printf '%%s\\n' \"$_p\" > %s\n" % pidfile)
            + "sleep 0.3\n"
            "SRC_PIDS=$_p\n"
            "_start=$(date +%s)\n"
            "kill_sources\n"
            "_end=$(date +%s)\n"
            'printf "elapsed=%s arm=%s alive=%s\\n" '
            '"$((_end - _start))" "${ARM_STATUS:-}" "$(left_in_groups)"\n'
            'kill -KILL -"$_p" 2>/dev/null || true\n'
            + "exit 0\n"
        )
        try:
            result = subprocess.run(
                ["sh", "-c", body], capture_output=True, text=True, timeout=15,
                check=False,
            )
        except subprocess.TimeoutExpired:
            self.fail(
                "kill_sources blocked on wait; the KILL escalation after "
                "KILL_WAIT was never reached"
            )
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, out)
        self.assertIn("elapsed=", out, out)
        elapsed = int(out.split("elapsed=")[1].split()[0])
        self.assertLess(elapsed, 10, "kill_sources blocked on wait: %s" % out)
        self.assertIn("alive=", out, out)
        self.assertEqual(out.split("alive=")[1].strip(), "",
                         "the source group survived: %s" % out)


class AggregateStatusTest(unittest.TestCase):
    """The arm row must carry a documented status, and result.json must agree."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mc50-agg-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = self.tmp
        self.arm_dir = self.tmp / "arm-a"
        self.arm_dir.mkdir()

    def write_rows(self, client_status):
        row = ("a\tAA:BB:CC:DD:EE:01\tphy1-ap0\t37\t320\t2\t-52\t"
               "1000\t1000\t2.000\t0.004\t0.004\t0\t0\t%s\t1\n")
        (self.arm_dir / "result.tsv").write_text(row % client_status)

    def run_sh(self, body):
        return subprocess.run(
            ["sh", "-c", body], capture_output=True, text=True, check=False,
            env={"PATH": os.environ["PATH"], "OUT": str(self.out),
                 "ARM_DIR": str(self.arm_dir)},
        )

    def arm_statuses(self, client_status):
        self.write_rows(client_status)
        body = (
            "say() { :; }\n"
            "tsv_field() { printf '%s\\n' \"$1\" | cut -f\"$2\"; }\n"
            "ARM=a ARM_STATUS=abort WINDOW_SECS=2.000 MIN_MBIT=1 ACTIVE_COUNT=1\n"
            + functions("print_arm_table", "write_result_json")
            + "print_arm_table >/dev/null\n"
            + 'cp "$ARM_DIR/result.tsv" "$OUT/result.tsv"\n'
            + "write_result_json\n"
        )
        self.run_sh(body)
        data = json.loads((self.tmp / "result.json").read_text())
        return data["rows"], data["arms"]

    def test_invalid_client_row_bounds_the_aggregate_to_the_vocabulary(self):
        rows, arms = self.arm_statuses("invalid")
        self.assertEqual(len(arms), 1, arms)
        for row in rows:
            self.assertIn(row["status"], STATUS_VOCAB, row)
        self.assertIn(arms[0]["status"], STATUS_VOCAB, arms[0])
        self.assertEqual(arms[0]["status"], "invalid", arms[0])

    def test_idle_client_row_is_reported_as_idle_not_abort(self):
        rows, arms = self.arm_statuses("idle")
        self.assertEqual(len(arms), 1, arms)
        for row in rows:
            self.assertIn(row["status"], STATUS_VOCAB, row)
        self.assertEqual(arms[0]["status"], "idle", arms[0])

    def test_no_parsable_row_is_invalid_not_ok(self):
        # A row-format drift would leave zero data points; the arm must not
        # then publish "ok" (the old awk fell through to it on an empty file).
        (self.arm_dir / "result.tsv").write_text("")
        body = (
            "say() { :; }\n"
            "tsv_field() { printf '%s\\n' \"$1\" | cut -f\"$2\"; }\n"
            "ARM=a ARM_STATUS=abort WINDOW_SECS=2.000 MIN_MBIT=1 ACTIVE_COUNT=1\n"
            + functions("print_arm_table")
            + "print_arm_table >/dev/null\n"
            + 'tail -n 1 "$ARM_DIR/result.tsv" | cut -f15\n'
        )
        result = self.run_sh(body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "invalid", result.stdout)


IW_STUB = """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
rates = []
with open(os.path.join(os.environ["MC50_FIX"], "macs")) as fh:
    for line in fh:
        mac, rate = line.split()
        rates.append((mac, float(rate)))
if args == ["dev"]:
    print("Interface phy0-ap0")
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
        print("Station %s (on phy0-ap0)" % mac)
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
cmd=
for a in "$@"; do cmd=$a; done
case $cmd in
*"cat /sys/class/net/"*) echo 10000; exit 0 ;;
*"ip -4 -o addr"*) echo "4: br-lan    inet 192.168.1.10/24 brd 192.168.1.0/24 scope global"; exit 0 ;;
*"ip route get"*) ip=$(echo "$cmd" | awk '{ for (i = 1; i <= NF; i++) if ($i == "get") { print $(i + 1); exit } }')
	echo "$ip via 192.168.1.1 dev br-lan src 192.168.1.10"; exit 0 ;;
esac
exec sh -c "$cmd"
"""


class TargetThresholdTest(unittest.TestCase):
    """M2: aggregate target thresholds (--target-a-gbit / --target-b-gbit)."""

    MAC1 = "aa:bb:cc:dd:ee:01"
    MAC2 = "aa:bb:cc:dd:ee:02"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mc50-m2-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fix = self.tmp / "fix"
        self.fix.mkdir()
        (self.fix / "debugfs").mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, body in (("iw", IW_STUB), ("ssh", SSH_STUB)):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)

    def run_harness(self, rates, extra=(), arm="a", subdir="out"):
        (self.fix / "macs").write_text(
            "".join("%s %s\n" % (mac, rate) for mac, rate in rates)
        )
        out = self.tmp / subdir
        env = os.environ.copy()
        env.update({
            "PATH": "%s:%s" % (self.bin, env.get("PATH", "/usr/bin:/bin")),
            "MC50_FIX": str(self.fix),
            "DEBUGFS_ROOT": str(self.fix / "debugfs"),
            "KILL_WAIT": "5",
        })
        for k in ("MIN_MBIT", "TARGET_A_GBIT", "TARGET_B_GBIT"):
            env.pop(k, None)
        cmd = [
            str(SCRIPT),
            "--client", self.MAC1,
            "--client-ip", "%s=10.0.0.2" % self.MAC1,
            "--client", self.MAC2,
            "--client-ip", "%s=10.0.0.3" % self.MAC2,
            "--source", 'sleep "$SOURCE_SECS"',
            "--arm", arm,
            "--window", "1",
            "--warmup", "1",
            "--interval", "1",
            "--out", str(out),
        ] + list(extra)
        proc = subprocess.run(
            cmd, cwd=str(REPO_ROOT), env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=60, check=False,
        )
        return proc, out

    def test_arm_a_below_default_target_exits_5_with_fail_verdict(self):
        # 500 + 500 Mbit/s = 1.0 Gbit/s: both clients ok, below 2.0 Gbit/s target.
        proc, out = self.run_harness([(self.MAC1, 500.0), (self.MAC2, 500.0)], subdir="a-fail")
        self.assertEqual(proc.returncode, 5, proc.stdout + proc.stderr)
        data = json.loads((out / "result.json").read_text())
        arm = data["arms"][0]
        self.assertIn(arm["status"], STATUS_VOCAB, arm)
        self.assertEqual(arm["status"], "ok", arm)
        self.assertEqual(arm["target_gbit"], 2.0, arm)
        self.assertIs(arm["target_met"], False, arm)
        self.assertIn("FAIL", proc.stdout, proc.stdout)

    def test_arm_a_meets_target_exits_0_with_pass_verdict(self):
        proc, out = self.run_harness(
            [(self.MAC1, 500.0), (self.MAC2, 500.0)],
            extra=["--target-a-gbit", "0.5"],
            subdir="a-pass",
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        data = json.loads((out / "result.json").read_text())
        arm = data["arms"][0]
        self.assertEqual(arm["status"], "ok", arm)
        self.assertEqual(arm["target_gbit"], 0.5, arm)
        self.assertIs(arm["target_met"], True, arm)
        self.assertIn("PASS", proc.stdout, proc.stdout)

    def test_zero_target_disables_gate(self):
        proc, out = self.run_harness(
            [(self.MAC1, 10.0), (self.MAC2, 10.0)],
            extra=["--target-a-gbit", "0"],
            subdir="a-off",
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        data = json.loads((out / "result.json").read_text())
        arm = data["arms"][0]
        self.assertEqual(arm["status"], "ok", arm)
        self.assertEqual(arm["target_gbit"], 0, arm)
        self.assertIs(arm["target_met"], True, arm)

    def test_arm_b_uses_target_b_gbit_default_and_zero_disable(self):
        proc, out = self.run_harness(
            [(self.MAC1, 500.0), (self.MAC2, 500.0)],
            arm="b",
            extra=["--feeder", "root@feeder.invalid", "--feeder-if", "br-lan"],
            subdir="b-fail",
        )
        self.assertEqual(proc.returncode, 5, proc.stdout + proc.stderr)
        data = json.loads((out / "result.json").read_text())
        arm = data["arms"][0]
        self.assertEqual(arm["arm"], "b", arm)
        self.assertEqual(arm["status"], "ok", arm)
        self.assertEqual(arm["target_gbit"], 1.5, arm)
        self.assertIs(arm["target_met"], False, arm)
        self.assertIn("FAIL", proc.stdout, proc.stdout)

        proc2, out2 = self.run_harness(
            [(self.MAC1, 500.0), (self.MAC2, 500.0)],
            arm="b",
            extra=[
                "--feeder", "root@feeder.invalid", "--feeder-if", "br-lan",
                "--target-b-gbit", "0",
            ],
            subdir="b-off",
        )
        self.assertEqual(proc2.returncode, 0, proc2.stdout + proc2.stderr)
        data2 = json.loads((out2 / "result.json").read_text())
        self.assertEqual(data2["arms"][0]["target_gbit"], 0)
        self.assertIs(data2["arms"][0]["target_met"], True)

    def test_invalid_target_flag_rejected_with_exit_2(self):
        for flag in ("--target-a-gbit", "--target-b-gbit"):
            proc = subprocess.run(
                [str(SCRIPT), "--dry-run", flag, "-1"],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)

    def test_missing_iw_exits_2_as_missing_tool_and_standalone_fallback_exits_3(self):
        # Missing iw must classify as missing-tool (exit 2) rather than exit 1.
        empty_bin = self.tmp / "empty-bin"
        empty_bin.mkdir()
        for tool in ("sh", "awk", "sed", "tr", "cut", "cat", "mkdir", "mv", "rm", "date", "dirname", "basename", "grep", "head", "tail", "uname"):
            for base in ("/bin", "/usr/bin"):
                cand = Path(base) / tool
                if cand.exists() and not (empty_bin / tool).exists():
                    (empty_bin / tool).symlink_to(cand)
        out_missing = self.tmp / "out-no-iw"
        env_no_iw = {"PATH": str(empty_bin), "HOME": str(self.tmp)}
        proc = subprocess.run(
            ["sh", str(SCRIPT), "--client", self.MAC1, "--client", self.MAC2, "--out", str(out_missing)],
            capture_output=True, text=True, env=env_no_iw, check=False,
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        rec = json.loads((out_missing / "no-hardware" / "result.json").read_text())
        self.assertEqual(rec.get("cause"), "missing-tool", rec)

        # Standalone copy without lib/no-client.sh must still exit 3 on <2 clients.
        standalone_dir = self.tmp / "standalone-mc"
        standalone_dir.mkdir()
        standalone = standalone_dir / "multi-client.sh"
        standalone.write_text(SCRIPT.read_text())
        standalone.chmod(0o755)
        bin_no_sta = self.tmp / "bin-no-sta"
        bin_no_sta.mkdir()
        iw_stub = bin_no_sta / "iw"
        iw_stub.write_text(
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "dev) printf 'phy#0\\n\\tInterface phy0-ap0\\n\\t\\ttype AP\\n' ;;\n"
            "'dev phy0-ap0 info') printf 'Interface phy0-ap0\\n\\ttype AP\\n\\tchannel 36 (5180 MHz), width: 160 MHz\\n' ;;\n"
            "*) ;;\n"
            "esac\n"
        )
        iw_stub.chmod(0o755)
        env_standalone = os.environ.copy()
        env_standalone["PATH"] = f"{bin_no_sta}:{os.environ['PATH']}"
        proc_s = subprocess.run(
            ["sh", str(standalone), "--client", self.MAC1, "--client", self.MAC2, "--out", str(self.tmp / "out-standalone")],
            capture_output=True, text=True, env=env_standalone, check=False,
        )
        self.assertEqual(proc_s.returncode, 3, proc_s.stdout + proc_s.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
