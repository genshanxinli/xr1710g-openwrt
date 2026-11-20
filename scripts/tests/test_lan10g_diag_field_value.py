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
        # ponytail: no behavioural busybox run here, the device repro in PR
        # is the behavioural check.
        self.assertIsNone(
            re.search(r"\[[^\]]*(?<!\\)/[^\]]*\]", self.function),
            "unescaped '/' inside a bracket expression breaks BusyBox awk")

    def test_next_key_does_not_leak(self):
        # "Advertised pause frame use" follows the mode list; the mode
        # value must not swallow it.
        self.assertNotIn("pause", self.field_value("Advertised link modes"))


if __name__ == "__main__":
    unittest.main()
