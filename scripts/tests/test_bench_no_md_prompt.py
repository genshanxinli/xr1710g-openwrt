"""Scripts must not ask the user to maintain prose records (#13).

The repo holds no authored prose: a benchmark run is recorded as
``scripts/perf-baselines/<run>/result.json`` and cited from
``scripts/claims.yaml``.  A script that prints "commit this file as
scripts/perf-baselines/<run>.md before citing it" drags the prose back in.

Rule: a ``.md`` name may be mentioned only if the same file also writes that
name (a runtime artifact such as ``$RESULT_DIR/baseline.md``); any other
mention is a prompt for the user to create a document and fails.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ROOTS = ("scripts", "tools", ".github")
SUFFIXES = (".sh", ".bash", ".py")
SKIP_PREFIX = ("scripts/tests",)  # test fixtures write throwaway README.md files
MD_MENTION = re.compile(r"([A-Za-z0-9_.$%{}~/-]+\.md)(?![A-Za-z0-9_.])")
WRITE_MARKERS = ("mv ", "cp ", ">", "open(", ".write(", "install ")


def _basename(token: str) -> str:
    return token.rsplit("/", 1)[-1]


def _scanned_files() -> list[Path]:
    found = []
    for root in ROOTS:
        base = REPO / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.suffix not in SUFFIXES:
                continue
            rel = path.relative_to(REPO).as_posix()
            if rel.startswith(SKIP_PREFIX):
                continue
            found.append(path)
    return found


def _written_md_names(lines: list[str]) -> set[str]:
    written = set()
    for line in lines:
        if not any(marker in line for marker in WRITE_MARKERS):
            continue
        for token in MD_MENTION.findall(line):
            written.add(_basename(token))
    return written


def _md_prompt_mentions(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    written = _written_md_names(lines)
    bad = []
    for number, line in enumerate(lines, 1):
        for token in MD_MENTION.findall(line):
            name = _basename(token)
            if not any(w.startswith(name) for w in written):
                bad.append((number, token))
    return bad


class BenchNoMdPromptTest(unittest.TestCase):
    def test_no_script_asks_for_a_markdown_record(self):
        violations = {}
        for path in _scanned_files():
            bad = _md_prompt_mentions(path)
            if bad:
                violations[path.relative_to(REPO).as_posix()] = bad
        self.assertEqual(
            {},
            violations,
            "scripts still ask the user to create .md documents: "
            f"{violations}",
        )


if __name__ == "__main__":
    unittest.main()
