#!/usr/bin/env python3
"""Every reference in scripts/claims.yaml must resolve to real evidence.

scripts/check-claims.py and scripts/claims-verify.py both re-read cited
``path:line`` entries, but only for rows that carry a ``verify:`` hook; a row
with no hook (``refuted``/``unverified``) returns early and its sources are
never touched.  That is how a row can keep pointing at a deleted file, at a
blank line, or at a line that moved onto unrelated text while every gate stays
green.

This test closes that hole at the reference level:

  source   URL -> skipped (needs the network).
           path[:line] -> the path must exist; with a line, the line must be
           inside the file and must hold something other than whitespace or a
           bare comment separator.  A citation is evidence, not a marker.
  verify   text: path[:line] SUBSTRING -> path, line range and the exact
           substring must hold.
           kconfig:/symbol: with a repo path -> the path must exist; a glob is
           a build artifact (build_dir/**) and is skipped.
           device: -> sysfs/debugfs path on the box, skipped.

Run from the repository root:

    python3 -m unittest scripts/tests/test_claims_sources_exist.py
"""

import importlib.util
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LEDGER = REPO_ROOT / "scripts" / "claims.yaml"

URL_RE = re.compile(r"^https?://")
FILE_LINE_RE = re.compile(r"^([^\s:][^:]*):(\d+)$")
GLOB_RE = re.compile(r"[*?[]")
# A line that is only comment punctuation still "exists" but is not evidence.
MARKER_RE = re.compile(r"^(?:[#*/;\-]{1,4}|--)\s*$")


def _load_checker():
    path = REPO_ROOT / "scripts" / "check-claims.py"
    spec = importlib.util.spec_from_file_location("check_claims", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ClaimsReferencesExist(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.records = _load_checker().parse_ledger(LEDGER.read_text(encoding="utf-8"))

    def _line(self, path_text: str, line_no: int) -> str | None:
        path = REPO_ROOT / path_text
        if not path.is_file():
            return None
        lines = path.read_bytes().splitlines()
        if line_no < 1 or line_no > len(lines):
            return None
        return lines[line_no - 1].decode("utf-8", "replace")

    def test_sources_resolve(self):
        problems = []
        for record in self.records:
            for value in record.get("source") or []:
                value = value.strip()
                if URL_RE.match(value):
                    continue
                match = FILE_LINE_RE.fullmatch(value)
                if not match:
                    if not (REPO_ROOT / value).is_file():
                        problems.append(f"{record.get('id')}: source missing: {value}")
                    continue
                path_text, line_no = match.group(1), int(match.group(2))
                text = self._line(path_text, line_no)
                if text is None:
                    problems.append(
                        f"{record.get('id')}: source {value} does not resolve "
                        "(missing path or line out of range)"
                    )
                elif not text.strip() or MARKER_RE.match(text.strip()):
                    problems.append(
                        f"{record.get('id')}: source {value} cites a blank/marker "
                        f"line, not evidence ({text.strip()[:40]!r})"
                    )
        self.assertEqual(problems, [], "\n".join(problems))

    def test_verify_references_resolve(self):
        problems = []
        for record in self.records:
            for item in record.get("verify") or []:
                verb, _, rest = item.strip().partition(" ")
                verb = verb.rstrip(":").lower()
                rest = rest.strip()
                if verb in ("device", "symbol"):
                    continue  # box path / build artifact glob
                if verb == "kconfig":
                    path_text = rest.partition(" ")[0]
                    if GLOB_RE.search(path_text):
                        continue
                    if not (REPO_ROOT / path_text).is_file():
                        problems.append(f"{record.get('id')}: kconfig path missing: {path_text}")
                    continue
                if verb != "text":
                    problems.append(f"{record.get('id')}: unknown verify verb: {item!r}")
                    continue
                head, _, substring = rest.partition(" ")
                match = FILE_LINE_RE.fullmatch(head)
                path_text, line_no = (match.group(1), int(match.group(2))) if match else (head, None)
                path = REPO_ROOT / path_text
                if not path.is_file():
                    problems.append(f"{record.get('id')}: text path missing: {path_text}")
                    continue
                if not substring:
                    problems.append(f"{record.get('id')}: text assertion has no substring: {item!r}")
                    continue
                if line_no is None:
                    haystack = path.read_bytes()
                    where = path_text
                else:
                    text = self._line(path_text, line_no)
                    if text is None:
                        problems.append(
                            f"{record.get('id')}: text {path_text}:{line_no} out of range"
                        )
                        continue
                    haystack = text.encode()
                    where = f"{path_text}:{line_no}"
                if substring.encode() not in haystack:
                    problems.append(
                        f"{record.get('id')}: {where} lacks {substring!r}"
                    )
        self.assertEqual(problems, [], "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
