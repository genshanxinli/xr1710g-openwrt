#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The PPE meter switch must stay writable at run time (issue #351).

airoha_ppe_meter is a measurement switch, not a security boundary: it is
opt-in (default N), and turning it on only lets tc police flows reach the
PPE/QDMA meter groups.  While it was declared 0444 every measurement needed
a custom image with bootargs-append, because the only way to set it was the
kernel command line.  These assertions read the patch and look at the line it
leaves behind, so a later edit cannot silently put the read-only mode back.

Set PPE_METER_PARAM_PATCH to a copy of the 7.4 patch to run the red proof
against a damaged copy (the copy puts 0444 back).
"""

import os
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PATCH_74 = Path(
    os.environ.get(
        "PPE_METER_PARAM_PATCH",
        REPO_ROOT
        / "target/linux/airoha/patches-7.4"
        / "989-net-airoha-add-an-opt-in-per-flow-PPE-meter.patch",
    )
)
WRITABLE = "module_param(airoha_ppe_meter, bool, 0644);"
READ_ONLY = "module_param(airoha_ppe_meter, bool, 0444);"


def post_image(text):
    """The lines the hunks leave behind: context and additions."""
    lines = []
    for line in text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
        elif line.startswith(" "):
            lines.append(line[1:])
    return lines


class PpeMeterParamWritable(unittest.TestCase):
    def test_param_declared_writable(self):
        lines = post_image(PATCH_74.read_text())
        decls = [l for l in lines if "module_param(airoha_ppe_meter" in l]

        self.assertEqual(
            decls,
            [WRITABLE],
            "the 7.4 PPE meter patch must declare airoha_ppe_meter 0644, "
            "exactly once (0444 makes every measurement need a custom image)",
        )

    def test_no_read_only_decl_left(self):
        lines = post_image(PATCH_74.read_text())
        read_only = [l for l in lines if l == READ_ONLY]

        self.assertEqual(read_only, [], "0444 is back: the switch would only be "
                         "settable from the kernel command line again")


if __name__ == "__main__":
    unittest.main()
