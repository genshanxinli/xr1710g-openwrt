#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for the JSON escaping in scripts/wifi-reg-report.sh.

The report script runs on the router, so its awk is BusyBox v1.38.0 awk.
Measured on the device (r38121):

    $ printf 'X\tY\n' | awk '{ gsub(/\t/, "\\t"); printf "%s", $0 }' | wc -c
    3                      # "XtY": the replacement escape ate the backslash
    $ printf 'X\tY\n' | awk '{ gsub(/\t/, "\\\\t"); printf "%s", $0 }' | wc -c
    4                      # "X\tY": doubled for BusyBox

gawk/mawk do the opposite: the first form is correct and the second emits two
backslashes.  There is no single gsub() replacement that is right on both, so
the script builds the escape with literal concatenation instead; that is
parsed identically by every awk.  The first test guards the construct (it
fails on the old gsub implementation on any host), the second checks the
escaped bytes on the host awk, and the third runs the shipped --dry-run
fixture end to end.

Run from the repository root:

    python3 -m unittest scripts/tests/test_wifi_reg_report.py
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("WIFI_REG_REPORT_UNDER_TEST")
    or REPO_ROOT / "scripts/wifi-reg-report.sh"
).resolve()

FUNCTION = re.compile(
    r"^json_escape\(\) \{\n.*?^\}\n", re.MULTILINE | re.DOTALL)


def json_escape_body():
    match = FUNCTION.search(SCRIPT.read_text())
    if not match:
        raise AssertionError("json_escape() not found in %s" % SCRIPT)
    return match.group(0)


class JsonEscapeTest(unittest.TestCase):
    def setUp(self):
        self.awk = shutil.which("awk")
        if not self.awk:
            self.skipTest("no awk on this host")

    def test_escape_does_not_use_gsub_replacements(self):
        # gsub() replacement escapes diverge between BusyBox awk and
        # gawk/mawk (see the module docstring), so this function must not
        # depend on them.
        self.assertNotIn(
            "gsub", json_escape_body(),
            "json_escape() uses gsub(): its replacement escapes are eaten by "
            "BusyBox awk; build the escape with literal concatenation")

    def test_escape_bytes_match_json(self):
        payload = "line1\ttab\nback\\slash \"quote\"\r\nlast"
        harness = self._harness()
        result = subprocess.run(
            ["sh", str(harness), payload],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, json.dumps(payload)[1:-1])

    def test_dry_run_keeps_reg_tabs(self):
        result = subprocess.run(
            ["sh", str(SCRIPT), "--dry-run"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = json.loads(result.stdout)["reg"]["raw"]
        # The fixture (like `iw reg get`) indents every rule with a tab.
        self.assertIn("\n\t(902 - 904 @ 2)", raw)
        self.assertNotIn("\nt(902 - 904 @ 2)", raw,
                         "tab was flattened to 't'")

    def _harness(self):
        tmpdir = tempfile.TemporaryDirectory(prefix="wifi-reg-report.")
        self.addCleanup(tmpdir.cleanup)
        path = Path(tmpdir.name) / "escape.sh"
        path.write_text("#!/bin/sh\n%s\nprintf '%%s' \"$1\" | json_escape\n"
                        % json_escape_body())
        return path


if __name__ == "__main__":
    unittest.main()
