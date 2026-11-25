#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline regression tests for bench-10g-unidirectional.sh (#13 F1/F2/F3/F4/F11).

Covers:
  - F1: capture_iface_counters sits adjacent to /proc/{uptime,stat,interrupts},
        packet rate divides by iperf3.seconds when positive numeric, and
        window_skew_pct is emitted.
  - F2: TSO/GSO/GRO coalescing detection (avg_bytes_per_pkt > mtu + 18),
        skb_per_sec / avg_bytes_per_pkt / coalesced fields, and pps=null when
        coalesced (never quoting skb/s as wire pps).
  - F3: serve_iperf() polls kill -0 "$_lpid" (no grep '"sum_received"'),
        propagates real wait exit status, and fails on JSON "error" or null
        bits_per_second.
  - F4: --baseline suppresses the paste-ready claims.yaml entry unless BOTH TX
        and RX succeed with real numeric Gbit/s.
  - F11: /proc/stat uses USER_HZ via clk_tck() (100, never CONFIG_HZ=250) and
        baseline table labels "CPU busy % of capacity", not "CPU busy % of wall".

BENCH_UNDER_TEST points at an alternate copy for red-green proof.

Run from the repository root:

    python3 -m unittest scripts.tests.test_bench_metrics
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("BENCH_UNDER_TEST")
    or REPO_ROOT / "scripts/bench-10g-unidirectional.sh"
)

VALID_IPERF_JSON = json.dumps(
    {
        "end": {
            "sum_sent": {
                "bits_per_second": 940000000.0,
                "bytes": 587500000,
                "seconds": 5.0,
                "retransmits": 2,
            },
            "sum_received": {
                "bits_per_second": 935000000.0,
                "bytes": 584375000,
                "seconds": 5.0,
            },
        }
    },
    indent=2,
) + "\n"


def script_functions_prefix() -> str:
    """Return the variable/function definitions before CLI arg parsing."""
    lines = SCRIPT.read_text(encoding="utf-8").splitlines()
    for idx, line in enumerate(lines):
        if line.strip() == "# arguments":
            return "\n".join(lines[:idx]) + "\n"
    raise AssertionError("could not find '# arguments' marker in %s" % SCRIPT)


def make_fake_iperf3(bin_dir: Path, body: str) -> Path:
    path = bin_dir / "iperf3"
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return path


class BenchMetricsTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), SCRIPT)
        self.tmp = Path(tempfile.mkdtemp(prefix="bench-metrics."))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def run_lib(self, body: str, env_extra: dict | None = None, timeout: int = 20):
        env = dict(os.environ)
        if env_extra:
            env.update(env_extra)
        code = script_functions_prefix() + "\n" + body + "\n"
        return subprocess.run(
            ["sh", "-c", code],
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
            check=False,
        )

    def _write_snapshots(
        self,
        root: Path,
        direction: str,
        *,
        uptime_before: str = "100.00 0.00\n",
        uptime_after: str = "107.00 0.00\n",
        tx_pkts_before: int = 1000,
        tx_pkts_after: int = 2000,
        tx_bytes_before: int = 0,
        tx_bytes_after: int = 20000000,
        rx_pkts_before: int = 500,
        rx_pkts_after: int = 10500,
        rx_bytes_before: int = 0,
        rx_bytes_after: int = 14000000,
    ):
        bdir = root / "snapshots" / f"{direction}-before"
        adir = root / "snapshots" / f"{direction}-after"
        bdir.mkdir(parents=True, exist_ok=True)
        adir.mkdir(parents=True, exist_ok=True)
        (bdir / "uptime.txt").write_text(uptime_before, encoding="utf-8")
        (adir / "uptime.txt").write_text(uptime_after, encoding="utf-8")
        (bdir / "iface-counters.txt").write_text(
            f"rx_packets {rx_pkts_before}\n"
            f"tx_packets {tx_pkts_before}\n"
            f"rx_bytes {rx_bytes_before}\n"
            f"tx_bytes {tx_bytes_before}\n"
            "rx_errors 0\n"
            "tx_errors 0\n",
            encoding="utf-8",
        )
        (adir / "iface-counters.txt").write_text(
            f"rx_packets {rx_pkts_after}\n"
            f"tx_packets {tx_pkts_after}\n"
            f"rx_bytes {rx_bytes_after}\n"
            f"tx_bytes {tx_bytes_after}\n"
            "rx_errors 0\n"
            "tx_errors 0\n",
            encoding="utf-8",
        )
        (bdir / "proc-stat.txt").write_text(
            "cpu  100 0 100 700 0 0 0 0 0 0\n"
            "cpu0 100 0 100 700 0 0 0 0 0 0\n",
            encoding="utf-8",
        )
        (adir / "proc-stat.txt").write_text(
            "cpu  150 0 150 1000 0 0 0 0 0 0\n"
            "cpu0 150 0 150 1000 0 0 0 0 0 0\n",
            encoding="utf-8",
        )
        (bdir / "proc-interrupts.txt").write_text(
            "           CPU0\n 23:       1000 GICv3 airoha_eth.0\n",
            encoding="utf-8",
        )
        (adir / "proc-interrupts.txt").write_text(
            "           CPU0\n 23:       1500 GICv3 airoha_eth.0\n",
            encoding="utf-8",
        )
        return bdir, adir

    # --- F1: window alignment, iperf3.seconds denominator, window_skew_pct ---

    def test_f1_snapshot_order_keeps_iface_counters_adjacent_to_proc(self):
        # Inspect the logged order of snapshot_before / snapshot_after.
        run_dir = self.tmp / "order"
        (run_dir / "snapshots/tx-before").mkdir(parents=True)
        (run_dir / "snapshots/tx-after").mkdir(parents=True)
        raw_log = run_dir / "raw.log"
        raw_log.write_text("", encoding="utf-8")
        proc = self.run_lib(
            f'RESULT_DIR="{run_dir}"\n'
            f'RAW_LOG="{raw_log}"\n'
            'IFACE=lo\n'
            'snapshot_before tx\n'
            'snapshot_after tx\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = raw_log.read_text(encoding="utf-8").splitlines()

        def phase_events(marker, stop_marker=None):
            start = next(i for i, l in enumerate(lines) if marker in l) + 1
            end = (
                next(i for i, l in enumerate(lines) if stop_marker in l)
                if stop_marker
                else len(lines)
            )
            return lines[start:end]

        before = phase_events("snapshot before tx", "snapshot after tx")
        after = phase_events("snapshot after tx")

        # Before: slow commands (nft/tc/ethtool/ppe) finish BEFORE the tight
        # iface-counters + /proc/{uptime,stat,interrupts} block.
        idx_before_if = next(i for i, l in enumerate(before) if "iface-counters.txt" in l)
        idx_before_up = next(i for i, l in enumerate(before) if "uptime.txt" in l)
        idx_before_stat = next(i for i, l in enumerate(before) if "proc-stat.txt" in l)
        idx_before_irq = next(i for i, l in enumerate(before) if "proc-interrupts.txt" in l)
        tight_before = sorted([idx_before_if, idx_before_up, idx_before_stat, idx_before_irq])
        self.assertEqual(
            tight_before[-1] - tight_before[0], 3,
            f"before iface-counters is not adjacent to /proc captures: {before}",
        )
        self.assertEqual(
            tight_before[-1], len(before) - 1,
            f"before tight block must be last before iperf3: {before}",
        )

        # After: tight iface-counters + /proc/{stat,interrupts,uptime} block
        # runs FIRST, before slow commands (ethtool/nft/tc/ppe).
        idx_after_if = next(i for i, l in enumerate(after) if "iface-counters.txt" in l)
        idx_after_up = next(i for i, l in enumerate(after) if "uptime.txt" in l)
        idx_after_stat = next(i for i, l in enumerate(after) if "proc-stat.txt" in l)
        idx_after_irq = next(i for i, l in enumerate(after) if "proc-interrupts.txt" in l)
        tight_after = sorted([idx_after_if, idx_after_up, idx_after_stat, idx_after_irq])
        self.assertEqual(
            tight_after, [0, 1, 2, 3],
            f"after iface-counters must be taken with /proc before snapshot_extra: {after}",
        )

    def test_f1_rate_uses_iperf3_seconds_and_emits_window_skew_pct(self):
        run_dir = self.tmp / "f1"
        bdir, adir = self._write_snapshots(
            run_dir,
            "rx",
            uptime_before="100.00 0.00\n",
            uptime_after="107.00 0.00\n",
            rx_pkts_before=500,
            rx_pkts_after=10500,  # delta = 10000 pkts
            rx_bytes_before=0,
            rx_bytes_after=14000000,  # avg = 1400 B/pkt (<= 1518, not coalesced)
        )
        ijson = run_dir / "iperf3-rx.json"
        ijson.write_text(VALID_IPERF_JSON, encoding="utf-8")  # seconds = 5.0
        proc = self.run_lib(
            f'RESULT_DIR="{run_dir}"\n'
            'TARGET=127.0.0.1\nIFACE=eth0\nPEER=client\nDURATION=5\nPARALLEL=4\nPORT=5201\n'
            '_mtu=1500\n'
            f'emit_direction rx 0 "{ijson}" "{bdir}" "{adir}"\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        # 10000 pkts / 5.0 s = 2000.0 (NOT 10000 / 7.0 = 1428.6)
        self.assertAlmostEqual(data["pps"], 2000.0, places=1)
        self.assertAlmostEqual(data["skb_per_sec"], 2000.0, places=1)
        # (7.0 - 5.0) / 5.0 * 100 = 40.0%
        self.assertIn("window_skew_pct", data)
        self.assertAlmostEqual(data["window_skew_pct"], 40.0, places=1)

    # --- F2: TSO/GSO/GRO coalescing detection ---

    def test_f2_coalesced_tx_sets_pps_null_and_emits_skb_metrics(self):
        run_dir = self.tmp / "f2"
        bdir, adir = self._write_snapshots(
            run_dir,
            "tx",
            uptime_before="100.00 0.00\n",
            uptime_after="105.00 0.00\n",
            tx_pkts_before=1000,
            tx_pkts_after=2000,      # delta = 1000 skbs
            tx_bytes_before=0,
            tx_bytes_after=20000000,  # avg = 20000 B/pkt > 1500 + 18
        )
        ijson = run_dir / "iperf3-tx.json"
        ijson.write_text(VALID_IPERF_JSON, encoding="utf-8")  # seconds = 5.0
        proc = self.run_lib(
            f'RESULT_DIR="{run_dir}"\n'
            'TARGET=127.0.0.1\nIFACE=eth0\nPEER=client\nDURATION=5\nPARALLEL=4\nPORT=5201\n'
            '_mtu=1500\n'
            f'emit_direction tx 0 "{ijson}" "{bdir}" "{adir}"\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertIs(data["coalesced"], True)
        self.assertIsNone(data["pps"], "coalesced skb/s must never be quoted as wire pps")
        self.assertAlmostEqual(data["skb_per_sec"], 200.0, places=1)
        self.assertAlmostEqual(data["avg_bytes_per_pkt"], 20000.0, places=1)

    def test_f2_non_coalesced_keeps_numeric_pps(self):
        run_dir = self.tmp / "f2-ok"
        bdir, adir = self._write_snapshots(
            run_dir,
            "rx",
            uptime_before="100.00 0.00\n",
            uptime_after="105.00 0.00\n",
            rx_pkts_before=0,
            rx_pkts_after=10000,
            rx_bytes_before=0,
            rx_bytes_after=15180000,  # avg = 1518.0 == mtu + 18 (not > mtu + 18)
        )
        ijson = run_dir / "iperf3-rx.json"
        ijson.write_text(VALID_IPERF_JSON, encoding="utf-8")
        proc = self.run_lib(
            f'RESULT_DIR="{run_dir}"\n'
            'TARGET=127.0.0.1\nIFACE=eth0\nPEER=client\nDURATION=5\nPARALLEL=4\nPORT=5201\n'
            '_mtu=1500\n'
            f'emit_direction rx 0 "{ijson}" "{bdir}" "{adir}"\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertIs(data["coalesced"], False)
        self.assertAlmostEqual(data["pps"], 2000.0, places=1)
        self.assertAlmostEqual(data["skb_per_sec"], 2000.0, places=1)
        self.assertAlmostEqual(data["avg_bytes_per_pkt"], 1518.0, places=1)

    # --- F3: serve_iperf process liveness, exit status, JSON error / null bps ---

    def _run_serve_iperf(self, fake_iperf_body: str, direction: str = "rx", peer_wait: int = 12):
        bin_dir = self.tmp / f"bin-{time.time_ns()}"
        bin_dir.mkdir()
        make_fake_iperf3(bin_dir, fake_iperf_body)
        raw_log = bin_dir / "raw.log"
        raw_log.write_text("", encoding="utf-8")
        out_json = bin_dir / f"iperf3-{direction}.json"
        err_file = bin_dir / f"iperf3-{direction}.err"
        empty_proc = bin_dir / "proc"
        empty_proc.mkdir()
        t0 = time.monotonic()
        proc = self.run_lib(
            f'PATH="{bin_dir}:$PATH"\n'
            f'RAW_LOG="{raw_log}"\n'
            f'SWEEP_PROC="{empty_proc}"\n'
            f'PEER=server\nPORT=5299\nDURATION=1\nPARALLEL=1\nPEER_WAIT={peer_wait}\n'
            'IFACE=lo\n_box_ip=127.0.0.1\n'
            f'serve_iperf {direction} "{out_json}" "{err_file}"\n',
            timeout=peer_wait + 10,
        )
        elapsed = time.monotonic() - t0
        return proc, elapsed, raw_log

    def test_f3_serve_iperf_exits_promptly_on_dead_listener_with_real_status(self):
        proc, elapsed, _ = self._run_serve_iperf(
            'printf \'{"error": "unable to bind"}\\n\'\nexit 1\n',
            peer_wait=12,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertLess(
            elapsed, 5.0,
            f"serve_iperf waited {elapsed:.1f}s instead of detecting dead listener via kill -0",
        )

    def test_f3_serve_iperf_propagates_nonzero_exit_even_if_sum_received_present(self):
        proc, elapsed, _ = self._run_serve_iperf(
            f"cat <<'JSON'\n{VALID_IPERF_JSON}JSON\nexit 2\n",
            peer_wait=12,
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertLess(elapsed, 5.0)

    def test_f3_serve_iperf_fails_on_json_error_even_if_exit_zero(self):
        # Inject "error" into pretty-printed VALID_IPERF_JSON so iperf_summary()
        # parses valid numeric bits_per_second; failure MUST come from "error".
        err_doc = json.loads(VALID_IPERF_JSON)
        err_doc["error"] = "interrupt"
        err_json = json.dumps(err_doc, indent=2) + "\n"
        proc, elapsed, raw_log = self._run_serve_iperf(
            f"cat <<'JSON'\n{err_json}JSON\nexit 0\n",
            peer_wait=12,
        )
        self.assertNotEqual(proc.returncode, 0, "JSON error must fail serve_iperf")
        self.assertLess(elapsed, 5.0)
        log_text = raw_log.read_text(encoding="utf-8")
        self.assertIn("reported JSON error: interrupt", log_text)
        self.assertNotIn("null or non-positive bits_per_second", log_text)

    def test_f3_serve_iperf_fails_on_null_bits_per_second(self):
        proc, elapsed, _ = self._run_serve_iperf(
            'printf \'{\\n  "end": {\\n    "sum_received": {\\n      "bits_per_second": null\\n    }\\n  }\\n}\\n\'\nexit 0\n',
            peer_wait=12,
        )
        self.assertNotEqual(proc.returncode, 0, "null bits_per_second must fail serve_iperf")
        self.assertLess(elapsed, 5.0)

    def test_f3_serve_iperf_succeeds_on_valid_json_and_zero_exit(self):
        proc, elapsed, _ = self._run_serve_iperf(
            f"cat <<'JSON'\n{VALID_IPERF_JSON}JSON\nexit 0\n",
            peer_wait=12,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertLess(elapsed, 5.0)

    def test_f3_pid_exited_helper_used_in_loop_and_post_loop(self):
        proc = self.run_lib("type pid_exited >/dev/null && (exit 0) & p=$!; wait $p; pid_exited $p")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        src = SCRIPT.read_text(encoding="utf-8")
        start = src.index("serve_iperf() {")
        end = src.index("\n}\n", start)
        body = src[start:end]
        self.assertGreaterEqual(
            body.count('pid_exited "$_lpid"'), 2,
            "serve_iperf() must use pid_exited both inside the wait loop and post-loop",
        )

    # --- F4: --baseline claims.yaml gating ---

    def _run_full_baseline_with_fake_iperf(self, fake_iperf_body: str, name: str):
        bin_dir = self.tmp / f"bin-{name}"
        bin_dir.mkdir()
        make_fake_iperf3(bin_dir, fake_iperf_body)
        out_dir = self.tmp / f"out-{name}"
        env = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ.get('PATH', '')}",
            TARGET="127.0.0.1",
            IFACE="lo",
            PORT="5298",
            DURATION="1",
            PARALLEL="1",
        )
        return subprocess.run(
            [
                "sh", str(SCRIPT),
                "--baseline",
                "--label", f"test-{name}",
                "--result-dir", str(out_dir),
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
            check=False,
        )

    def test_f4_baseline_suppresses_claims_yaml_when_one_direction_fails(self):
        body = (
            'case "$*" in\n'
            '*--version*) printf "iperf 3.22 fake\\n"; exit 0 ;;\n'
            '*" -R "*) printf \'{"error": "peer reset"}\\n\'; exit 1 ;;\n'
            f'*) cat <<\'JSON\'\n{VALID_IPERF_JSON}JSON\nexit 0 ;;\n'
            'esac\n'
        )
        proc = self._run_full_baseline_with_fake_iperf(body, "f4-fail")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertNotIn("status: supported", proc.stdout)
        self.assertNotIn("evidence: 实测", proc.stdout)
        self.assertNotIn("- id: baseline-test-f4-fail", proc.stdout)

    def test_f4_baseline_emits_claims_yaml_when_both_directions_succeed(self):
        body = (
            'case "$*" in\n'
            '*--version*) printf "iperf 3.22 fake\\n"; exit 0 ;;\n'
            f'*) cat <<\'JSON\'\n{VALID_IPERF_JSON}JSON\nexit 0 ;;\n'
            'esac\n'
        )
        proc = self._run_full_baseline_with_fake_iperf(body, "f4-ok")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("status: supported", proc.stdout)
        self.assertIn("evidence: 实测", proc.stdout)
        self.assertIn("TX 0.940 Gbit/s、RX 0.935 Gbit/s", proc.stdout)
        # F11 table header check in the same baseline output
        self.assertIn("CPU busy % of capacity", proc.stdout)
        self.assertNotIn("CPU busy % of wall", proc.stdout)

    # --- F11: clk_tck() and USER_HZ=100 ---

    def test_f11_cpu_seconds_uses_clk_tck_user_hz_not_config_hz_250(self):
        b = self.tmp / "stat-before.txt"
        a = self.tmp / "stat-after.txt"
        # dt = 400 ticks, di = 300 ticks -> busy = 100 ticks
        b.write_text("cpu  100 0 100 700 0 0 0 0 0 0\n", encoding="utf-8")
        a.write_text("cpu  150 0 150 1000 0 0 0 0 0 0\n", encoding="utf-8")

        # Default (USER_HZ=100 on Linux, NEVER CONFIG_HZ=250):
        # busy=1.00s, total=4.00s, idle=75.00%
        proc_def = self.run_lib(
            f'unset BENCH_CLK_TCK\nclk_tck\ncpu_seconds "{b}" "{a}"\n'
        )
        self.assertEqual(proc_def.returncode, 0, proc_def.stderr)
        lines = proc_def.stdout.strip().splitlines()
        self.assertEqual(lines[0], "100")
        self.assertEqual(lines[1], "1.00 4.00 75.00")

        # Explicit override via BENCH_CLK_TCK=200 proves clk_tck() is wired.
        proc_200 = self.run_lib(
            f'BENCH_CLK_TCK=200\nclk_tck\ncpu_seconds "{b}" "{a}"\n'
        )
        self.assertEqual(proc_200.returncode, 0, proc_200.stderr)
        lines2 = proc_200.stdout.strip().splitlines()
        self.assertEqual(lines2[0], "200")
        self.assertEqual(lines2[1], "0.50 2.00 75.00")


if __name__ == "__main__":
    unittest.main(verbosity=2)
