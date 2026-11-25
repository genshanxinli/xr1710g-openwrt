#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""No prose may enter the index: .md lives in packages, not in this tree.

``34fa6cf5ee`` deleted the prose tree (19 files under ``docs/``, 7 under
``scripts/``, 3 under ``tools/``, 3 under ``.github/``) and
``scripts/tests/test_openwrt_pr_convergence.py:364`` keeps ``docs/`` and
``.github/upstream/`` from coming back.  Neither gate notices the shapes that
actually recurred on 2026-11-24: ``AGENTS.md`` at the root and a
``scripts/agent/`` working directory (four dispatch briefs plus two host
scripts) were one ``git add -A`` away from being committed, and ``git
add -An`` listed all seven.

What is asserted, against the index -- so a staged ``git add`` is caught
before the commit exists:

  * nothing under ``scripts/agent/``: that is where agent scratch piles up,
    and the path collides with the abandoned ``scripts/agent/recovb12`` tree
    in ``7a99ea1c97``;
  * no prose file at the repository root except ``README.md``;
  * no prose file under ``scripts/``, ``tools/``, ``.github/research/`` or
    ``.github/upstream/`` -- the four directories ``34fa6cf5ee`` emptied.

``package/**/*.md`` stays legal: those are inherited package documents
(22 files: ``README.md``, ``CHANGELOG.md``, ``CONTRIBUTING.md``,
``package/luci-app-appflow/docs/*.md``), and ``.github/llm-review-rules.md``
is a reviewed rule file.  ``target/**`` and ``local-feed/**`` prose is
upstream content and is not in a guarded prefix either.  A prose file added
outside the guarded directories is this test's known ceiling.

An untracked ``AGENTS.md`` is legal and expected: the harness reads it from
the workspace root and ``test_agents_md_references.py`` guards its content.
This test reads the index, never the worktree, so the file's presence on disk
cannot fail it; only ``git add AGENTS.md`` does.

Red half: feed a bad index instead of the real one.

    printf 'AGENTS.md\\nscripts/agent/brief.md\\nNotes.MD\\n' > /tmp/bad.index
    NO_PROSE_INDEX_UNDER_TEST=/tmp/bad.index \\
        python3 -m unittest scripts.tests.test_no_prose_docs -v

  -> three violations (root document, agent working directory, case-folded
  ``.MD``); the same command without the variable -> ok.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

PROSE_SUFFIXES = (".md", ".markdown", ".rst", ".adoc")
ROOT_ALLOWED = {"README.md"}
PROSE_DIRS = ("scripts/", "tools/", ".github/research/", ".github/upstream/")
BANNED_DIRS = ("scripts/agent/",)


def _index_paths() -> list[str]:
    override = os.environ.get("NO_PROSE_INDEX_UNDER_TEST")
    if override:
        text = Path(override).read_text(encoding="utf-8")
        return [line.strip() for line in text.splitlines() if line.strip()]
    listed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    if listed.returncode:
        raise unittest.SkipTest(f"git ls-files failed: {listed.stderr.strip()}")
    return [name for name in listed.stdout.split("\0") if name]


def _violations(paths: list[str]) -> list[tuple[str, str]]:
    found = []
    for path in paths:
        name = path.rsplit("/", 1)[-1]
        lower = name.lower()
        if path.startswith(BANNED_DIRS):
            found.append((path, "agent working directory, not repo content"))
        elif lower.endswith(PROSE_SUFFIXES) and "/" not in path and name not in ROOT_ALLOWED:
            found.append((path, "the root carries one document: README.md"))
        elif lower.endswith(PROSE_SUFFIXES) and path.startswith(PROSE_DIRS):
            found.append((path, "34fa6cf5ee emptied the prose from here"))
    return found


class NoProseDocsTest(unittest.TestCase):
    def test_no_prose_is_committed(self) -> None:
        paths = _index_paths()
        if not os.environ.get("NO_PROSE_INDEX_UNDER_TEST"):
            # A reader that returned nothing would make the loop below pass.
            self.assertIn("README.md", paths, "index reader returned nothing useful")
        bad = _violations(paths)
        self.assertEqual(
            [],
            bad,
            "prose or agent files entered the index: "
            + "; ".join(f"{path} ({why})" for path, why in bad),
        )


if __name__ == "__main__":
    unittest.main()
