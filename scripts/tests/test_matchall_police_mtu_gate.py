#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression guards for the matchall police mtu gate (issue #341).

airoha_tc_matchall_act_validate() refused a police action whenever
act->police.mtu was set.  act_police fills tcfp_mtu with ~0 or the rate-table
cell size before the action is stored, so the term is true for every action tc
can build and matchall police never reached airoha_qdma_set_rx_meter().  The
fix is a patch, not code in this tree, so these assertions read the patch and
look at the file it leaves behind: context and '+' lines are the post-image,
'-' lines are the removed old image.

Set MATCHALL_POLICE_PATCH to a copy of the 7.4 patch to run the red proof
against a damaged copy (the copy puts the mtu term back).
"""

import os
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PATCH_74 = Path(
    os.environ.get(
        "MATCHALL_POLICE_PATCH",
        REPO_ROOT
        / "target/linux/airoha/patches-7.4"
        / "99992-net-airoha-let-the-tc-matchall-police-reach-the-rx-meter.patch",
    )
)
PATCH_73 = (
    REPO_ROOT
    / "target/linux/airoha/patches-7.3"
    / "99992-net-airoha-let-the-tc-matchall-police-reach-the-rx-meter.patch"
)
CONDITION = "if (act->police.peakrate_bytes_ps || act->police.avrate ||"
MESSAGE = '"peakrate/avrate/overhead police is not supported"'


def post_image(text):
    """The lines the hunk leaves behind: context and additions."""
    lines = []
    for line in text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
        elif line.startswith(" "):
            lines.append(line[1:])
    return "\n".join(lines)


def removed_lines(text):
    return [
        line[1:]
        for line in text.splitlines()
        if line.startswith("-") and not line.startswith("---")
    ]


class MatchallPoliceMtuGate(unittest.TestCase):
    def assert_patch_drops_mtu(self, path):
        text = path.read_text()
        post = post_image(text)

        self.assertIn(
            CONDITION,
            post,
            f"{path}: the matchall guard must keep the peakrate/avrate terms",
        )
        self.assertIn(
            "act->police.overhead) {",
            post,
            f"{path}: the matchall guard must end after act->police.overhead",
        )
        self.assertNotIn(
            "act->police.mtu",
            post,
            f"{path}: the matchall guard still tests act->police.mtu; "
            "act_police makes that term true for every police action",
        )
        self.assertIn(
            MESSAGE,
            post,
            f"{path}: the extack string must still name peakrate, which the "
            "matchall path refuses",
        )
        self.assertTrue(
            any("act->police.mtu" in line for line in removed_lines(text)),
            f"{path}: the patch is supposed to REMOVE the mtu term",
        )

    def test_74_patch_drops_mtu_from_the_matchall_guard(self):
        self.assert_patch_drops_mtu(PATCH_74)

    def test_73_patch_drops_mtu_from_the_matchall_guard(self):
        self.assert_patch_drops_mtu(PATCH_73)

    def test_putting_mtu_back_turns_the_check_red(self):
        # Use 7.3 so the red proof still runs when MATCHALL_POLICE_PATCH
        # points the 7.4 test at a damaged copy.
        text = PATCH_73.read_text()
        mutated = text.replace(
            "+\t    act->police.overhead) {",
            "+\t    act->police.overhead || act->police.mtu) {",
        )
        self.assertNotEqual(
            text, mutated, "the red proof no longer matches the added guard"
        )
        with self.assertRaises(AssertionError):
            self.assert_patch_drops_mtu_text(mutated)

    def assert_patch_drops_mtu_text(self, text):
        post = post_image(text)
        self.assertIn(CONDITION, post)
        self.assertIn("act->police.overhead) {", post)
        self.assertNotIn("act->police.mtu", post)
        self.assertIn(MESSAGE, post)


if __name__ == "__main__":
    unittest.main()
