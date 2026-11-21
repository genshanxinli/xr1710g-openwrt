#!/usr/bin/env python3
"""kmod-sched-flower must be packaged, and must imply CONFIG_NET_CLS_FLOWER.

issue #317: without cls_flower, "tc ... flower ... action police" cannot be
constructed, so patch 989's per-flow PPE meter path can never be exercised on
a real an7581.  The third test mutates a copy of target.mk and requires the
check to fail, so the test cannot pass on a tree where the package line has
been dropped again.
"""

import re
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET_MK = Path("target/linux/airoha/an7581/target.mk")
NETSUPPORT_MK = Path("package/kernel/linux/modules/netsupport.mk")
FLOWER = "kmod-sched-flower"


def default_packages(text):
    """Every token of every DEFAULT_PACKAGES += assignment."""
    lines = text.splitlines()
    packages = []
    for index, line in enumerate(lines):
        line = line.split("#", 1)[0].rstrip()
        if not line.startswith("DEFAULT_PACKAGES"):
            continue
        value = line.split("+=", 1)[1] if "+=" in line else ""
        while value.endswith("\\") and index + 1 < len(lines):
            index += 1
            value = value[:-1] + " " + lines[index].split("#", 1)[0]
        packages.extend(value.split())
    return packages


def sched_flower_kconfig(text):
    block = re.search(
        r"^define KernelPackage/sched-flower\n(.*?)^endef", text, re.M | re.S
    )
    if block is None:
        return None
    kconfig = re.search(r"^\s*KCONFIG:=(.*)$", block.group(1), re.M)
    return kconfig.group(1).strip() if kconfig else None


def packaged(root):
    return FLOWER in default_packages((root / TARGET_MK).read_text())


class TestFlowerPackaged(unittest.TestCase):
    def test_default_packages_contains_flower(self):
        self.assertIn(
            FLOWER,
            default_packages((ROOT / TARGET_MK).read_text()),
            f"{TARGET_MK} DEFAULT_PACKAGES must ship {FLOWER} (issue #317)",
        )

    def test_sched_flower_selects_net_cls_flower(self):
        self.assertEqual(
            sched_flower_kconfig((ROOT / NETSUPPORT_MK).read_text()),
            "CONFIG_NET_CLS_FLOWER",
            f"{NETSUPPORT_MK}: KernelPackage/sched-flower KCONFIG must be "
            "CONFIG_NET_CLS_FLOWER",
        )

    def test_removing_the_line_turns_the_check_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in (TARGET_MK, NETSUPPORT_MK):
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / rel, root / rel)
            mutated = (root / TARGET_MK).read_text().replace(" " + FLOWER, "")
            (root / TARGET_MK).write_text(mutated)
            self.assertFalse(
                packaged(root),
                "deleting the package from a copy of target.mk did not turn "
                "the check red; this test cannot detect a regression",
            )
        self.assertTrue(
            packaged(ROOT),
            f"{FLOWER} is missing from the real tree after the mutation test",
        )


if __name__ == "__main__":
    unittest.main()
