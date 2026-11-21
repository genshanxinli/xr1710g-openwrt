#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Executable form of the OpenWrt PR #26296 convergence checklist (issue #56).

The checklist used to live in .github/upstream/openwrt-pr-26296.md. That file
was removed with the docs/ tree (34fa6cf5ee), and the maintainer does not take
authored prose back, so every row that can be decided from this tree is
asserted here instead. The table below is the checklist; the test name is the
row.

  | # | Checklist row                | Asserted here                                  |
  |---|------------------------------|------------------------------------------------|
  | 1 | netwatchdog guard exists     | GuardTest: file, sh -n, runtime callers         |
  | 2 | guard is fail-closed         | GuardTest: no service -> nonzero, no JSON loss  |
  | 3 | pcie-single-cut exists       | PcieCutTest: file, sh -n, --confirm gate         |
  | 4 | lab tooling not in the image | LabToolingTest: no reference under target/ or package/ |
  | 5 | guard is adopted, not idle   | GuardTest: every adopter propagates the status  |
  | 6 | DTS quirks stay local-only   | DtsTest: they are present and named `local only` |
  | 7 | kernel baseline              | KernelTest: 6.18 mainline, 7.4 testing           |
  | 8 | 10G series placement         | KernelTest: 744 pending, 745/747/748/749 airoha  |
  | 9 | `998` is not upstreamable    | KernelTest: still hides the pinctrl error       |
  |10 | NPU blobs are the local v0.8 | FirmwareTest: size + sha256 of both blobs       |
  |11 | mt76 base is the fork        | ForkTest: source is OpenWRT-fanboy, not openwrt |
  |12 | U-Boot carries `999` only    | ForkTest: 999 present, PR`s 403 absent          |
  |13 | compat gate is local        | BoardTest: DEVICE_COMPAT_VERSION + 05_compat    |
  |14 | fan init has the XR case     | BoardTest: gemtek,xr1710g-ubi in the case arm   |
  |15 | the docs file stayed deleted | DocsTest: no docs/ tree, no .github/upstream    |
  |16 | PR board tree not half-taken | DtsTest: an7581-gemtek_xr1710g-ubi.dts absent    |

Rows that cannot be decided offline (upstream merge state, upstream file
lists) live in UpstreamSnapshotTest, which is skipped unless
OPENWRT_PR_26296_ONLINE=1. The URLs it fetches are listed in OPEN_QUESTIONS.

Run from the repository root:

    python3 scripts/tests/test_openwrt_pr_convergence.py

No network by default. Stdlib only.
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "scripts/lib/netwatchdog-guard.sh"
GUARD_TEST = REPO / "scripts/lib/netwatchdog-guard-test.sh"
PCIE = REPO / "scripts/pcie-single-cut.sh"
WIRELESS = REPO / "scripts/wireless"
AIROHA = REPO / "target/linux/airoha"
DTSI = AIROHA / "dts/an7581.dtsi"
XR_DTS = AIROHA / "dts/an7581-xr1710g-ubi.dts"
AIROHA_MK = AIROHA / "image/an7581.mk"
COMPAT = AIROHA / "an7581/base-files/etc/board.d/05_compat-version"
FAN_INIT = AIROHA / "an7581/base-files/etc/init.d/airoha_fan"
MT76_MK = REPO / "package/kernel/mt76/Makefile"
UBOOT_PATCHES = REPO / "package/boot/uboot-airoha/patches"
BLOB_DIR = REPO / "package/firmware/linux-firmware/files/airoha"

# The upstream facts this local tree is converging towards. They were read from
# openwrt/openwrt at the snapshot below and are not re-fetched here; see
# UpstreamSnapshotTest for the online half.
UPSTREAM_MAIN_SHA = "8b34d6283fc51dc3d5235d4ea3c97c72cd8ed506"
PR_26296_HEAD = "1b981abdd1931f7bde8defc2965260572bc6bfec"
UPSTREAM_MT76 = ("https://github.com/openwrt/mt76", "2026-10-28",
                 "0936617dc529ff9da0385221d3fa6de732231177")
LOCAL_MT76 = ("https://github.com/OpenWRT-fanboy/mt76-firmware", "2026-10-28",
              "46b67e5b7c49313d11b2b2d83df3c8025406d63e")

NPU_BLOBS = {
    "en7581_MT7996_npu_rv32.bin": (125832,
        "7068a987bb95e89129a69de10d598f234a4400023eb23aacc8eb377e5f0fe0ea"),
    "en7581_MT7996_npu_data.bin": (3092,
        "6fd9506e399ebb309801ac2ecc74d3e10fa66731afc828c76fde8a67b2153f49"),
}

# Upstream `target/linux/airoha/patches-6.18` entries this tree does not carry,
# measured against main at UPSTREAM_MAIN_SHA on 2026-11-20. Upstream has 164
# files here, the local tree 195: the extra 45 are local/fork patches, and
# these 14 are upstream ones the local baseline still owes.
UPSTREAM_LAG_6_18 = (
    "230-v7.3-nvmem-airoha-Add-support-for-SMC-eFUSE.patch",
    "231-nvmem-airoha-smc-efuses-Fix-the-SMC-function-ID-for-eFuse-read.patch",
    "402-08-v7.4-thermal-drivers-airoha-Request-the-EN7581-IRQ-after-zone-registration.patch",
    "402-09-thermal-drivers-airoha-read-the-EN7581-CPU-sensor.patch",
    "602-03-dt-bindings-phy-airoha-Document-support-for-AN7583-Gen3-PCIe-PHY.patch",
    "603-01-PCI-mediatek-gen3-add-support-for-Airoha-AN7583-SoC.patch",
    "603-03-PCI-mediatek-Convert-bool-to-single-quirks-entry-and-bitmap.patch",
    "603-05-PCI-mediatek-add-support-for-Airoha-AN7583-SoC.patch",
    "607-03-dt-bindings-phy-Add-documentation-for-Airoha-AN7583-PCIe-Gen2-PHY.patch",
    "610-01-dt-bindings-clock-airoha-Add-PHY-binding-for-Serdes-.patch",
    "610-02-clk-en7523-Add-support-for-selecting-the-Serdes-port.patch",
    "610-03-clk-en7523-Add-support-for-selecting-the-Serdes-port.patch",
    "914-PCI-mediatek-handle-reset-for-AN7583-startup.patch",
    "916-phy-airoha-fix-AN7583-USB-SerDes-mode-setup.patch",
)

# Everything the offline rows cannot answer, with the exact place to look.
OPEN_QUESTIONS = (
    "https://github.com/openwrt/openwrt/pull/26296 (open/merged, head sha)",
    "https://github.com/openwrt/openwrt/pull/26297 (open/merged)",
    "https://github.com/openwrt/openwrt/pull/26508 (open/merged)",
    "https://github.com/openwrt/openwrt/pull/23990 (RFC, open/merged)",
    "https://github.com/openwrt/openwrt/pull/22536 (closed unmerged)",
    "https://api.github.com/repos/openwrt/openwrt/contents/"
    "target/linux/airoha/patches-6.18?ref=main",
    "https://api.github.com/repos/openwrt/openwrt/contents/"
    "target/linux/generic/pending-6.18?ref=main",
    "https://api.github.com/repos/openwrt/openwrt/contents/"
    "package/kernel/mt76/Makefile?ref=main",
)


def read(path):
    return Path(path).read_text()


def sh_syntax_ok(path):
    """`sh -n` on a POSIX sh script; returns (ok, message)."""
    result = subprocess.run(["sh", "-n", str(path)], capture_output=True,
                            universal_newlines=True)
    return result.returncode == 0, result.stderr.strip()


def image_tree_files():
    """Every text file the image installs, same roots test_flock... scans."""
    roots = list(REPO.glob("target/linux/*/*/base-files"))
    roots += list(REPO.glob("target/linux/*/*/files"))
    roots.append(REPO / "package")
    for root in roots:
        if root.is_dir():
            yield from (p for p in root.rglob("*") if p.is_file())


class GuardTest(unittest.TestCase):
    """Rows 1, 2 and 5: the netwatchdog guard is real, fail-closed, adopted."""

    def test_guard_exists_and_is_valid_sh(self):
        self.assertTrue(GUARD.is_file(), "netwatchdog-guard.sh disappeared")
        ok, err = sh_syntax_ok(GUARD)
        self.assertTrue(ok, err)
        self.assertTrue(GUARD_TEST.is_file(), "the guard's own test is gone")

    def test_guard_is_fail_closed_without_netwatchdog(self):
        # The checklist claimed the guard was "planned, not present". Exercise
        # the real library: a missing service must refuse the destructive step,
        # and NWD_ALLOW_NO_SERVICE=1 is the only way past it.
        tmp = Path(tempfile.mkdtemp(prefix="nw-guard-"))
        try:
            probe = tmp / "probe.sh"
            probe.write_text(
                '#!/bin/sh\n'
                'set -u\n'
                '. "%s"\n'
                'nw_guard_init --apply --result-json "%s/nw.json"\n'
                'nw_guard_take\n'
                'exit $?\n' % (GUARD, tmp))
            env = {"PATH": "/usr/bin:/bin",
                   "NW_GUARD_COMMAND": str(tmp / "absent-netwatchdog"),
                   "NW_GUARD_HOLD_FILE": str(tmp / "hold")}
            refused = subprocess.run(["sh", str(probe)], env=env,
                                     capture_output=True, universal_newlines=True)
            self.assertNotEqual(refused.returncode, 0,
                                "missing netwatchdog was not refused")
            self.assertIn("refusing the destructive step", refused.stderr)

            env["NWD_ALLOW_NO_SERVICE"] = "1"
            allowed = subprocess.run(["sh", str(probe)], env=env,
                                     capture_output=True, universal_newlines=True)
            self.assertEqual(allowed.returncode, 0,
                             "NWD_ALLOW_NO_SERVICE=1 did not downgrade")
        finally:
            shutil.rmtree(tmp)

    def test_every_adopter_propagates_the_status(self):
        # A fail-closed library that callers ignore is not fail-closed. Any
        # script that sources it must use `nw_guard_take ||` and must not
        # swallow the status with `|| true`.
        adopters = [p for p in sorted(WIRELESS.glob("*.sh"))
                    if "netwatchdog-guard.sh" in read(p)]
        self.assertEqual(len(adopters), 7,
                         "expected the 7 destructive scripts from #102, got %d"
                         % len(adopters))
        for path in adopters:
            body = read(path)
            self.assertRegex(body, r"nw_guard_take\s*\|\|",
                             "%s ignores nw_guard_take's status" % path.name)
            self.assertNotRegex(body, r"nw_guard_take\s*\|\|\s*true",
                                "%s swallows the refusal" % path.name)


class PcieCutTest(unittest.TestCase):
    """Row 3: pcie-single-cut exists, is valid sh, and needs --confirm."""

    def test_script_exists_and_is_valid_sh(self):
        self.assertTrue(PCIE.is_file(), "pcie-single-cut.sh disappeared")
        ok, err = sh_syntax_ok(PCIE)
        self.assertTrue(ok, err)
        self.assertTrue((REPO / "scripts/tests/test_pcie_single_cut.py").is_file())

    def test_apply_requires_confirm(self):
        # Missing /dev/mem and devmem: apply must refuse on usage, not on
        # access, so the --confirm gate is provable without hardware.
        result = subprocess.run(
            ["sh", str(PCIE), "apply"],
            env={"PATH": "/usr/bin:/bin"}, capture_output=True,
            universal_newlines=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--confirm", result.stderr + result.stdout)


class LabToolingTest(unittest.TestCase):
    """Row 4: the lab scripts are not part of any image."""

    def test_nothing_in_the_image_tree_calls_them(self):
        offenders = []
        for path in image_tree_files():
            try:
                body = path.read_text(errors="ignore")
            except OSError:
                continue
            if "pcie-single-cut" in body or "netwatchdog-guard" in body:
                offenders.append(str(path.relative_to(REPO)))
        self.assertEqual(offenders, [],
                         "lab tooling leaked into the image tree: %s" % offenders)


class DtsTest(unittest.TestCase):
    """Rows 6 and 16: the local quirks are local, and the PR tree is not half-taken."""

    def test_local_only_quirks_are_present(self):
        body = read(XR_DTS)
        for token in ("realtek,sds-mode = <0x88c6>",
                      "realtek,patch-rtk-serdes",
                      'openwrt,netdev-name = "cpu"'):
            self.assertIn(token, body,
                          "%s lost %r, a local-only delta" % (XR_DTS.name, token))

    def test_pr_board_tree_is_not_present(self):
        # PR #26296 adds an7581-gemtek-common.dtsi + an7581-gemtek_xr1710g-ubi.dts.
        # Half-adopting them would leave two board trees; adopting them means
        # the rebase happened on purpose.
        for name in ("an7581-gemtek-common.dtsi",
                     "an7581-gemtek_xr1710g-ubi.dts"):
            self.assertFalse((AIROHA / "dts" / name).exists(),
                             "%s appeared: re-check the PR #26296 rebase row"
                             % name)

    def test_local_board_uses_its_own_dts(self):
        self.assertIn("DEVICE_DTS := an7581-xr1710g-ubi", read(AIROHA_MK))


class KernelTest(unittest.TestCase):
    """Rows 7, 8 and 9: baselines and where the 10G/998 patches live."""

    def test_baseline_is_618_with_74_testing(self):
        body = read(AIROHA / "Makefile")
        self.assertIn("KERNEL_PATCHVER:=6.18", body)
        # The testing slot is pinned to one version on purpose: PR #277
        # (edefd0f0cc) moved it from 7.3 to 7.4, and 7.3 is now only a
        # historical value. A future bump must fail this row once so the
        # checklist gets refreshed, instead of drifting silently.
        self.assertRegex(body, r"KERNEL_TESTING_PATCHVER:=7\.4")

    def test_10g_series_is_where_the_row_says(self):
        # 744 is a generic net-phy fix, 745/747/748/749 are airoha net-pcs ones.
        # Wrong placement means a kernel bump silently drops a fix.
        for kernel in ("6.18", "7.3", "7.4"):
            airoha = {p.name for p in (AIROHA / ("patches-" + kernel)).glob("74*")}
            for prefix in ("745", "746", "748", "749"):
                self.assertTrue(any(n.startswith(prefix) for n in airoha),
                                "patches-%s lost the %s 10G fix" % (kernel, prefix))
        for kernel in ("7.3", "7.4"):
            pending = REPO / "target/linux/generic" / ("pending-" + kernel)
            self.assertTrue(any(p.name.startswith("744-")
                                for p in pending.glob("744-*")),
                            "pending-%s lost 744, the RTL8261BE SerDes fix"
                            % kernel)
        # The deleted checklist said "744/747/748/749 are 7.3-only; 745 is also
        # carried in patches-6.18". Half of that is wrong at this HEAD: 748 and
        # 749 are in patches-6.18 too, while 744 is absent from pending-6.18.
        # So the 6.18 baseline has no SerDes reapply and gains 748/749 unwatched.
        self.assertFalse(any(p.name.startswith("744-")
                             for p in (REPO / "target/linux/generic/"
                                       "pending-6.18").glob("744-*")),
                         "744 was forward-ported to 6.18: refresh the 10G row")

    def test_998_still_hides_the_pinctrl_error(self):
        # The row says `998` is not upstreamable as-is. This asserts the debt is
        # still there, so nobody "converges" by quietly keeping it.
        patch = AIROHA / "patches-7.3/998-silence-PHY-LED-pinctrl-error.patch"
        self.assertTrue(patch.is_file())
        body = read(patch)
        self.assertIn("-	if (IS_ERR(pinctrl))", body)
        self.assertIn("Failed to setup PHY LED pinctrl", body)


class FirmwareTest(unittest.TestCase):
    """Row 10: the NPU blobs in-tree are the local v0.8, not upstream's."""

    def test_blobs_match_the_recorded_v08(self):
        import hashlib
        for name, (size, sha) in NPU_BLOBS.items():
            path = BLOB_DIR / name
            self.assertTrue(path.is_file(), "%s is gone" % name)
            self.assertEqual(path.stat().st_size, size,
                             "%s changed size: re-check the v0.8 row" % name)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), sha,
                             "%s changed content: re-check the v0.8 row" % name)

    def test_package_reads_the_local_files(self):
        body = read(REPO / "package/firmware/linux-firmware/airoha.mk")
        self.assertIn("./files/airoha/en7581_MT7996_npu_rv32.bin", body,
                      "the local MT7996 package no longer overrides upstream")


class ForkTest(unittest.TestCase):
    """Rows 11 and 12: the mt76 base and the U-Boot patch are the fork's."""

    def test_mt76_is_still_the_fork_base(self):
        body = read(MT76_MK)
        for token in ("PKG_SOURCE_URL:=%s" % LOCAL_MT76[0],
                      "PKG_SOURCE_DATE:=%s" % LOCAL_MT76[1],
                      "PKG_SOURCE_VERSION:=%s" % LOCAL_MT76[2]):
            self.assertIn(token, body,
                          "mt76 base changed: %r gone, upstream is %s"
                          % (token, UPSTREAM_MT76))
        self.assertNotIn("PKG_SOURCE_URL:=%s" % UPSTREAM_MT76[0], body)

    def test_uboot_carries_999_and_not_the_pr_patch(self):
        names = {p.name for p in UBOOT_PATCHES.iterdir()}
        self.assertIn("999-airoha-add-gemtek-xr1710g.patch", names)
        self.assertFalse(any(n.startswith("403-") for n in names),
                         "403-ad-gemtek-xr1710g.patch appeared: the U-Boot row "
                         "needs its rebase recorded")


class BoardTest(unittest.TestCase):
    """Rows 13 and 14: the compat gate and the fan case arm."""

    def test_compat_gate_is_declared_twice(self):
        self.assertIn("DEVICE_COMPAT_VERSION := 2.0", read(AIROHA_MK),
                      "the device lost its compat gate")
        body = read(COMPAT)
        self.assertIn("gemtek,xr1710g-ubi", body,
                      "05_compat-version no longer covers XR1710G")

    def test_fan_init_has_the_xr_case(self):
        self.assertIn("gemtek,xr1710g-ubi", read(FAN_INIT),
                      "the fan init lost its XR1710G case arm")


class DocsTest(unittest.TestCase):
    """Row 15: the deleted prose did not come back."""

    def test_no_docs_tree_and_no_upstream_checklist(self):
        self.assertFalse((REPO / "docs").exists(), "docs/ came back")
        self.assertFalse((REPO / ".github/upstream").exists(),
                         ".github/upstream came back; the judge is this file")
        self.assertFalse(
            (REPO / ".github/upstream/openwrt-pr-26296.md").exists(),
            "the removed checklist was restored as prose")


class UpstreamSnapshotTest(unittest.TestCase):
    """The online half of the checklist. Skipped without
    OPENWRT_PR_26296_ONLINE=1; the URLs are in OPEN_QUESTIONS."""

    ONLINE = os.environ.get("OPENWRT_PR_26296_ONLINE") == "1"

    def gh(self, *args):
        return subprocess.run(["gh"] + list(args), capture_output=True,
                              universal_newlines=True)

    def test_pr_26296_state(self):
        if not self.ONLINE:
            self.skipTest("needs network; see OPEN_QUESTIONS: %s"
                          % OPEN_QUESTIONS[0])
        self.assertIn('"number":26296', self.gh(
            "pr", "view", "26296", "--repo", "openwrt/openwrt",
            "--json", "number").stdout)

    def test_local_patches_6_18_lag_is_the_recorded_one(self):
        # The 2026-11-15 checklist assumed the local 6.18 set was upstream's
        # copy plus 7.3 forward-ports. Measured against main at
        # UPSTREAM_MAIN_SHA it is the other way round: main has 14 patches this
        # tree does not carry, so the local baseline lags, it does not lead.
        # Pinned so the lag cannot grow unnoticed.
        if not self.ONLINE:
            self.skipTest("needs network; see OPEN_QUESTIONS[5]")
        listing = self.gh("api", "repos/openwrt/openwrt/contents/"
                          "target/linux/airoha/patches-6.18?ref=main",
                          "--jq", ".[].name").stdout.split()
        local = {p.name for p in (AIROHA / "patches-6.18").iterdir()}
        missing = sorted(set(listing) - local)
        self.assertEqual(missing, sorted(UPSTREAM_LAG_6_18),
                         "the airoha/patches-6.18 lag changed; re-run the "
                         "convergence rows against upstream main")


if __name__ == "__main__":
    unittest.main()
