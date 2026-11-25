#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The #385 no-hardware contract: cause vocabulary, record fields, report v2.

Issue #385 found that the wireless harnesses conflated three different
outcomes in one exit status (0 = measured, 0 = clean skip, 3 = partial) and
that hw-gap-report.sh silently dropped every record whose "status" was not
exactly "no-client" or "blocked".  The fix keeps the v1 record readable and
adds a cause vocabulary on top of it:

  cause                 legacy status  outcome     exit
  missing-hardware      no-client      not-measured  3
  missing-tool          no-client      not-measured  2
  config-block          blocked        not-measured  2
  permission            blocked        not-measured  2
  environment           blocked        not-measured  2
  output-collision      blocked        not-measured  2
  precondition-mismatch blocked        not-measured  4
  internal              failed         measured      1
  interrupted           interrupted    not-measured  130 (129/143 by signal)

The report now scans <out>/no-hardware/{result.json,precondition.json,
arms/<arm>.json} plus the legacy <out>/no-client/result.json and any
<out>/result.json that really is a no-client record, counts what it dropped,
and only turns contract violations into exit 1 under --strict.

Red half: this file is written before lib/no-client.sh and
scripts/wireless/hw-gap-report.sh learn the vocabulary, so every case below
fails on that tree for the expected reason (the old report also prints no
"scanned:" line and no Cause column at all).

Run from the repository root:

    python3 scripts/tests/test_no_hardware_contract.py
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB = Path(
    os.environ.get("NO_CLIENT_LIB_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/lib/no-client.sh"
)
REPORT = Path(
    os.environ.get("HW_GAP_REPORT_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/hw-gap-report.sh"
)
SH = shutil.which("sh") or "/bin/sh"

CAUSES = {
    "missing-hardware": ("no-client", "not-measured", 3),
    "missing-tool": ("no-client", "not-measured", 2),
    "config-block": ("blocked", "not-measured", 2),
    "permission": ("blocked", "not-measured", 2),
    "environment": ("blocked", "not-measured", 2),
    "output-collision": ("blocked", "not-measured", 2),
    "precondition-mismatch": ("blocked", "not-measured", 4),
    "internal": ("failed", "measured", 1),
    "interrupted": ("interrupted", "not-measured", 130),
}


def run_lib(body, extra_args=(), env=None):
    """Source the library in a fresh shell and run BODY with it."""
    merged = os.environ.copy()
    merged.update(env or {})
    return subprocess.run(
        [SH, "-c", '. "$1"; shift; ' + body, "lib", str(LIB), *map(str, extra_args)],
        capture_output=True,
        text=True,
        timeout=60,
        env=merged,
        check=False,
    )


def record_via_lib(directory, cause=None, status=None, extra_env=None, args=("48",)):
    env = dict(extra_env or {})
    if cause is not None:
        env["NC_RECORD_CAUSE"] = cause
    if status is not None:
        env["NC_RECORD_STATUS"] = status
    proc = run_lib(
        'no_client_record "$@"',
        extra_args=(directory, *args, "6ghz-eht-client", "run-cmd", "reason",
                    "criteria one", "criteria two"),
        env=env,
    )
    return proc


def write_json(path, status=None, **fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"schema": "wireless-no-client/v1"}
    if status is not None:
        record["status"] = status
    record.update(fields)
    path.write_text(json.dumps(record), encoding="utf-8")


def run_report(*args, env=None):
    merged = os.environ.copy()
    merged.update(env or {})
    return subprocess.run(
        [SH, str(REPORT), *map(str, args)],
        capture_output=True,
        text=True,
        timeout=60,
        env=merged,
        cwd=str(REPO_ROOT),
        check=False,
    )


def table_rows(markdown):
    rows = []
    for line in markdown.splitlines():
        if line.startswith("| `"):
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows


def scan_line(markdown, key):
    for line in markdown.splitlines():
        if line.startswith(key + ":"):
            return line
    return ""


class CauseVocabularyTest(unittest.TestCase):
    """The table is the contract: status, outcome and exit for every cause."""

    def test_every_cause_maps_to_its_documented_row(self):
        for cause, (status, outcome, rc) in CAUSES.items():
            with self.subTest(cause=cause):
                body = (
                    'printf "status=%s\\noutcome=%s\\nexit=%s\\n" '
                    '"$(nc_cause_status ' + cause + ')" '
                    '"$(nc_cause_outcome ' + cause + ')" '
                    '"$(nc_cause_exit ' + cause + ')"'
                )
                proc = run_lib(body)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(
                    proc.stdout.splitlines(),
                    ["status=%s" % status, "outcome=%s" % outcome, "exit=%s" % rc],
                )

    def test_unknown_and_empty_cause_fail_loudly_with_exit_1(self):
        for cause in ("bogus", ""):
            with self.subTest(cause=cause):
                proc = run_lib(
                    'rc=$(nc_cause_exit %s) || true; printf "rc=%%s\\n" "$rc"; '
                    'exit 0' % ("'%s'" % cause if cause else "''")
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn("rc=1", proc.stdout)
                self.assertIn("unknown cause", proc.stderr)
                self.assertIn(cause or "empty", proc.stderr)


class RecordFieldTest(unittest.TestCase):
    """Records stay v1-readable and gain the cause fields only when asked."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="no-hw-record."))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def read(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        path = Path(proc.stdout.strip().splitlines()[-1])
        self.assertTrue(path.is_file(), proc.stdout + proc.stderr)
        return json.loads(path.read_text(encoding="utf-8")), path

    def test_cause_record_keeps_v1_fields_and_adds_the_contract(self):
        data, path = self.read(record_via_lib(self.tmp / "out", cause="missing-tool"))
        self.assertEqual(path.name, "result.json")
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["contract"], "v2")
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["cause"], "missing-tool")
        self.assertEqual(data["outcome"], "not-measured")
        self.assertEqual(data["exit"], 2)
        self.assertEqual(data["ticket"], "48")
        self.assertEqual(data["missing"], "6ghz-eht-client")
        self.assertEqual(data["criteria"], ["criteria one", "criteria two"])
        self.assertTrue(data["timestamp"])

    def test_blocked_cause_derives_the_legacy_status(self):
        data, _ = self.read(record_via_lib(self.tmp / "out", cause="config-block"))
        self.assertEqual(data["status"], "blocked")
        self.assertEqual(data["cause"], "config-block")
        self.assertEqual(data["exit"], 2)

    def test_explicit_status_override_wins_over_the_cause(self):
        data, _ = self.read(
            record_via_lib(
                self.tmp / "out", cause="config-block", status="no-client"
            )
        )
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["cause"], "config-block")

    def test_legacy_call_without_a_cause_stays_v1(self):
        data, _ = self.read(record_via_lib(self.tmp / "out"))
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["status"], "no-client")
        self.assertNotIn("cause", data)
        self.assertNotIn("contract", data)

    def test_legacy_blocked_call_still_records_blocked(self):
        data, _ = self.read(record_via_lib(self.tmp / "out", status="blocked"))
        self.assertEqual(data["status"], "blocked")
        self.assertNotIn("cause", data)

    def test_no_hardware_dir_is_the_v2_location(self):
        proc = run_lib('no_hardware_dir "$1"', extra_args=(self.tmp / "out",))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(self.tmp / "out" / "no-hardware"))


class ReportV2Test(unittest.TestCase):
    """One fixture tree: v2 locations, a legacy record and a real measurement."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="no-hw-report."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.scan = self.tmp / "scan"

    def make_fixture(self):
        write_json(
            self.scan / "no-hardware/result.json",
            script="6g-rx.sh", ticket="48", missing="6ghz-eht-client",
            command="sh scripts/wireless/6g-rx.sh --sta-ip <STA_IP>",
            reason="no station on a 6 GHz BSS",
            criteria=["station rx bytes"],
            cause="missing-hardware", outcome="not-measured", exit=3,
            contract="v2", timestamp="2026-11-25T00:00:01Z",
        )
        write_json(
            self.scan / "no-hardware/precondition.json",
            script="edca-6g-ab.sh", ticket="43", missing="iperf3",
            command="install iperf3",
            reason="iperf3 not installed",
            cause="missing-tool", outcome="not-measured", exit=2,
            contract="v2", timestamp="2026-11-25T00:00:02Z",
        )
        write_json(
            self.scan / "no-hardware/arms/a.json",
            script="6g320-matrix.sh", ticket="47", missing="6ghz-owe-mismatch",
            command="uci set wireless.wifi7.encryption=owe",
            reason="live OWE vs open UCI profile",
            cause="config-block", outcome="not-measured", exit=2,
            contract="v2", arm="a", timestamp="2026-11-25T00:00:03Z",
        )
        write_json(
            self.scan / "no-hardware/arms/b.json",
            script="2.5g-wired.sh", ticket="70", missing="ssh",
            command="ssh -o BatchMode=yes root@<DEVICE> true",
            reason="device did not answer",
            cause="environment", outcome="not-measured", exit=2,
            contract="v2", arm="b", timestamp="2026-11-25T00:00:04Z",
        )
        # The legacy location stays readable and its cause is derived from the
        # v1 status + key so an old tree keeps reporting the same rows.
        write_json(
            self.scan / "no-client/result.json",
            status="no-client", script="b-path-25g.sh", ticket="70", missing="2.5g-peer",
            command="sh scripts/wireless/b-path-25g.sh --device <DEVICE>",
            reason="no 2.5G feeder", timestamp="2026-11-25T00:00:05Z",
        )
        # Real measurement results across all supported schemas: counted as
        # measured with zero warnings under --strict.
        write_json(
            self.scan / "runs/x/result.json",
            schema="6g-rx/v1", status="ok", script="6g-rx.sh",
        )
        write_json(
            self.scan / "runs/y/result.json",
            schema="edca-6g-ab/v1", ok=True,
        )
        write_json(
            self.scan / "runs/z/result.json",
            schema="bench-10g-unidirectional/v1", status="ok",
        )

    def test_counts_and_table_cover_every_location(self):
        self.make_fixture()
        proc = run_report(self.scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("5 no-client record(s), 5 missing hardware item(s), "
                      "4 ticket(s) covered.", proc.stdout, proc.stdout)
        self.assertEqual(
            scan_line(proc.stdout, "scanned"),
            "scanned: 8 files, 5 records, 3 measured, 0 invalid, 0 ignored, "
            "0 duplicate",
        )
        self.assertEqual(
            scan_line(proc.stdout, "not measured"),
            "not measured: 5 (missing-hardware 2, config-block 1, "
            "environment 1, missing-tool 1)",
        )
        self.assertIn("| Missing hardware | Tickets | Harnesses | "
                      "Command once acquired | Class | Cause |", proc.stdout)
        rows = table_rows(proc.stdout)
        self.assertEqual(len(rows), 5, proc.stdout)
        by_missing = {r[0].strip("`"): r for r in rows}
        self.assertEqual(by_missing["6ghz-eht-client"][4], "hardware")
        self.assertEqual(by_missing["6ghz-eht-client"][5], "missing-hardware")
        self.assertEqual(by_missing["iperf3"][5], "missing-tool")
        self.assertEqual(by_missing["6ghz-owe-mismatch"][4], "configuration")
        self.assertEqual(by_missing["ssh"][4], "environment")
        self.assertEqual(by_missing["ssh"][5], "environment")
        self.assertEqual(by_missing["2.5g-peer"][5], "missing-hardware")
        # Every accepted record is still listed with its path in the details.
        for name in ("result.json", "precondition.json", "arms/a.json",
                     "arms/b.json"):
            self.assertIn(name, proc.stdout)

    def test_json_output_states_the_schema_and_the_stats(self):
        self.make_fixture()
        proc = run_report("--json", self.scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["schema"], "hw-gap-report/v2")
        self.assertEqual(
            data["stats"],
            {"scanned": 8, "records": 5, "measured": 3, "invalid": 0,
             "ignored": 0, "duplicate": 0},
        )
        self.assertEqual(len(data["groups"]), 5)
        groups = {g["missing"]: g for g in data["groups"]}
        self.assertEqual(groups["ssh"]["causes"], ["environment"])
        self.assertEqual(groups["iperf3"]["causes"], ["missing-tool"])
        legacy = [r for r in data["records"] if r["missing"] == "2.5g-peer"]
        self.assertEqual(len(legacy), 1)
        self.assertEqual(legacy[0]["cause"], "missing-hardware")
        self.assertEqual(legacy[0]["cause_source"], "derived")

    def test_strict_is_clean_on_a_consistent_tree(self):
        self.make_fixture()
        proc = run_report("--strict", self.scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr, "")

    def test_strict_flags_contract_violations_but_default_does_not(self):
        write_json(
            self.scan / "no-hardware/result.json",
            script="6g-rx.sh", ticket="48", missing="6ghz-eht-client",
            command="run", reason="no station",
            cause="config-block", outcome="not-measured", exit=3,
            contract="v2", timestamp="2026-11-25T00:00:01Z",
        )
        write_json(
            self.scan / "no-hardware/arms/x.json",
            script="edca-6g-ab.sh", ticket="43", missing="iperf3",
            command="run", reason="no tool",
            cause="zenon", timestamp="2026-11-25T00:00:02Z",
        )
        # A v2 location without a cause is a contract violation, not a legacy
        # record: those live under no-client/ or a top-level result.json.
        write_json(
            self.scan / "no-hardware/precondition.json",
            script="thermal-soak.sh", ticket="53",
            missing="second-associated-wifi-client",
            command="run", reason="only one client",
            timestamp="2026-11-25T00:00:03Z",
        )
        default = run_report(self.scan)
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertIn("warning", default.stderr)
        self.assertIn("config-block", default.stderr)
        strict = run_report("--strict", self.scan)
        self.assertEqual(strict.returncode, 1, strict.stdout + strict.stderr)
        self.assertIn("exit", strict.stderr)
        self.assertIn("unknown cause", strict.stderr)
        self.assertIn("missing cause", strict.stderr)

    def test_one_record_in_two_directories_is_a_duplicate(self):
        write_json(
            self.scan / "no-client/result.json",
            status="no-client", script="6g-rx.sh", ticket="48",
            missing="6ghz-eht-client", command="run", reason="no station",
            timestamp="2026-11-25T00:00:01Z",
        )
        shutil.copytree(
            self.scan / "no-client", self.scan / "copies/no-client"
        )
        proc = run_report(self.scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            scan_line(proc.stdout, "scanned"),
            "scanned: 2 files, 1 records, 0 measured, 0 invalid, 0 ignored, "
            "1 duplicate",
        )

    def test_unreadable_json_is_invalid_only_under_strict(self):
        (self.scan / "no-hardware").mkdir(parents=True)
        (self.scan / "no-hardware/result.json").write_text("{broken", encoding="utf-8")
        default = run_report(self.scan)
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertIn("invalid", default.stderr)
        strict = run_report("--strict", self.scan)
        self.assertEqual(strict.returncode, 1, strict.stdout + strict.stderr)

    def test_empty_scan_still_returns_zero(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        proc = run_report(empty)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('No "no-client" record found', proc.stdout)

    def test_unknown_option_is_a_usage_error(self):
        proc = run_report("--bogus", self.scan)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)

    def test_unrelated_arms_json_is_ignored_under_strict(self):
        self.make_fixture()
        unrelated = self.scan / "other/arms/a.json"
        unrelated.parent.mkdir(parents=True, exist_ok=True)
        unrelated.write_text(json.dumps({"arm": 0, "gbps": 3.1}), encoding="utf-8")
        proc = run_report("--strict", self.scan)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(proc.stderr, "")
        self.assertEqual(
            scan_line(proc.stdout, "scanned"),
            "scanned: 8 files, 5 records, 3 measured, 0 invalid, 0 ignored, "
            "0 duplicate",
        )

    def test_multiple_causes_for_one_missing_key_keep_six_markdown_columns(self):
        write_json(
            self.scan / "run1/no-hardware/result.json",
            script="2.5g-wired.sh", ticket="70", missing="2.5g-peer",
            status="blocked", cause="config-block", outcome="not-measured",
            exit=2, contract="v2", command="run1", reason="no port",
            timestamp="2026-11-25T00:00:01Z",
        )
        write_json(
            self.scan / "run2/no-hardware/result.json",
            script="b-path-25g.sh", ticket="70", missing="2.5g-peer",
            status="no-client", cause="missing-hardware", outcome="not-measured",
            exit=3, contract="v2", command="run2", reason="no feeder",
            timestamp="2026-11-25T00:00:02Z",
        )
        proc = run_report("--strict", self.scan)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        rows = table_rows(proc.stdout)
        self.assertEqual(len(rows), 1, proc.stdout)
        self.assertEqual(len(rows[0]), 6, rows[0])
        self.assertEqual(rows[0][5], "config-block, missing-hardware")

    def test_interrupted_accepts_signal_exit_codes_under_strict(self):
        for idx, code in enumerate((129, 130, 143), 1):
            write_json(
                self.scan / ("s%d/no-hardware/result.json" % idx),
                script="edca-6g-ab.sh", ticket="43", missing="6ghz-eht-client",
                status="interrupted", cause="interrupted",
                outcome="not-measured", exit=code, contract="v2",
                command="run", reason="signal %d" % code,
                timestamp="2026-11-25T00:00:0%dZ" % idx,
            )
        proc = run_report("--strict", self.scan)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(proc.stderr, "")
        # A non-signal exit code for interrupted must still fail --strict.
        write_json(
            self.scan / "bad/no-hardware/result.json",
            script="edca-6g-ab.sh", ticket="43", missing="6ghz-eht-client",
            status="interrupted", cause="interrupted",
            outcome="not-measured", exit=2, contract="v2",
            command="run", reason="bad code",
            timestamp="2026-11-25T00:00:09Z",
        )
        bad = run_report("--strict", self.scan)
        self.assertEqual(bad.returncode, 1, bad.stdout + bad.stderr)
        self.assertIn("exit 2 for cause interrupted", bad.stderr)

    def test_strict_flags_missing_and_unknown_schema_in_v2_records(self):
        missing_schema = self.scan / "no-hardware/result.json"
        missing_schema.parent.mkdir(parents=True, exist_ok=True)
        missing_schema.write_text(json.dumps({
            "script": "6g-rx.sh", "ticket": "48", "missing": "6ghz-eht-client",
            "status": "no-client", "cause": "missing-hardware",
            "outcome": "not-measured", "exit": 3, "contract": "v2",
            "command": "run", "reason": "no station",
            "timestamp": "2026-11-25T00:00:01Z",
        }), encoding="utf-8")
        bad_schema = self.scan / "no-hardware/arms/bad.json"
        bad_schema.parent.mkdir(parents=True, exist_ok=True)
        bad_schema.write_text(json.dumps({
            "schema": "bogus/v9",
            "script": "edca-6g-ab.sh", "ticket": "43", "missing": "iperf3",
            "status": "no-client", "cause": "missing-tool",
            "outcome": "not-measured", "exit": 2, "contract": "v2",
            "command": "run", "reason": "no tool",
            "timestamp": "2026-11-25T00:00:02Z",
        }), encoding="utf-8")
        default = run_report(self.scan)
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertIn("missing schema", default.stderr)
        self.assertIn("unknown schema", default.stderr)
        strict = run_report("--strict", self.scan)
        self.assertEqual(strict.returncode, 1, strict.stdout + strict.stderr)
        self.assertIn("missing schema", strict.stderr)
        self.assertIn("unknown schema", strict.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
