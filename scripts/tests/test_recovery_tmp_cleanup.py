#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""push_image() must clear /tmp/<image> and /tmp/<name> before it streams (#366).

The transfer itself was proved on the board (r38247+1-280fd1aabd): a 16 MB
stream commits at ``mv``, and a session killed three different ways never
created the final name.  What it did leave behind is the *original* name:

    interrupt           /tmp/openwrt-...-initramfs-recovery.itb
    after 16 MB         2999488 bytes (file size at the kill)
    after  5 MB          999488 bytes
    after 500 kB         2780600 bytes  -- not a stitched file, just one O_TRUNC

busybox ``tar -x`` truncates, so retries never splice two attempts together,
but nothing removes the partial file either: it sits in the device's tmpfs
next to #89's ``/tmp/no-client/result.json`` until the box reboots.  So every
attempt starts with ``rm -f`` on both names, and a pre-clean that fails must
abort the push instead of letting the following ``mv`` overwrite the residue
and make the run look clean.

These cases read the script and judge the shape of ``push_image()`` and of the
plan text that describes it.  ``RECOVERY_DRYRUN_UNDER_TEST`` names another
copy, which is how the red proof is taken:

    sed '/cannot clear a stale/d; /rm -f \\/tmp\\/\\$IMG_NAME/d' \\
        scripts/recovery-boot-dryrun.sh > /tmp/no-preclean.sh
    RECOVERY_DRYRUN_UNDER_TEST=/tmp/no-preclean.sh \\
        python3 scripts/tests/test_recovery_tmp_cleanup.py

The same variable is the one scripts/tests/test_recovery_transfer.py:47 uses,
so both files follow one convention.
"""

from __future__ import annotations

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("RECOVERY_DRYRUN_UNDER_TEST")
    or REPO_ROOT / "scripts/recovery-boot-dryrun.sh"
)

RM = re.compile(r"\brm\s+-f\b")
TAR = "tar -C \"$IMG_DIR\" -cf - \"$IMG_NAME\" |"
MV = "mv -f /tmp/$IMG_NAME /tmp/$NAME"
BOTH = ("/tmp/$IMG_NAME", "/tmp/$NAME")

# The delivered pre-clean, verbatim, so the red proofs below mutate exactly the
# lines they claim to mutate and nothing else.
PRECLEAN = (
    '\tssh "$HOST" "rm -f /tmp/$IMG_NAME /tmp/$NAME" || {\n'
    '\t\techo "cannot clear a stale /tmp/$IMG_NAME or /tmp/$NAME on $HOST" >&2\n'
    "\t\treturn $EXIT_IMAGE\n"
    "\t}"
)
SWALLOWED = '\tssh "$HOST" "rm -f /tmp/$IMG_NAME /tmp/$NAME" || true'


def push_image_body(text: str) -> str:
    """The text between ``push_image() {`` and its closing brace."""
    lines = text.splitlines()
    try:
        start = next(
            i for i, line in enumerate(lines) if re.match(r"^push_image\(\)\s*\{", line)
        )
    except StopIteration:  # a copy with the function renamed or deleted
        return ""
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start : end + 1])
    return ""


def plan_push_block(text: str) -> str:
    """The plan lines under step 1, up to step 2."""
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if "1. push the image" in line)
    except StopIteration:
        return ""
    for end in range(start + 1, len(lines)):
        if "2. prove the pushed bytes" in lines[end]:
            return "\n".join(lines[start:end])
    return ""


def preclean_problems(text: str) -> list[str]:
    """Everything wrong with how push_image() clears the device /tmp first."""
    body = push_image_body(text)
    if not body:
        return ["no push_image() in the script"]
    problems: list[str] = []

    rm_lines = [line for line in body.splitlines() if RM.search(line)]
    if not rm_lines:
        problems.append("push_image() has no rm -f before the tar stream")
        return problems

    rm_line = rm_lines[0]
    missing = [name for name in BOTH if name not in rm_line]
    if missing:
        problems.append("the pre-clean rm -f does not name %s" % " and ".join(missing))
    if not re.search(r"\|\|\s*\{", rm_line):
        problems.append(
            "the pre-clean rm -f is not guarded by a || { ... } that aborts on failure"
        )
    if re.search(r"\|\|\s*(true|:)\b", rm_line):
        problems.append("the pre-clean rm -f swallows its failure with || true")
    if re.search(r"\|\|\s*(true|:)\b", body):
        problems.append("push_image() swallows a failure with || true")

    if TAR not in body:
        problems.append("push_image() no longer streams tar over ssh")
    elif body.index(rm_line) > body.index(TAR):
        problems.append("the rm -f runs after the tar stream, so it cleans nothing")
    if MV not in body:
        problems.append("push_image() no longer commits with mv -f")

    if "return $EXIT_IMAGE" not in body:
        problems.append("a failed pre-clean does not return $EXIT_IMAGE")
    if not re.search(r"^EXIT_IMAGE=6$", text, re.M):
        problems.append("EXIT_IMAGE is not 6 in the script")
    return problems


def plan_problems(text: str) -> list[str]:
    """The plan text has to show the command that really runs (#366 lesson)."""
    block = plan_push_block(text)
    if not block:
        return ["the plan has no 'push the image' step"]
    problems: list[str] = []
    if "rm -f /tmp/$IMG_NAME /tmp/$NAME" not in block:
        problems.append("the plan never shows the pre-clean rm -f")
    if MV not in block:
        problems.append("the plan no longer shows the mv -f commit")
    if re.search(r"\bscp\b", block):
        problems.append("the plan still describes the scp transfer")
    return problems


class TmpCleanupTest(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text()

    def test_delivered_push_image_preclears_both_names(self):
        self.assertEqual([], preclean_problems(self.text))

    def test_delivered_plan_shows_the_preclean(self):
        self.assertEqual([], plan_problems(self.text))

    def test_copy_without_the_preclean_fails(self):
        """Red proof: drop the whole pre-clean and the judgement must turn red."""
        self.assertTrue(PRECLEAN in self.text, "the delivered pre-clean changed shape")
        stripped = self.text.replace(PRECLEAN + "\n", "")
        self.assertEqual(
            ["push_image() has no rm -f before the tar stream"],
            preclean_problems(stripped),
        )

    def test_copy_that_swallows_the_failure_fails(self):
        """Red proof: `|| true` must be caught, not accepted as a guard."""
        self.assertTrue(PRECLEAN in self.text, "the delivered pre-clean changed shape")
        weakened = self.text.replace(PRECLEAN, SWALLOWED)
        problems = preclean_problems(weakened)
        self.assertIn(
            "the pre-clean rm -f swallows its failure with || true",
            problems,
        )
        self.assertIn("push_image() swallows a failure with || true", problems)


class DeliveredScriptTest(unittest.TestCase):
    """Only meaningful when the file under test is the shipped script."""

    @unittest.skipIf(
        os.environ.get("RECOVERY_DRYRUN_UNDER_TEST"),
        "running against a copy, not the delivered script",
    )
    def test_function_names_the_exit_code_it_returns(self):
        text = SCRIPT.read_text()
        self.assertIn("EXIT_IMAGE=6", text)
        self.assertIn("return $EXIT_IMAGE", push_image_body(text))


if __name__ == "__main__":
    unittest.main()
