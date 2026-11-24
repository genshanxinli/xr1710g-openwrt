#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""sensors.csv carries the board temperature, not just the fan (issue #53).

F53-1: `thermal-soak.sh` wrote t_cpu_c, the three mt7996 temperatures and the
nct7802 PWM/tach columns, but never `temp1_input` -- the board's own sensor on
the same chip.  Every fan-curve conclusion was then unreproducible: the CSV
showed what the fan did and what the radio/cpu temperatures were, not what
the fan controller was reading when it did it.

The fixture here is the board's own shape: a nct7802 hwmon whose temp1_input
is the interesting column, and a CSV whose run column is $33 after the new
column lands.  THERMAL_SOAK_UNDER_TEST points at a copy for the red proof.

Run from the repository root:

    python3 scripts/tests/test_thermal_board_temp.py
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("THERMAL_SOAK_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/thermal-soak.sh"
)

# Board columns in order; the script must keep this layout or the summary
# below reads the wrong field.  board_c sits right after t_wifi2_c because
# that is where the old run column used to start.
EXPECTED_PREFIX = [
    "time", "epoch", "elapsed_s", "uptime_s", "boot_id", "t_cpu_c",
    "t_wifi0_c", "t_wifi1_c", "t_wifi2_c", "board_c", "freq_mhz",
    "freq_max_mhz", "governor",
]


def extract_function(name):
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def extract_assignment(name):
    for line in SCRIPT.read_text().splitlines():
        if line.startswith(name + "='" ):
            return line.split("'", 2)[1]
        if line.startswith(name + '="'):
            return line.split('"', 2)[1]
    raise AssertionError(f"{name} assignment is missing")


def run_sh(body, cwd=None):
    return subprocess.run(
        ["sh", "-c", body], capture_output=True, text=True, cwd=cwd, check=False
    )


def sensors_row(values):
    return ",".join(str(v) for v in values) + "\n"


class HeaderLayout(unittest.TestCase):
    def test_the_header_names_the_board_column_after_wifi2(self):
        cols = extract_assignment("SENSORS_HEADER").split(",")
        self.assertEqual(cols[: len(EXPECTED_PREFIX)], EXPECTED_PREFIX)
        self.assertEqual(len(cols), 33, cols)

    def test_append_sensors_prints_as_many_values_as_the_header(self):
        body = extract_function("append_sensors")
        # One %s per column; the run column is still last and is $33.
        self.assertEqual(body.count("%s"), 33, body)
        body = extract_function("summary_window")
        self.assertIn("$33", body)
        self.assertNotIn("$32", body)


class BoardSample(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.hwmon = Path(self.tmp.name) / "hwmon"
        self.hwmon.mkdir()
        self.body = (
            extract_function("read_temp_c_or_na")
            + extract_function("sample_board")
        )

    def sample(self, board=None):
        env = f"BOARD_HWMON={str(board)!r}\n" if board is not None else "BOARD_HWMON=''\n"
        out = run_sh(self.body + env + "sample_board\nprintf '%s\\n' \"$S_BOARD\"\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_temp1_input_is_read_in_whole_degrees(self):
        (self.hwmon / "temp1_input").write_text("42000\n")
        self.assertEqual(self.sample(self.hwmon), "42.0")

    def test_a_missing_sensor_is_na_not_a_refusal(self):
        self.assertEqual(self.sample(self.hwmon), "na")

    def test_no_board_hwmon_is_na(self):
        self.assertEqual(self.sample(""), "na")


class SummaryReadsBoardColumn(unittest.TestCase):
    def test_the_board_temperature_reaches_the_summary(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        run = Path(tmp.name)
        rows = []
        for board in ("40.0", "41.0"):
            values = ["t", "1", "0", "9", "boot", "60.0",
                      "50.0", "51.0", "52.0", board,
                      "1000", "1200", "performance",
                      "100", "1", "100", "100", "1200",
                      "20", "500", "1", "na", "na", "0",
                      "0", "0", "0", "0", "0", "0", "0", "0", "r1"]
            rows.append(sensors_row(values))
        (run / "sensors.csv").write_text(
            extract_assignment("SENSORS_HEADER") + "\n" + "".join(rows)
        )
        body = (
            "is_uint() {\n"
            "\tcase ${1-} in ''|*[!0-9]*) return 1 ;; esac\n"
            "}\n"
            + extract_function("summary_window")
            + extract_function("thermal_summary")
            + f"RUN={str(run)!r}\nRUN_ID=r1\nIP_A=''\n"
            + "thermal_summary\n"
        )
        out = run_sh(body)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(
            "board-thermal: min 40.0 C max 41.0 C avg 40.5 C", out.stdout
        )
        self.assertIn("mt7996: max 52.0 C", out.stdout)
        self.assertIn("fan: min 1200 RPM max 1200 RPM", out.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
