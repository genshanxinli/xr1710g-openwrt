#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""#381: an7581 defaults cpufreq to ondemand, and 940 maps OPP states from 500 MHz.

`CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y` pins `policy->min == policy->max`,
so cpufreq-dt never calls `set_target` and the board sits at 1200 MHz with
`total_trans 0`.  The ondemand default is a two-line fragment edit that a merge
or a cleanup pass can silently undo; the governor drivers stay built so a
runtime `echo performance > scaling_governor` remains available for rollback.

The 940 pmdomain patch turns a required-OPP level into a PLL frequency.  State
14 is the 1200 MHz OPP, so a 700 MHz base programmed 1400 MHz -- overclocking
the issue explicitly excludes -- and a 500 MHz request landed on 700 MHz.

Files are injected through `*_UNDER_TEST` variables so the red half can point
at unmodified copies:

    CONFIG74_UNDER_TEST=/tmp/copy/config-7.4 \
    PATCHES74_UNDER_TEST=/tmp/copy/patches-7.4 \
        python3 -m unittest scripts.tests.test_an7581_cpufreq_gov_config -v

Run from the repository root:

    python3 -m unittest scripts.tests.test_an7581_cpufreq_gov_config -v
"""

import os
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG = Path(
    os.environ.get(
        "CONFIG74_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/an7581/config-7.4",
    )
).resolve()
PATCH_DIR = Path(
    os.environ.get(
        "PATCHES74_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/patches-7.4",
    )
).resolve()

# Pre-fix 940 formula; state 14 would program 1400 MHz.
SEVEN_HUNDRED_BASE = r"700\s*\+\s*state\s*\*"
# Fixed base, as a macro or as the literal formula.
FIVE_HUNDRED_BASE = (
    r"#define\s+AIROHA_CPU_MIN_FREQ_MHZ\s+500\b|500\s*\+\s*state\s*\*\s*50"
)


class An7581CpufreqGovernorConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config_lines = [line.strip() for line in CONFIG.read_text().splitlines()]

    def test_default_governor_is_ondemand(self):
        self.assertIn(
            "CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y",
            self.config_lines,
            f"{CONFIG} must default to ondemand",
        )
        self.assertNotIn(
            "# CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND is not set",
            self.config_lines,
            f"{CONFIG} still overrides the ondemand default off",
        )
        self.assertIn(
            "# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE is not set",
            self.config_lines,
            f"{CONFIG} must not keep performance as the default governor",
        )

    def test_both_governors_stay_built_for_runtime_switch(self):
        for symbol in (
            "CONFIG_CPU_FREQ_GOV_ONDEMAND=y",
            "CONFIG_CPU_FREQ_GOV_PERFORMANCE=y",
        ):
            with self.subTest(symbol=symbol):
                self.assertIn(symbol, self.config_lines)

    def test_940_does_not_program_from_a_700_mhz_opp_base(self):
        patches = sorted(PATCH_DIR.glob("940-*"))
        self.assertTrue(patches, f"no 940-* patch in {PATCH_DIR}")
        for patch in patches:
            with self.subTest(patch=patch.name):
                self.assertNotRegex(
                    patch.read_text(),
                    SEVEN_HUNDRED_BASE,
                    f"{patch.name} still maps OPP states from 700 MHz; "
                    "state 14 would program 1400 MHz",
                )

    def test_940_keeps_the_mapping_on_the_500_mhz_opp_base(self):
        pmdomain = sorted(PATCH_DIR.glob("940-*pmdomain*"))
        self.assertEqual(
            len(pmdomain),
            1,
            f"expected one 940 pmdomain patch in {PATCH_DIR}, got {pmdomain}",
        )
        self.assertRegex(pmdomain[0].read_text(), FIVE_HUNDRED_BASE)


if __name__ == "__main__":
    unittest.main()
