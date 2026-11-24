#!/usr/bin/env python3
"""Gate on the release's distfeeds asset: it must never vanish silently.

Issue #6: the release job listed distfeeds.tar.gz but ran with
``fail_on_unmatched_files: false`` and skipped the packing step when bin/ was
empty, so a release could ship without any feeds and still look green.  A
device then had no way to `apk add` anything that was not already in the
image.  These tests pin the properties of the fix:

  a. the release actually demands its files (``fail_on_unmatched_files: true``);
  b. the pack step builds the tree and asserts the tarball exists;
  c. every ``files:`` block lists ``distfeeds.tar.gz`` -- the asset this file is
     about; ``fail_on_unmatched_files`` alone guards whatever is listed, so
     deleting the tarball from the list would disable the guard it feeds;
  d. ``build-distfeeds.sh --emit-build-patch`` stays byte-stable;
  e. flipping (a) back to ``false`` or dropping the tarball from ``files:``
     makes this suite red.

(d) is the reason no patch file is stored in this tree.  The hunk targets
``.github/workflows/build.yml`` in the separate genshanxinli/xr1710g-builds
repo, which this tree cannot see, so a stored copy would rot unnoticed; the
sha256 constant below is the reproducibility evidence instead.  When the
heredoc moves, this test fails and the handoff is re-checked with
``git apply --check`` in the build repo.

Runs with the standard library alone (no PyYAML on build hosts):

    python3 -m unittest scripts/tests/test_distfeeds_gate.py
"""

import hashlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "github-release.yml"
SCRIPT = REPO_ROOT / "scripts" / "build-distfeeds.sh"

# sha256 of `sh scripts/build-distfeeds.sh --emit-build-patch`, byte-identical
# to the docs/packaging/xr1710g-builds-build.yml.patch that 34fa6cf5ee deleted
# with the docs tree.  Re-derive with: sh scripts/build-distfeeds.sh \
#   --emit-build-patch | sha256sum
BUILD_PATCH_SHA256 = "8fda431295a4c28d9913bab6485e51e5be243955a6121e1d913105c0879b0bd1"


def distfeeds_step(text):
    """The body of the `Pack distfeeds` step, or "" when the step is gone."""
    lines = text.splitlines()
    start = next(
        (i for i, line in enumerate(lines)
         if line.strip() == "- name: Pack distfeeds"),
        None,
    )
    if start is None:
        return ""
    body = []
    for line in lines[start + 1:]:
        if re.match(r"^      - ", line):
            break
        body.append(line)
    return "\n".join(body)


def asset_lists(text):
    """Every `files:` list in the workflow, as lists of entries."""
    out, current, indent = [], None, 0
    for line in text.splitlines():
        if re.match(r"^\s*files:\s*\|", line):
            current, indent = [], len(line) - len(line.lstrip())
            out.append(current)
            continue
        if current is None:
            continue
        if not line.strip():
            continue
        if len(line) - len(line.lstrip()) <= indent:
            current = None
            continue
        current.append(line.strip())
    return out


def workflow_problems(text):
    """Every reason the release could ship without its feeds.

    A function over text rather than over the file so the negative test can
    feed it a mutated copy instead of touching the real workflow.
    """
    problems = []
    wanted = re.findall(r"^\s*fail_on_unmatched_files:\s*(\S+)\s*$", text,
                        re.MULTILINE)
    if not wanted or any(value != "true" for value in wanted):
        problems.append(
            "fail_on_unmatched_files is %r, not `true` on every release step: an "
            "absent distfeeds.tar.gz is dropped from the release without failing"
            % (wanted,))

    # Both tiers list the tarball in `files:`.  `fail_on_unmatched_files` only
    # guards the entries that are there, so dropping the tarball itself would
    # take the guard away without touching the flag this file pins.
    lists = asset_lists(text)
    if not lists:
        problems.append("no `files:` block lists the release assets")
    for entries in lists:
        if "distfeeds.tar.gz" not in entries:
            problems.append(
                "a `files:` block does not list distfeeds.tar.gz (%r): the feed "
                "tarball is what this gate exists for" % (entries,))

    step = distfeeds_step(text)
    if not step:
        problems.append("no `Pack distfeeds` step")
    elif "build-distfeeds.sh distfeeds" not in step:
        problems.append("`Pack distfeeds` does not build the feed tree")
    elif "test -s distfeeds.tar.gz" not in step:
        problems.append("`Pack distfeeds` does not assert the tarball exists")
    return problems


class DistfeedsGate(unittest.TestCase):
    def test_release_refuses_to_publish_without_feeds(self):
        self.assertEqual(workflow_problems(WORKFLOW.read_text()), [])

    def test_build_patch_is_byte_stable(self):
        patch = subprocess.run(
            ["sh", str(SCRIPT), "--emit-build-patch"],
            check=True, capture_output=True).stdout
        self.assertEqual(hashlib.sha256(patch).hexdigest(),
                         BUILD_PATCH_SHA256)

    def test_gate_turns_red_when_the_asset_may_vanish(self):
        text = WORKFLOW.read_text()
        mutated = text.replace("fail_on_unmatched_files: true",
                               "fail_on_unmatched_files: false")
        self.assertNotEqual(mutated, text,
                            "workflow no longer sets the flag to true")
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "github-release.yml"
            copy.write_text(mutated)
            self.assertTrue(workflow_problems(copy.read_text()),
                            "gate stayed green with a droppable asset")

    def test_gate_turns_red_when_the_feeds_are_not_listed(self):
        text = WORKFLOW.read_text()
        mutated = text.replace("            distfeeds.tar.gz\n", "", 1)
        self.assertNotEqual(mutated, text,
                            "workflow no longer lists distfeeds.tar.gz")
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "github-release.yml"
            copy.write_text(mutated)
            self.assertTrue(workflow_problems(copy.read_text()),
                            "gate stayed green with the feeds left out of "
                            "`files:`")


if __name__ == "__main__":
    unittest.main()
