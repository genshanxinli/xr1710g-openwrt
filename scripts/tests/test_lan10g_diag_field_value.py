#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests for field_value() in xr1710g-lan10g-diag.

Run from the repository root with ``python3 -m unittest``.

ethtool wraps the advertised/link-partner mode lists over indented
continuation lines.  field_value() must join them; returning after the
first matching line truncates the report to ``10baseT/*``.
"""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (REPO_ROOT / "target/linux/airoha/an7581/base-files"
          / "usr/sbin/xr1710g-lan10g-diag")

ETHTOOL_OUTPUT = """\
Settings for lan4:
\tSupported ports: [ TP ]
\tSupported link modes:   10baseT/Half 10baseT/Full
\t                        100baseT/Half 100baseT/Full
\tAdvertised link modes:  10baseT/Half 10baseT/Full
\t                        100baseT/Half 100baseT/Full
\t                        1000baseT/Full
\t                        2500baseT/Full
\tAdvertised pause frame use: Symmetric
\tLink partner advertised link modes:  10baseT/Half 10baseT/Full
\t                                     100baseT/Half 100baseT/Full
\t                                     1000baseT/Full
\t                                     2500baseT/Full
\tSpeed: 1000Mb/s
\tDuplex: Full
\tLink detected: yes
"""


def extract_field_value():
    """Copy the field_value() function out of the diag script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index("field_value() {")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError("field_value() is not closed")


class FieldValueTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.function = extract_field_value()

    def field_value(self, key):
        script = f'{self.function}field_value "$1" "$2"\n'
        out = subprocess.run(
            ["sh", "-c", script, "sh", ETHTOOL_OUTPUT, key],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.rstrip("\n")

    def test_continuation_lines_are_joined(self):
        self.assertEqual(
            self.field_value("Advertised link modes"),
            "10baseT/Half 10baseT/Full 100baseT/Half 100baseT/Full "
            "1000baseT/Full 2500baseT/Full",
        )

    def test_partner_list_is_joined(self):
        self.assertEqual(
            self.field_value("Link partner advertised link modes"),
            "10baseT/Half 10baseT/Full 100baseT/Half 100baseT/Full "
            "1000baseT/Full 2500baseT/Full",
        )

    def test_single_line_keys_are_unchanged(self):
        self.assertEqual(self.field_value("Speed"), "1000Mb/s")
        self.assertEqual(self.field_value("Duplex"), "Full")
        self.assertEqual(self.field_value("Link detected"), "yes")

    def test_absent_key_yields_empty(self):
        self.assertEqual(self.field_value("FEC modes"), "")

    def test_busybox_awk_rejects_bare_slash_in_bracket(self):
        # BusyBox awk 1.38.0 (the device awk) ends a bracket expression at a
        # bare "/" and dies with
        #   awk: bad regex '^[A-Za-z][A-Za-z0-9 ()': Missing ']'
        # which fails the whole program and empties every field, including
        # the single-line ones.  gawk accepts the bare form, so running the
        # function on the host does not catch it; this is the textual guard.
        # POSIX class tokens are stripped first, because [[:alnum:]] carries
        # its own "[" and "]" and hides a bare "/" that follows it.
        # ponytail: no behavioural busybox run here, the device repro in PR
        # is the behavioural check.
        normalized = re.sub(r"\[:[a-z]+:\]", "", self.function)
        self.assertIsNone(
            re.search(r"\[[^\]]*(?<!\\)/[^\]]*\]", normalized),
            "unescaped '/' inside a bracket expression breaks BusyBox awk")

    def test_next_key_does_not_leak(self):
        # "Advertised pause frame use" follows the mode list; the mode
        # value must not swallow it.
        self.assertNotIn("pause", self.field_value("Advertised link modes"))


class EnableFlagTest(unittest.TestCase):
    """`--enable` must report its own failure instead of dying in a redirect."""

    def run_enable(self, marker):
        # The script hardcodes MARKER=/etc/...; rewrite it in a scratch copy
        # so the test never touches /etc.
        with tempfile.TemporaryDirectory() as td:
            copy = Path(td) / "diag.sh"
            copy.write_text(SCRIPT.read_text().replace(
                "MARKER=/etc/xr1710g-10g-lab.enable",
                f"MARKER={marker}", 1))
            copy.chmod(0o755)
            return subprocess.run(["sh", str(copy), "--enable"],
                                  capture_output=True, text=True)

    def test_enable_creates_marker(self):
        with tempfile.TemporaryDirectory() as td:
            marker = Path(td) / "lab.enable"
            out = self.run_enable(marker)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("enabled: created", out.stdout)
            self.assertTrue(marker.exists())

    def test_enable_into_unwritable_dir_reports_and_fails(self):
        # `: > $MARKER` is a special builtin: a failed redirect terminates the
        # shell outright, so without a subshell guard the script exits with
        # the shell's own diagnosis instead of its "cannot create" line.
        # Compare stderr exactly: the shell prefixes its message with the
        # shell name ("dash: 1: ...", "sh: line 0: ..."), the script does not.
        marker = "/nonexistent-dir/xr1710g-10g-lab.enable"
        out = self.run_enable(marker)
        self.assertEqual(out.returncode, 1, out.stderr)
        self.assertEqual(out.stderr.strip(), f"cannot create {marker}")


if __name__ == "__main__":
    unittest.main()
