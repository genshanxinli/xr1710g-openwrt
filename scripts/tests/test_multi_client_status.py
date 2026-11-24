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


if __name__ == "__main__":
    unittest.main(verbosity=2)
