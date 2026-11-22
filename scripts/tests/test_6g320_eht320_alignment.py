#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""320 MHz legality in scripts/wireless/6g320-matrix.sh.

The matrix checked band geometry only: centre +/- width/2 had to sit inside
5945..7125 MHz.  A 320 MHz block is not free to sit anywhere inside that
band, though.  hostapd picks eht_oper_centr_freq_seg0_idx from the primary
channel with the table in
package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/hostapd.uc

    primary <=  61 -> centre index  31 -> 6105 MHz
    primary <= 125 -> centre index  95 -> 6425 MHz
    primary <= 189 -> centre index 159 -> 6745 MHz
    primary <= 221 -> centre index 191 -> 6905 MHz

so a 320 MHz row centred on 6125 MHz is not a block this tree can bring up,
and a primary channel above 221 has no 320 MHz block at all.  Widths below
320 MHz are not tied to the table and must stay accepted.

The functions under test are copied out of the script, not re-implemented.
Point SIXG320_MATRIX_UNDER_TEST at a copy to test that copy instead.
"""

import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("SIXG320_MATRIX_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/6g320-matrix.sh"
)

CONSTANTS = (
    "CH_BAND_LO",
    "CH_BAND_HI",
    "EHT320_PRIMARY_MAX_CH",
    "EHT320_CH_BASE_MHZ",
    "EHT320_CH_STEP_MHZ",
)


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def extract_assignment(name):
    """Copy one integer top-level NAME=value assignment."""
    for line in SCRIPT.read_text().splitlines():
        if line.startswith(f"{name}=") and line[len(name) + 1:].isdigit():
            return line + "\n"
    raise AssertionError(f"{name}=<integer> is not in {SCRIPT}")


def body():
    return (
        "".join(extract_assignment(name) for name in CONSTANTS)
        + extract_function("eht320_centre_mhz")
        + extract_function("channel_block_reason")
    )


def run_sh(text):
    return subprocess.run(
        ["sh", "-c", text], capture_output=True, text=True, check=False
    )


def reason(freq, width, center1=None):
    """The reason channel_block_reason gives for one plan row.

    Mirrors check_rows: the block centre is center1 when the row carries one,
    the primary channel frequency otherwise.
    """
    centre = center1 if center1 is not None else freq
    args = f'{centre} {width} {freq}'
    if center1 is not None:
        args += f' {center1}'
    out = run_sh(body() + f"channel_block_reason {args}\n")
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


class LegalBlocks(unittest.TestCase):
    def test_ch37_320_center1_6105_is_legal(self):
        self.assertEqual(reason(6135, 320, 6105), "")

    def test_ch221_320_center1_6905_is_legal(self):
        self.assertEqual(reason(7055, 320, 6905), "")

    def test_widths_below_320_are_not_tied_to_the_table(self):
        # 6135 MHz is a legal 160 MHz centre; only 320 MHz blocks are aligned.
        self.assertEqual(reason(6135, 160), "")
        self.assertEqual(reason(6135, 80), "")
        self.assertEqual(reason(6135, 20), "")


class IllegalBlocks(unittest.TestCase):
    def test_center_off_the_hostapd_table_is_rejected(self):
        text = reason(6135, 320, 6125)
        self.assertIn("does not match the EHT320 table", text)
        self.assertIn("takes centre 6105 MHz", text)
        self.assertIn("20 MHz off", text)

    def test_primary_above_221_has_no_320_block(self):
        text = reason(7075, 320, 6905)
        self.assertIn("has no 320 MHz block", text)
        self.assertIn("225", text)
        self.assertIn("221", text)

    def test_ch233_overruns_the_band_edge(self):
        # The audit case: 7115 MHz + 160 MHz reaches 7275 MHz.
        text = reason(7115, 320)
        self.assertIn("7275", text)
        self.assertIn("7125", text)

    def test_320_row_without_the_primary_channel_is_rejected(self):
        text = reason(6135, 320)
        self.assertIn("only one of center1 and the primary channel", text)

    def test_primary_off_the_channel_raster_is_rejected(self):
        text = reason(6137, 320, 6105)
        self.assertIn("not on the 6 GHz channel raster", text)


class CentreTable(unittest.TestCase):
    def centre(self, channel):
        out = run_sh(body() + f"eht320_centre_mhz {channel}\n")
        return out.returncode, out.stdout.strip()

    def test_table_matches_the_hostapd_indices(self):
        # index 31/95/159/191 are 5 MHz steps from 5950 MHz.
        for channel, mhz in (
            (1, "6105"),
            (61, "6105"),
            (62, "6425"),
            (125, "6425"),
            (126, "6745"),
            (189, "6745"),
            (190, "6905"),
            (221, "6905"),
        ):
            self.assertEqual(self.centre(channel), (0, mhz), channel)

    def test_channel_above_221_has_no_block(self):
        for channel in (222, 233):
            code, text = self.centre(channel)
            self.assertNotEqual(code, 0, channel)
            self.assertEqual(text, "", channel)


if __name__ == "__main__":
    unittest.main()
