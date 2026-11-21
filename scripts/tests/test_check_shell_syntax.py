#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The shell syntax sweep must use the interpreter each file's shebang names.

`sh -n` rejects bash-only syntax at parse time, so a repo-wide `sh -n` scan
reports three healthy scripts (a `;&` fallthrough, `declare -A`, an array
literal) as broken forever.  The fix is not a whitelist -- the sweep in
scripts/check-shell-syntax.py dispatches on the shebang.  This test pins that
dispatch down:

  | # | case                                   | expect                        |
  |---|----------------------------------------|-------------------------------|
  | 1 | scripts/getver.sh (bash, `;&`)          | rc 0 via bash -n, rc 2 via sh |
  | 2 | tools/.../build-eagle-v4.sh (bash, [])  | rc 0 via bash -n, rc 2 via sh |
  | 3 | scripts/pppoe-decap-hw-bench.sh         | rc 0 (shebang is bash)        |
  | 4 | broken bash fixture                     | rc 1                          |
  | 5 | broken POSIX fixture                    | rc 1                          |
  | 6 | ucode shebang                           | skipped, rc 0                 |
  | 7 | the real tree                           | rc 0                          |

Run from the repository root:

    python3 scripts/tests/test_check_shell_syntax.py
"""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GATE = Path(os.environ.get("SHELL_SYNTAX_GATE", REPO_ROOT / "scripts/check-shell-syntax.py"))

# Files that a repo-wide `sh -n` sweep reports as broken although each one
# parses cleanly under the interpreter its shebang names.
BASH_SHEBANG_SCRIPTS = (
    "scripts/getver.sh",
    "tools/npu-firmware/build-eagle-v4.sh",
    "scripts/pppoe-decap-hw-bench.sh",
)


def run_gate(*paths: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(GATE), *paths],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


class DispatcherTest(unittest.TestCase):
    def test_each_named_script_parses_under_its_own_shebang(self):
        for name in BASH_SHEBANG_SCRIPTS:
            with self.subTest(script=name):
                result = run_gate(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("0 failed", result.stdout)

    def test_sh_would_still_reject_two_of_them(self):
        """The point of the dispatch: `sh -n` alone is the wrong question."""
        if shutil.which("sh") is None:
            self.skipTest("sh is required")
        for name in BASH_SHEBANG_SCRIPTS[:2]:
            with self.subTest(script=name):
                direct = subprocess.run(
                    ["sh", "-n", name], capture_output=True, text=True, check=False
                )
                self.assertNotEqual(
                    direct.returncode,
                    0,
                    f"sh -n unexpectedly accepts {name}; the dispatch test no longer "
                    "proves anything, pick another bash-only fixture",
                )

    def test_broken_bash_script_is_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            broken = Path(tmp, "broken.sh")
            broken.write_text(
                "#!/usr/bin/env bash\nif true; then\n\techo hi\n", encoding="utf-8"
            )
            result = run_gate(str(broken))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("bash -n", result.stderr)
            self.assertIn("FAILED", result.stdout)

    def test_broken_posix_script_is_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            broken = Path(tmp, "broken.sh")
            broken.write_text("#!/bin/sh\nif true\n\techo hi\nfi\n", encoding="utf-8")
            result = run_gate(str(broken))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("sh -n", result.stderr)

    def test_bash_only_body_behind_a_bash_shebang_is_green(self):
        """Decisive dispatch check: this body is a syntax error under dash."""
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp, "array.sh")
            script.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    declare -A MAP=([a]=1)
                    arr=(one two)
                    case x in
                    a) echo a ;&
                    b) echo b ;;
                    esac
                    """
                ),
                encoding="utf-8",
            )
            result = run_gate(str(script))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 parsed", result.stdout)

    def test_non_shell_interpreter_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp, "wireless.sh")
            script.write_text(
                "#!/usr/bin/ucode\nfunction phy_suffix(radio, sep) {\n}\n", encoding="utf-8"
            )
            result = run_gate(str(script))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 skipped", result.stdout)
            self.assertIn("0 parsed", result.stdout)

    def test_repository_sweep_is_green(self):
        result = run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
