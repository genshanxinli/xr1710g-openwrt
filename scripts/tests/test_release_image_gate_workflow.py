#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The image tier must exist, and must not be a permanently red job.

`.github/workflows/check-release-image-features.yml` used to run the gate with
`--skip-build --skip-image` on push and `workflow_dispatch` -- that is the
source half only, so the "974/968 are in the *image*" criterion (#101) was
never checked anywhere in CI.  The workflow now has two tiers, and this test
keeps them apart:

  | # | property                                                      | why                        |
  |---|---------------------------------------------------------------|----------------------------|
  | 1 | one step runs the gate with --skip-build --skip-image          | the fast tier stays fast   |
  | 2 | one step runs the gate with neither, plus --build-dir/-image-dir | the image is read          |
  | 3 | the image step is reachable from schedule/workflow_dispatch    | a job no event starts is   |
  |   |                                                               | still a no-op              |
  | 4 | it runs on ${{ vars.XR1710G_BUILD_RUNNER }}, and skips when unset | ubuntu-latest has no bin/  |
  | 5 | its checkout has clean: false                                  | git clean would delete the |
  |   |                                                               | tree it is checking        |
  | 6 | missing build_dir/bin fails loudly, it does not pass           | a silent SKIP is the       |
  |   |                                                               | original defect            |
  | 7 | every path that gates the push also gates the PR               | a PR that touches          |
  |   |                                                               | patches-*/ was not gated   |
  |   |                                                               | by this file at all (#P1-1)|

Run from the repository root:

    python3 scripts/tests/test_release_image_gate_workflow.py
"""

import copy
import re
import unittest
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github/workflows/check-release-image-features.yml"
# The path, not the basename: scripts/tests/check-release-image-features.py is
# the self-test and must not be mistaken for the gate itself.
GATE = "scripts/check-release-image-features.py"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def gate_steps(data: dict) -> list[tuple[str, dict]]:
    """(job name, step) for every step that runs the release-image gate."""
    return [
        (name, step)
        for name, job in data["jobs"].items()
        for step in job.get("steps", [])
        if GATE in (step.get("run") or "")
    ]


def path_filter_problems(data: dict) -> list[str]:
    """Paths that gate the push but not the PR.

    The PR list may be a superset of the push list (a PR can run a gate the
    branch push does not), but never a subset: a path that only re-runs on merge
    is a gate the PR passed by not being asked.
    """
    triggers = data.get("on") or data.get(True)
    push = set(triggers["push"]["paths"])
    pr = set(triggers["pull_request"]["paths"])
    return sorted(push - pr)


def without_pr_path(text: str, path: str) -> str:
    """Delete one entry from the pull_request paths list, leaving push alone."""
    start = text.index("  pull_request:")
    end = text.index("\n  push:", start)
    block = text[start:end]
    return text[:start] + block.replace("      - '%s'\n" % path, "", 1) + text[end:]


class TierTest(unittest.TestCase):
    def setUp(self):
        self.data = load()

    def test_triggers_include_schedule_and_dispatch(self):
        triggers = self.data.get("on") or self.data.get(True)
        self.assertIn("schedule", triggers, "the image tier needs a periodic chance to run")
        self.assertIn("workflow_dispatch", triggers)
        self.assertIn("pull_request", triggers, "the source tier must still run on PRs")

    def test_fast_tier_skips_build_and_image(self):
        fast = [
            (name, step)
            for name, step in gate_steps(self.data)
            if "--skip-image" in step["run"]
        ]
        self.assertEqual(len(fast), 1, "expected exactly one fast-tier gate step")
        self.assertIn("--skip-build", fast[0][1]["run"])

    def test_image_tier_reads_the_build_tree_and_the_image(self):
        full = [
            (name, step)
            for name, step in gate_steps(self.data)
            if "--skip-image" not in step["run"] and "--skip-build" not in step["run"]
        ]
        self.assertEqual(len(full), 1, "expected exactly one image-tier gate step")
        run = full[0][1]["run"]
        self.assertIn("--build-dir", run)
        self.assertIn("--image-dir", run)

    def test_image_tier_is_reachable_and_gated_on_a_builder(self):
        full_job = next(
            name
            for name, step in gate_steps(self.data)
            if "--skip-image" not in step["run"] and "--skip-build" not in step["run"]
        )
        job = self.data["jobs"][full_job]
        condition = str(job.get("if", ""))
        self.assertIn("vars.XR1710G_BUILD_RUNNER != ''", condition)
        self.assertIn("schedule", condition)
        self.assertIn("workflow_dispatch", condition)
        self.assertIn(
            "vars.XR1710G_BUILD_RUNNER",
            str(job["runs-on"]),
            "the image tier must run on the builder, not on a runner without bin/",
        )

    def test_image_tier_keeps_its_build_tree(self):
        full_job = next(
            name
            for name, step in gate_steps(self.data)
            if "--skip-image" not in step["run"] and "--skip-build" not in step["run"]
        )
        checkouts = [
            step
            for step in self.data["jobs"][full_job]["steps"]
            if "checkout" in (step.get("uses") or "")
        ]
        self.assertTrue(checkouts, "the image tier needs a checkout of this repo")
        for step in checkouts:
            self.assertIs(
                step.get("with", {}).get("clean"),
                False,
                "actions/checkout runs `git clean -ffdx` by default and would delete "
                "build_dir/ and bin/ -- the artifacts this job exists to read",
            )

    def test_missing_tree_fails_instead_of_passing(self):
        full_job = next(
            name
            for name, step in gate_steps(self.data)
            if "--skip-image" not in step["run"] and "--skip-build" not in step["run"]
        )
        steps = self.data["jobs"][full_job]["steps"]
        guard = [step for step in steps if "is missing on this runner" in (step.get("run") or "")]
        self.assertTrue(guard, "no guard step: a runner without the tree would run the gate "
                               "and fail with an unclear exit 3, or worse, pass")
        run = guard[0]["run"]
        self.assertIn("bin/targets/airoha/an7581", run)
        self.assertRegex(run, r'exit\s+"?\$?ok"?', "the guard must exit non-zero")

    def test_self_test_job_runs_both_suites(self):
        runs = [
            step.get("run", "")
            for job in self.data["jobs"].values()
            for step in job.get("steps", [])
        ]
        joined = "\n".join(runs)
        self.assertIn("scripts/tests/check-release-image-features.py", joined)
        self.assertIn("scripts/tests/test_release_image_gate_workflow.py", joined)

    def test_pr_and_push_path_filters_agree(self):
        self.assertEqual(
            path_filter_problems(self.data), [],
            "a path that gates the push does not gate the PR: %r"
            % (path_filter_problems(self.data),),
        )

    def test_dropping_a_pr_path_turns_it_red(self):
        # Same file, one filter removed from the PR trigger: the check must
        # notice, or it would pass on a list it never compared.
        path = "target/linux/airoha/patches-*/**"
        mutated = without_pr_path(WORKFLOW.read_text(encoding="utf-8"), path)
        self.assertNotEqual(mutated, WORKFLOW.read_text(encoding="utf-8"),
                            "the PR paths filter %r was not in the PR block" % path)
        self.assertIn(path, path_filter_problems(yaml.safe_load(mutated)),
                      "the check stayed green with the PR filter deleted")

    def test_a_pr_superset_stays_green(self):
        data = copy.deepcopy(self.data)
        triggers = data.get("on") or data.get(True)
        triggers["pull_request"]["paths"].append("target/linux/airoha/dts/**")
        self.assertEqual(path_filter_problems(data), [],
                         "a path that only runs on the PR is allowed")


if __name__ == "__main__":
    unittest.main()
