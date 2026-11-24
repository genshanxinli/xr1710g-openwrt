#!/usr/bin/env python3
"""Red half for P1-8: a drift check that cannot run must say why.

``needs_reverify()`` used to return ``None`` both for "nothing moved" and for
"could not tell".  A shallow CI checkout (fetch-depth 1) and a row whose only
sources are URLs both fell into the second case, so the warning that exists to
catch stale evidence was silent exactly where it was needed.

Red half: point ``CLAIMS_VERIFY_UNDER_TEST`` at a copy of the pre-fix script and
run this file; the two ``assertIsNotNone`` cases fail with the reason swallowed.

Usage: python3 -m unittest scripts/tests/test_claims_verify_shallow.py
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
VERIFY = REPO / "scripts" / "claims-verify.py"

GIT = ["git", "-c", "user.email=test@example.com", "-c", "user.name=test",
       "-c", "commit.gpgsign=false"]


def load_verify():
    path = Path(os.environ.get("CLAIMS_VERIFY_UNDER_TEST") or VERIFY)
    spec = importlib.util.spec_from_file_location("claims_verify_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root, *args):
    result = subprocess.run([*GIT, "-C", str(root), *args],
                            capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed: {result.stderr}")
    return result.stdout


def commit_file(root, name, text):
    (Path(root) / name).write_text(text)
    git(root, "add", name)
    git(root, "commit", "-q", "-m", text.strip())
    return git(root, "rev-parse", "HEAD").strip()


class NeedsReverifyReasonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verify = load_verify()

    def test_shallow_clone_cannot_be_diffed_and_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            src.mkdir()
            git(src, "init", "-q")
            old = commit_file(src, "evidence.txt", "one\n")
            commit_file(src, "evidence.txt", "two\n")
            shallow = Path(tmp) / "shallow"
            subprocess.run(["git", "clone", "-q", "--depth", "1",
                            src.resolve().as_uri(), str(shallow)],
                           check=True, capture_output=True, timeout=120)
            self.assertEqual(git(shallow, "rev-parse", "--is-shallow-repository").strip(), "true")
            self.assertNotIn(old, git(shallow, "rev-list", "--all"))

            record = {"id": "shallow", "source": ["evidence.txt:1"], "verified_at": old}
            reason = self.verify.needs_reverify(record, shallow, None)

            self.assertIsNotNone(reason, "shallow clone must not read as 'no drift'")
            self.assertIn("shallow", reason.lower())
            self.assertIn(old, reason)

    def test_url_only_source_names_the_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            record = {
                "id": "url-only",
                "source": ["https://github.com/genshanxinli/xr1710g-openwrt/issues/191"],
                "verified_at": "0123456789abcdef0123456789abcdef01234567",
            }
            reason = self.verify.needs_reverify(record, Path(tmp), None)

            self.assertIsNotNone(reason, "URL-only evidence must not read as 'no drift'")
            self.assertIn("in-tree", reason)

    def test_full_history_unchanged_path_is_quiet(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            root.mkdir()
            git(root, "init", "-q")
            old = commit_file(root, "evidence.txt", "one\n")
            commit_file(root, "other.txt", "two\n")

            record = {"id": "quiet", "source": ["evidence.txt:1"], "verified_at": old}
            self.assertIsNone(self.verify.needs_reverify(record, root, None))

    def test_full_history_changed_path_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            root.mkdir()
            git(root, "init", "-q")
            old = commit_file(root, "evidence.txt", "one\n")
            commit_file(root, "evidence.txt", "two\n")

            record = {"id": "moved", "source": ["evidence.txt:1"], "verified_at": old}
            reason = self.verify.needs_reverify(record, root, None)

            self.assertIsNotNone(reason)
            self.assertIn("evidence.txt", reason)


if __name__ == "__main__":
    unittest.main(verbosity=2)
