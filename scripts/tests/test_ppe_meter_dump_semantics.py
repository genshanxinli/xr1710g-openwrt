#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The ppe/meter dump carries two meanings that are easy to erase (issue #351).

`enabled=` prints ppe->meter_enabled, which is assigned once in
airoha_ppe_init() from the airoha_ppe_meter module parameter: it is the
value the parameter had when the module probed, not the live switch (the
gate that decides whether a police action is accepted reads the parameter
itself).  That snapshot is the only field that says whether the image that
booted had the meter on, so it must keep its meaning and say where the live
value lives.

`reg` is a read of FE + 0x200c + 16 * group, and hw_rate/hw_bucket are
derived from it.  On AN7581 that read returns 0xdeadbeef; the driver only
ever writes bits 2..18 there (TICK bit 2, RATE bits 16..3, BUCKET bits
18..17), so a word with bit 31 set cannot be that write coming back, and
the three register columns are not evidence of the rate the PPE holds.
They stay for comparison against a vendor SDK dump, which is only honest as
long as the comment says so.

Set PPE_METER_DUMP_PATCH to a copy of the 7.4 patch to run the red proof
against a damaged copy (the copy puts the old comment back).
"""

import os
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PATCH_74 = Path(
    os.environ.get(
        "PPE_METER_DUMP_PATCH",
        REPO_ROOT
        / "target/linux/airoha/patches-7.4"
        / "989-net-airoha-add-an-opt-in-per-flow-PPE-meter.patch",
    )
)

ENABLED_PRINT = 'seq_printf(m, "enabled=%u groups_total=%u\\n"'
SHOW_START = "/* Read-only view of the opt-in per-flow meters."
SHOW_END = "DEFINE_SHOW_ATTRIBUTE(airoha_ppe_debugfs_meter);"

ENABLED_MARKERS = (
    "probed",
    "probe-time snapshot",
    "/sys/module/airoha_eth/parameters/airoha_ppe_meter",
)
REGISTER_MARKERS = (
    "AN7581",
    "deadbeef",
    "bit 31",
    "cannot be that write coming back",
)
OLD_LIE = "the register value next to it is what the PPE"
GROUPS_MARKERS = ("groups_total= is AIROHA_PPE_METER_NUM",)


def post_image(text):
    """The lines the hunks leave behind: context and additions."""
    lines = []
    for line in text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
        elif line.startswith(" "):
            lines.append(line[1:])
    return lines


class PpeMeterDumpSemantics(unittest.TestCase):
    def body(self, path):
        return "\n".join(post_image(path.read_text()))

    def test_enabled_is_documented_as_a_probe_snapshot(self):
        body = self.body(PATCH_74)
        index = body.find(ENABLED_PRINT)
        self.assertNotEqual(index, -1, "the enabled= print is gone from 7.4")

        head = body[:index]
        block = head[head.rfind("/*") :]
        self.assertTrue(
            block.rstrip().endswith("*/"),
            "the enabled= print must be preceded by a comment block",
        )
        for marker in GROUPS_MARKERS:
            self.assertIn(
                marker, block,
                "groups= is the compile-time group count, not the free "
                "count: the field must say so and be named groups_total",
            )
        self.assertNotIn(
            "groups=%u", body,
            "the print still names a compile-time constant groups=",
        )

        for marker in ENABLED_MARKERS:
            self.assertIn(
                marker, block,
                f"the comment above enabled= must say {marker!r}: the field is "
                "the probe-time value of airoha_ppe_meter, and the live switch "
                "is the module parameter",
            )

    def test_register_columns_documented_as_untrusted_on_an7581(self):
        body = self.body(PATCH_74)
        start = body.find(SHOW_START)
        self.assertNotEqual(start, -1, "the meter dump's header comment is gone")
        end = body.find("*/", start)
        header = body[start:end]

        for marker in REGISTER_MARKERS:
            self.assertIn(
                marker, header,
                f"the dump's header comment must record {marker!r}: on AN7581 "
                "reg/hw_rate/hw_bucket are derived from a read that is not the "
                "value this driver wrote",
            )
        self.assertNotIn(
            OLD_LIE, body,
            "the comment still claims the register read is what the PPE "
            "actually holds; on AN7581 it is 0xdeadbeef",
        )


if __name__ == "__main__":
    unittest.main()
