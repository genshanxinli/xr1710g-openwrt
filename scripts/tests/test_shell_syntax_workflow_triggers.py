#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The shell-syntax job must run for every input its Python suite checks.

`.github/workflows/shell-syntax.yml` ends with
`python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, which runs the
full offline guard suite (including `test_release_cli_tools.py`,
`test_check_release_image_features.py`, `test_release_image_gate_workflow.py`,
`test_hostapd_log_noise.py`, `test_tr_busybox_operands.py`, kernel/DTS/config
guards, and `test_agents_md_references.py`), plus `check-shell-syntax.py`,
`check-test-cleanup-safety.py --strict-unknown`, and `check-uboot-ubi-volumes.py`.

Rather than comparing a hand-copied list of glob strings, this test evaluates
GitHub Actions glob matching against concrete tracked repository files for every
guarded input, pins that `push` is not wider than `pull_request`, pins the
`--strict-unknown` cleanup gate, and proves via `path_filter_problems()` that
dropping coverage for a guarded file turns red.

WORKFLOW_UNDER_TEST overrides the workflow path for red-green runs.

Run from the repository root:

    python3 -m unittest scripts.tests.test_shell_syntax_workflow_triggers
"""

import os
import re
import subprocess
import unittest
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = Path(
    os.environ.get("WORKFLOW_UNDER_TEST")
    or REPO_ROOT / ".github/workflows/shell-syntax.yml"
).resolve()

# Concrete tracked repository files that the workflow's checks and Python tests
# read.  Every entry here must exist AND be tracked in git, and must match at
# least one `paths:` pattern in both `pull_request` and `push`.  Non-.sh /
# non-Makefile runtime paths are chosen where possible so `**/*.sh` cannot mask
# a missing directory filter.
GUARDED_FILES = (
    ".github/workflows/shell-syntax.yml",
    ".github/workflows/check-release-image-features.yml",
    "config/Config-kernel.in",
    "include/kernel-defaults.mk",
    "package/base-files/files/lib/preinit/70_initramfs_test",
    "package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch",
    "package/firmware/linux-firmware/Makefile",
    "package/kernel/linux/modules/netsupport.mk",
    "package/kernel/mt76/Makefile",
    "package/luci-app-airoha-fancontrol/root/etc/init.d/fan",
    "package/luci-app-airoha-flowsense/Makefile",
    "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-domains-update",
    "package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/hostapd.uc",
    "package/network/services/hostapd/patches/819-ap-mld-refuse-an-association-while-a-link-is-not-started.patch",
    "scripts/check-shell-syntax.py",
    "target/linux/airoha/Makefile",
    "target/linux/airoha/an7581/config-7.4",
    "target/linux/airoha/an7581/target.mk",
    "target/linux/airoha/an7581/base-files/etc/board.d/05_compat-version",
    "target/linux/airoha/dts/an7581-xr1710g-ubi.dts",
    "target/linux/airoha/image/an7581.mk",
    "target/linux/airoha/patches-7.4/968-net-airoha-budget-aware-napi-complete.patch",
    "target/linux/generic/config-7.4",
    "target/linux/generic/other-files/init",
    "target/linux/generic/pending-7.4/100-compiler.h-only-include-asm-rwonce.h-for-kernel-code.patch",
)

# Paths intentionally untracked in git (so a fresh CI clone will not have them
# on disk), but still verified against the workflow's `paths:` triggers.
TRIGGER_ONLY_FILES = ("AGENTS.md",)
ALL_TRIGGERED_FILES = GUARDED_FILES + TRIGGER_ONLY_FILES


def load():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def triggers(data):
    return data.get("on") or data.get(True)


def glob_to_regex(pattern: str) -> re.Pattern:
    """Translate a GitHub Actions `paths:` glob into a fullmatch regex."""
    i = 0
    n = len(pattern)
    out = ["^"]
    while i < n:
        if pattern[i:i + 3] == "**/":
            out.append("(?:.*/)?")
            i += 3
        elif pattern[i:i + 2] == "**":
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    out.append("$")
    return re.compile("".join(out))


def matches_any_pattern(patterns, rel_path: str) -> bool:
    """Return True if GitHub Actions `paths:` patterns match `rel_path`."""
    matched = False
    for raw in patterns:
        if raw.startswith("!"):
            if glob_to_regex(raw[1:]).fullmatch(rel_path):
                matched = False
        else:
            if glob_to_regex(raw).fullmatch(rel_path):
                matched = True
    return matched


def path_filter_problems(data, guarded_files=ALL_TRIGGERED_FILES) -> list[str]:
    """Validate that shell-syntax.yml triggers cover every guarded suite input."""
    problems = []
    trig = triggers(data) or {}
    for event in ("pull_request", "push"):
        block = trig.get(event) or {}
        patterns = list(block.get("paths") or ())
        for rel_path in guarded_files:
            if not matches_any_pattern(patterns, rel_path):
                problems.append("%s does not match guarded file %r" % (event, rel_path))
    pr = list((trig.get("pull_request") or {}).get("paths") or ())
    push = list((trig.get("push") or {}).get("paths") or ())
    extra = sorted(set(push) - set(pr))
    if extra:
        problems.append("push paths wider than pull_request: %r" % (extra,))
    runs = [
        step.get("run", "")
        for job in (data.get("jobs") or {}).values()
        for step in job.get("steps", [])
    ]
    if not any("unittest discover -s scripts/tests" in run for run in runs):
        problems.append(
            "the Python suite step is gone; the path filter no longer gates it"
        )
    if not any(
        "check-test-cleanup-safety.py --strict-unknown" in run for run in runs
    ):
        problems.append(
            "check-test-cleanup-safety.py is not invoked with --strict-unknown"
        )
    return problems


def without_pr_pattern(text: str, pattern: str) -> str:
    """Delete one `- 'pattern'` line from the pull_request block only."""
    start = text.index("  pull_request:")
    end = text.index("\n  push:", start)
    block = text[start:end]
    hit = "      - '%s'\n" % pattern
    if hit not in block:
        return text
    return text[:start] + block.replace(hit, "") + text[end:]


class TriggerTest(unittest.TestCase):
    def setUp(self):
        self.data = load()

    def test_guarded_files_exist_in_repo(self):
        missing = [f for f in GUARDED_FILES if not (REPO_ROOT / f).is_file()]
        self.assertEqual(missing, [], "guarded test fixture paths missing from repo")
        if (REPO_ROOT / ".git").exists():
            proc = subprocess.run(
                ["git", "-C", str(REPO_ROOT), "ls-files", "--", *GUARDED_FILES],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            tracked = set(proc.stdout.splitlines())
            untracked = [f for f in GUARDED_FILES if f not in tracked]
            self.assertEqual(
                untracked, [],
                "GUARDED_FILES must contain only git-tracked files (put untracked "
                "paths in TRIGGER_ONLY_FILES so fresh CI clones pass)",
            )

    def test_all_guarded_files_run_the_suite(self):
        self.assertEqual(path_filter_problems(self.data), [])

    def test_the_suite_is_still_the_step_the_filter_gates(self):
        runs = [
            step.get("run", "")
            for job in self.data["jobs"].values()
            for step in job.get("steps", [])
        ]
        self.assertTrue(
            any("unittest discover -s scripts/tests" in run for run in runs),
            "the Python suite step is gone; the path filter no longer gates it",
        )
        self.assertTrue(
            any("check-test-cleanup-safety.py --strict-unknown" in run for run in runs),
            "cleanup-safety gate must run with --strict-unknown",
        )

    def test_push_list_is_not_wider_than_the_pr_list(self):
        pr = set(triggers(self.data)["pull_request"]["paths"])
        push = set(triggers(self.data)["push"]["paths"])
        self.assertEqual(sorted(push - pr), [],
                         "these filters only re-run on merge")

    def test_dropping_coverage_turns_validator_red(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        mutated = without_pr_pattern(text, "package/luci-app-airoha-flowsense/**")
        self.assertNotEqual(mutated, text)
        problems = path_filter_problems(yaml.safe_load(mutated))
        self.assertTrue(
            any(
                "pull_request" in p
                and "package/luci-app-airoha-flowsense/Makefile" in p
                for p in problems
            ),
            "path_filter_problems() did not catch lost flowsense coverage: %r"
            % (problems,),
        )


if __name__ == "__main__":
    unittest.main()
