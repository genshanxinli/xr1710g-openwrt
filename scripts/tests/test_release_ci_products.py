#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The release job must obtain the CI-built feeds, and must not be able to fake it.

#6: `.github/workflows/github-release.yml` ran on `ubuntu-latest`, where nothing
ever built the tree, so `scripts/build-distfeeds.sh` refused the empty `bin/` and
the first tag pushed would have gone red -- and the assets the release lists
(`bin/targets/**/*.itb`) cannot exist on a hosted runner at all.  The workflow is
now two tiers: pack from a local `bin/` on the builder named by
`vars.XR1710G_BUILD_RUNNER`, and otherwise fetch the release of
`genshanxinli/xr1710g-builds` for this commit and re-derive the feed tree from
it.  Both repos are public, so that fetch reads a release asset anonymously:
`actions/download-artifact` across repositories would need `actions:read` on the
other repo, i.e. a long-lived PAT.

This test pins the four properties that keep the second tier honest:

  | # | property                                                   | why                          |
  |---|------------------------------------------------------------|------------------------------|
  | 1 | a step fetches BUILDS_REPO's release assets                 | nothing else supplies bin/   |
  | 2 | that step cannot fail quietly (no `|| true`, no            | a swallowed 404 is a release |
  |   | `continue-on-error`), and it reports `::error::` + exit 1   | with no feeds                |
  | 3 | `fail_on_unmatched_files` is exactly `true`                | #320's gate, not regressed   |
  | 4 | the pack step still asserts `test -s distfeeds.tar.gz`     | idem                         |

Each of the four is also proven by mutation: a bad copy of the same file must be
reported, so a future edit that deletes the fetch or flips a flag cannot leave
this file green (`test_*_turns_red`).

The workflow under test is `$XR1710G_RELEASE_WORKFLOW` when set, else this
repo's.  The path is printed on import, because a red proof that silently read
the real file instead of the bad copy would report the opposite of the truth.

Run from the repository root:

    python3 scripts/tests/test_release_ci_products.py
    XR1710G_RELEASE_WORKFLOW=/tmp/bad.yml python3 scripts/tests/test_release_ci_products.py
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
BUILDS_REPO = "genshanxinli/xr1710g-builds"
# The workflow names the repo through this variable; the slug itself only
# appears once, in the workflow-level env block.
REPO_VAR = "$BUILDS_REPO"

print("# test_release_ci_products parses %s" % WORKFLOW, file=sys.stderr)


def steps(text):
    """[(step name, body)] for every named step in the workflow."""
    out, name, body = [], None, []
    for line in text.splitlines():
        match = re.match(r"^      - name:\s*(\S.*?)\s*$", line)
        if match:
            out.append((name, "\n".join(body)))
            name, body = match.group(1), []
        elif name is not None:
            body.append(line)
    if name is not None:
        out.append((name, "\n".join(body)))
    return out


def fetch_steps(text):
    """Steps that read an asset out of BUILDS_REPO's releases."""
    return [
        (name, body)
        for name, body in steps(text)
        if REPO_VAR in body and "releases" in body and "curl" in body
    ]


def problems(text):
    """Every reason the release tier could publish without the CI-built feeds.

    A function over text rather than over the file so the red proofs can feed it
    a mutated copy instead of touching the real workflow.
    """
    found = []
    fetch = fetch_steps(text)
    if not fetch:
        found.append(
            "no step fetches %s's release assets: the job assumes a bin/ that "
            "a hosted runner does not have" % BUILDS_REPO)
    for name, body in fetch:
        for swallow in ("|| true", "|| :", "continue-on-error"):
            if swallow in body:
                found.append("`%s` swallows failures (%r)" % (name, swallow))
        if "::error::" not in body:
            found.append("`%s` fails without an ::error:: annotation" % name)
        if not re.search(r"\bexit 1\b", body):
            found.append("`%s` never exits non-zero itself" % name)

    if re.search(r"^\s*continue-on-error:\s*true\s*$", text, re.MULTILINE):
        found.append("a step is allowed to fail (continue-on-error: true)")

    wanted = re.findall(r"^\s*fail_on_unmatched_files:\s*(\S+)\s*$", text,
                        re.MULTILINE)
    if wanted != ["true"]:
        found.append(
            "fail_on_unmatched_files is %r, not `true`: an absent "
            "distfeeds.tar.gz is dropped from the release without failing"
            % (wanted,))

    if "test -s distfeeds.tar.gz" not in text:
        found.append("nothing asserts the packed tarball exists "
                     "(`test -s distfeeds.tar.gz`)")

    if "vars.XR1710G_BUILD_RUNNER" not in text:
        found.append("tier 1 is not gated on vars.XR1710G_BUILD_RUNNER, so it "
                     "runs where bin/ cannot exist")
    return found


def local_tier(text):
    """The tier-1 job body: everything up to the next job key."""
    match = re.search(r"^  release:\n(.*?)(?=^  \S)", text, re.MULTILINE | re.DOTALL)
    return match.group(0) if match else ""


def drop_step(text, name):
    """Remove one named step, body included."""
    lines = text.splitlines(keepends=True)
    start = next(
        (i for i, line in enumerate(lines)
         if line.strip() == "- name: %s" % name),
        None,
    )
    if start is None:
        return text
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^      - ", lines[i]) or re.match(r"^  \S", lines[i]):
            end = i
            break
    return "".join(lines[:start] + lines[end:])


def bad_copy(text, mutate):
    """Write a mutated copy and return its path, so tests read real bytes.

    The directory outlives the call on purpose: the red proofs read the file
    back from disk, which is the only way to catch "the test never looked at the
    copy it was given".
    """
    path = Path(tempfile.mkdtemp(prefix="release-bad-")) / "github-release.yml"
    path.write_text(mutate(text), encoding="utf-8")
    return path


class ReleaseTier(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_release_obtains_the_ci_build_output(self):
        self.assertEqual(problems(self.text), [])

    def test_the_fetch_is_the_only_thing_that_can_supply_bin(self):
        fetch = fetch_steps(self.text)
        self.assertEqual(len(fetch), 1, "expected exactly one fetch step")
        name, body = fetch[0]
        self.assertIn("api.github.com", body,
                      "the fetch must resolve the asset without a token")
        self.assertIn("tar -xzf", body, "the fetch must unpack the feed tree")
        self.assertIn("build-distfeeds.sh", self.text,
                      "the fetched tree must be re-derived, not just trusted")

    def test_tier_one_stays_on_the_builder(self):
        tier = local_tier(self.text)
        self.assertIn("vars.XR1710G_BUILD_RUNNER", tier)
        self.assertIn("vars.XR1710G_BUILD_RUNNER != ''", tier,
                      "tier 1 must skip, not fail, when there is no builder")

    def test_deleting_the_fetch_turns_it_red(self):
        copy = bad_copy(self.text,
                        lambda t: drop_step(t, "Fetch the build's distfeeds "
                                               "for this commit"))
        self.assertNotEqual(copy.read_text(), self.text, "step name changed")
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with no step fetching the feeds")

    def test_a_swallowed_failure_turns_it_red(self):
        copy = bad_copy(self.text, lambda t: t.replace(
            "      - name: Fetch the build's distfeeds for this commit\n",
            "      - name: Fetch the build's distfeeds for this commit\n"
            "        continue-on-error: true\n"))
        self.assertNotEqual(copy.read_text(), self.text, "step name changed")
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with the fetch on continue-on-error")

    def test_an_ignored_asset_turns_it_red(self):
        copy = bad_copy(self.text, lambda t: t.replace(
            'curl -fsSL --retry 3 -o "$RUNNER_TEMP/distfeeds.tar.gz" "$url" ||',
            'curl -fsSL --retry 3 -o "$RUNNER_TEMP/distfeeds.tar.gz" "$url" || true #'))
        self.assertNotEqual(copy.read_text(), self.text)
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with an || true on the download")

    def test_flag_flip_turns_it_red(self):
        copy = bad_copy(self.text, lambda t: t.replace(
            "fail_on_unmatched_files: true", "fail_on_unmatched_files: false"))
        self.assertNotEqual(copy.read_text(), self.text)
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with a droppable asset")

    def test_lost_tarball_assertion_turns_it_red(self):
        copy = bad_copy(self.text, lambda t: t.replace(
            "          test -s distfeeds.tar.gz\n", ""))
        self.assertNotEqual(copy.read_text(), self.text)
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green without `test -s distfeeds.tar.gz`")


if __name__ == "__main__":
    unittest.main()
