#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard the --baseline record of scripts/bench-10g-unidirectional.sh (issue #13).

Three things the citable baseline rests on:

  1. `--baseline` leaves the whole environment in result.json -- the link
     snapshot (environment), the raw iperf3 JSON of both directions and the
     PPE binding fields -- so no second file is needed to cite a number.
  2. the script asks nobody to write a prose record: it used to print
     "Commit this file as scripts/perf-baselines/<label>.md before citing
     it", and this repo keeps measurements as data.  There is no .md
     anywhere in the script, and the pasted claims.yaml entry points at
     result.json:1.
  3. scripts/claims.yaml still validates, and both the 1G baseline claim
     and the stock-vs-OpenWrt claim keep the evidence/status pair they are
     allowed to have.

Run: python3 -m unittest scripts.tests.test_bench_baseline
"""

import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("BENCH_UNDER_TEST")
    or REPO / "scripts/bench-10g-unidirectional.sh"
)
PERF_BASELINES = Path(
    os.environ.get("PERF_BASELINES_UNDER_TEST")
    or REPO / "scripts/perf-baselines"
)
CLAIMS = REPO / "scripts/claims.yaml"
CHECK_CLAIMS = REPO / "scripts/check-claims.py"

# The record file the script must not tell anyone to write.
MD_HINT = re.compile(r"(\w|`)\s*(\.md|\\u002emd)")


def check_baseline_artifacts(result_json: Path) -> list:
    """Return missing/broken artifact pointer messages for one result.json."""
    base = result_json.parent
    data = json.loads(result_json.read_text(encoding="utf-8"))
    errors = []
    if data.get("schema") != "bench-10g-unidirectional/v1":
        return errors

    raw_log = data.get("raw_log")
    if not raw_log or not (base / raw_log).is_file():
        errors.append(f"missing raw_log: {raw_log}")

    env = data.get("environment")
    if isinstance(env, dict):
        captures = env.get("captures")
        cap_dir = base / captures if captures else None
        if not cap_dir or not cap_dir.is_dir() or not any(cap_dir.iterdir()):
            errors.append(f"missing environment.captures dir: {captures}")

    directions = data.get("directions") or {}
    for direction in ("tx", "rx"):
        arm = directions.get(direction) or {}
        snaps = arm.get("snapshots") or {}
        for key in ("before", "after"):
            rel = snaps.get(key)
            if not rel or not (base / rel).is_dir():
                errors.append(f"missing directions.{direction}.snapshots.{key}: {rel}")
        iperf_rel = snaps.get("iperf3")
        if not iperf_rel or not (base / iperf_rel).is_file():
            errors.append(f"missing directions.{direction}.snapshots.iperf3: {iperf_rel}")
    return errors


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(shutil.which("iperf3"), "iperf3 is not installed")
@unittest.skipUnless(SCRIPT.exists(), "bench-10g-unidirectional.sh is missing")
class BaselineRecordTest(unittest.TestCase):
    """One real --baseline run on loopback: the cheapest link this box has."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="bench-baseline.")
        cls.port = free_port()
        cls.result_dir = Path(cls.tmp) / "lan4-1g-2026-11-20"
        cls.server = subprocess.Popen(
            # No -1: the harness runs two client sessions, and a
            # single-shot server would be gone before the second one.
            ["iperf3", "-s", "-p", str(cls.port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", cls.port), 0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            cls.server.kill()
            raise AssertionError("iperf3 server never listened")

        env = dict(os.environ, TARGET="127.0.0.1", IFACE="lo",
                   PORT=str(cls.port), DURATION="1", PARALLEL="1")
        cls.bench = subprocess.run(
            [str(SCRIPT), "--baseline", "--label", cls.result_dir.name,
             "--result-dir", str(cls.result_dir)],
            capture_output=True, text=True, env=env, timeout=120,
        )
        cls.server.terminate()
        try:
            cls.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.server.kill()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def result(self):
        with open(self.result_dir / "result.json", encoding="utf-8") as fh:
            return json.load(fh)

    def test_run_succeeded(self):
        self.assertEqual(self.bench.returncode, 0, self.bench.stderr[-2000:])
        self.assertTrue((self.result_dir / "result.json").is_file())

    def test_result_json_has_the_four_sections(self):
        d = self.result()
        # (1) environment: the link snapshot --baseline exists to add.
        self.assertIn("environment", d)
        env = d["environment"]
        self.assertIsNotNone(env, "--baseline must fill environment, not null")
        for key in ("link_speed_mbps", "duplex", "driver",
                    "flowtable_hw_offload", "captures"):
            self.assertIn(key, env, f"environment lacks {key}")
        self.assertEqual(env["captures"], "snapshots/env")
        for capture in sorted(os.listdir(self.result_dir / "snapshots/env")):
            self.assertTrue(capture, capture)

        # (2)(3) the raw iperf3 JSON of both directions.
        for direction in ("tx", "rx"):
            arm = d["directions"][direction]
            self.assertIn("iperf3", arm, f"directions.{direction} lacks iperf3")
            for key in ("command", "bits_per_second", "gbps", "bytes",
                        "seconds", "throughput_source"):
                self.assertIn(key, arm["iperf3"],
                              f"directions.{direction}.iperf3 lacks {key}")
            self.assertTrue((self.result_dir / f"iperf3-{direction}.json").is_file())

        # (4) PPE binding: present in both directions, and its absence on
        # this box is recorded, not guessed.
        for direction in ("tx", "rx"):
            ppe = d["directions"][direction]["ppe"]
            for key in ("available", "usage_path", "before", "after",
                        "bound_delta", "l2b_bound_delta", "l2_flows_sw_delta"):
                self.assertIn(key, ppe, f"directions.{direction}.ppe lacks {key}")
            if not ppe["available"]:
                for key in ("before", "after", "bound_delta"):
                    self.assertIsNone(ppe[key], key)

    def test_no_other_record_file_is_written(self):
        written = sorted(p.name for p in self.result_dir.iterdir())
        self.assertEqual(
            written,
            ["iperf3-rx.json", "iperf3-tx.json", "raw.log", "result.json",
             "snapshots"],
            "the run wrote something besides the captures and result.json",
        )

    def test_pasted_claims_entry_points_at_result_json(self):
        out = self.bench.stdout
        self.assertIn("scripts/perf-baselines/%s/result.json:1"
                      % self.result_dir.name, out)
        self.assertNotIn(".md", out)
        self.assertIn("no summary document is written", out)

    def test_fresh_baseline_artifacts_are_complete(self):
        self.assertEqual(
            check_baseline_artifacts(self.result_dir / "result.json"), [],
            "fresh --baseline run produced broken artifact pointers",
        )


class BaselineArtifactIntegrityTest(unittest.TestCase):
    """F7: every non-legacy baseline under scripts/perf-baselines/ resolves cleanly."""

    def test_committed_baselines_have_complete_pointers_or_legacy_flag(self):
        results = sorted(PERF_BASELINES.glob("*/result.json"))
        self.assertTrue(results, f"no baseline result.json under {PERF_BASELINES}")
        for result_json in results:
            data = json.loads(result_json.read_text(encoding="utf-8"))
            if data.get("schema") != "bench-10g-unidirectional/v1":
                continue
            missing = check_baseline_artifacts(result_json)
            if data.get("legacy_incomplete"):
                # Historical incomplete record must still carry its core evidence
                # files and must actually have omitted snapshot pointers.
                self.assertTrue(
                    missing,
                    f"{result_json} is marked legacy_incomplete but has no missing pointers",
                )
                for core in ("raw.log", "iperf3-tx.json", "iperf3-rx.json"):
                    self.assertTrue(
                        (result_json.parent / core).is_file(),
                        f"legacy baseline {result_json} is missing {core}",
                    )
            else:
                self.assertEqual(
                    missing, [],
                    f"{result_json} has broken artifact pointers: {missing}",
                )

    def test_missing_snapshots_are_caught_on_non_legacy_baseline(self):
        tmp = Path(tempfile.mkdtemp(prefix="bench-f7."))
        self.addCleanup(shutil.rmtree, tmp, True)
        run_dir = tmp / "sample"
        run_dir.mkdir()
        (run_dir / "raw.log").write_text("ok\n", encoding="utf-8")
        (run_dir / "iperf3-tx.json").write_text("{}\n", encoding="utf-8")
        (run_dir / "iperf3-rx.json").write_text("{}\n", encoding="utf-8")
        record = {
            "schema": "bench-10g-unidirectional/v1",
            "raw_log": "raw.log",
            "environment": {"captures": "snapshots/env"},
            "directions": {
                "tx": {"snapshots": {"before": "snapshots/tx-before", "after": "snapshots/tx-after", "iperf3": "iperf3-tx.json"}},
                "rx": {"snapshots": {"before": "snapshots/rx-before", "after": "snapshots/rx-after", "iperf3": "iperf3-rx.json"}},
            },
        }
        result_json = run_dir / "result.json"
        result_json.write_text(json.dumps(record), encoding="utf-8")
        missing = check_baseline_artifacts(result_json)
        self.assertTrue(any("snapshots/env" in e for e in missing), missing)
        self.assertTrue(any("snapshots/tx-before" in e for e in missing), missing)


class ScriptSourceTest(unittest.TestCase):
    """Static guard: the source must not steer anyone to a prose record."""

    def setUp(self):
        self.source = SCRIPT.read_text(encoding="utf-8")

    def test_no_markdown_record_anywhere(self):
        # This is the assertion that failed before the fix: the script
        # printed "Commit this file as scripts/perf-baselines/<label>.md".
        self.assertIsNone(
            MD_HINT.search(self.source),
            "the script still mentions a .md file; the record is result.json",
        )

    def test_no_commit_the_file_wording(self):
        for banned in ("before citing it", "Commit this file",
                       "write baseline.md", "paste-ready record file"):
            self.assertNotIn(banned, self.source, banned)

    def test_baseline_still_records_environment(self):
        self.assertIn('"environment"', self.source)
        self.assertIn("snapshots/env", self.source)


class ClaimsTest(unittest.TestCase):
    """The validator and the two claims this issue touches."""

    def test_validator_passes(self):
        run = subprocess.run(["python3", str(CHECK_CLAIMS)],
                             capture_output=True, text=True, cwd=REPO)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("OK:", run.stdout)

    def _claim(self, ident):
        text = CLAIMS.read_text(encoding="utf-8")
        block = re.search(r"^  - id: %s\n(.*?)(?=^  - id: )" % re.escape(ident),
                          text, re.S | re.M)
        self.assertIsNotNone(block, f"{ident} is not in claims.yaml")
        return block.group(1)

    def test_stock_gap_stays_a_conditional(self):
        block = self._claim("stock-bridge-gap")
        self.assertIn("evidence: 推断", block)
        self.assertIn("status: unverified", block)
        # The claim is a condition with both directions named, not a ratio.
        self.assertIn("双向", block)
        self.assertIn("result.json", block)
        self.assertIn("本机无法取得", block)
        # The quoted 9.4/3.2 Gbit/s are labelled as second-hand targets; the
        # claim must not state them as a result.
        self.assertIn("不主张任何比值", block)
        self.assertIn("现场口述/转引", block)

    def test_1g_baseline_is_supported_and_points_at_result_json(self):
        block = self._claim("baseline-lan4-1g-2026-11-20")
        self.assertIn("evidence: 实测", block)
        self.assertIn("status: supported", block)
        self.assertIn(
            "scripts/perf-baselines/lan4-1g-2026-11-20/result.json:1", block)


if __name__ == "__main__":
    unittest.main()
