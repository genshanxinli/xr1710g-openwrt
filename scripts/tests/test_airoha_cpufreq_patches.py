#!/usr/bin/env python3
"""Static checks for the 7.4 Airoha CPU frequency patches (#381).

The two patches move the CPU between OPP states, so they have to agree with
the OPP tables in target/linux/airoha/dts/an7581.dtsi: 15 states from 500 to
1200 MHz in 50 MHz steps, smcc_opp0..smcc_opp14.  They also have to seed the
genpd performance state the bootloader left behind, bound the state they
program, and verify/roll back a PLL write before switching the CPU clock back.

Red half (the pre-fix patches, e.g. from commit b5a02c63a9):

    tmp=$(mktemp -d)
    git show HEAD:target/linux/airoha/patches-7.4/939-cpufreq-airoha-Add-EN7581-CPUFreq-SMCCC-driver.patch >"$tmp/939-cpufreq-airoha-Add-EN7581-CPUFreq-SMCCC-driver.patch"
    git show HEAD:target/linux/airoha/patches-7.4/940-pmdomain-airoha-Add-Airoha-CPU-PM-Domain-support.patch >"$tmp/940-pmdomain-airoha-Add-Airoha-CPU-PM-Domain-support.patch"
    AIROHA_CPUFREQ_PATCH_DIR_UNDER_TEST="$tmp" python3 scripts/tests/test_airoha_cpufreq_patches.py

fails on the 700 MHz base, the missing state bound, the unverified PLL write
and the missing performance-state sync; the current patches pass.
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Overridable so the red half can run against the pre-fix patches.
PATCH_DIR = Path(
    os.environ.get("AIROHA_CPUFREQ_PATCH_DIR_UNDER_TEST")
    or REPO_ROOT / "target/linux/airoha/patches-7.4"
)
DTSI = Path(
    os.environ.get("AIROHA_AN7581_DTSI_UNDER_TEST")
    or REPO_ROOT / "target/linux/airoha/dts/an7581.dtsi"
)

CPUFREQ_FILE = "drivers/cpufreq/airoha-cpufreq.c"
PLATDEV_FILE = "drivers/cpufreq/cpufreq-dt-platdev.c"
PMDOMAIN_FILE = "drivers/pmdomain/mediatek/airoha-cpu-pmdomain.c"


def _patch_path(prefix):
    hits = sorted(PATCH_DIR.glob(f"{prefix}-*.patch"))
    if len(hits) != 1:
        raise AssertionError(f"expected exactly one {prefix}-*.patch in {PATCH_DIR}, got {hits}")
    return hits[0]


def _post_lines(patch_text, path):
    """Lines `path` holds after the patch, i.e. context plus added lines."""
    lines = []
    current = None
    for line in patch_text.splitlines():
        if line.startswith("+++ b/"):
            current = line[len("+++ b/"):].strip()
            continue
        if line.startswith("diff --git ") or line.startswith("--- a/"):
            current = None
            continue
        if current != path or line.startswith("@@"):
            continue
        if line.startswith("+") or line.startswith(" "):
            lines.append(line[1:])
    return "\n".join(lines)


def _function(text, signature):
    start = text.index(signature)
    end = text.index("\n}\n", start)
    return text[start:end]


class AirohaCpufreqPatchesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cpufreq = _patch_path("939").read_text()
        cls.pmdomain = _patch_path("940").read_text()
        cls.cpufreq_src = _post_lines(cls.cpufreq, CPUFREQ_FILE)
        cls.platdev_src = _post_lines(cls.cpufreq, PLATDEV_FILE)
        cls.pmdomain_src = _post_lines(cls.pmdomain, PMDOMAIN_FILE)
        cls.pll_set_freq = _function(
            cls.pmdomain_src, "static int airoha_cpu_pll_set_freq("
        )

    def test_cpu_opp_tables_match_driver_state_range(self):
        """State N must map to 500 + N*50 MHz, N bounded by smcc_opp14."""
        dtsi = DTSI.read_text()
        opp_start = dtsi.index("cpu_opp_table: opp-table {")
        smcc_start = dtsi.index("cpu_smcc_opp_table:")
        rates = [
            int(hz)
            for hz in re.findall(
                r"opp-hz = /bits/ 64 <(\d+)>", dtsi[opp_start:smcc_start]
            )
        ]
        levels = [
            int(level)
            for level in re.findall(
                r"opp-level = <(\d+)>",
                dtsi[smcc_start:dtsi.index("timer {", smcc_start)],
            )
        ]

        self.assertEqual(len(rates), 15, "cpu_opp_table must describe 15 states")
        self.assertEqual(levels, list(range(15)), "smcc levels must be 0..14")
        self.assertEqual(rates[0] // 1000000, 500, "lowest OPP must be 500 MHz")
        self.assertEqual(rates[-1] // 1000000, 1200, "highest OPP must be 1200 MHz")
        self.assertEqual((rates[1] - rates[0]) // 1000000, 50, "OPP step must be 50 MHz")

        self.assertRegex(
            self.pmdomain_src,
            r"#define\s+AIROHA_CPU_MIN_FREQ_MHZ\s+"
            + str(rates[0] // 1000000)
            + r"\b",
        )
        self.assertRegex(
            self.pmdomain_src,
            r"#define\s+AIROHA_CPU_FREQ_STEP_MHZ\s+"
            + str((rates[1] - rates[0]) // 1000000)
            + r"\b",
        )
        self.assertRegex(
            self.pmdomain_src,
            r"#define\s+AIROHA_CPU_MAX_OPP_STATE\s+" + str(levels[-1]) + r"\b",
        )

    def test_pll_programs_state_from_opp_base(self):
        """No 700 MHz base: the pre-fix formula overclocked every state."""
        self.assertNotIn("700 + state", self.pmdomain_src)
        self.assertNotIn("1400", self.pmdomain_src)
        self.assertRegex(
            self.pll_set_freq,
            r"freq_mhz\s*=\s*AIROHA_CPU_MIN_FREQ_MHZ\s*\+\s*\n?\s*"
            r"state\s*\*\s*AIROHA_CPU_FREQ_STEP_MHZ",
        )

    def test_pll_programming_is_idempotent(self):
        """Reprogramming the frequency the PLL already runs at is a clock glitch."""
        self.assertRegex(
            self.pll_set_freq,
            r"airoha_cpu_pll_clk_get\(priv\)\s*==",
        )

    def test_performance_state_is_bounded(self):
        """genpd passes through any requested state; bound it to the OPP table."""
        body = _function(
            self.pmdomain_src,
            "static int airoha_cpu_pmdomain_set_performance_state(",
        )
        self.assertRegex(body, r"state\s*>\s*AIROHA_CPU_MAX_OPP_STATE")
        self.assertIn("return -EINVAL;", body)
        self.assertLess(
            body.index("AIROHA_CPU_MAX_OPP_STATE"),
            body.index("priv->use_smc"),
            "the bound must be checked before any frequency change",
        )

    def test_pll_write_is_verified_and_rolled_back(self):
        """A rejected PCW write must not be switched in, and must be undone."""
        self.assertRegex(self.pll_set_freq, r"old_pcw\s*=\s*readl\(")
        self.assertRegex(
            self.pll_set_freq,
            r"FIELD_GET\(CPUPLL_PCW_INT_MASK,\s*readl\(",
        )
        self.assertRegex(self.pll_set_freq, r"writel\(old_pcw,\s*base")
        self.assertIn("return ret;", self.pll_set_freq)
        self.assertIn("-EIO", self.pll_set_freq)
        self.assertIn("udelay(50)", self.pll_set_freq)
        self.assertNotIn("udelay(20)", self.pll_set_freq)

    def test_pmdomain_exports_current_state(self):
        """The cpufreq driver reads the state the CPU runs at through this."""
        self.assertIn(
            "EXPORT_SYMBOL_GPL(airoha_cpu_pmdomain_get_state);", self.pmdomain_src
        )
        self.assertRegex(
            _function(self.pmdomain_src, "int airoha_cpu_pmdomain_get_state(void)"),
            r"\(\s*freq_mhz\s*-\s*AIROHA_CPU_MIN_FREQ_MHZ\s*\)\s*/\s*"
            r"AIROHA_CPU_FREQ_STEP_MHZ",
        )

    def test_cpufreq_seeds_the_boot_performance_state(self):
        """Both genpd caches start at 0, so a request for state 0 is dropped."""
        self.assertIn("airoha_cpu_pmdomain_get_state();", self.cpufreq_src)
        self.assertIn("dev_pm_genpd_set_performance_state(", self.cpufreq_src)
        self.assertLess(
            self.cpufreq_src.index("pm_runtime_resume_and_get(virt_devs[i])"),
            self.cpufreq_src.index("airoha_cpu_pmdomain_get_state();"),
            "the sync has to happen after the domain device is resumed",
        )

    def test_cpufreq_keeps_attach_by_name(self):
        """r10 #381: attach_by_name already registers the required OPP link."""
        self.assertIn("dev_pm_domain_attach_by_name(", self.cpufreq_src)
        self.assertNotIn("dev_pm_domain_attach_list", self.cpufreq_src)
        self.assertNotIn("PD_FLAG_REQUIRED_OPP", self.cpufreq_src)

    def test_an7581_is_blocklisted_for_cpufreq_dt(self):
        """cpufreq-dt must not bind on its own before the OPP chain is set up."""
        self.assertIn("airoha,an7581", self.platdev_src)


if __name__ == "__main__":
    unittest.main()
