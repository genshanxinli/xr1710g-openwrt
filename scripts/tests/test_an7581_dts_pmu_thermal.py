#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard the EN7581 PMU node, the CPU diode thermal zone and the ramoops size.

Issue #377: the EN7581 has an ARM PMU (PPI 7) and a second thermal ADC for
the CPU diode, but an7581.dtsi described neither.  The driver side is
patches-7.4/402-09; without the DT side it stays inert, and a driver that
registers two zones against a zero-cell provider fails its probe outright
(``of_thermal_zone_find()`` turns the trailing ``<0>`` into a second phandle
and returns -ENOENT).  The three pieces therefore belong to one change.

Issue #383: the 64 KiB ramoops area spent all of it on dmesg records, so a
watchdog reset - which never runs kmsg_dump - left nothing behind.  A
console zone is the only pstore channel that is written straight from
``pstore_console_write()``.  16 KiB is enough for a useful tail and still
leaves twelve dmesg records.  ``unbuffered`` is not added: the default
mem-type 0 is already write-combined (Normal-NC) on arm64, and the
deprecated property would demote the area to Device memory.

The assertions are read from the dtsi text, so this runs without dtc or a
kernel tree:

    python3 scripts/tests/test_an7581_dts_pmu_thermal.py

AN7581_DTSI_UNDER_TEST points at another copy for the red proof.
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DTSI = Path(
    os.environ.get("AN7581_DTSI_UNDER_TEST")
    or REPO_ROOT / "target/linux/airoha/dts/an7581.dtsi"
)


def node_body(text, marker):
    """Return the brace-balanced body of the first node matching marker.

    ``marker`` is the text before the opening brace, e.g. ``pmu`` or
    ``cpu_die_thermal: cpu-die-thermal``.  Comments may contain braces in
    theory; this tree has none inside a node header or body.
    """
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


class En7581Dtsi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = DTSI.read_text()

    # --- issue #377 -----------------------------------------------------

    def test_pmu_node(self):
        body = node_body(self.text, "pmu")
        self.assertIn('compatible = "arm,cortex-a53-pmu";', body)
        self.assertIn("interrupts = <GIC_PPI 7 IRQ_TYPE_LEVEL_LOW>;", body)

    def test_cpu_die_zone(self):
        zones = node_body(self.text, "thermal-zones")
        self.assertIn("cpu_die_thermal: cpu-die-thermal", zones)
        body = node_body(self.text, "cpu_die_thermal: cpu-die-thermal")
        self.assertIn("thermal-sensors = <&thermal 1>;", body)
        self.assertIn("polling-delay-passive = <0>;", body)
        self.assertIn("polling-delay = <0>;", body)
        self.assertNotIn("trips", body)
        self.assertNotIn("cooling-maps", body)
        self.assertIn(
            "/* Read-only zone; trips stay on the main sensor zone above */",
            self.text,
        )

    def test_cells_is_one(self):
        provider = node_body(self.text, "thermal: thermal-sensor@1efbd000")
        self.assertIn("#thermal-sensor-cells = <1>;", provider)

    def test_main_zone_keeps_its_trip(self):
        body = node_body(self.text, "cpu_thermal: cpu-thermal")
        self.assertIn("thermal-sensors = <&thermal 0>;", body)
        self.assertIn("temperature = <95000>;", body)
        self.assertIn('type = "passive";', body)

    # --- issue #383 -----------------------------------------------------

    def test_ramoops_console_zone(self):
        body = node_body(self.text, "ramoops@86ff0000")
        self.assertIn("console-size = <0x4000>;", body)
        self.assertIn("record-size = <0x1000>;", body)
        self.assertIn("reg = <0x0 0x86ff0000 0x0 0x10000>;", body)

    def test_ramoops_has_no_deprecated_or_unused_knobs(self):
        body = node_body(self.text, "ramoops@86ff0000")
        self.assertNotIn("unbuffered", body)
        self.assertNotIn("mem-type", body)
        self.assertNotIn("pmsg-size", body)


if __name__ == "__main__":
    unittest.main()
