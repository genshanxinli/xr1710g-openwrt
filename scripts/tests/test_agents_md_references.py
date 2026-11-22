#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""AGENTS.md may not point at the prose the tree deleted.

``docs/`` was removed in ``34fa6cf5ee`` and
``scripts/tests/test_openwrt_pr_convergence.py:364`` keeps it out, so a pointer
to ``docs/agents/*.md`` or ``docs/adr/`` is dangling by construction: the file
it names cannot exist while that gate is green.  The same goes for a
``path:line`` citation whose path has moved or whose line is blank -- a
citation is evidence, not a marker.

What is asserted, offline and with no third-party dependency:

  * no ``docs/`` token followed by a name (``docs/agents/``, ``docs/adr/``,
    ``docs/MTU-POLICY.md``).  A bare ``docs/`` stays legal: prose about the
    deletion has to be able to name the directory it deleted.
  * every path token on a line that does not assert absence exists under the
    repo root; ``path:line`` additionally names a line that exists and holds
    something other than whitespace.  An absence claim ("X 不存在", "删掉") is
    exempt, because naming a deleted file is the point of such a line.
  * an absent AGENTS.md is skipped, not failed: the file is a local harness
    artifact and a fresh clone has none.

Red half: copy AGENTS.md, put ``docs/agents/issue-tracker.md`` and
``README.md:9999`` back into the copy, run with ``AGENTS_MD_PATH`` pointing at
it -> both assertions fail on those tokens; run again against the real file ->
green.

Run from the repository root:

    python3 scripts/tests/test_agents_md_references.py
    AGENTS_MD_PATH=/home/l1n/projects/.scratch/agentsmd/AGENTS.md.broken \\
        python3 scripts/tests/test_agents_md_references.py
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_MD = Path(os.environ.get("AGENTS_MD_PATH") or REPO_ROOT / "AGENTS.md")

# A bare "docs/" is prose about the deletion; "docs/<name>" is a live pointer.
DELETED_DOCS_RE = re.compile(r"docs/[A-Za-z0-9_.\-]")
# A line carrying an absence claim is allowed to name what is gone.
ABSENCE_RE = re.compile(r"不存在|没有|删掉|已删|removed|deleted")
PATH_RE = re.compile(
    r"[A-Za-z0-9_./-]+\.[A-Za-z0-9]+(?::\d+)?"
)
CHECKED_SUFFIXES = ("py", "sh", "md", "yaml", "yml", "json", "mk", "toml")


def read_agents_md():
    with AGENTS_MD.open(encoding="utf-8") as handle:
        return handle.read()


def checked_tokens(line):
    """Path-looking tokens on a line, with an optional :line suffix."""
    for match in PATH_RE.finditer(line):
        token = match.group(0)
        if token.rsplit(".", 1)[-1].split(":")[0] not in CHECKED_SUFFIXES:
            continue
        if token.startswith("/") and not (REPO_ROOT / token.lstrip("/")).exists():
            continue  # absolute path outside the tree, e.g. a scratch dir
        yield token


class AgentsMdCitationTest(unittest.TestCase):
    def setUp(self):
        if not AGENTS_MD.exists():
            self.skipTest("no AGENTS.md at %s" % AGENTS_MD)
        self.text = read_agents_md()

    def test_no_pointer_into_the_deleted_docs_tree(self):
        hits = [
            (number, line.strip())
            for number, line in enumerate(self.text.splitlines(), 1)
            if DELETED_DOCS_RE.search(line)
        ]
        self.assertEqual(
            hits,
            [],
            "AGENTS.md names a path inside the deleted docs/ tree (34fa6cf5ee "
            "removed it; scripts/tests/test_openwrt_pr_convergence.py:364 keeps "
            "it out): %r" % (hits,),
        )

    def test_every_cited_path_and_line_exists(self):
        missing = []
        for number, line in enumerate(self.text.splitlines(), 1):
            if ABSENCE_RE.search(line):
                continue
            for token in checked_tokens(line):
                path, _, cited = token.partition(":")
                target = REPO_ROOT / path.lstrip("./")
                if not target.is_file():
                    missing.append("%d: %s" % (number, token))
                    continue
                if not cited:
                    continue
                lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
                at = int(cited)
                if at < 1 or at > len(lines):
                    missing.append("%d: %s (no such line)" % (number, token))
                elif not lines[at - 1].strip():
                    missing.append("%d: %s (blank line)" % (number, token))
        self.assertEqual(
            missing,
            [],
            "AGENTS.md cites paths or lines that are not there: %r" % (missing,),
        )


if __name__ == "__main__":
    unittest.main()
