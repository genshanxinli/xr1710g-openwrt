#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The feed-source tier must carry the build's public key into the tree it publishes.

#362: `feed-source` unpacks `distfeeds-<sha>.tar.gz` into
`$RUNNER_TEMP/build/bin` with `--strip-components=1`, so the asset's
`public-key.pem` lands in `build/bin/`.  `scripts/build-distfeeds.sh` only reads
`$topdir/public-key.pem` (`TOPDIR=$RUNNER_TEMP/build`), and the copy under it is
guarded by `if [ -f ... ]`.  Nothing was printed, the re-derived tree came out
one file short, and the published feed could not be verified by any device --
the build's signing key is generated per build (`package/Makefile`).

The workflow has to move the key to the path the script reads, and a missing key
has to fail the job instead of skipping a copy.  This test pins both, plus the
order (after unpack, before the script runs):

  | # | property                                                     |
  |---|--------------------------------------------------------------|
  | 1 | a `cp` from `build/bin/public-key.pem` to `build/public-key.pem` |
  | 2 | that copy carries `||` and an `::error::` + `exit 1`          |
  | 3 | no `if [ -f ... public-key.pem ]` guard around it             |
  | 4 | the copy sits after `tar -xzf` and before `build-distfeeds.sh` |

(2) is also proven by mutation: a copy of the same file with the `|| { ... }`
dropped must be reported, so an edit that turns the red back into a silent
skip cannot leave this file green.

The workflow under test is `$XR1710G_RELEASE_WORKFLOW` when set, else this
repo's.  The path is printed on import, because a red proof that silently read
the real file instead of the bad copy would report the opposite of the truth.

Run from the repository root:

    python3 -m unittest scripts.tests.test_release_public_key
    XR1710G_RELEASE_WORKFLOW=/tmp/bad.yml python3 scripts/tests/test_release_public_key.py
"""

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOW = Path(
    os.environ.get("XR1710G_RELEASE_WORKFLOW")
    or REPO_ROOT / ".github" / "workflows" / "github-release.yml"
)
# The two paths the workflow has to reconcile: where --strip-components=1 puts
# the asset's key, and where scripts/build-distfeeds.sh looks for it.
UNPACKED_KEY = "$RUNNER_TEMP/build/bin/public-key.pem"
SCRIPT_KEY = "$RUNNER_TEMP/build/public-key.pem"

print("# test_release_public_key parses %s" % WORKFLOW, file=sys.stderr)


def feed_source(text):
    """The whole `feed-source` job body, or "" when the job is gone."""
    match = re.search(r"^  feed-source:\n(.*?)(?=^  \S|\Z)", text,
                      re.MULTILINE | re.DOTALL)
    return match.group(0) if match else ""


def key_move(text):
    """The shell statement that copies the key, continuations joined.

    The `||` that makes a missing key red sits on the continuation line, so a
    test that looked at single lines could not see it.
    """
    lines = feed_source(text).splitlines()
    for i, line in enumerate(lines):
        if "cp " not in line or "build/bin/public-key.pem" not in line:
            continue
        statement = [line]
        while statement[-1].rstrip().endswith("\\") and i + len(statement) < len(lines):
            statement.append(lines[i + len(statement)])
        return "\n".join(statement)
    return ""


def problems(text):
    """Every reason the tier could publish a feed without its key."""
    found = []
    job = feed_source(text)
    if not job:
        found.append("no feed-source job: the tier that re-derives the feed "
                     "from the build's asset is gone")
        return found

    move = key_move(text)
    if not move:
        found.append("nothing copies %s to %s: the re-derived tree loses the "
                     "key the feed is signed with (#362)" % (UNPACKED_KEY, SCRIPT_KEY))
    else:
        if SCRIPT_KEY not in move:
            found.append("the key is not copied to %s, which is the only path "
                         "build-distfeeds.sh reads" % SCRIPT_KEY)
        if "||" not in move:
            found.append("the key copy can fail quietly (no `||`): a missing "
                         "key must fail the job, not skip a file")
        if not re.search(r"\bexit 1\b", move):
            found.append("the key copy never exits non-zero itself")

    if re.search(r"if\s+\[\s+-f[^\]]*public-key\.pem", job):
        found.append("an `if [ -f ... public-key.pem ]` guard is back: a "
                     "missing key becomes a silent no-op again")

    errors = [line for line in job.splitlines() if "::error::" in line]
    if not errors:
        found.append("the job never prints an ::error:: annotation")
    elif not any("public-key.pem" in line for line in errors):
        found.append("no ::error:: annotation names public-key.pem")

    unpack = text.find("tar -xzf")
    if unpack < 0:
        found.append("nothing unpacks the asset (`tar -xzf`)")
    elif move:
        # The re-derive step, not a mention of the script in a comment: the
        # copy has to land before the step that runs it.
        derive = text.find("- name: Re-derive the published tree")
        copy_at = text.find(move.splitlines()[0].strip())
        if copy_at < unpack:
            found.append("the key is copied before the asset is unpacked")
        if derive >= 0 and copy_at > derive:
            found.append("the key is copied after build-distfeeds.sh already "
                         "ran, which is the defect: the script's own `if [ -f ]` "
                         "reads the old path")

    if 'TOPDIR="$RUNNER_TEMP/build"' not in text:
        found.append("the re-derive step no longer sets TOPDIR=$RUNNER_TEMP/build, "
                     "so this test's two paths no longer describe the run")
    return found


def bad_copy(text, mutate, name="github-release.yml"):
    """Write a mutated copy and return its path, so tests read real bytes.

    The directory outlives the call on purpose: the red proofs read the file
    back from disk, which is the only way to catch "the test never looked at the
    copy it was given".
    """
    path = Path(tempfile.mkdtemp(prefix="release-key-bad-")) / name
    path.write_text(mutate(text), encoding="utf-8")
    return path


class PublicKeyWiring(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_the_tier_moves_the_key_where_the_script_reads_it(self):
        self.assertEqual(problems(self.text), [])

    def test_a_missing_key_is_red_not_silent(self):
        move = key_move(self.text)
        self.assertIn("||", move)
        self.assertIn("::error::", move)

    def test_dropping_the_guard_turns_it_red(self):
        copy = bad_copy(self.text, lambda t: re.sub(
            r"\n\s*\|\| \{ echo \"::error::[^\n]*exit 1; \}", "", t, count=1))
        self.assertNotEqual(copy.read_text(), self.text,
                            "the `|| { ...; exit 1; }` block was not found")
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with a bare `cp` and no red on a "
                        "missing key")

    def test_an_if_guard_turns_it_red(self):
        # The original shape: only copy when the file is there, say nothing when
        # it is not.  Reinstating it must not pass.
        def mutate(text):
            return re.sub(
                r"cp \"%s\" \"%s\" \\\n\s*\|\| \{ echo \"::error::[^\n]*exit 1; \}"
                % (re.escape(UNPACKED_KEY), re.escape(SCRIPT_KEY)),
                'if [ -f "%s" ]; then\n            cp "%s" "%s"\n          fi'
                % (UNPACKED_KEY, UNPACKED_KEY, SCRIPT_KEY),
                text, count=1)

        copy = bad_copy(self.text, mutate)
        self.assertNotEqual(copy.read_text(), self.text, "the copy was not replaced")
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with `if [ -f ]` around the copy")


if __name__ == "__main__":
    unittest.main()
