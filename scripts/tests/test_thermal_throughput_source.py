#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The throughput source picked from an iperf3 JSON result.

json_bps() prints "%.3f", so an iperf3 run that moved zero bits gives the
string "0.000".  The guard used to be "[ "$bps" != 0 ]", which is true for
that string: the zero was written into the row as an iperf measurement
(throughput 0.000, src=iperf) and the AP-side byte-counter fallback below it
never ran.  The guard now asks the value, not the spelling.

The JSON parser, the guard block and the helper are copied out of the script,
not re-implemented.  Point THERMAL_SOAK_UNDER_TEST at a copy to test that
copy instead.
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("THERMAL_SOAK_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/thermal-soak.sh"
)

# The real guard, verbatim: throughput/src come out of leg_loop().
GUARD = re.compile(
    r"(\t\tthroughput=na\n\t\tsrc=na\n\t\tif \[[^\n]*\n(?:\t\t\t[^\n]*\n)*?\t\tfi\n)"
)

# Real iperf3 -J shape: json_bps() reads the bits_per_second that follows the
# named sum object.
ZERO = """{
	"end": {
		"sum_received": {
			"bits_per_second": 0
		}
	}
}
"""
MOVING = ZERO.replace("\"bits_per_second\": 0", "\"bits_per_second\": 25000000.0")


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


class Source(unittest.TestCase):
    def setUp(self):
        match = GUARD.search(SCRIPT.read_text())
        assert match, "the throughput guard is not in " + str(SCRIPT)
        self.guard = match.group(1)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = Path(self.dir.name) / "iperf.json"

    def pick(self, document):
        self.path.write_text(document)
        body = (
            extract_function("json_bps")
            + extract_function("bps_is_zero")
            + f'jf={self.path}\n'
            + 'bps=$(json_bps "$jf" sum_received) || bps=\n'
            + self.guard
            + "printf 'throughput=%s src=%s\\n' \"$throughput\" \"$src\"\n"
        )
        out = subprocess.run(
            ["sh", "-c", body], capture_output=True, text=True, check=False
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_zero_bits_are_not_an_iperf_measurement(self):
        # 0.000 moved nothing: leave throughput to the AP byte counter.
        self.assertEqual(self.pick(ZERO), "throughput=na src=na")

    def test_moving_bits_are_an_iperf_measurement(self):
        self.assertEqual(self.pick(MOVING), "throughput=25.000 src=iperf")


class ZeroTest(unittest.TestCase):
    def test_the_helper_reads_the_value_not_the_spelling(self):
        body = (
            extract_function("bps_is_zero")
            + "\nfor v in 0 0.0 0.000 00.000; do\n"
            '  bps_is_zero "$v" && echo "zero $v" || echo "live $v"\n'
            "done\n"
            "for v in 0.001 1.000 25000000.000 0.5; do\n"
            '  bps_is_zero "$v" && echo "zero $v" || echo "live $v"\n'
            "done\n"
        )
        out = subprocess.run(
            ["sh", "-c", body], capture_output=True, text=True, check=False
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(
            out.stdout.split("\n"),
            [
                "zero 0",
                "zero 0.0",
                "zero 0.000",
                "zero 00.000",
                "live 0.001",
                "live 1.000",
                "live 25000000.000",
                "live 0.5",
                "",
            ],
        )


if __name__ == "__main__":
    unittest.main()
