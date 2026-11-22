#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/hw-gap-report.sh.

The report merges the wireless harnesses' "no-client" result.json records by
the hardware each one is missing, so a board without a 6 GHz client still
leaves a machine-readable "buy/borrow this next" list behind instead of a
scatter of SKIP lines.

Four things are guarded here, none of them needs a radio:

  * Grouping.  Four fixture result.json files (three no-client, one normal)
    and two distinct "missing" values must come out as exactly two table rows,
    with the tickets and the run-once-acquired command in each row.
  * The grouping is load-bearing.  A copy of the report with the "group by
    missing" key broken (grouping by record path instead) must no longer
    produce two rows: the same assertion fails on it.
  * The convention really landed.  At least five harness sources call the
    shared no_client_record helper and the helper writes
    status "no-client"; a report alone would prove nothing.
  * The last five gaps land too.  The 2.5G pair (2.5g-wired.sh and
    b-path-25g.sh) shares one "2.5g-peer" key, so issue #70 is listed once,
    and the three client-gap harnesses keep one row each.

Run from the repository root:

    python3 scripts/tests/test_hw_gap_report.py
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# NO_HARD_ROOT points the source guards at a tree of pre-fix script copies,
# which is the red proof: the working tree is the tree that got fixed.
TREE = Path(os.environ.get("NO_HARD_ROOT") or REPO_ROOT)
SCRIPT = TREE / "scripts/wireless/hw-gap-report.sh"
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

    def test_last_five_hardware_gaps_merge_under_shared_keys(self):
        """The five harnesses that used to print a bare SKIP now leave records.

        Both 2.5G harnesses name the same missing hardware ("2.5g-peer"), so
        the two of them merge into one row and issue #70 is listed once, not
        twice.  The other three keep one row each.
        """
        scan = self.tmp / "scan-five"
        records = [
            ("2.5g-wired", "2.5g-wired.sh", "70", "2.5g-peer",
             "sh scripts/wireless/2.5g-wired.sh --device <USER@DEVICE_IP>"),
            ("b-path-25g", "b-path-25g.sh", "70", "2.5g-peer",
             "sh scripts/wireless/b-path-25g.sh --client <STA_IP>"),
            ("ab-80-160", "ab-80-160.sh", "43", "5ghz-eht-client",
             "sh scripts/wireless/ab-80-160.sh --client <STA_MAC>"),
            ("4ss-lab", "4ss-lab.sh", "4", "4ss-client",
             "sh scripts/wireless/4ss-lab.sh --run --client <STA_MAC>"),
            ("wifi7-supply-bench", "wifi7-supply-bench.sh", "4", "eht-client",
             "sh scripts/wifi7-supply-bench.sh --host-if <HOST_IF>"),
        ]
        for subdir, script, ticket, missing, command in records:
            write_record(
                scan / subdir,
                script=script,
                ticket=ticket,
                missing=missing,
                reason="no %s" % missing,
                command=command,
                criteria=["fixture criterion"],
            )

        proc = run_report(SCRIPT, scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = table_rows(proc.stdout)
        by_missing = {r[0].strip("`"): r for r in rows}
        # Five records, four rows: the 2.5G pair shares a key.
        self.assertEqual(len(rows), 4, proc.stdout)
        self.assertEqual(set(by_missing), {"2.5g-peer", "5ghz-eht-client",
                                           "4ss-client", "eht-client"})
        peer = by_missing["2.5g-peer"]
        self.assertIn("#70", peer[1])
        self.assertEqual(peer[1], "#70", "issue #70 must appear once")
        self.assertIn("2.5g-wired.sh", peer[2])
        self.assertIn("b-path-25g.sh", peer[2])
        self.assertEqual(peer[1].count("#70"), 1)
        self.assertIn("#43", by_missing["5ghz-eht-client"][1])
        self.assertIn("#4", by_missing["4ss-client"][1])
        self.assertIn("#4", by_missing["eht-client"][1])
        self.assertIn("5 no-client record(s)", proc.stdout)
        self.assertIn("4 missing hardware item(s)", proc.stdout)

        # The fixtures are only worth something if the harnesses really name
        # these keys; guard the five sources so the two cannot drift apart.
        for script, ticket, missing in (
            ("scripts/wireless/2.5g-wired.sh", "70", "2.5g-peer"),
            ("scripts/wireless/b-path-25g.sh", "70", "2.5g-peer"),
            ("scripts/wireless/ab-80-160.sh", "43", "5ghz-eht-client"),
            ("scripts/wireless/4ss-lab.sh", "4", "4ss-client"),
            ("scripts/wifi7-supply-bench.sh", "4", "eht-client"),
        ):
            text = (REPO_ROOT / script).read_text(encoding="utf-8")
            self.assertIn("no_client_record", text, script)
            self.assertIn("%s %s" % (ticket, missing), text,
                          "%s must record ticket %s / missing %s"
                          % (script, ticket, missing))


    def test_tool_gaps_join_the_table_as_hardware(self):
        """A missing tool is recorded as no-client, so it lands in the same
        "buy/borrow this" table as a missing client, not in the
        configuration-block section.  A status "blocked" record still does."""
        scan = self.tmp / "scan-tools"
        write_record(
            scan / "bench10g",
            script="bench-10g-unidirectional.sh",
            ticket="13",
            missing="iperf3",
            reason="iperf3 not found in PATH (install it on the host under test)",
            command="IFACE=<IFACE> TARGET=<PEER_IP> "
                    "scripts/bench-10g-unidirectional.sh --peer-connects",
            criteria=["both directions run"],
        )
        write_record(
            scan / "clearair",
            script="6g-clear-air.sh",
            ticket="68",
            missing="no-interferer",
            reason="NO_INTERFERER: station has no ARP entry",
            command="sh scripts/wireless/6g-clear-air.sh --interferer "
                    "<2.4GHZ_AP_IP> --target <6GHZ_STA_IP>",
            criteria=["loaded arm moves bytes on another band"],
        )
        write_record(
            scan / "bridged",
            script="2.5g-wired.sh",
            ticket="70",
            status="blocked",
            missing="port-in-bridge",
            reason="lan2 is in br-lan",
            command="ip link set <DEV_IF> nomaster",
            criteria=["the selected device port has no master"],
        )
        proc = run_report(SCRIPT, scan)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = {r[0].strip("`"): r for r in table_rows(proc.stdout)}
        self.assertEqual(set(rows), {"iperf3", "no-interferer", "port-in-bridge"},
                         proc.stdout)
        self.assertEqual(rows["iperf3"][4], "hardware", proc.stdout)
        self.assertEqual(rows["no-interferer"][4], "hardware", proc.stdout)
        self.assertEqual(rows["port-in-bridge"][4], "configuration", proc.stdout)
        self.assertIn("#13", rows["iperf3"][1])
        self.assertIn("#68", rows["no-interferer"][1])

    def test_the_tool_harnesses_record_instead_of_dying(self):
        """The eight harnesses that used to die on a missing tool keep a
        no_client_record call and no hard iperf3 die, so the table above can
        only get fuller over time."""
        cases = (
            "scripts/wireless/6g-clear-air.sh",
            "scripts/wireless/6g-rx.sh",
            "scripts/wireless/edca-6g-ab.sh",
            "scripts/wireless/2.5g-wired.sh",
            "scripts/wireless/b-path-25g.sh",
            "scripts/bench-10g-unidirectional.sh",
            "scripts/wireless/thermal-soak.sh",
        )
        # A die about iperf3 *missing* is the defect; a die about a run that
        # produced no throughput stays, because that one is a real failure.
        hard_die = re.compile(
            r'need_cmd "\$IPERF3"'
            r'|\|\| die "iperf3 (not found|not installed|is missing)'
            r'|dev_have iperf3 \|\| die'
        )
        for path in cases:
            text = (TREE / path).read_text(encoding="utf-8")
            self.assertIn("no_client_record", text, path)
            self.assertIsNone(hard_die.search(text),
                              "%s still dies on a missing iperf3" % path)
        clear_air = (TREE / "scripts/wireless/6g-clear-air.sh").read_text(
            encoding="utf-8")
        self.assertIn("68 no-interferer", clear_air)


if __name__ == "__main__":
    unittest.main(verbosity=2)
