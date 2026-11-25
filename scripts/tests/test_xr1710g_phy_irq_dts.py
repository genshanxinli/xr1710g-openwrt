#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard the XR1710G internal PHY interrupts and the wan_mac nvmem reference.

Issue #376: the board DTS dropped the ``interrupts = <1>``/``<2>`` lines the
upstream Gemtek common DTSI already declared, so both internal PHYs register
with ``irq=POLL``.  The cell is the regmap-irq hwirq, i.e. the ``PHY_LC`` line
number == port index, not the MDIO address (9/10 land in the zero-mask hole
7..15).  ``<&wan_mac 0>`` is the other half: the provider has no
``#nvmem-cell-cells``, so the trailing argument is invalid and only worked
because the nvmem core ignores it for index 0.

The assertions are read from the dts text, so this runs without dtc or a
kernel tree:

    python3 scripts/tests/test_xr1710g_phy_irq_dts.py

XR1710G_DTS_UNDER_TEST points at another copy for the red proof.
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DTS = Path(
    os.environ.get("XR1710G_DTS_UNDER_TEST")
    or REPO_ROOT / "target/linux/airoha/dts/an7581-xr1710g-ubi.dts"
)


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


class Xr1710gPhyIrqDts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = DTS.read_text()

    def assert_irq_between_status_and_pinctrl(self, marker, line):
        body = node_body(self.text, marker)
        self.assertIn(line, body)
        self.assertLess(body.index('status = "okay";'), body.index(line))
        self.assertLess(body.index(line), body.index("pinctrl-names"))

    def test_gsw_phy1_interrupt_is_phy1_lc(self):
        self.assert_irq_between_status_and_pinctrl("&gsw_phy1", "interrupts = <1>;")

    def test_gsw_phy2_interrupt_is_phy2_lc(self):
        self.assert_irq_between_status_and_pinctrl("&gsw_phy2", "interrupts = <2>;")

    def test_gdm2_references_wan_mac_without_argument(self):
        body = node_body(self.text, "&gdm2")
        self.assertIn("nvmem-cells = <&wan_mac>;", body)
        self.assertNotIn("<&wan_mac 0>", body)

    def test_wan_mac_provider_has_no_cell_args(self):
        body = node_body(self.text, "wan_mac: macaddr@5000")
        self.assertNotIn("#nvmem-cell-cells", body)


if __name__ == "__main__":
    unittest.main()
