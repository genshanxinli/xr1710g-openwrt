#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard that every mt76 package patch has a unique numeric apply-order prefix.

OpenWrt applies package patches in ``LC_ALL=C`` lexical filename order.  When
two patches share the same leading numeric prefix (such as five ``0016-*``
patches or two ``0017-*`` patches), their relative apply order silently depends
on the English slug after the number, so renaming a slug or inserting a new
patch can reorder hunks without anyone noticing (issue #4).

Each ``*.patch`` under ``package/kernel/mt76/patches/`` must therefore carry a
unique numeric prefix (``NNNN-`` or sub-numbered ``NNNN-NN-``), and a bare
prefix ``NNNN`` must not coexist with sub-numbered ``NNNN-NN`` entries.

Red-green proof:
  * Set ``MT76_PATCHES_DIR_UNDER_TEST`` to a directory containing colliding
    prefixes (e.g. ``0016-a.patch`` and ``0016-b.patch``) or run against the
    pre-fix tree to observe the failure.
  * Run against the fixed ``package/kernel/mt76/patches/`` directory to observe
    the green run.

Run from the repository root:

    python3 -m unittest scripts/tests/test_mt76_patch_order.py
"""

import os
import re
import shutil
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PATCH_DIR = Path(
    os.environ.get(
        "MT76_PATCHES_DIR_UNDER_TEST",
        REPO / "package/kernel/mt76/patches",
    )
)

PREFIX_RE = re.compile(r"^(\d+(?:-\d+)*)-")


def find_prefix_issues(patch_dir: Path) -> list[str]:
    """Return human-readable errors for missing or colliding patch prefixes."""
    patches = sorted(p.name for p in patch_dir.glob("*.patch"))
    issues: list[str] = []
    if not patches:
        issues.append(f"no *.patch files found in {patch_dir}")
        return issues

    by_prefix: dict[str, list[str]] = defaultdict(list)
    by_major: dict[str, set[str]] = defaultdict(set)

    for name in patches:
        match = PREFIX_RE.match(name)
        if not match:
            issues.append(f"missing numeric prefix: {name}")
            continue
        prefix = match.group(1)
        major = prefix.split("-", 1)[0]
        by_prefix[prefix].append(name)
        by_major[major].add(prefix)

    for prefix, names in sorted(by_prefix.items()):
        if len(names) > 1:
            issues.append(
                f"duplicate numeric prefix {prefix!r}: {', '.join(names)}"
            )

    for major, prefixes in sorted(by_major.items()):
        if major in prefixes and len(prefixes) > 1:
            issues.append(
                f"mixed bare and sub-numbered prefix {major!r}: "
                f"{', '.join(sorted(prefixes))}"
            )

    return issues


class Mt76PatchOrderTest(unittest.TestCase):
    def test_mt76_patches_have_unique_numeric_prefixes(self):
        issues = find_prefix_issues(PATCH_DIR)
        self.assertEqual(
            issues,
            [],
            "mt76 patch numbering collisions/errors:\n  "
            + "\n  ".join(issues),
        )

    def test_detector_flags_duplicate_and_mixed_prefixes(self):
        tmp = Path(tempfile.mkdtemp(prefix="mt76-patch-order."))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "0016-first.patch").write_text("")
        (tmp / "0016-second.patch").write_text("")
        (tmp / "0017-bare.patch").write_text("")
        (tmp / "0017-01-sub.patch").write_text("")
        issues = find_prefix_issues(tmp)
        self.assertEqual(len(issues), 2)
        self.assertIn("duplicate numeric prefix '0016'", issues[0])
        self.assertIn("mixed bare and sub-numbered prefix '0017'", issues[1])


if __name__ == "__main__":
    unittest.main()
