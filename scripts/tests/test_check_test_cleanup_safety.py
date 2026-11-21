#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The cleanup-safety gate must refuse the accident shape, and stay quiet otherwise.

`scripts/check-test-cleanup-safety.py` is a static gate over the test suite,
so the only way to trust it is to feed it fixtures it must refuse and fixtures
it must accept.  A gate nobody red-tested is the same "it looked fine when I
read it" that let `shutil.rmtree(record.parent)` through in the first place.

  | # | fixture                                             | expect        |
  |---|-----------------------------------------------------|---------------|
  | 1 | `tmp = tempfile.mkdtemp(); shutil.rmtree(tmp)`      | rc 0          |
  | 2 | `shutil.rmtree(Path(x).parents[1])`                 | rc 1, line no |
  | 3 | `shutil.rmtree(self.record.parent)`                 | rc 1, line no |
  | 4 | `shutil.rmtree(mystery)`                            | rc 0, unknown |
  | 5 | the real scripts/tests tree                          | rc 0          |

Run from the repository root:

    python3 scripts/tests/test_check_test_cleanup_safety.py

Set TEST_CLEANUP_GATE to check a different copy of the gate.
"""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GATE = Path(
    os.environ.get("TEST_CLEANUP_GATE", REPO_ROOT / "scripts/check-test-cleanup-safety.py")
)


def run_gate(*paths: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(GATE), *[str(path) for path in paths]],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def rmtree_line(path: Path) -> int:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if "rmtree(" in line:
            return number
    raise AssertionError(f"fixture at {path} has no rmtree call")


class GateTest(unittest.TestCase):
    def setUp(self):
        self.sandbox = Path(tempfile.mkdtemp(prefix="cleanup-safety-test."))
        self.addCleanup(shutil.rmtree, self.sandbox, True)

    def write_fixture(self, source: str) -> Path:
        tests = self.sandbox / "scripts" / "tests"
        tests.mkdir(parents=True, exist_ok=True)
        path = tests / "fixture_case.py"
        path.write_text(textwrap.dedent(source).lstrip())
        return path

    def test_allows_the_directory_the_test_made(self):
        path = self.write_fixture(
            """
            import shutil
            import tempfile

            tmp = tempfile.mkdtemp(prefix="run.")
            self.addCleanup(shutil.rmtree, tmp, True)
            """
        )
        result = run_gate(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 violations", result.stdout)

    def test_refuses_a_parents_index(self):
        path = self.write_fixture(
            """
            import shutil
            from pathlib import Path

            shutil.rmtree(Path("/tmp/result.json").parents[1])
            """
        )
        result = run_gate(path)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"::error file={path},line={rmtree_line(path)}::", result.stdout)
        self.assertIn("parents[N]", result.stdout)

    def test_refuses_a_path_taken_from_the_program_under_test(self):
        path = self.write_fixture(
            """
            import shutil


            class Case:
                def tearDown(self):
                    shutil.rmtree(self.record.parent)
            """
        )
        result = run_gate(path)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"::error file={path},line={rmtree_line(path)}::", result.stdout)
        self.assertIn("record", result.stdout)

    def test_an_unrecognised_name_is_reported_not_refused(self):
        path = self.write_fixture(
            """
            import shutil

            shutil.rmtree(mystery)
            """
        )
        result = run_gate(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 unknown", result.stdout)
        self.assertIn(f"unknown: {path}:", result.stdout)

    def test_the_real_test_suite_is_clean(self):
        result = run_gate(REPO_ROOT / "scripts/tests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 violations", result.stdout)


if __name__ == "__main__":
    unittest.main()
