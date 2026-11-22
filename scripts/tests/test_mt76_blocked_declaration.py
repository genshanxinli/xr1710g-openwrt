#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""The mt76 blocked-symbol list has exactly one home; keep it live and cited.

The mt76-pin-drift row in scripts/claims.yaml does NOT copy
PKG_MIRROR_BLOCKED_BY: its ``source:`` entries are provenance pointers
(``file:line``), not symbols.  A set comparison between that list and the pin
file would compare a symbol list with a list of citations, so there is no
second copy to disagree with -- and nothing to cross-check.  What can rot is
the wiring around the single declaration in package/kernel/mt76/Makefile:

  * the list is emptied (``PKG_MIRROR_BLOCKED_BY:=``): check-mt76-pin.sh then
    prints no ``blocked.by`` row and still says keep, while the ledger still
    says supported -- the exact silent mismatch #9 is about;
  * scripts/check-mt76-pin.sh stops reading the key, so the declared list
    becomes documentation the tool ignores;
  * the ledger's verify hook drifts off the declaration line.

Red proof (point the test at a corrupt copy; every failure message names the
file it read):

    MT76_PIN_FILE=/tmp/pin MT76_PIN_CHECK_UNDER_TEST=/tmp/pin.sh \\
    CLAIMS_YAML_UNDER_TEST=/tmp/claims.yaml \\
        python3 -m unittest scripts/tests/test_mt76_blocked_declaration.py

Run from the repository root:

    python3 -m unittest scripts/tests/test_mt76_blocked_declaration.py
"""

import importlib.util
import os
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PIN_FILE = Path(os.environ.get("MT76_PIN_FILE", REPO_ROOT / "package/kernel/mt76/Makefile"))
PIN_SCRIPT = Path(
    os.environ.get("MT76_PIN_CHECK_UNDER_TEST", REPO_ROOT / "scripts" / "check-mt76-pin.sh")
)
LEDGER = Path(os.environ.get("CLAIMS_YAML_UNDER_TEST", REPO_ROOT / "scripts" / "claims.yaml"))

CLAIM_ID = "mt76-pin-drift"
PIN_REL = "package/kernel/mt76/Makefile"
KEY = "PKG_MIRROR_BLOCKED_BY:="


def _load_checker():
    """Reuse the ledger parser from check-claims.py (hyphen in the name)."""
    path = REPO_ROOT / "scripts" / "check-claims.py"
    spec = importlib.util.spec_from_file_location("check_claims", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _declaration():
    """Return (line number, value) of the PKG_MIRROR_BLOCKED_BY:= line."""
    for number, line in enumerate(PIN_FILE.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith(KEY):
            return number, line[len(KEY):].strip()
    return None, None


class Mt76BlockedDeclaration(unittest.TestCase):
    def test_pin_declares_a_non_empty_canonical_symbol_list(self):
        line_no, value = _declaration()
        self.assertIsNotNone(line_no, f"{PIN_FILE}: no {KEY} line")
        self.assertTrue(
            value,
            f"{PIN_FILE}:{line_no}: {KEY} is empty; check-mt76-pin.sh would "
            "print no blocked.by row while the ledger still says supported",
        )
        symbols = value.split(",")
        self.assertNotIn("", symbols, f"{PIN_FILE}:{line_no}: empty entry in {value!r}")
        self.assertEqual(
            len(symbols), len(set(symbols)),
            f"{PIN_FILE}:{line_no}: duplicate symbol in {value!r}",
        )
        self.assertNotIn(
            " ", value, f"{PIN_FILE}:{line_no}: whitespace in {value!r}"
        )

    def test_script_reads_that_key(self):
        reader = "s/^" + KEY + "//p"
        self.assertIn(
            reader,
            PIN_SCRIPT.read_text(encoding="utf-8"),
            f"{PIN_SCRIPT}: no sed reader for {KEY}; the declared list would be "
            "ignored instead of printed as blocked.by",
        )

    def test_claim_hook_is_anchored_on_the_declaration(self):
        line_no, _ = _declaration()
        self.assertIsNotNone(line_no, f"{PIN_FILE}: no {KEY} line")
        records = _load_checker().parse_ledger(LEDGER.read_text(encoding="utf-8"))
        record = next((r for r in records if r.get("id") == CLAIM_ID), None)
        self.assertIsNotNone(record, f"{LEDGER}: no claim {CLAIM_ID!r}")
        anchor = f"text: {PIN_REL}:{line_no} {KEY}"
        self.assertTrue(
            any(item.startswith(anchor) for item in record.get("verify") or []),
            f"{LEDGER}: {CLAIM_ID} has no {anchor!r} hook; the ledger would "
            "not re-read the line the script depends on",
        )

    def test_injection_points_at_the_files_that_are_read(self):
        """A red run must name the copy, not the checkout."""
        for var, path in (
            ("MT76_PIN_FILE", PIN_FILE),
            ("MT76_PIN_CHECK_UNDER_TEST", PIN_SCRIPT),
            ("CLAIMS_YAML_UNDER_TEST", LEDGER),
        ):
            if var in os.environ:
                self.assertTrue(
                    path.is_file(), f"{var}={path}: not a file; the copy did not load"
                )


if __name__ == "__main__":
    unittest.main()
