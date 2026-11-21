#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/hw-gap-report.sh.

The report merges the wireless harnesses' "no-client" result.json records by
the hardware each one is missing, so a board without a 6 GHz client still
leaves a machine-readable "buy/borrow this next" list behind instead of a
scatter of SKIP lines.

Three things are guarded here, none of them needs a radio:

  * Grouping.  Four fixture result.json files (three no-client, one normal)
    and two distinct "missing" values must come out as exactly two table rows,
    with the tickets and the run-once-acquired command in each row.
  * The grouping is load-bearing.  A copy of the report with the "group by
    missing" key broken (grouping by record path instead) must no longer
    produce two rows: the same assertion fails on it.
  * The convention really landed.  At least five harness sources call the
    shared no_client_record helper and the helper writes
    status "no-client"; a report alone would prove nothing.

Run from the repository root:

    python3 scripts/tests/test_hw_gap_report.py
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
SCRIPT = REPO_ROOT / "scripts/wireless/hw-gap-report.sh"
LIB = REPO_ROOT / "scripts/wireless/lib/no-client.sh"
WIRELESS = REPO_ROOT / "scripts/wireless"
SH = shutil.which("sh") or "/bin/sh"


def write_record(directory: Path, **fields) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    record = {"schema": "wireless-no-client/v1", "status": "no-client"}
    record.update(fields)
    (directory / "result.json").write_text(json.dumps(record), encoding="utf-8")


def run_report(report: Path, scan_dir: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [SH, str(report), str(scan_dir)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )


def table_rows(markdown: str) -> list:
    """The data rows of the "| Missing hardware | ..." table."""
    rows = []
    for line in markdown.splitlines():
        if not line.startswith("| `"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        rows.append(cells)
    return rows


class HwGapReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hw-gap-report-test."))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_fixtures(self) -> Path:
        scan = self.tmp / "scan"
        write_record(
            scan / "six-g-rx",
            script="6g-rx.sh",
            ticket="48",
            missing="6ghz-eht-client",
            reason="no station on a 6 GHz BSS",
            command="sh scripts/wireless/6g-rx.sh --sta-ip <STA_IP>",
            criteria=["station rx bytes", "ethtool rx_ampdu_bytes_cnt delta"],
        )
        write_record(
            scan / "edca",
            script="edca-6g-ab.sh",
            ticket="43",
            missing="6ghz-eht-client",
            reason="no 6G STA",
            command="sh scripts/wireless/edca-6g-ab.sh --target <STA_IP>",
            criteria=["EDCA A/B throughput delta"],
        )
        write_record(
            scan / "matrix",
            script="6g320-matrix.sh",
            ticket="47",
            missing="6ghz-eht320-client",
            reason="no 320 MHz client",
            command="sh scripts/wireless/6g320-matrix.sh --iface <IFACE>",
            criteria=["320 MHz width and NSS"],
        )
        # A measured run: present, valid JSON, but not a no-client record.
        write_record(
            scan / "normal",
            script="6g-rx.sh",
            ticket="48",
            status="ok",
            missing="6ghz-eht-client",
            reason="",
            command="",
        )
        return scan

    def test_three_no_client_records_merge_into_two_missing_rows(self):
        scan = self.make_fixtures()
        proc = run_report(SCRIPT, scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = table_rows(proc.stdout)
        self.assertEqual(len(rows), 2, proc.stdout)
        self.assertEqual({r[0] for r in rows},
                         {"`6ghz-eht-client`", "`6ghz-eht320-client`"})
        by_missing = {r[0].strip("`"): r for r in rows}
        self.assertIn("#48", by_missing["6ghz-eht-client"][1])
        self.assertIn("#43", by_missing["6ghz-eht-client"][1])
        self.assertIn("#47", by_missing["6ghz-eht320-client"][1])
        for row in rows:
            self.assertNotEqual(row[3], "-", "command column must not be empty")
            self.assertIn("sh scripts/wireless/", row[3])
        # The ok record contributes nothing, not even a row of its own.
        self.assertNotIn("normal", proc.stdout.split("# Missing")[0])
        self.assertIn("3 no-client record(s)", proc.stdout)

    def test_broken_grouping_is_detected(self):
        """A copy that groups by record path instead of "missing" fails the
        same assertion the real report passes."""
        scan = self.make_fixtures()
        broken = self.tmp / "hw-gap-report-broken.sh"
        source = SCRIPT.read_text(encoding="utf-8")
        needle = 'by_missing.setdefault(record.get("missing") or "unknown", []).append(record)'
        self.assertIn(needle, source, "grouping line moved; update this test")
        broken.write_text(
            source.replace(needle,
                           'by_missing.setdefault(record["_path"], []).append(record)'),
            encoding="utf-8",
        )
        proc = run_report(broken, scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = table_rows(proc.stdout)
        self.assertEqual(len(rows), 3, "broken grouping must split the records")
        self.assertNotEqual({r[0] for r in rows},
                            {"`6ghz-eht-client`", "`6ghz-eht320-client`"})

    def test_harnesses_use_the_shared_no_client_convention(self):
        self.assertTrue(LIB.is_file(), LIB)
        lib_text = LIB.read_text(encoding="utf-8")
        self.assertIn('"status": "no-client"', lib_text)
        self.assertIn("no_client_record()", lib_text)
        callers = sorted(
            p.name for p in WIRELESS.glob("*.sh")
            if "no_client_record" in p.read_text(encoding="utf-8", errors="replace")
        )
        self.assertGreaterEqual(
            len(callers), 5,
            "fewer than five harnesses write the no-client record: %r" % callers)
        # The 6 GHz harnesses named in the ticket set must be among them.
        for name in ("6g-rx.sh", "6g-clear-air.sh", "6g320-matrix.sh", "edca-6g-ab.sh"):
            self.assertIn(name, callers)

    def test_empty_scan_prints_a_clean_report(self):
        scan = self.tmp / "empty"
        scan.mkdir()
        proc = run_report(SCRIPT, scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("# Wireless hardware gap report", proc.stdout)
        self.assertIn("No", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
