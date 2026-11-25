#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard thermal emergency shutdown safety net and NCT7802 RTD2 suppression (#379).

Three thermal-safety pieces are pinned across the an7581 kernel config and DT:

  * ``CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS >= 3000`` in
    ``target/linux/airoha/an7581/config-7.4``.  At 0 ms the kernel cuts power
    immediately on a critical trip without giving userspace, filesystems, or
    pstore/ramoops a window to flush logs.
  * ``cpu_thermal`` in ``target/linux/airoha/dts/an7581.dtsi`` must set
    ``polling-delay = <5000>;`` (safety-net polling even if an interrupt trip
    window is missed) and include a ``cpu_hot`` trip (105 C, 2 C hysteresis,
    ``type = "hot"``) between ``cpu_passive`` (95 C) and ``cpu-critical``
    (120 C) while keeping ``cooling-maps`` bound only to ``cpu_passive``.
  * ``hwmon@2e`` (``nuvoton,nct7802``) in
    ``target/linux/airoha/dts/an7581-xr1710g-ubi.dts`` must disable the open
    RTD2 diode (``channel@2 { reg = <2>; status = "disabled"; }``) so it stops
    reporting a spurious 127.875 C open-diode reading.

Inject unmodified copies via ``CONFIG_74_UNDER_TEST``, ``DTSI_UNDER_TEST``,
and ``XR1710G_DTS_UNDER_TEST`` for the red half:

    CONFIG_74_UNDER_TEST=/path/to/old/config-7.4 \\
    DTSI_UNDER_TEST=/path/to/old/an7581.dtsi \\
    XR1710G_DTS_UNDER_TEST=/path/to/old/an7581-xr1710g-ubi.dts \\
        python3 -m unittest scripts.tests.test_thermal_safety_config -v

Run from the repository root:

    python3 -m unittest scripts.tests.test_thermal_safety_config -v
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_74 = Path(
    os.environ.get(
        "CONFIG_74_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/an7581/config-7.4",
    )
).resolve()
DTSI = Path(
    os.environ.get(
        "DTSI_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/dts/an7581.dtsi",
    )
).resolve()
XR1710G_DTS = Path(
    os.environ.get(
        "XR1710G_DTS_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/dts/an7581-xr1710g-ubi.dts",
    )
).resolve()


def node_body(text, marker):
    """Return the brace-balanced body of the first DT node matching marker."""
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
                return text[start + 1 : pos]
    raise AssertionError(f"node {marker!r} is not closed")


class ThermalSafetyConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config_text = CONFIG_74.read_text(encoding="utf-8")
        cls.dtsi_text = DTSI.read_text(encoding="utf-8")
        cls.xr_dts_text = XR1710G_DTS.read_text(encoding="utf-8")

    def test_emergency_poweroff_delay_at_least_3000ms(self):
        match = re.search(
            r"^CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=(\d+)$",
            self.config_text,
            re.MULTILINE,
        )
        self.assertIsNotNone(
            match,
            f"CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS missing in {CONFIG_74}",
        )
        delay_ms = int(match.group(1))
        self.assertGreaterEqual(
            delay_ms,
            3000,
            f"CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS={delay_ms} is below "
            "the 3000 ms floor needed to flush logs/pstore before poweroff",
        )

    def test_cpu_thermal_polling_delay_nonzero(self):
        zone = node_body(self.dtsi_text, "cpu_thermal: cpu-thermal")
        match = re.search(r"\bpolling-delay\s*=\s*<(\d+)>;", zone)
        self.assertIsNotNone(match, "cpu_thermal is missing polling-delay")
        delay = int(match.group(1))
        self.assertEqual(
            delay,
            5000,
            f"cpu_thermal polling-delay must be 5000 ms, got {delay}",
        )

    def test_cpu_hot_trip_between_passive_and_critical(self):
        zone = node_body(self.dtsi_text, "cpu_thermal: cpu-thermal")
        trips = node_body(zone, "trips")
        passive_body = node_body(trips, "cpu_passive: cpu-passive")
        hot_body = node_body(trips, "cpu_hot: cpu-hot")
        crit_body = node_body(trips, "cpu-critical")

        def trip_temp(body, name):
            m = re.search(r"\btemperature\s*=\s*<(\d+)>;", body)
            self.assertIsNotNone(m, f"{name} missing temperature")
            return int(m.group(1))

        t_passive = trip_temp(passive_body, "cpu_passive")
        t_hot = trip_temp(hot_body, "cpu_hot")
        t_crit = trip_temp(crit_body, "cpu-critical")

        self.assertEqual(t_hot, 105000)
        self.assertLess(t_passive, t_hot)
        self.assertLess(t_hot, t_crit)
        self.assertIn("hysteresis = <2000>;", hot_body)
        self.assertIn('type = "hot";', hot_body)

        # Ordering inside trips: passive before hot before critical.
        self.assertLess(trips.index("cpu_passive"), trips.index("cpu_hot"))
        self.assertLess(trips.index("cpu_hot"), trips.index("cpu-critical"))

        # cooling-maps stays bound to cpu_passive, never cpu_hot.
        cmaps = node_body(zone, "cooling-maps")
        self.assertIn("trip = <&cpu_passive>;", cmaps)
        self.assertNotIn("cpu_hot", cmaps)

    def test_xr1710g_nct7802_disables_open_rtd2_channel(self):
        hwmon = node_body(self.xr_dts_text, "hwmon@2e")
        self.assertIn('compatible = "nuvoton,nct7802";', hwmon)
        self.assertIn("#address-cells = <1>;", hwmon)
        self.assertIn("#size-cells = <0>;", hwmon)
        ch2 = node_body(hwmon, "channel@2")
        self.assertIn("reg = <2>;", ch2)
        self.assertIn('sensor-type = "temperature";', ch2)
        self.assertIn('temperature-mode = "thermal-diode";', ch2)
        self.assertIn('status = "disabled";', ch2)


if __name__ == "__main__":
    unittest.main()
