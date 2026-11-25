#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard the issue #382 watchdog reset-cause diagnostic.

Issue #382: ``bootstatus`` is a structural zero because ``airoha_wdt_probe()``
never reads the NP-SCU PMC bitmap at 0x080 -- the only reset-cause evidence
that survives a reboot on this boot chain (ATF does not write it, U-Boot
neither reads nor clears it).  The issue #382 design review accepts a
read-only diagnostic first: log the raw PMC value, change neither
``bootstatus`` nor ``options``, and never touch the write-1-to-clear bits,
because the EN7581 bit semantics are not confirmed on AN7581 silicon yet.

The same review rejected the behavioural patch (9909) until the
cold-boot / clean-reboot / watchdog-bite matrix shows ``WDG_RST_R && !SYS_RST_R``.
An unconditional ``WDIOF_CARDRESET`` turns every clean reboot into a fake
watchdog reset, so no queued patch may advertise it yet; that is what the
last test below enforces.

Everything is read as text: no dtc, no kernel tree, no compiler.

    python3 scripts/tests/test_airoha_wdt_diag.py

Red half, two axes.  (a) Point ``AIROHA_WDT_PATCH_UNDER_TEST`` at a pre-fix
copy of ``9908`` that still returns ``-EPROBE_DEFER``: the
``never_defers`` test alone fails, which is the B1 guard.  (b) Point
``AIROHA_WDT_DTSI_UNDER_TEST`` at the pre-change dtsi (still ``reg =
<0x38>``, no phandle) and both ``AIROHA_WDT_PATCH_UNDER_TEST`` and
``AIROHA_WDT_PATCH_DIR_UNDER_TEST`` at a fixture directory holding the
rejected behavioural patch: no fixture file carries the ``9908`` mail
headers, so all nine fail.  Green half runs against the tree.
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PATCH_DIR = Path(
    os.environ.get("AIROHA_WDT_PATCH_DIR_UNDER_TEST")
    or REPO_ROOT / "target/linux/airoha/patches-7.4"
)
DTSI = Path(
    os.environ.get("AIROHA_WDT_DTSI_UNDER_TEST")
    or REPO_ROOT / "target/linux/airoha/dts/an7581.dtsi"
)
PATCH = Path(
    os.environ.get("AIROHA_WDT_PATCH_UNDER_TEST")
    or PATCH_DIR / "9908-watchdog-airoha-report-reset-cause.patch"
)

DRIVER = "drivers/watchdog/airoha_wdt.c"
BINDING = "Documentation/devicetree/bindings/watchdog/airoha,en7581-wdt.yaml"
HUNK_FILE_RE = re.compile(r"^\+\+\+ b/(\S+)", re.M)


def node_body(text, marker):
    """Return the brace-balanced body of the first node matching marker."""
    match = re.search(r"(?:^|\n)[ \t]*" + re.escape(marker) + r"\s*\{", text)
    if not match:
        raise AssertionError(f"node {marker!r} not found")
    start = text.index("{", match.start())
    depth = 0
    for pos in range(start, len(text)):
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:pos]
    raise AssertionError(f"node {marker!r} is not closed")


def added_lines(text):
    """Lines a patch adds, without the leading '+' and without file headers."""
    out = []
    for line in text.splitlines():
        if line.startswith("+++"):
            continue
        if line.startswith("+"):
            out.append(line[1:])
    return out


class WatchdogDiag(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dtsi = DTSI.read_text()
        cls.patch = PATCH.read_text()

    # --- DT -------------------------------------------------------------

    def test_dts_reg_covers_wdt_reload(self):
        # WDT_RELOAD is 0x38; a 0x38-sized reg stops one register short and
        # only the full-page ioremap keeps the driver alive.
        body = node_body(self.dtsi, "watchdog@1fbf0100")
        self.assertIn("reg = <0x0 0x1fbf0100 0x0 0x3c>;", body)

    def test_dts_links_scu(self):
        body = node_body(self.dtsi, "watchdog@1fbf0100")
        self.assertIn("airoha,scu = <&scuclk>;", body)

    # --- patch ----------------------------------------------------------

    def test_patch_mail_header(self):
        self.assertRegex(self.patch, r"(?m)^From: \S")
        self.assertRegex(self.patch, r"(?m)^Date: \S")
        self.assertRegex(self.patch, r"(?m)^Subject: \[PATCH\] \S")
        self.assertRegex(self.patch, r"(?m)^Signed-off-by: \S")

    def test_patch_touches_only_driver_and_binding(self):
        self.assertEqual(
            set(HUNK_FILE_RE.findall(self.patch)), {DRIVER, BINDING}
        )

    def test_patch_logs_raw_pmc(self):
        added = "\n".join(added_lines(self.patch))
        self.assertIn(
            'syscon_regmap_lookup_by_phandle(dev->of_node, "airoha,scu")', added
        )
        self.assertIn("AIROHA_SCU_PMC", added)
        self.assertIn("regmap_read(scu, AIROHA_SCU_PMC, &pmc)", added)
        self.assertIn('"SCU PMC=0x%08x WDG_RST_R=%u SYS_RST_R=%u\\n"', added)

    def test_patch_never_defers_on_missing_scu(self):
        # The phandle is optional and the read is diagnostic only, so a
        # missing or not-yet-probed SCU must never fail or defer probe:
        # -EPROBE_DEFER is just one more IS_ERR() value on the same
        # dev_info() degrade path as -ENODEV or -ENOENT.
        added = "\n".join(added_lines(self.patch))
        self.assertIn("no SCU reset-cause regmap", added)
        self.assertNotIn("return -EPROBE_DEFER;", added)

    def test_patch_syncs_binding(self):
        added = "\n".join(added_lines(self.patch))
        self.assertIn("airoha,scu:", added)
        self.assertIn("$ref: /schemas/types.yaml#/definitions/phandle", added)
        self.assertIn("airoha,scu = <&scuclk>;", added)

    def test_patch_is_diagnostic_only(self):
        # The whole point of the first patch: no behaviour, no capability
        # claim and no destructive W1C before the bit semantics are proven.
        added = "\n".join(added_lines(self.patch))
        for forbidden in (
            "WDIOF_CARDRESET",
            "bootstatus",
            "options |=",
            "regmap_write",
        ):
            self.assertNotIn(forbidden, added)

    def test_no_queued_patch_advertises_cardreset_early(self):
        offenders = []
        for candidate in sorted(PATCH_DIR.glob("*.patch")):
            text = candidate.read_text(errors="replace")
            if f"--- a/{DRIVER}" not in text:
                continue
            if "WDIOF_CARDRESET" in "\n".join(added_lines(text)):
                offenders.append(candidate.name)
        self.assertEqual(offenders, [], "CARDRESET advertised before the experiment")


if __name__ == "__main__":
    unittest.main()
