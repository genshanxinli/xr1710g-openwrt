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

This test pins the six properties that keep the two tiers honest:

  | # | property                                                   | why                          |
  |---|------------------------------------------------------------|------------------------------|
  | 1 | a step fetches BUILDS_REPO's release assets                 | nothing else supplies bin/   |
  | 2 | that step cannot fail quietly (no `|| true`, no            | a swallowed 404 is a release |
  |   | `continue-on-error`), and it reports `::error::` + exit 1   | with no feeds                |
  | 3 | `fail_on_unmatched_files` is exactly `true` on every        | #320's gate, not regressed   |
  |   | release step                                                |                              |
  | 4 | the pack step still asserts `test -s distfeeds.tar.gz`     | idem                         |
  | 5 | tier 1's checkout passes `clean: false`                     | the default `git clean      |
  |   |                                                             | -ffdx` deletes the bin/ it  |
  |   |                                                             | is about to pack (#P0-1)    |
  | 6 | tier 2 publishes the tarball it verified, or fails loudly   | a green job that releases   |
  |   |                                                             | nothing (#P0-2)             |

Each of the six is also proven by mutation: a bad copy of the same file must be
reported, so a future edit that deletes the fetch, the publish step, or the
`clean: false`, or flips a flag, cannot leave this file green
(`test_*_turns_red`).

The workflow under test is `$XR1710G_RELEASE_WORKFLOW` when set, else this
repo's.  The path is printed on import, because a red proof that silently read
the real file instead of the bad copy would report the opposite of the truth.

Run from the repository root:

    python3 scripts/tests/test_release_ci_products.py
    XR1710G_RELEASE_WORKFLOW=/tmp/bad.yml python3 scripts/tests/test_release_ci_products.py
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
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
    if not wanted or any(value != "true" for value in wanted):
        found.append(
            "fail_on_unmatched_files is %r, not `true` on every release step: an "
            "absent distfeeds.tar.gz is dropped from the release without failing"
            % (wanted,))

    if "test -s distfeeds.tar.gz" not in text:
        found.append("nothing asserts the packed tarball exists "
                     "(`test -s distfeeds.tar.gz`)")

    if "vars.XR1710G_BUILD_RUNNER" not in text:
        found.append("tier 1 is not gated on vars.XR1710G_BUILD_RUNNER, so it "
                     "runs where bin/ cannot exist")

    # P0-1: the tier only exists to pack the bin/ that the previous `make` left
    # in the workspace, and actions/checkout cleans with `git clean -ffdx`
    # unless told otherwise -- it would delete its own input before packing it.
    if not cleans_nothing(text):
        found.append(
            "tier 1's checkout does not pass `clean: false`: the default "
            "`git clean -ffdx` deletes the bin/ the job is about to pack (#P0-1)")

    # P0-2: tier 2 verified the published feeds, wrote distfeeds.tar.gz and then
    # let it die with the runner -- a tag push went green and published nothing.
    if not publishes_or_fails(text):
        found.append(
            "tier 2 verified the feeds, wrote distfeeds.tar.gz, and released "
            "nothing: neither a release step nor an explicit failure (#P0-2)")

    # P1-8a: `git rev-parse --short HEAD` yields 7 chars on depth-1 checkouts
    # and 10+ chars on full clones, mismatching `distfeeds-<sha>.tar.gz`.
    for name, body in fetch:
        shell_lines = "\n".join(
            line for line in body.splitlines()
            if not line.lstrip().startswith("#")
        )
        if re.search(r"\brev-parse\b[^\n]*--short\b", shell_lines):
            found.append(
                "`%s` uses depth-dependent `git rev-parse --short`, which "
                "yields 7 chars on shallow checkouts vs 10 on full clones (#P1-8)"
                % name)
        if not re.search(r"\bgit\s+rev-parse\s+HEAD\b", shell_lines):
            found.append(
                "`%s` does not resolve the full 40-char commit via "
                "`git rev-parse HEAD` (#P1-8)" % name)

    # P1-8b: workflow_dispatch runs on a branch ref, so softprops/action-gh-release
    # fails without an explicit tag_name input wired into every release step.
    if has_workflow_dispatch(text):
        dispatch = workflow_dispatch_block(text)
        if not re.search(r"^\s*tag_name:\s*$", dispatch, re.MULTILINE):
            found.append(
                "workflow_dispatch does not declare a `tag_name` input (#P1-8)")
        elif not re.search(r"^\s*required:\s*true\s*$", dispatch, re.MULTILINE):
            found.append(
                "workflow_dispatch `tag_name` input is not `required: true` (#P1-8)")
        rel_steps = release_steps(text)
        if not rel_steps:
            found.append("no `action-gh-release` step found to receive `tag_name`")
        for rname, rbody in rel_steps:
            if not re.search(
                r"^\s*tag_name:\s*\$\{\{\s*inputs\.tag_name\b",
                rbody,
                re.MULTILINE,
            ):
                found.append(
                    "release step `%s` does not pass `tag_name` from "
                    "`inputs.tag_name` for workflow_dispatch (#P1-8)" % rname)
    return found


def has_workflow_dispatch(text):
    """True when the workflow enables manual workflow_dispatch runs."""
    return re.search(r"^  workflow_dispatch:", text, re.MULTILINE) is not None


def workflow_dispatch_block(text):
    """The `workflow_dispatch:` mapping under `on:`, or ""."""
    match = re.search(
        r"^  workflow_dispatch:[^\n]*\n(.*?)(?=^  \S|^\S|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    return match.group(0) if match else ""


def release_steps(text):
    """Every step in the workflow that invokes softprops/action-gh-release."""
    return [
        (name, body)
        for name, body in steps(text)
        if "action-gh-release" in body
    ]


def fetch_python_snippet(text):
    """Extract the embedded `<<'PY' ... PY` asset selector from the fetch step."""
    fetch = fetch_steps(text)
    if not fetch:
        return ""
    body = fetch[0][1]
    match = re.search(r"<<'PY'[^\n]*\n(.*?)^\s*PY\s*$", body,
                      re.MULTILINE | re.DOTALL)
    return textwrap.dedent(match.group(1)) if match else ""


def local_tier(text):
    """The tier-1 job body: everything up to the next job key."""
    match = re.search(r"^  release:\n(.*?)(?=^  \S|\Z)", text,
                      re.MULTILINE | re.DOTALL)
    return match.group(0) if match else ""


def checkout_step(text):
    """The tier-1 Checkout step body, or ""."""
    for name, body in steps(local_tier(text)):
        if name == "Checkout":
            return body
    return ""


def cleans_nothing(text):
    """True only when the Checkout step itself passes `clean: false`.

    A substring search over the whole job body is satisfied by the `::error::`
    prose that mentions `clean: false?`, so the key has to be read where it
    lives: inside the Checkout step, as a key of its own.
    """
    return re.search(r"^\s*clean:\s*false\s*$", checkout_step(text),
                     re.MULTILINE) is not None


def feed_source_body(text):
    """The tier-2 job body, or "" when the job is gone."""
    match = re.search(r"^  feed-source:\n(.*?)(?=^  \S|\Z)", text,
                      re.MULTILINE | re.DOTALL)
    return match.group(0) if match else ""


def tier_two_release_step(text):
    """The tier-2 step that publishes released assets, or ""."""
    for _name, body in steps(feed_source_body(text)):
        if "action-gh-release" in body or "gh release create" in body:
            return body
    return ""


def publishes_or_fails(text):
    """Tier 2 either publishes what it verified, or fails loudly and says why.

    Both are acceptable products; a green job that does neither is not.  The
    "released nothing" arm has to find the `::error::`, the non-zero exit and
    the statement in one step: this job's fetch step already ends in `exit 1`
    with an `::error::`, so markers read from anywhere in the job would let a
    comment stand in for the failure.
    """
    for _name, step in steps(feed_source_body(text)):
        if "action-gh-release" in step or "gh release create" in step:
            return True
        if ("released nothing" in step and "::error::" in step
                and re.search(r"\bexit 1\b", step)):
            return True
    return False


def without_tier_two_release(text):
    """Drop tier 2's publish step (it is the job's last step)."""
    at = text.find("  feed-source:")
    if at < 0:
        return text
    head, tail = text[:at], text[at:]
    step = tail.find("      - name: Release\n")
    return head + tail[:step] if step >= 0 else text


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

    def test_tier_one_checkout_keeps_the_build_tree(self):
        """Tier 1's entire input is the bin/ a previous `make` left behind."""
        self.assertTrue(cleans_nothing(self.text),
                        "tier-1 checkout runs `git clean -ffdx` and deletes the "
                        "bin/ it is about to pack")

    def test_cleaning_the_tier_one_checkout_turns_it_red(self):
        copy = bad_copy(self.text,
                        lambda t: t.replace("          clean: false\n", "", 1))
        self.assertNotEqual(copy.read_text(), self.text,
                            "the tier-1 `clean: false` was not found")
        self.assertTrue(problems(copy.read_text()),
                        "gate stayed green with a checkout that cleans bin/ away")

    def test_tier_two_publishes_or_says_it_published_nothing(self):
        self.assertTrue(publishes_or_fails(self.text),
                        "tier 2 verified the feeds, wrote distfeeds.tar.gz, and "
                        "released nothing")

    def test_the_tier_two_release_step_ships_the_verified_tarball(self):
        step = tier_two_release_step(self.text)
        self.assertTrue(step, "no release step in the feed-source tier")
        self.assertIn("distfeeds.tar.gz", step,
                      "the published asset is the tarball the tier verified")
        self.assertIn("draft: true", step)
        self.assertIn("prerelease: true", step)
        self.assertIn("fail_on_unmatched_files: true", step)
        # Tier 2 has no bin/targets: listing those globs with
        # fail_on_unmatched_files: true would turn every tag push red.
        self.assertNotIn("bin/targets", step,
                         "tier 2 has no bin/targets; an unmatched glob there "
                         "fails the release")

    def test_deleting_the_tier_two_release_turns_it_red(self):
        copy = bad_copy(self.text, without_tier_two_release)
        self.assertNotEqual(copy.read_text(), self.text,
                            "the tier-2 release step was not found")
        self.assertFalse(publishes_or_fails(copy.read_text()),
                         "the check stayed green after deleting the publish step")
        self.assertTrue(problems(copy.read_text()),
                        "problems() stayed green with tier 2 publishing nothing")

    def test_fetch_matches_any_unambiguous_sha_prefix_lengths(self):
        snippet = fetch_python_snippet(self.text)
        self.assertTrue(snippet, "no embedded Python asset matcher found")
        full_sha = "83aeaa81234567890abcdef1234567890abcdef1"

        def run_matcher(assets, sha=full_sha):
            with tempfile.TemporaryDirectory() as tmp:
                releases = [{"assets": assets}]
                (Path(tmp) / "releases.json").write_text(
                    json.dumps(releases), encoding="utf-8"
                )
                env = dict(os.environ)
                env["RUNNER_TEMP"] = tmp
                return subprocess.run(
                    [sys.executable, "-c", snippet, sha],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )

        # 7-char shallow-clone name matches full 40-char HEAD.
        r7 = run_matcher([
            {"name": "distfeeds-83aeaa8.tar.gz", "browser_download_url": "https://ex/7"}
        ])
        self.assertEqual(r7.returncode, 0, r7.stderr)
        self.assertEqual(r7.stdout.strip(), "https://ex/7")

        # 10-char full-clone name matches full 40-char HEAD.
        r10 = run_matcher([
            {"name": "distfeeds-83aeaa8123.tar.gz", "browser_download_url": "https://ex/10"}
        ])
        self.assertEqual(r10.returncode, 0, r10.stderr)
        self.assertEqual(r10.stdout.strip(), "https://ex/10")

        # Full 40-char name matches full 40-char HEAD.
        r40 = run_matcher([
            {"name": "distfeeds-%s.tar.gz" % full_sha, "browser_download_url": "https://ex/40"}
        ])
        self.assertEqual(r40.returncode, 0, r40.stderr)
        self.assertEqual(r40.stdout.strip(), "https://ex/40")

        # Unrelated SHA does not match.
        rmiss = run_matcher([
            {"name": "distfeeds-9999999.tar.gz", "browser_download_url": "https://ex/miss"}
        ])
        self.assertNotEqual(rmiss.returncode, 0, "unrelated SHA unexpectedly matched")

        # Prefix shorter than 7 hex chars is refused.
        rshort = run_matcher([
            {"name": "distfeeds-83ae.tar.gz", "browser_download_url": "https://ex/short"}
        ])
        self.assertNotEqual(rshort.returncode, 0, "too-short SHA prefix unexpectedly matched")

        # Ambiguous multiple matches fail loudly instead of picking silently.
        rambig = run_matcher([
            {"name": "distfeeds-83aeaa8.tar.gz", "browser_download_url": "https://ex/7"},
            {"name": "distfeeds-83aeaa8123.tar.gz", "browser_download_url": "https://ex/10"},
        ])
        self.assertNotEqual(rambig.returncode, 0, "ambiguous multi-match was not rejected")

    def test_reverting_to_short_sha_turns_it_red(self):
        copy = bad_copy(
            self.text,
            lambda t: t.replace("git rev-parse HEAD", "git rev-parse --short HEAD", 1),
        )
        self.assertNotEqual(copy.read_text(), self.text,
                            "`git rev-parse HEAD` not found in workflow")
        self.assertTrue(
            problems(copy.read_text()),
            "gate stayed green with depth-dependent `git rev-parse --short HEAD`",
        )

    def test_workflow_dispatch_passes_tag_name_to_every_release_step(self):
        self.assertTrue(has_workflow_dispatch(self.text))
        dispatch = workflow_dispatch_block(self.text)
        self.assertIn("tag_name:", dispatch)
        self.assertIn("required: true", dispatch)
        steps_list = release_steps(self.text)
        self.assertEqual(len(steps_list), 2, "expected both tier 1 and tier 2 release steps")
        for rname, rbody in steps_list:
            self.assertIn("tag_name: ${{ inputs.tag_name }}", rbody,
                          "release step %s missing tag_name wiring" % rname)

    def test_dropping_dispatch_tag_name_turns_it_red(self):
        copy = bad_copy(
            self.text,
            lambda t: re.sub(
                r"^  workflow_dispatch:\n(?:    .*\n)+",
                "  workflow_dispatch:\n",
                t,
                count=1,
                flags=re.MULTILINE,
            ),
        )
        self.assertNotEqual(copy.read_text(), self.text,
                            "workflow_dispatch inputs block not found")
        self.assertTrue(
            problems(copy.read_text()),
            "gate stayed green after dropping workflow_dispatch tag_name input",
        )

    def test_dropping_release_tag_name_turns_it_red(self):
        copy = bad_copy(
            self.text,
            lambda t: t.replace("          tag_name: ${{ inputs.tag_name }}\n", "", 1),
        )
        self.assertNotEqual(copy.read_text(), self.text,
                            "release step `tag_name` line not found")
        self.assertTrue(
            problems(copy.read_text()),
            "gate stayed green after dropping `tag_name` from a release step",
        )


if __name__ == "__main__":
    unittest.main()
